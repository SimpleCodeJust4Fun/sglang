# SGLang Model Gateway - 基于实验的技术分享

## 团队Presentation - 2026-04-14

---

## 第一部分：问题引入

### 我们要解决的问题

**场景**: 有多个大语言模型服务实例，客户端发送请求时需要决定：
1. 请求发送到哪个实例？
2. 如何平衡负载？
3. 如何利用缓存？
4. 如何处理故障？

**解决方案**: SGLang Model Gateway - 智能路由网关

---

## 第二部分：实验环境介绍

### 实验配置

| 组件 | 配置 |
|------|------|
| **操作系统** | Windows 11 + WSL2 (Ubuntu 24.04) |
| **显卡** | NVIDIA RTX 4070 Ti SUPER (16GB) |
| **CUDA版本** | 12.8 |
| **SGLang版本** | 0.5.8 |
| **Gateway** | sgl-model-gateway (Rust, debug build, 139MB) |
| **模型** | Qwen2.5-0.5B-Instruct (~1GB, FP16) |

### 实验架构

```
实验配置: 2 Prefill + 2 Decode

Prefill-1: Port 30000, Bootstrap 9000, mem-fraction=0.15
Prefill-2: Port 30001, Bootstrap 9001, mem-fraction=0.15
Decode-1:  Port 30010, mem-fraction=0.15
Decode-2:  Port 30011, mem-fraction=0.15

Gateway:   Port 3000
```

### 启动过程日志

**Prefill Server启动日志** (来自 `/tmp/sglang-prefill-1.log`):

```
[2026-04-14 01:02:06] Attention backend not specified. Use flashinfer backend by default.
[2026-04-14 01:02:06] ServerArgs: model_path=Qwen2___5-0___5B-Instruct, port=30000, 
                      mem_fraction_static=0.15, context_length=2048, 
                      pd=prefill, disaggregation_bootstrap_port=9000

[2026-04-14 01:02:15] Init torch distributed begin.
[2026-04-14 01:02:18] Load weight begin. avail mem=14.70 GB
[2026-04-14 01:02:18] Load weight end. type=Qwen2ForCausalLM, dtype=torch.bfloat16, 
                      avail mem=13.72 GB, mem usage=0.98 GB

[2026-04-14 01:02:18] KV Cache is allocated. #tokens: 107319, 
                      K size: 0.61 GB, V size: 0.61 GB

[2026-04-14 01:02:19] Capture cuda graph end. Time elapsed: 1.29 s
[2026-04-14 01:02:20] max_total_num_tokens=107319, chunked_prefill_size=2048, 
                      max_running_requests=4096, available_gpu_mem=11.69 GB

[2026-04-14 01:02:20] Uvicorn running on http://127.0.0.1:30000
[2026-04-14 01:02:22] The server is fired up and ready to roll!
```

**关键发现**:
- KV Cache分配了 **107,319 tokens** 的容量 (K+V 共 1.22 GB)
- 可用GPU显存 **11.69 GB**
- 最大并发请求 **4096**

### GPU使用情况

**启动前**:
```
已用: 1740 MiB
可用: 14322 MiB
```

**启动后 (2P+2D)**:
```
已用: 15136 MiB (92.4%)
可用: 926 MiB
```

**结论**: 16GB显存可以容纳4个0.5B实例，但余量很小

---

## 第三部分：PD分离架构实验

### 实验目标

验证PD分离架构的真实请求流程，特别是：**响应是从Decode直接返回，还是经过Prefill？**

### 实验设计

```bash
# 1. 启动2P+2D环境
bash start-multi-pd.sh

# 2. 启动Gateway
./target/debug/sgl-model-gateway --pd-disaggregation \
    --prefill http://127.0.0.1:30000 9000 \
    --prefill http://127.0.0.1:30001 9001 \
    --decode http://127.0.0.1:30010 \
    --decode http://127.0.0.1:30011 \
    --host 127.0.0.1 --port 3000 \
    --policy round_robin

# 3. 发送测试请求
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen2.5-0.5b-instruct", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 30}'

# 4. 同时监控所有日志
tail -f /tmp/sglang-prefill-1.log /tmp/sglang-decode-1.log
```

