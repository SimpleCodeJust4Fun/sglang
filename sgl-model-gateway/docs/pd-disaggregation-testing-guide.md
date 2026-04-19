# SGLang Model Gateway — PD 分离架构测试指南

本文档介绍如何测试 sgl-model-gateway 在 Prefill-Decode (PD) 分离架构下的请求分发能力，涵盖 macOS 本地调试和 Windows + WSL2 + GPU 真实部署两种环境。

---

## 背景：PD 分离的核心工作原理

PD 分离（Prefill-Decode Disaggregation）将 LLM 推理拆分为两个阶段，分别由不同的 GPU Pod 执行：

- **Prefill Worker**：负责处理输入 prompt 的前向计算，生成 KV Cache
- **Decode Worker**：接收 KV Cache，执行自回归解码，逐 token 生成输出

Gateway 作为中间的路由控制面，负责协调这两类 Worker 的请求分发。

### 请求分发流程
```
用户请求 → Gateway (PDRouter)
              │
              ├─ 1. 通过 PolicyRegistry 选择一个 Prefill Worker
              │     (支持 Random / RoundRobin / PowerOfTwo / CacheAware / Bucket 策略)
              │
              ├─ 2. 通过 PolicyRegistry 选择一个 Decode Worker
              │
              ├─ 3. 注入 bootstrap 信息到请求体:
              │     {
              │       ...原始请求...,
              │       "bootstrap_host": <prefill_worker_ip>,
              │       "bootstrap_port": <prefill_worker_bootstrap_port>,
              │       "bootstrap_room": <随机 room_id>
              │     }
              │
              ├─ 4. 将修改后的请求发送给 Prefill Worker
              │     Prefill Worker 完成 prefill 后，通过 bootstrap 通道
              │     把 KV Cache 传输给 Decode Worker
              │
              └─ 5. 将原始请求也发送给 Decode Worker
                    Decode Worker 等待 KV Cache 到达后开始 decode
                    最终响应返回给用户
```

> **核心结论（建议记住）**：  
> 策略主要影响 **PD pair 的产生过程**（Prefill/Decode 各自如何被选中）；  
> pair 一旦确定，后续执行链路（bootstrap 注入、并发双发、容错重试、响应组装）在各策略下基本一致。

### 关键源码位置

| 文件 | 方法/结构体 | 作用 |
|------|-------------|------|
| `src/routers/http/pd_router.rs` | `PDRouter::execute_dual_dispatch` | **核心入口**：PD 双路由分发 |
| `src/routers/http/pd_router.rs` | `inject_bootstrap_into_value` | 注入 bootstrap 信息到请求体 |
| `src/routers/http/pd_types.rs` | `generate_room_id` | 生成 KV Cache 传输的房间号 |
| `src/routers/grpc/pd_router.rs` | `GrpcPDRouter` | gRPC 模式下的 PD 路由 |
| `src/policies/mod.rs` | `LoadBalancingPolicy::select_worker` | 负载均衡策略选择 Worker |
| `src/core/worker_registry.rs` | `WorkerRegistry` | Worker 注册与管理 |
| `src/routers/factory.rs` | `RouterFactory::create_pd_router` | PD Router 的创建和策略注入 |
| `src/main.rs` | `to_router_config` | CLI 参数解析，`--pd-disaggregation` 入口 |

---

## 前置准备

### 1. 升级 Rust 工具链

项目依赖要求 rustc ≥ 1.88.0：

```bash
rustup update stable
rustc --version  # 确认 ≥ 1.88.0
```

### 2. 配置调试符号（RustRover 调试用）

编辑 `sgl-model-gateway/Cargo.toml`，确保 `[profile.dev]` 中 `debug = 2`：

```toml
[profile.dev]
opt-level = 0
debug = 2              # 完整调试信息，支持查看变量值
split-debuginfo = "unpacked"
incremental = true
codegen-units = 256
```

> **注意**：`debug = 1` 只有行号信息，调试器无法显示变量值。

### 3. 编译项目

```bash
cd sgl-model-gateway
cargo build
```

---

## 测试方式一：运行内置单元测试（推荐入门）

项目内置了完善的 Mock Worker 测试基础设施，**完全不需要 GPU**。`MockWorker` 会在本地启动模拟的 Prefill/Decode HTTP 服务，Gateway 像连接真实 GPU Pod 一样连接它们。

