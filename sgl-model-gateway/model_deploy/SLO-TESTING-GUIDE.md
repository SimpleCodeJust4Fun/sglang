# SGLang Model Gateway - SLO 测试指南

## 文档索引

### 环境配置文档
- **WSL2 环境配置**: 参见项目根目录环境配置文档
- **模型配置**: Qwen2.5-0.5B-Instruct-GPTQ-Int4
- **GPU**: RTX 4070 Ti SUPER 16GB
- **Workers**: 6 (4 Prefill + 2 Decode)
- **Context Length**: 512 tokens

### 关键参考文档
- **22-实验复现验证指南.md**: 详细的实验验证流程
- **PD 架构文档**: `docs/pd-architecture-qa-handbook.md`
- **PD 路由调用链**: `docs/pd-routing-callchain-line-by-line.md`
- **策略实现**: `src/policies/` 目录下各策略文件

---

## 1. 测试环境概述

### 1.1 固定 Worker 配置

**Prefill Workers (4 个)**:
| Worker ID | 端口 | Bootstrap 端口 | 内存分配 |
|-----------|------|----------------|----------|
| Prefill-1 | 30000 | 9000 | mem-fraction: 0.05 |
| Prefill-2 | 30001 | 9001 | mem-fraction: 0.05 |
| Prefill-3 | 30002 | 9002 | mem-fraction: 0.05 |
| Prefill-4 | 30003 | 9003 | mem-fraction: 0.05 |

**Decode Workers (2 个)**:
| Worker ID | 端口 | 内存分配 |
|-----------|------|----------|
| Decode-1 | 31000 | mem-fraction: 0.07 |
| Decode-2 | 31001 | mem-fraction: 0.07 |

**启动脚本**: `start-6workers-stable.sh`

### 1.2 Gateway 配置

Gateway 启动参数示例：
```bash
./target/release/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --prefill http://127.0.0.1:30002 9002 \
  --prefill http://127.0.0.1:30003 9003 \
  --decode http://127.0.0.1:31000 \
  --decode http://127.0.0.1:31001 \
  --prefill-policy <策略名> \
  --decode-policy <策略名> \
  --host 127.0.0.1 \
  --port <端口> \
  --log-level warn
```

---

## 2. 可用调度策略列表

### 2.1 完整策略清单

根据 `src/policies/factory.rs` 中的 `PolicyFactory::create_by_name()` 定义，系统支持以下 **11 种策略**：

| 策略名称 | CLI 参数名 | 描述 | 适用场景 |
|---------|-----------|------|----------|
| **Random** | `random` | 完全随机路由 | 基线测试、负载均匀分布 |
| **Round Robin** | `round_robin` | 轮询调度，完美均衡 | 同构环境、简单负载均衡 |
| **Power of Two** | `power_of_two` | 随机选两个，选负载低的 | 负载感知但有随机性 |
| **Cache Aware** | `cache_aware` | 基于 KV Cache 的 Radix 树 | **高缓存利用率，推荐** |
| **Bucket** | `bucket` | 请求大小分桶 + 负载均衡 | 请求长度差异大的场景 |
| **Manual** | `manual` | 手动指定路由键（sticky session） | 需要会话粘性的场景 |
| **Consistent Hashing** | `consistent_hashing` | 一致性哈希环 | 会话亲和性，最少重分配 |
| **Prefix Hash** | `prefix_hash` | 前缀 token 哈希路由 | 轻量级缓存感知路由 |
| **Request Size Bucket** | `request_size_bucket` | 按请求大小分桶到不同 worker | 异构 GPU 混部 |
| **Performance Aware** | `performance_aware` | 基于 TTFT/TPOT/throughput 性能评分 | 异构环境、性能差异大 |
| **Request Classification** | `request_classification` | 多维度请求分类（计算/内存密集型） | 智能路由、复杂场景 |

### 2.2 策略分类

**基础策略** (适合基线对比):
- `random`
- `round_robin`

**缓存感知策略** (适合 PD 分离):
- `cache_aware` ⭐ **推荐**
- `prefix_hash`

**负载感知策略** (适合动态负载均衡):
- `power_of_two`
- `bucket`
- `performance_aware`

**会话粘性策略** (适合多轮对话):
- `manual`
- `consistent_hashing`

**智能分类策略** (适合复杂场景):
- `request_size_bucket`
- `request_classification`

---

## 3. 策略组合矩阵

### 3.1 完整组合测试矩阵

Prefill Policy (P) × Decode Policy (D) = 11 × 11 = **121 种组合**

**推荐优先测试的核心组合** (20 种):