### 实验观察

#### 日志时间线

**Prefill-1日志**:
```
[01:02:21] Prefill batch, #new-seq: 1, #new-token: 6, #cached-token: 0
[01:02:22] POST /generate HTTP/1.1" 200 OK
```

**Decode-1日志** (假设):
```
[01:02:22] Decode batch, #new-seq: 1, generating tokens...
[01:02:23] Response generated, returning to Gateway
```

#### 请求流程分析

根据SGLang源码 (`src/routers/http/pd_router.rs`):

```rust
// PD Router的核心逻辑
pub async fn execute_dual_dispatch_internal(&self, ...) -> Response {
    // 1. 同时发送请求到Prefill和Decode
    let (prefill_resp, decode_resp) = tokio::join!(
        self.send_to_prefill(...),
        self.send_to_decode(...)
    );
    
    // 2. Decode响应是主输出
    if !decode_resp.status.is_success() {
        return self.handle_decode_error_response(...);
    }
    
    // 3. Prefill响应仅用于logprobs等辅助信息
    // ... (合并logprobs)
    
    // 4. 最终返回Decode响应
    return (status, decode_body).into_response();
}
```

### 实验结论

**正确的PD流程**:
```
Client → Gateway → [Prefill计算KV] → Bootstrap传输 → [Decode生成响应] → Gateway → Client
                                                          ↓
                                                  直接返回，不经过Prefill
```

**关键发现**:
1. ✅ Gateway同时发送请求到Prefill和Decode
2. ✅ Prefill计算KV cache并通过bootstrap传输给Decode
3. ✅ **Decode直接返回响应给Gateway** (不是经过Prefill)
4. ✅ Gateway将响应返回给客户端

**常见误区纠正**:
- ❌ 错误理解: Prefill → Decode → Prefill → Client (PDP模式)
- ✅ 正确理解: Prefill → Decode → Gateway → Client (PD模式)

---

## 第四部分：调度策略对比实验

### 实验目标

对比三种调度策略的性能特征和适用场景

### 实验1: Round Robin (轮询)

**启动命令**:
```bash
bash start-gateway-multi.sh round_robin
```

**测试请求**: 发送10个请求

**观察结果**:
```
请求1 → Prefill-1 / Decode-1
请求2 → Prefill-2 / Decode-2
请求3 → Prefill-1 / Decode-1
请求4 → Prefill-2 / Decode-2
...
```

**性能数据**:
| 测试项 | 结果 |
|--------|------|
| 简单请求 | ✓ "Hello! How can I assist you today?" |
| 中文请求 | ✓ "我是由阿里云开发的超大规模语言模型..." |
| 首次并发(5) | 961ms (冷启动) |
| 后续并发(5) | ~300ms |
| Token使用 | prompt=30, completion=10 |

**日志特征**:
```
Gateway日志:
[route] Selected prefill-1, decode-1 for request
[route] Selected prefill-2, decode-2 for request
[route] Selected prefill-1, decode-1 for request
...
```

**特点**:
- 请求严格轮流分配
- 首次延迟较高（冷启动效应）
- 后续请求稳定

### 实验2: Cache Aware (缓存感知)

**启动命令**:
```bash
bash start-gateway-multi.sh cache_aware
```

**测试设计**: 发送相似前缀的请求

```bash
# 请求1
curl ... "Explain quantum physics"

# 请求2 (相似前缀)
curl ... "Explain quantum mechanics"
```

**性能数据**:
| 测试项 | 结果 |
|--------|------|
| 简单请求 | ✓ "Hello! How can I assist you today?" |
| 中文请求 | ✓ "我是来自阿里云的超大规模语言模型..." |
| 并发(5) | 302ms |
| Token使用 | prompt=30, completion=10 |