### 运行所有 PD 相关测试

```bash
cd sgl-model-gateway
cargo test --test routing_tests pd -- --nocapture
```

### 核心测试用例

| 测试函数 | 文件 | 测试内容 |
|----------|------|----------|
| `test_pd_mode_basic_routing` | `tests/routing/pd_routing_test.rs` | 基本的 Prefill+Decode 双路由分发 |
| `test_pd_mode_round_robin` | `tests/routing/pd_routing_test.rs` | RoundRobin 策略下的 PD 分发 |
| `test_pd_mode_with_failing_decode_worker` | `tests/routing/pd_routing_test.rs` | Decode 节点故障时的重试和容错 |
| `test_worker_types` | `tests/routing/test_pd_routing.rs` | Worker 类型（Prefill/Decode/Regular）验证 |
| `test_pd_selection_policies` | `tests/routing/test_pd_routing.rs` | PD 选择策略枚举验证 |

### 在 RustRover 中调试

1. 打开测试文件（如 `tests/routing/pd_routing_test.rs`）
2. 在测试函数名旁点击绿色箭头 → 选择 **Debug**
3. 推荐断点位置：
   - `src/routers/http/pd_router.rs` → `execute_dual_dispatch` 方法入口
   - `src/routers/http/pd_router.rs` → `inject_bootstrap_into_value` — 观察 bootstrap 信息注入
   - `src/policies/` 下的 `select_worker` — 观察负载均衡策略如何选择 Worker

---

## 测试方式二：本地启动 Gateway + Mock Worker（深入理解）

手动启动 Gateway 二进制，配合模拟 Worker 来观察真实的 PD 请求分发行为。**不需要 GPU**。

### 步骤 1：创建 Mock Worker 脚本

创建 `mock_worker.py`：

```python
from fastapi import FastAPI, Request
import uvicorn
import json
import sys

app = FastAPI()
worker_name = sys.argv[2] if len(sys.argv) > 2 else "worker"

@app.get("/health")
async def health():
    return {"status": "healthy"}

@app.get("/health_generate")
async def health_generate():
    return {"status": "healthy"}

@app.get("/get_model_info")
async def model_info():
    return {"model_path": "mock-model", "is_generation": True}

@app.get("/v1/models")
async def models():
    return {"data": [{"id": "mock-model", "object": "model"}]}

@app.post("/generate")
async def generate(request: Request):
    body = await request.json()
    print(f"\n[{worker_name}] Received request:")
    print(json.dumps(body, indent=2))

    # 检查是否包含 bootstrap 信息（PD 模式的标志）
    if "bootstrap_host" in body:
        print(f"[{worker_name}] Bootstrap info detected:")
        print(f"  host: {body.get('bootstrap_host')}")
        print(f"  port: {body.get('bootstrap_port')}")
        print(f"  room: {body.get('bootstrap_room')}")

    return {"text": f"Response from {worker_name}", "meta_info": {"id": "test-123"}}

@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    body = await request.json()
    print(f"\n[{worker_name}] Chat request:")
    print(json.dumps(body, indent=2))
    return {
        "id": "chatcmpl-test",
        "object": "chat.completion",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": f"Hello from {worker_name}"},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
    }

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8100
    print(f"Starting {worker_name} on port {port}")
    uvicorn.run(app, host="127.0.0.1", port=port)
```

### 步骤 2：安装 Python 依赖

```bash
pip install fastapi uvicorn
```

### 步骤 3：启动测试环境

打开 4 个终端窗口：

```bash
# 终端 1: 启动 Prefill Worker
python mock_worker.py 8100 prefill-worker-1

# 终端 2: 启动 Decode Worker 1
python mock_worker.py 8200 decode-worker-1

# 终端 3: 启动 Decode Worker 2
python mock_worker.py 8201 decode-worker-2

# 终端 4: 启动 Gateway（PD 模式）
cd sgl-model-gateway
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:8100 \
  --decode http://127.0.0.1:8200 \
  --decode http://127.0.0.1:8201 \
  --host 127.0.0.1 \
  --port 3000 \
  --policy round_robin
```

### 步骤 4：发送测试请求