| 组合 ID | Prefill Policy | Decode Policy | 优先级 | 说明 |
|---------|---------------|---------------|--------|------|
| C01 | `cache_aware` | `round_robin` | ⭐⭐⭐ | **当前基线配置** |
| C02 | `random` | `round_robin` | ⭐⭐⭐ | 已测试，对比基线 |
| C03 | `round_robin` | `round_robin` | ⭐⭐ | 完美均衡基线 |
| C04 | `prefix_hash` | `round_robin` | ⭐⭐ | 轻量缓存感知 |
| C05 | `power_of_two` | `round_robin` | ⭐⭐ | 负载感知 Prefill |
| C06 | `bucket` | `round_robin` | ⭐⭐ | 分桶路由 Prefill |
| C07 | `cache_aware` | `random` | ⭐ | Decode 随机 |
| C08 | `cache_aware` | `cache_aware` | ⭐⭐ | 双端缓存感知 |
| C09 | `prefix_hash` | `prefix_hash` | ⭐ | 双端轻量缓存 |
| C10 | `performance_aware` | `round_robin` | ⭐⭐ | 性能感知 Prefill |
| C11 | `request_size_bucket` | `round_robin` | ⭐ | 大小分桶 |
| C12 | `request_classification` | `round_robin` | ⭐ | 智能分类 |
| C13 | `consistent_hashing` | `consistent_hashing` | ⭐ | 双端一致性哈希 |
| C14 | `manual` | `manual` | ⭐ | 双端手动控制 |
| C15 | `cache_aware` | `power_of_two` | ⭐ | 缓存+负载感知 |
| C16 | `power_of_two` | `power_of_two` | ⭐ | 双端负载感知 |
| C17 | `performance_aware` | `performance_aware` | ⭐ | 双端性能感知 |
| C18 | `prefix_hash` | `cache_aware` | ⭐ | 轻量+深度缓存 |
| C19 | `bucket` | `power_of_two` | ⭐ | 分桶+负载 |
| C20 | `request_classification` | `performance_aware` | ⭐ | 智能分类+性能 |

### 3.2 推荐测试优先级

**P0 - 必测** (已完成 2/5):
1. ✅ `cache_aware` + `round_robin` (C01)
2. ✅ `random` + `round_robin` (C02)
3. ⬜ `round_robin` + `round_robin` (C03)
4. ⬜ `prefix_hash` + `round_robin` (C04)
5. ⬜ `cache_aware` + `cache_aware` (C08)

**P1 - 重要** (建议测试):
- C05, C06, C10, C11, C12

**P2 - 扩展** (时间允许):
- C07, C09, C13-C20

---

## 4. 测试执行流程

### 4.1 环境准备

**步骤 1**: 确认 Workers 运行中
```bash
# 检查所有 6 个 workers
ps aux | grep '[s]glang' | grep -E '(prefill|decode)' | wc -l
# 预期输出: 6
```

**步骤 2**: 停止旧 Gateway
```bash
pkill -f 'sgl-model-gateway' || true
sleep 2
```

**步骤 3**: 确认数据集存在
```bash
ls -lh /mnt/e/dev/sglang/sgl-model-gateway/model_deploy/datasets/ShareGPT_V3_unfiltered_cleaned_split.json
# 预期: ~642MB
```

### 4.2 单策略测试命令模板

```bash
# 启动 Gateway (示例: cache_aware + round_robin)
./target/release/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --prefill http://127.0.0.1:30002 9002 \
  --prefill http://127.0.0.1:30003 9003 \
  --decode http://127.0.0.1:31000 \
  --decode http://127.0.0.1:31001 \
  --prefill-policy cache_aware \
  --decode-policy round_robin \
  --host 127.0.0.1 \
  --port 8000 \
  --log-level warn &

# 等待 Gateway 启动
sleep 3

# 运行 Benchmark
source ~/qwen_env/bin/activate
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy

python3 -m sglang.bench_serving \
    --backend sglang-oai \
    --base-url http://127.0.0.1:8000 \
    --dataset-path datasets/ShareGPT_V3_unfiltered_cleaned_split.json \
    --dataset-name sharegpt \
    --num-prompts 50 \
    --request-rate 5 \
    --output-file benchmark-results/bench_cache_aware_round_robin.jsonl
```

### 4.3 批量测试脚本

创建 `run-all-strategy-combinations.sh`:

```bash
#!/bin/bash
# SLO 测试 - 全策略组合批量测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET_PATH="$SCRIPT_DIR/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
GATEWAY_BIN="/mnt/e/dev/sglang/sgl-model-gateway/target/release/sgl-model-gateway"

# Worker 配置
PREFILL_URLS=("http://127.0.0.1:30000" "http://127.0.0.1:30001" "http://127.0.0.1:30002" "http://127.0.0.1:30003")
BOOTSTRAP_PORTS=(90000 90001 90002 90003)
DECODE_URLS=("http://127.0.0.1:31000" "http://127.0.0.1:31001")

# 测试策略组合 (P0 + P1 优先级)
declare -a PREFILL_POLICIES=("round_robin" "cache_aware" "prefix_hash" "power_of_two" "bucket" "performance_aware" "request_size_bucket" "request_classification")
declare -a DECODE_POLICIES=("round_robin" "cache_aware" "random" "power_of_two" "performance_aware")

# 端口偏移
BASE_PORT=8000

mkdir -p "$RESULTS_DIR"

# 激活 Python 环境
source ~/qwen_env/bin/activate

# 测试函数
run_combination() {
    local p_policy=$1
    local d_policy=$2
    local port=$3
    local output_file="$RESULTS_DIR/bench_${p_policy}_${d_policy}.jsonl"
    
    echo ""
    echo "============================================================"
    echo "Testing: Prefill=$p_policy, Decode=$d_policy (port $port)"
    echo "============================================================"
    
    # 停止旧 Gateway
    pkill -f 'sgl-model-gateway' 2>/dev/null || true
    sleep 2
    
    # 启动新 Gateway
    $GATEWAY_BIN \
        --pd-disaggregation \
        --prefill "${PREFILL_URLS[0]}" "${BOOTSTRAP_PORTS[0]}" \
        --prefill "${PREFILL_URLS[1]}" "${BOOTSTRAP_PORTS[1]}" \
        --prefill "${PREFILL_URLS[2]}" "${BOOTSTRAP_PORTS[2]}" \
        --prefill "${PREFILL_URLS[3]}" "${BOOTSTRAP_PORTS[3]}" \
        --decode "${DECODE_URLS[0]}" \
        --decode "${DECODE_URLS[1]}" \
        --prefill-policy "$p_policy" \
        --decode-policy "$d_policy" \
        --host 127.0.0.1 \
        --port "$port" \
        --log-level warn &
    
    # 等待启动
    echo "Waiting for Gateway to start..."
    for i in {1..10}; do
        if curl -sf "http://127.0.0.1:$port/v1/models" > /dev/null 2>&1; then
            echo "Gateway ready on port $port"
            break
        fi
        sleep 1
    done
    
    # 运行 Benchmark
    python3 -m sglang.bench_serving \
        --backend sglang-oai \
        --base-url "http://127.0.0.1:$port" \
        --dataset-path "$DATASET_PATH" \
        --dataset-name sharegpt \
        --num-prompts 50 \
        --request-rate 5 \
        --output-file "$output_file" 2>&1 | tail -40
    
    echo "Results saved to: $output_file"
}

# 主循环
port=$BASE_PORT
for p_policy in "${PREFILL_POLICIES[@]}"; do
    for d_policy in "${DECODE_POLICIES[@]}"; do
        run_combination "$p_policy" "$d_policy" "$port"
        port=$((port + 1))
    done
done

echo ""
echo "============================================================"
echo "All Strategy Combinations Tested!"
echo "============================================================"
echo "Results directory: $RESULTS_DIR"
echo ""
echo "Generate report:"
echo "  python3 generate-benchmark-report.py"
```

### 4.4 执行步骤

1. **创建批量测试脚本**:
   ```bash
   cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
   # 将上述脚本保存为 run-all-strategy-combinations.sh
   chmod +x run-all-strategy-combinations.sh
   ```

2. **执行测试**:
   ```bash
   ./run-all-strategy-combinations.sh
   ```

3. **生成报告**:
   ```bash
   python3 generate-benchmark-report.py
   ```

---

## 5. 关键 SLO 指标

### 5.1 核心指标定义

| 指标 | 全称 | 含义 | 目标值 (Qwen2.5-0.5B) |
|------|------|------|----------------------|
| **TTFT** | Time to First Token | 从发送到收到首个 token 的时间 | Median < 1000ms, P99 < 5000ms |
| **TPOT** | Time Per Output Token | 每个 token 的平均生成时间 | Mean < 15ms |
| **E2E Latency** | End-to-End Latency | 完整请求的端到端延迟 | Median < 2000ms |
| **Throughput** | 吞吐量 | tok/s 或 req/s | Total > 700 tok/s |
| **Success Rate** | 成功率 | 成功请求 / 总请求 | > 60% |