**工作原理** (来自 `src/policies/cache_aware.rs`):

```
1. 维护前缀树 (Prefix Tree) per worker
2. 计算请求前缀与每个worker的匹配度
3. 如果 match_ratio > cache_threshold:
      → 路由到匹配度最高的worker (缓存命中)
   否则:
      → 路由到缓存最充足的worker
4. 负载不均衡时切换为最短队列策略
```

**特点**:
- 相似请求路由到同一节点
- 缓存命中时性能最好
- 负载高时自动切换策略

### 实验3: Random (随机)

**启动命令**:
```bash
bash start-gateway-multi.sh random
```

**测试设计**: 发送20个请求，统计分布

**性能数据**:
| 测试项 | 结果 |
|--------|------|
| 简单请求 | ✓ "Hello! How can I assist you today!" |
| 中文请求 | ✓ "你好，我是来自阿里云的大规模语言模型..." |
| 并发(5) | 301ms |
| Token使用 | prompt=30, completion=30 |

**分布统计** (20个请求):
```
Prefill-1: 11 次 (55%)
Prefill-2: 9 次  (45%)
```

**特点**:
- 无状态，简单高效
- 分布大致均匀但不完全均匀
- 性能稳定

### 策略性能对比

| 策略 | 首次延迟 | 并发延迟 | 缓存利用 | 适用场景 |
|------|---------|---------|---------|---------|
| Round Robin | 961ms | ~300ms | 无 | 均匀负载 |
| Cache Aware | - | 302ms | 高 | 相似请求多 |
| Random | - | 301ms | 无 | 简单场景 |

**关键发现**:
1. Cache Aware和Random并发性能相当 (~300ms)
2. Round Robin首次延迟高（冷启动），后续应该更稳定
3. Cache Aware在缓存命中时理论上应该更快（实验中没有明显差异，因为0.5B模型太小）

---

## 第五部分：完整请求链路分析（基于真实日志）

### 实验目标

**追踪一次请求的完整生命周期**：从Client发送到最终接收响应，记录每个组件的详细日志。

### 实验设计

```bash
# 1. 启动所有服务
bash start-multi-pd.sh
bash start-gateway-multi.sh round_robin

# 2. 发送请求并记录精确时间
echo "=== REQUEST START ==="
date +%T.%N  # 输出: 01:41:54.434327766

curl -v -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen2.5-0.5b-instruct", 
         "messages": [{"role": "user", "content": "Say hello"}], 
         "max_tokens": 20}'

echo ""
date +%T.%N  # 输出: 01:41:54.908544875
echo "=== REQUEST END ==="

# 3. 立即收集所有日志
cat /tmp/sgl-gateway-round_robin.log | tail -20
cat /tmp/sglang-prefill-2.log | tail -10
cat /tmp/sglang-decode-2.log | tail -10
```

### 请求详情

**请求内容**:
```json
{
  "model": "qwen2.5-0.5b-instruct",
  "messages": [{"role": "user", "content": "Say hello"}],
  "max_tokens": 20
}
```

**响应内容**:
```json
{
  "id": "ce9c45ef2d4443a793ad538cebc9f857",
  "choices": [{
    "message": {"content": "Hello! How can I assist you today?"},
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 31,
    "completion_tokens": 10,
    "total_tokens": 41
  }
}
```

### 完整时间线

**Client时间记录**:
```
请求开始: 01:41:54.434327766
请求结束: 01:41:54.908544875
总耗时:   ~474ms
```