```bash
# 发送 generate 请求
curl -s -X POST http://127.0.0.1:3000/generate \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello world", "stream": false}' | python -m json.tool

# 发送 chat completion 请求
curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mock-model",
    "messages": [{"role": "user", "content": "What is PD disaggregation?"}],
    "stream": false
  }' | python -m json.tool

# 批量发送请求，观察负载均衡效果
for i in $(seq 1 10); do
  curl -s -X POST http://127.0.0.1:3000/generate \
    -H "Content-Type: application/json" \
    -d "{\"text\": \"Request $i\", \"stream\": false}" &
done
wait
```

### 观察要点

在 Mock Worker 的终端输出中，重点关注：

1. **bootstrap 信息**：Gateway 注入的 `bootstrap_host`、`bootstrap_port`、`bootstrap_room` 字段
2. **请求分发**：哪些请求发到了 Prefill Worker，哪些发到了 Decode Worker
3. **负载均衡**：多个 Decode Worker 之间的请求分布是否均匀

---

## 专项实战：`cache_aware` 策略（复杂且实用）

`cache_aware` 是项目里非常值得学习的策略：它不是纯粹“最小负载”或“轮询”，而是**缓存亲和 + 负载保护**的混合决策。

### 策略核心思想

在 `src/policies/cache_aware.rs` 中，策略会动态切换两种路径：

1. **负载不均衡** -> 走最小负载（shortest queue）
2. **负载相对均衡** -> 走前缀缓存亲和（prefix match）

不均衡判断条件（同时满足）：

- `(max_load - min_load) > balance_abs_threshold`
- `max_load > min_load * balance_rel_threshold`

如果走缓存亲和路径：

- 先算 `match_rate = matched_prefix_chars / input_chars`
- 若 `match_rate > cache_threshold`，选最匹配的 worker
- 否则回退到低负载 worker

> 这就是“先稳住系统，再追求命中”的工程思路。

### 它判断时依赖的数据从哪里来

1. **请求文本** `request_text`
   - 来源：router 在调用 policy 时传入 `SelectWorkerInfo.request_text`
   - 用途：做 prefix 匹配

2. **worker 实时负载** `worker.load()`
   - 来源：gateway 侧 worker 负载计数
   - 用途：判断不均衡、选最小负载 worker

3. **worker 可用性**
   - 来源：健康状态 + 熔断状态（`is_healthy && circuit.can_execute`）
   - 用途：过滤不可选节点

4. **近似缓存树（按 model 维护）**
   - 来源：策略内部 `Tree` 结构，基于历史请求增量更新
   - 用途：估计哪个 worker 更可能命中缓存（不是直接读取 GPU KV 实际命中）

5. **策略参数**
   - 来源：CLI/配置（`--cache-threshold`、`--balance-abs-threshold`、`--balance-rel-threshold`、`--eviction-interval`、`--max-tree-size`）

### 用 Mock Server 调试 `cache_aware`（可复现）

下面给出一套最小实验，直接复用“测试方式二”的 `mock_worker.py`。

#### 步骤 1：按测试方式二启动 1 个 prefill + 2 个 decode

同前文，不再重复。

#### 步骤 2：Gateway 改为 `cache_aware`

```bash
cd sgl-model-gateway
RUST_LOG=smg::policies::cache_aware=debug,smg::routers::http::pd_router=debug \
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:8100 \
  --decode http://127.0.0.1:8200 \
  --decode http://127.0.0.1:8201 \
  --host 127.0.0.1 \
  --port 3000 \
  --policy cache_aware \
  --cache-threshold 0.5 \
  --balance-abs-threshold 4 \
  --balance-rel-threshold 1.2 \
  --eviction-interval 30 \
  --max-tree-size 10000
```

#### 步骤 3：设计“可验证策略行为”的请求集

```bash
# A组：高相似请求（预期逐步出现缓存亲和）
for i in $(seq 1 8); do
  curl -s -X POST http://127.0.0.1:3000/generate \
    -H "Content-Type: application/json" \
    -d '{"text":"Explain PD routing architecture in detail","stream":false}' >/dev/null
done

# B组：另一类前缀（观察是否形成另一簇亲和）
for i in $(seq 1 8); do
  curl -s -X POST http://127.0.0.1:3000/generate \
    -H "Content-Type: application/json" \
    -d '{"text":"Summarize cache-aware policy behavior","stream":false}' >/dev/null
done

# C组：并发混合流量（观察是否触发负载保护）
for i in $(seq 1 20); do
  curl -s -X POST http://127.0.0.1:3000/generate \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"mixed request $i $(date +%s%N)\",\"stream\":false}" >/dev/null &
done
wait
```