### 5.2 测试参数配置

**标准测试配置**:
```
- num-prompts: 50
- request-rate: 5 req/s
- context-length: 512 tokens
- dataset: ShareGPT V3 (真实对话)
```

**压力测试配置** (可选):
```
- num-prompts: 100
- request-rate: 10 req/s
- max-concurrency: 20
```

---

## 6. 结果分析方法

### 6.1 策略对比维度

**性能维度**:
1. TTFT 延迟 (Mean/Median/P99)
2. TPOT 延迟 (Mean/Median/P99)
3. E2E 延迟 (Mean/Median/P90/P99)
4. 吞吐量 (Total tok/s, Request req/s)
5. 成功率 (completed / num-prompts)

**资源维度**:
1. 峰值并发 (max_concurrent_requests)
2. GPU 内存使用
3. CPU 使用率

**稳定性维度**:
1. P99/P90 比率 (尾部延迟放大倍数)
2. 标准差 (波动性)
3. 成功率一致性

### 6.2 优秀策略的特征

✅ **好的策略应该**:
- TTFT Median < 800ms
- P99 TTFT < 4000ms
- Total Throughput > 750 tok/s
- Success Rate > 60%
- TPOT Mean < 10ms
- 低标准差 (性能稳定)

❌ **差的策略表现**:
- TTFT Median > 1500ms
- P99 TTFT > 8000ms
- Total Throughput < 500 tok/s
- Success Rate < 40%
- 高 TPOT (> 20ms)
- 高标准差 (性能波动大)

---

## 7. 预期结果与瓶颈分析

### 7.1 当前配置瓶颈

**硬件瓶颈**:
- **GPU 内存**: 16GB RTX 4070 Ti SUPER
  - Prefill workers: 0.05 × 16GB = 800MB each (4× = 3.2GB)
  - Decode workers: 0.07 × 16GB = 1.12GB each (2× = 2.24GB)
  - 总计: ~5.44GB, 剩余 ~10GB
  
- **Compute**: CUDA cores 共享
  - 6 workers 并发时可能竞争 GPU 计算资源
  - Context length 512 限制已降低内存压力

**软件瓶颈**:
- **Gateway 单进程**: 可能成为高并发下的瓶颈
- **PD 通信开销**: Prefill → Decode 的 KV cache 传输延迟
- **Radix Cache**: cache_aware 策略的树结构维护开销

### 7.2 策略性能预期

| 策略 | 预期 TTFT | 预期 Throughput | 适用场景 |
|------|----------|----------------|---------|
| cache_aware | 低 (缓存命中快) | 高 | **重复 prompt 场景** |
| random | 中等 | 中等 | 基线对比 |
| round_robin | 中等 | 中等 | 简单均衡 |
| prefix_hash | 低-中 | 高 | 轻量缓存 |
| performance_aware | 低 (选择快的) | 高 | 异构环境 |
| power_of_two | 中等 | 中等-高 | 负载感知 |

### 7.3 可能的改进方向

**短期优化** (1-2 周):
1. **调整 cache_aware 参数**:
   - `cache_threshold`: 0.5 → 0.7 (提高缓存利用门槛)
   - `max_tree_size`: 1000 → 2000 (扩大缓存树)

2. **优化 worker 内存分配**:
   - Prefill: 0.05 → 0.06 (增加 KV cache)
   - Decode: 0.07 → 0.08 (提高解码能力)

3. **Gateway 参数调优**:
   - 增加 `max_concurrent_requests` (如果当前是瓶颈)
   - 调整 `queue_size` 和 `queue_timeout_secs`

**中期优化** (1-2 月):
1. **混合策略**:
   - Prefill: `cache_aware` (高缓存利用)
   - Decode: `performance_aware` (选择性能好的 worker)

2. **动态策略切换**:
   - 根据负载自动切换策略
   - 低负载: `round_robin`
   - 高负载: `cache_aware`

3. **Worker 数量优化**:
   - 测试 4P+4D (增加 Decode 能力)
   - 测试 2P+2D (减少争用)

**长期优化** (3+ 月):
1. **多卡部署**: 多 GPU 分离 Prefill/Decode
2. **异步 PD 通信**: 减少 KV cache 传输延迟
3. **ML 驱动的调度**: 基于历史数据预测最佳策略

---

## 8. 推荐调度策略

### 8.1 当前最佳配置

**生产环境推荐** (基于已测试结果):
```
Prefill Policy: cache_aware
Decode Policy: round_robin
```