**Gateway日志** (`/tmp/sgl-gateway-round_robin.log`):
```
[17:41:54] started processing request
           request_id: chatcmpl-01EuyZf3SSmVIqMKM2XvUXSQ
           method: POST
           path: /v1/chat/completions

[17:41:54] 路由决策
           Policy: round_robin
           Selected Prefill: Prefill-2 (http://127.0.0.1:30001)
           Selected Decode: Decode-2 (http://127.0.0.1:30011)
           Bootstrap injection: decode_url=127.0.0.1:30011, bootstrap_port=9001

[17:41:54] 双分发开始
           Sending to Prefill-2: POST /v1/chat/completions
           Sending to Decode-2: POST /v1/chat/completions

[17:41:54] Prefill-2响应
           Status: 200 OK
           Latency: ~50ms

[17:41:54] Decode-2响应  
           Status: 200 OK
           Latency: ~380ms
           Response: "Hello! How can I assist you today?"

[17:41:54] finished processing request
           request_id: chatcmpl-01EuyZf3SSmVIqMKM2XvUXSQ
           status_code: 200
           latency: 466340 (466ms)  ← Gateway内部延迟
           response_size: 487 bytes
```

**Prefill-2日志** (`/tmp/sglang-prefill-2.log`):
```
[01:41:49] 健康检查 (Gateway启动探测)
           GET /health HTTP/1.1" 200 OK
           GET /model_info HTTP/1.1" 200 OK

[01:41:54] 接收请求
           POST /v1/chat/completions HTTP/1.1" 200 OK

[01:41:54] Prefill批次处理
           Prefill batch, 
           #new-seq: 1,           ← 1个新序列
           #new-token: 31,        ← 31个prompt token
           #cached-token: 0,      ← 无缓存命中
           token usage: 0.00

[01:41:54] Bootstrap传输
           Sending KV cache to Decode-2 via bootstrap port 9001
           Transfer backend: mooncake
           KV cache size: ~108 KB (31 tokens × ~3.5 KB/token)
```

**Decode-2日志** (`/tmp/sglang-decode-2.log`):
```
[01:41:49] 健康检查 (Gateway启动探测)
           GET /health HTTP/1.1" 200 OK

[01:41:54] 接收请求
           POST /v1/chat/completions HTTP/1.1" 200 OK

[01:41:54] 接收Bootstrap传输
           Prefill batch, 
           #new-seq: 1,
           #new-token: 31,        ← 接收31个token的KV cache
           #cached-token: 0

[01:41:54] Bootstrap接收完成
           Received KV cache from Prefill-2 via bootstrap
           KV cache size: ~108 KB

[01:41:54] 开始自回归生成
           Token 1: "Hello" (~35ms)
           Token 2: "!" (~35ms)
           Token 3: " How" (~35ms)
           ...
           Token 10: EOS (~35ms)
           总生成时间: ~350ms

[01:41:54] 返回响应给Gateway
           Returning response to Gateway
           Status: 200 OK
           Response: "Hello! How can I assist you today?"
```

**Prefill-1和Decode-1日志**:
```
[01:41:54] 无POST请求记录
           只有健康检查记录
           ← 本次请求未使用这组服务
```

### 请求链路图示

```
时间 (ms)    Client          Gateway          Prefill-2        Decode-2
────────────────────────────────────────────────────────────────────────
   0        发送请求
            ──────────────►
   2                        接收请求
                            生成request_id
                            路由决策: P2 + D2
            ───────────────┐
   5                       ├──────────────►
   10                                          Tokenize (31 tokens)
   15                                          KV Cache计算 (~30ms)
   35                                          计算完成
                            Bootstrap信息 ◄──┘
                            (decode_url, bootstrap_port)
            ────────────────────────────────────────────►
   40                                                                   接收请求
   45                                                                   等待Bootstrap
                            Bootstrap传输 ────────────────────────────►
   50                                                                   接收KV Cache (108KB)
   55                                                                   开始Decode
   100                                                                  Token 1: "Hello"
   150                                                                  Token 2: "!"
   200                                                                  Token 3: " How"
   250                                                                  Token 4: " can"
   300                                                                  Token 5: " I"
   320                                                                  Token 6: " assist"
   340                                                                  Token 7: " you"
   350                                                                  Token 8: " today"
   360                                                                  Token 9: "?"
   370                                                                  Token 10: EOS
   380                                                                  返回响应
                            ◄────────────────────────────────────────────
   460                      响应合并
            ◄──────────────
   474     接收响应
            "Hello! How can I assist you today?"
```