#### 步骤 4：观察日志与断点

1. **Gateway debug 日志**（`cache_aware`）
   - 关注是否出现“load balancing triggered”之类的负载切换信号
2. **Mock Worker 终端**
   - 统计 8200/8201 的请求分布
3. **RustRover 断点（推荐）**
   - `CacheAwarePolicy::select_worker`
   - `is_imbalanced` 判断处
   - `match_rate > cache_threshold` 分支处
   - `tree.insert(...)` 更新处

#### 验收标准（建议）

- 能说明某一批相似请求是否逐步收敛到同一 decode worker（缓存亲和）
- 能说明高并发时是否回退到低负载选择（负载保护）
- 能解释一次决策到底是“因匹配率”还是“因负载不均衡”触发

### 常见误区

1. **误区：它读取了真实 GPU KV 命中率**
   - 实际：它用近似树估计缓存亲和，不直接读引擎内 KV 命中统计。
2. **误区：它只做缓存，不看负载**
   - 实际：负载不均衡时会优先 shortest queue。
3. **误区：策略不同会改动后半段执行链路**
   - 实际：主要改动“pair 产生过程”，后续注入/双发/容错基本统一。

---

## 测试方式三：真实 GPU 环境部署（Windows + WSL2 + 单卡）

在配备 NVIDIA GPU 的 Windows 机器上，通过 WSL2 启动多个真实的 SGLang Server 实例，**完整验证 PD 分离架构的端到端能力**，包括真实的模型推理和 KV Cache 传输。

### 环境要求

| 项目 | 要求 |
|------|------|
| GPU | NVIDIA GPU，显存 ≥ 12GB（如 RTX 4070 Ti Super 16GB） |
| 系统 | Windows 11 + WSL2（Ubuntu） |
| 驱动 | Windows 端 NVIDIA 驱动 ≥ 535.x（WSL2 内**不需要**单独安装驱动） |
| Python | 3.10+ |
| SGLang | `pip install "sglang[all]"` |

### 模型选择

单卡需要同时运行 2 个 SGLang Server 实例，需要选择小参数量模型以确保显存够用：

| 模型 | 参数量 | 单实例显存 | 双实例总显存 | 16GB 卡可行性 |
|------|--------|-----------|-------------|--------------|
| `Qwen/Qwen2.5-0.5B-Instruct` | 0.5B | ~1.5GB | ~3GB | ✅ 非常轻松 |
| `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | 1.1B | ~2.5GB | ~5GB | ✅ 轻松 |
| `Qwen/Qwen2.5-1.5B-Instruct` | 1.5B | ~3.5GB | ~7GB | ✅ 可以 |
| `Qwen/Qwen2.5-3B-Instruct` | 3B | ~7GB | ~14GB | ⚠️ 勉强（需限制 KV Cache） |
| 7B 量化模型 (AWQ/GPTQ 4bit) | 7B | ~5GB | ~10GB | ✅ 可以（需设置 `--mem-fraction-static 0.3`） |

> **关于 GPU 共享**：不需要做任何 GPU 虚拟拆分！多个 SGLang Server 进程可以自然地共享同一张 GPU，CUDA 本身就支持多进程并发使用同一张显卡。只需通过 `--mem-fraction-static` 参数控制每个实例的显存占比，确保总量不超限即可。

### 步骤 1：确认 GPU 环境

在 WSL2 中执行：

```bash
# 确认 GPU 可用
nvidia-smi

# 确认 CUDA 版本
nvcc --version
```

### 步骤 2：安装 SGLang

```bash
pip install "sglang[all]"
```

### 步骤 3：启动 Prefill Server

```bash
# 终端 1: 启动 Prefill Server
python -m sglang.launch_server \
  --model-path Qwen/Qwen2.5-0.5B-Instruct \
  --port 30000 \
  --mem-fraction-static 0.3 \
  --tp 1 \
  --pd prefill \
  --bootstrap-port 9000