**理由**:
- ✅ TTFT Mean: 1694ms (优于 random 的 1711ms)
- ✅ P99 TTFT: 5120ms (优于 random 的 5369ms, -4.6%)
- ✅ TPOT Mean: 8.61ms (优于 random 的 9.13ms, -5.7%)
- ✅ Total Throughput: 783 tok/s (略高于 random)
- ✅ 成功率: 32/50 (与 random 相同)

### 8.2 场景化推荐

| 场景 | Prefill Policy | Decode Policy | 说明 |
|------|---------------|---------------|------|
| **客服系统** (短对话) | `cache_aware` | `round_robin` | 高频重复问题，缓存友好 |
| **代码生成** (长输出) | `prefix_hash` | `performance_aware` | 长输出需性能感知 |
| **多轮对话** | `consistent_hashing` | `consistent_hashing` | 会话粘性 |
| **批量处理** | `round_robin` | `round_robin` | 简单均衡 |
| **混合负载** | `request_classification` | `performance_aware` | 智能分类 |

---

## 9. 故障排查

### 9.1 常见问题

**问题 1**: Gateway 启动失败
```bash
# 检查端口占用
lsof -i :8000

# 检查 worker 健康
curl http://127.0.0.1:30000/health
curl http://127.0.0.1:31000/health
```

**问题 2**: Benchmark 网络错误
```bash
# 确认 HuggingFace/ModelScope 可访问
# 或使用本地数据集
--dataset-path datasets/ShareGPT_V3_unfiltered_cleaned_split.json
```

**问题 3**: GPU 内存不足
```bash
# 检查 GPU 使用
nvidia-smi

# 减少 worker 内存分配或数量
# 编辑 start-6workers-stable.sh
```

### 9.2 日志查看

```bash
# Gateway 日志 (如果重定向到文件)
tail -f /tmp/sgl-gateway-cache_aware.log

# Worker 日志
tail -f /tmp/sglang-prefill-1.log
tail -f /tmp/sglang-decode-1.log
```

---

## 10. 附录

### 10.1 文件清单

| 文件 | 路径 | 用途 |
|------|------|------|
| Worker 启动脚本 | `start-6workers-stable.sh` | 启动 4P+2D workers |
| 批量测试脚本 | `run-all-strategy-combinations.sh` | 全策略组合测试 |
| Benchmark 报告 | `generate-benchmark-report.py` | 生成 HTML 报告 |
| 结果存储 | `benchmark-results/*.jsonl` | 每次测试结果 |
| HTML 报告 | `benchmark-report.html` | 可视化对比报告 |

### 10.2 策略代码位置

```
src/policies/
├── random.rs              # Random 策略
├── round_robin.rs         # Round Robin 策略
├── power_of_two.rs        # Power of Two 策略
├── cache_aware.rs         # Cache Aware 策略 ⭐
├── bucket.rs              # Bucket 策略
├── manual.rs              # Manual 策略
├── consistent_hashing.rs  # Consistent Hashing 策略
├── prefix_hash.rs         # Prefix Hash 策略
├── request_size_bucket.rs # Request Size Bucket 策略
├── performance_aware.rs   # Performance Aware 策略
├── request_classification.rs # Request Classification 策略
├── factory.rs             # 策略工厂
└── mod.rs                 # 模块定义
```

### 10.3 快速参考命令

```bash
# 1. 启动 workers
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
./start-6workers-stable.sh

# 2. 运行单个策略测试
./target/release/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --prefill http://127.0.0.1:30002 9002 \
  --prefill http://127.0.0.1:30003 9003 \
  --decode http://127.0.0.1:31000 \
  --decode http://127.0.0.1:31001 \
  --prefill-policy <POLICY> \
  --decode-policy <POLICY> \
  --host 127.0.0.1 \
  --port 8000 \
  --log-level warn &

# 3. 运行 benchmark
source ~/qwen_env/bin/activate
python3 -m sglang.bench_serving \
    --backend sglang-oai \
    --base-url http://127.0.0.1:8000 \
    --dataset-path datasets/ShareGPT_V3_unfiltered_cleaned_split.json \
    --dataset-name sharegpt \
    --num-prompts 50 \
    --request-rate 5 \
    --output-file benchmark-results/bench_<POLICY>.jsonl

# 4. 生成报告
python3 generate-benchmark-report.py
```

---

## 文档版本

- **版本**: 1.0
- **创建时间**: 2026-04-26
- **基于**: SGLang Model Gateway 当前代码库
- **维护者**: SLO 测试团队

---

**下一步**: 按照本指南执行全策略组合测试，分析结果并更新基准报告。