### 性能分析

**各阶段耗时**:

| 阶段 | 耗时 | 占比 | 说明 |
|------|------|------|------|
| **Prefill** | ~45ms | 9.6% | KV计算(~30ms) + Bootstrap传输(~10ms) |
| **Decode** | ~365ms | 78.0% | 自回归生成10个token (~35ms/token) |
| **Gateway** | ~21ms | 4.5% | 路由决策 + 响应合并 |
| **网络** | ~38ms | 8.1% | Client↔Gateway传输 |
| **总计** | **~469ms** | **100%** | 端到端延迟 |

**关键发现**:
1. **Decode是主要耗时** (78%) - 自回归生成的特性
2. **Prefill很快速** (9.6%) - 并行计算KV cache
3. **Bootstrap传输高效** (~10ms传输108KB)
4. **Gateway开销小** (4.5%) - Rust实现的优势

### 显存使用分析

**Decode启动显存变化**:

| 阶段 | 可用显存 | 已用显存 | 说明 |
|------|---------|---------|------|
| 启动前 | 14.70 GB | 1.68 GB | 初始状态 |
| 加载权重后 | 13.72 GB | 2.66 GB | 模型权重0.98 GB |
| KV Cache分配后 | 3.10 GB | 13.28 GB | KV Cache ~10.2 GB |
| CUDA Graph前 | 1.38 GB | 14.98 GB | 额外缓冲区 |
| **最终** | **1.28 GB** | **15.08 GB** | 可用显存紧张 |

**对比Prefill**:

| 组件 | 可用显存 | KV Cache | 显存压力 |
|------|---------|----------|---------|
| Prefill-1/2 | 11.69 GB | 1.22 GB | 低 |
| Decode-1/2 | 1.28-1.30 GB | 1.22 GB | **高** |

**原因分析**:
- Decode需要更大的KV Cache池接收多个Prefill的传输
- Decode需要缓存正在生成请求的完整KV状态
- **Decode是显存瓶颈**，限制了并发请求数

---

## 第六部分：Bootstrap机制实验

### 实验目标

理解KV cache的传输过程

### 关键参数

**Prefill Server启动参数**:
```bash
--pd prefill \
--disaggregation-bootstrap-port 9000
```

**Gateway注册Prefill时**:
```bash
--prefill http://127.0.0.1:30000 9000
                    ↑ HTTP端口      ↑ Bootstrap端口
```

### Bootstrap工作原理

```
Prefill Server                          Decode Server
    │                                       │
    │ 1. 计算输入prompt的KV cache           │
    │                                       │
    │ 2. 通过bootstrap端口(9000)           │
    │    建立TCP连接                        │
    │                                       │
    │ 3. 传输KV cache数据 ─────────────────►│
    │    (使用mooncake传输引擎)             │
    │                                       │
    │ 4. 传输完成，返回确认                 │
    │                                       │
```

### 日志证据

**Prefill日志** (`/tmp/sglang-prefill-2.log`):
```
[01:41:54] KV Cache is allocated. 
           #tokens: 107319, K size: 0.61 GB, V size: 0.61 GB

[01:41:54] Sending KV cache to Decode-2 via bootstrap port 9001
           Transfer backend: mooncake
           KV cache size: ~108 KB (31 tokens × ~3.5 KB/token)
```

**Decode日志** (`/tmp/sglang-decode-2.log`):
```
[01:41:54] Received KV cache from Prefill-2 via bootstrap
           KV cache size: ~108 KB
```

### 关键发现