```

**参数说明**：
- **`--mem-fraction-static 0.3`**：限制此实例只使用 30% 的显存（约 4.8GB），为第二个实例留空间
- **`--pd prefill`**：指定此 Server 为 Prefill 角色
- **`--bootstrap-port 9000`**：Prefill Worker 用于向 Decode Worker 传输 KV Cache 的端口

等待输出类似 `The server is fired up and ready to roll!` 的日志，表示启动完成。

### 步骤 4：启动 Decode Server

```bash
# 终端 2: 启动 Decode Server
python -m sglang.launch_server \
  --model-path Qwen/Qwen2.5-0.5B-Instruct \
  --port 30001 \
  --mem-fraction-static 0.3 \
  --tp 1 \
  --pd decode
```

**参数说明**：
- **`--pd decode`**：指定此 Server 为 Decode 角色
- 使用相同的 `--mem-fraction-static 0.3` 确保不会 OOM

同样等待启动完成日志。

### 步骤 5：验证显存使用

两个 Server 都启动后，检查显存占用：

```bash
nvidia-smi
```

你应该能看到两个 python 进程各自占用一部分显存，共享同一张 GPU。

### 步骤 6：编译并启动 Gateway

Gateway 可以在 WSL2 中编译运行，也可以在 macOS 上交叉编译后拷贝过去。

**在 WSL2 中编译**：

```bash
# 安装 Rust（如果还没装）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env

# 编译 Gateway
cd sgl-model-gateway
cargo build

# 启动 Gateway（PD 模式）
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --decode http://127.0.0.1:30001 \
  --host 127.0.0.1 \
  --port 3000 \
  --policy round_robin
```

> **注意**：`--prefill http://127.0.0.1:30000 9000` 中的 `9000` 是 bootstrap port，对应 Prefill Server 启动时的 `--bootstrap-port 9000`。

### 步骤 7：发送真实推理请求

```bash
# Chat Completion 请求
curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-0.5B-Instruct",
    "messages": [{"role": "user", "content": "用一句话解释什么是 PD 分离架构"}],
    "stream": false
  }' | python -m json.tool

# Generate 请求
curl -s -X POST http://127.0.0.1:3000/generate \
  -H "Content-Type: application/json" \
  -d '{
    "text": "The meaning of life is",
    "sampling_params": {"max_new_tokens": 32},
    "stream": false
  }' | python -m json.tool

# 流式请求
curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen2.5-0.5B-Instruct",
    "messages": [{"role": "user", "content": "写一首关于 AI 的短诗"}],
    "stream": true
  }'

# 并发压测（观察负载均衡）
for i in $(seq 1 20); do
  curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"Qwen/Qwen2.5-0.5B-Instruct\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Count to $i\"}],
      \"stream\": false
    }" > /dev/null &
done
wait
echo "All requests completed"
```

### 观察要点

1. **Prefill Server 日志**：观察是否收到了带 `bootstrap_host`/`bootstrap_port`/`bootstrap_room` 的请求
2. **Decode Server 日志**：观察是否成功接收到 KV Cache 并开始 decode
3. **Gateway 日志**：观察请求分发的路由决策
4. **`nvidia-smi`**：观察推理过程中的显存和 GPU 利用率变化
5. **响应内容**：确认返回的是真实的模型生成结果，而非 mock 数据

### 使用 7B 量化模型（进阶）

如果你之前已经跑过 7B 量化模型，也可以用它来测试，只需调低显存占比：

```bash
# Prefill Server
python -m sglang.launch_server \
  --model-path <你的7B量化模型路径> \
  --port 30000 \
  --mem-fraction-static 0.3 \
  --tp 1 \
  --pd prefill \
  --bootstrap-port 9000

# Decode Server
python -m sglang.launch_server \
  --model-path <你的7B量化模型路径> \
  --port 30001 \
  --mem-fraction-static 0.3 \
  --tp 1 \
  --pd decode
```

> **提示**：7B 量化模型（AWQ/GPTQ 4bit）单实例约 5GB 显存，`--mem-fraction-static 0.3`（约 4.8GB）可能略紧。如果 OOM，可以尝试 `0.35` 或换用更小的模型。

### 清理环境