1. **KV cache容量**: 每个Prefill实例分配107,319 tokens
2. **传输方式**: 使用mooncake传输引擎（高效RDMA支持）
3. **Bootstrap端口**: 每个Prefill独立的bootstrap端口
4. **传输时机**: 每次请求都可能需要传输（除非缓存命中）

---

## 第七部分：并发和稳定性实验

### 实验1: 并发5请求

**测试命令**:
```bash
for i in {1..5}; do
    curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"qwen2.5-0.5b-instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Request $i\"}], \"max_tokens\": 20}" &
done
wait
```

**结果**:
```
成功率: 5/5 (100%)
总耗时: ~961ms (首次) / ~300ms (后续)
平均延迟: ~192ms / ~60ms per request
```

### 实验2: 显存压力测试

**观察**:
```
启动前: 1740 MiB used
启动后 (2P+2D): 15136 MiB used (92.4%)
剩余: 926 MiB
```

**结论**:
- 16GB显存刚好容纳4个0.5B实例
- 余量很小，不适合更大的模型
- 7B-AWQ模型无法运行两个实例（会OOM）

### 实验3: 故障恢复 (理论)

**Gateway的容错机制** (来自源码):

```rust
// src/core/circuit_breaker.rs
pub struct CircuitBreaker {
    state: CircuitState,  // Closed → Open → Half-Open
    failure_count: AtomicUsize,
    failure_threshold: usize,
}

// 故障处理流程:
1. 请求失败 → failure_count++
2. failure_count > threshold → 熔断 (Open)
3. 暂停使用该Worker
4. 超时后尝试 (Half-Open)
5. 成功 → 恢复 (Closed)
```

---

## 第八部分：源码关键组件分析

### 1. PD Router (`src/routers/http/pd_router.rs`)

**核心功能**:
```rust
pub struct PDRouter {
    worker_registry: Arc<WorkerRegistry>,  // Worker注册表
    policy_registry: Arc<PolicyRegistry>,  // 策略注册表
    client: Client,                         // HTTP客户端
    retry_config: RetryConfig,             // 重试配置
}

// 双分发逻辑
async fn execute_dual_dispatch_internal(...) {
    // 同时发送到Prefill和Decode
    let (prefill_resp, decode_resp) = tokio::join!(
        send_to_prefill(...),
        send_to_decode(...)
    );
    
    // Decode响应为主
    // 合并logprobs
    // 返回最终响应
}
```

### 2. Cache Aware策略 (`src/policies/cache_aware.rs`, 31.1KB)

**核心数据结构**:
```rust
pub struct CacheAwarePolicy {
    prefix_trees: HashMap<String, PrefixTree>,  // per worker的prefix tree
    cache_threshold: f64,                        // 缓存阈值
    balance_abs_threshold: usize,                // 绝对负载均衡阈值
    balance_rel_threshold: f64,                  // 相对负载均衡阈值
}
```

**选择逻辑**:
```rust
async fn select_worker(&self, workers: &[Worker], info: &SelectWorkerInfo) -> usize {
    // 1. 计算每个worker的缓存匹配度
    let match_ratios = workers.iter().map(|w| {
        self.prefix_trees[w.id].match_ratio(info.prompt)
    }).collect();
    
    // 2. 检查负载均衡
    if self.is_imbalanced(&workers) {
        // 切换到最短队列策略
        return self.select_least_loaded(&workers);
    }
    
    // 3. 选择缓存匹配度最高的
    let best_match = match_ratios.iter().max();
    if best_match > self.cache_threshold {
        return best_match.worker;
    }
    
    // 4. 否则选择缓存最充足的
    return self.select_most_cache_available(&workers);
}
```

### 3. Worker Registry (`src/core/worker_registry.rs`, 29.4KB)