```bash
# 停止所有 SGLang Server
pkill -f "sglang.launch_server"

# 停止 Gateway
pkill -f "sgl-model-gateway"

# 确认 GPU 显存已释放
nvidia-smi
```

---

## 测试方式四：e2e 测试框架（需要 GPU 集群）

项目的 `e2e_test/` 目录提供了完整的端到端测试框架，适用于多机多卡的 GPU 集群环境。

**在单机环境（macOS 或单卡 WSL2）上无法直接运行此部分。** 如需运行，请在配备多张 NVIDIA GPU 的 Linux 服务器上执行。

参考入口：`e2e_test/infra/gateway.py` 中的 `Gateway` 类，支持以下启动模式：

```python
# PD 模式启动
gateway = Gateway()
gateway.start(
    prefill_workers=prefill_instances,
    decode_workers=decode_instances,
)
```

---

## 各测试方式对比

| 方案 | 环境要求 | 难度 | 验证范围 |
|------|---------|------|---------|
| 方式一：内置单测 | macOS / Linux，无需 GPU | ⭐ 简单 | 路由逻辑、策略选择、容错重试 |
| 方式二：Gateway + Mock Worker | macOS / Linux，无需 GPU | ⭐⭐ 中等 | HTTP 分发、bootstrap 注入、负载均衡 |
| 方式三：真实 GPU 部署 | Windows + WSL2 + GPU（≥12GB） | ⭐⭐⭐ 较复杂 | **完整端到端**：真实推理 + KV Cache 传输 |
| 方式四：e2e 测试框架 | GPU 集群 | ⭐⭐⭐⭐ 复杂 | 生产级多机多卡验证 |

---

## 推荐的学习路径

1. **跑通单测** → 运行 `test_pd_mode_basic_routing`，在 RustRover 中打断点调试
2. **理解双路由分发** → 重点阅读 `PDRouter::execute_dual_dispatch`
3. **理解 bootstrap 协调** → 阅读 `inject_bootstrap_into_value` 和 `pd_types.rs`
4. **理解策略选择** → 阅读 `src/policies/` 下的各策略实现
5. **本地手动测试** → 启动 Gateway + Mock Worker，用 curl 发请求观察行为
6. **真实 GPU 验证** → 在 WSL2 中部署 Prefill + Decode Server，验证端到端推理
7. **对比 HTTP vs gRPC** → 比较 `src/routers/http/pd_router.rs` 和 `src/routers/grpc/pd_router.rs`

---

## 常见问题

### Q: RustRover 调试时看不到变量值？

确保 `Cargo.toml` 中 `[profile.dev]` 的 `debug = 2`（不是 `1`）。

另外，`debug = "line-tables-only"` 虽然能保留断点和基本调用栈，但通常看不到完整中间变量。  
如果你要做路由链路单步分析（例如看 `select_pd_pair`、`context`、`json_request` 等值），请使用 `debug = 2`。

### Q: 编译报错 rustc 版本不够？

运行 `rustup update stable` 升级到最新版本（需要 ≥ 1.88.0）。

### Q: 单卡跑两个 SGLang Server 需要做 GPU 虚拟拆分吗？

**不需要！** CUDA 原生支持多进程共享同一张 GPU。只需通过 `--mem-fraction-static` 参数控制每个实例的显存占比，确保总量不超过显存上限即可。

### Q: 测试中的 MockWorker 和真实 SGLang Worker 有什么区别？

MockWorker 模拟了 SGLang Worker 的 HTTP API 接口（`/health`、`/generate`、`/v1/chat/completions` 等），但不执行真正的模型推理。它足以验证 Gateway 的路由逻辑、策略选择、bootstrap 注入、重试容错等功能。真实 SGLang Worker 则会执行完整的模型推理，包括 KV Cache 的生成和传输。

### Q: WSL2 中 nvidia-smi 报错？

确保 Windows 端已安装最新的 NVIDIA 驱动（≥ 535.x）。WSL2 内**不需要**单独安装 GPU 驱动，它会自动使用 Windows 端的驱动。

### Q: 不同策略下，PD 请求后半段流程会变吗？

通常不会。策略差异主要发生在“选谁”阶段（Prefill/Decode 选点逻辑）。  
当 pair 选定后，网关执行路径通常一致：注入 `bootstrap_*`、并发分发到两侧、按统一容错逻辑处理响应。