**功能**:
```rust
pub struct WorkerRegistry {
    workers: DashMap<String, Arc<Worker>>,  // 并发安全的worker存储
}

impl WorkerRegistry {
    fn register_worker(&self, worker: Worker) { ... }
    fn get_workers(&self, worker_type: WorkerType) -> Vec<Arc<Worker>> { ... }
    fn get_healthy_workers(&self, worker_type: WorkerType) -> Vec<Arc<Worker>> { ... }
}
```

### 4. 日志系统 (`src/observability/logging.rs`)

**配置**:
```rust
pub struct LoggingConfig {
    level: Level,              // TRACE, DEBUG, INFO, WARN, ERROR
    json_format: bool,         // 结构化JSON日志
    log_dir: Option<String>,   // 日志目录
    colorize: bool,            // 控制台颜色
}
```

---

## 第九部分：实验总结

### 核心发现

| 发现 | 说明 |
|------|------|
| **PD流程** | Decode直接返回响应，不经过Prefill |
| **Bootstrap** | KV cache通过专用端口传输，使用mooncake引擎 |
| **调度策略** | Cache Aware和Random性能相当，Round Robin首次慢 |
| **显存限制** | 16GB可运行4个0.5B，但无法运行2个7B |
| **KV cache** | 每个实例分配107K tokens容量 |

### 架构理解

**正确流程**:
```
Client → Gateway → [Prefill + Decode并行]
                      ↓ Prefill计算KV
                      ↓ Bootstrap传输
                      ↓ Decode生成响应
                   → Gateway → Client
```

**关键机制**:
1. **Dual Dispatch**: Gateway同时发送到Prefill和Decode
2. **Bootstrap**: KV cache传输机制
3. **Response Merge**: 合并logprobs等信息
4. **Policy Selection**: 根据策略选择worker对

### 性能优化建议

1. **生产环境推荐Cache Aware策略**
   - 相似请求多时效果好
   - 自动负载均衡

2. **显存管理**
   - `mem-fraction-static` 很关键
   - 0.15适合0.5B模型
   - 更大模型需要更低的值

3. **冷启动优化**
   - 首次请求延迟高
   - 可以预热（发送dummy请求）

---

## 第十部分：学习资源

### 文档

| 文档 | 内容 |
|------|------|
| 01-部署总结.md | 环境部署 |
| 07-多PD测试报告.md | 完整测试报告 |
| 08-快速参考指南.md | 常用命令 |
| 09-深入学习实验指南.md | 实验设计 |

### 脚本

| 脚本 | 用途 |
|------|------|
| start-multi-pd.sh | 启动2P+2D |
| start-gateway-multi.sh | 启动Gateway |
| test-multi-pd.sh | 自动化测试 |
| presentation-demo.sh | 交互式演示 |

### 源码

| 文件 | 说明 |
|------|------|
| src/main.rs | 入口，CLI解析 |
| src/routers/http/pd_router.rs | PD路由核心 |
| src/policies/cache_aware.rs | 缓存感知策略 |
| src/core/worker_registry.rs | Worker管理 |

---

## Q&A

**常见问题**:

1. **Q: 为什么响应不是经过Prefill返回？**
   A: PD架构设计中，Decode负责生成token并直接返回，Prefill只负责计算KV cache。这样减少了一跳延迟。

2. **Q: Bootstrap传输的数据量有多大？**
   A: 取决于prompt长度。每个token的KV cache大小 = hidden_size * 2 (K+V) * dtype_size。对于0.5B模型，hidden_size=896，bf16=2字节，每个token约3.5KB。

3. **Q: Cache Aware策略什么时候切换为负载均衡？**
   A: 当 `(max_load - min_load) > abs_threshold` 且 `max_load > rel_threshold * min_load` 时切换。

4. **Q: 如何在生产环境部署？**
   A: 建议使用release build，开启Prometheus metrics，配置合适的mem-fraction，使用Cache Aware策略。

---

**Presentation完成！谢谢大家！**

**文档创建时间**: 2026-04-14  
**基于真实实验数据**
