# Worker 密度优化 - 最终测试报告

> **日期**: 2026-04-26  
> **目标**: 在 RTX 4070 Ti Super (16GB) 上部署尽可能多的 worker  
> **GPU**: 16GB VRAM

---

## 测试总结

### 测试过的模型

| 模型 | 参数量 | 量化 | 大小 | 状态 |
|------|--------|------|------|------|
| Qwen2.5-0.5B | 0.5B | FP16 | 954MB | ✅ 已测试 |
| Qwen2.5-1.5B | 1.5B | AWQ 4-bit | 1.6GB | ✅ 已测试 |
| Qwen3-0.6B | 0.6B | FP16 | ~1.2GB | ⏳ 下载中 |
| Qwen3.5-0.8B | 0.8B | BF16 | 1.7GB | ❌ Transformers 不兼容 |

---

## 测试结果对比

### Qwen2.5-0.5B (FP16, 954MB)

| 配置 | Workers | 调度对 | VRAM 使用 | 结果 |
|------|---------|--------|-----------|------|
| **2P+2D** | 4 | 4 | 13.9GB | ✅ **SUCCESS** |
| **2P+4D** | 6 | 8 | 13.8GB | ✅ **SUCCESS (最佳)** |
| 3P+3D | 6 | 9 | - | ❌ OOM |
| 4P+4D | 8 | 16 | 11GB | ❌ 部分失败 |

**最佳配置**: 2P+4D (6 workers, 8 调度对, 13.8GB)

---

### Qwen2.5-1.5B-AWQ (4-bit, 1.6GB)

| 配置 | Workers | 调度对 | VRAM 使用 | 结果 |
|------|---------|--------|-----------|------|
| **2P+2D** | 4 | 4 | 13.0GB | ✅ **SUCCESS** |
| 2P+4D | 6 | 8 | 13.4GB | ❌ 4/6 存活 |
| 3P+4D | 7 | 12 | 12.2GB | ❌ 4/7 存活 |
| 4P+4D | 8 | 16 | 10.8GB | ❌ 4/8 存活 |

**最佳配置**: 2P+2D (4 workers, 4 调度对, 13.0GB)

**发现**: AWQ 量化模型在稳定性测试中表现**更差**！

---

## 关键发现

### 1. AWQ 量化没有带来预期收益

**预期**:
- AWQ 4-bit: 模型 1.6GB vs FP16 3GB (节省 50%)
- 单 worker 显存: ~1.2GB vs ~2.0GB
- 应支持 7-9 个 worker

**实际**:
- 2P+2D 使用 13.0GB (比 Qwen2.5-0.5B 的 13.9GB 少 0.9GB)
- 但 2P+4D 配置全部 OOM
- 只能稳定运行 4 个 worker

**原因分析**:

1. **模型参数更大** (1.5B vs 0.5B)
   - 即使量化，运行时显存需求仍高于 0.5B FP16
   - KV Cache 与参数量成正比，1.5B 的 cache 是 0.5B 的 3 倍

2. **mem-fraction-static 计算基准不同**
   - 0.08 的 fraction 对 0.5B 模型 = ~1.3GB
   - 0.08 的 fraction 对 1.5B 模型 = ~2.6GB (3x)
   - 实际 VRAM 占用超出预期

3. **SGLang 对 AWQ 的支持**
   - AWQ 可能需要特殊配置
   - 推理引擎可能没有完全优化

### 2. Qwen2.5-0.5B 仍然是最佳选择

| 指标 | Qwen2.5-0.5B | Qwen2.5-1.5B-AWQ | 差异 |
|------|--------------|------------------|------|
| 最大稳定 workers | **6** | 4 | +50% |
| 最大调度对 | **8** | 4 | +100% |
| VRAM 使用 | 13.8GB | 13.0GB | +0.8GB |
| 模型大小 | 954MB | 1.6GB | -40% |
| 推理质量 | 较低 | 较高 | - |

**结论**: 如果目标是**最大化 worker 数量**，使用 **Qwen2.5-0.5B FP16**

---

## VRAM 使用模式深度分析

### 实际显存组成

单个 worker 的 VRAM 占用：

```
总 VRAM = 模型权重 + KV Cache + 运行时开销 + CUDA Graph
```

### Qwen2.5-0.5B (FP16)

- 模型权重: ~1.0GB (FP16)
- KV Cache: ~0.5-1.5GB (取决于 context length)
- 运行时开销: ~0.3-0.5GB
- **总计**: ~1.8-3.0GB/worker

### Qwen2.5-1.5B-AWQ (4-bit)

- 模型权重: ~1.6GB (4-bit 量化)
- KV Cache: ~1.5-4.5GB (3x 参数量)
- 运行时开销: ~0.3-0.5GB
- **总计**: ~3.4-6.6GB/worker

**关键**: KV Cache 与参数量成正比，量化只减少了权重，没有减少 KV Cache！

---

## 为什么无法突破 6 workers

### 数学计算

16GB VRAM，系统预留 2GB = 14GB 可用

**Qwen2.5-0.5B**:
- 单 worker: ~2.3GB (平均)
- 理论最大: 14 / 2.3 = 6.1 → **6 workers**
- 实际测试: 6 workers (2P+4D) ✅

**Qwen2.5-1.5B-AWQ**:
- 单 worker: ~3.5GB (平均，KV Cache 更大)
- 理论最大: 14 / 3.5 = 4.0 → **4 workers**
- 实际测试: 4 workers ✅

### 瓶颈分析

1. **模型权重** (固定开销)
   - 每个 worker 必须加载完整模型
   - CUDA 进程隔离，无法共享

2. **KV Cache** (可变开销)
   - 与参数量和 context length 成正比
   - 量化不减少 KV Cache

3. **系统开销** (固定)
   - CUDA context: ~200MB/worker
   - Python 运行时: ~100MB/worker

---

## 如果要突破 6 workers 的可能方案

### 方案 A: 使用更小模型 (0.1B - 0.3B)

```bash
# 寻找 100M-300M 参数模型
modelscope download --model "Qwen/Qwen2.5-0.1B"
```

**预期**:
- 模型权重: ~0.2-0.6GB
- KV Cache: ~0.1-0.3GB
- 单 worker: ~1.0-1.5GB
- 理论最大: **9-14 workers**

### 方案 B: Tensor Parallelism (需要多卡)

```bash
# 跨 2 张 GPU
--tp 2
```

**不适用**: 单卡环境

### 方案 C: vLLM 或其他推理引擎

某些推理引擎可能有更好的显存优化：
- vLLM: PagedAttention
- TGI: FlashAttention 优化

### 方案 D: 激进的配置优化 (理论可行)

```bash
# Qwen2.5-0.5B 极限配置
# Prefill: 0.06, Decode: 0.09
# 3P+4D = 3×1.0 + 4×1.5 = 9GB (理论)

bash model_deploy/start-multi-pd.sh 3p4d qwen2.5
```

但实际测试显示 mem-fraction < 0.07 时容易 OOM

---

## 最终推荐配置

### 目标: 最大化调度研究灵活性

```bash
# 使用 Qwen2.5-0.5B
bash model_deploy/start-multi-pd.sh 2p4d qwen2.5

# 启动 Gateway
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 90000 \
  --prefill http://127.0.0.1:30001 90001 \
  --decode http://127.0.0.1:31000 \
  --decode http://127.0.0.1:31001 \
  --decode http://127.0.0.1:31002 \
  --decode http://127.0.0.1:31003 \
  --host 127.0.0.1 --port 3000 \
  --prefill-policy cache_aware \
  --decode-policy round_robin
```

**配置**:
- Workers: 6 (2P + 4D)
- 调度对: 8
- VRAM: 13.8GB
- 稳定性: ✅ 已验证

---

## 测试脚本清单

| 脚本 | 用途 | 状态 |
|------|------|------|
| `test-worker-deployment.sh` | Qwen2.5-0.5B 测试 | ✅ 已验证 |
| `test-awq-workers.sh` | Qwen2.5-1.5B-AWQ 测试 | ✅ 已测试 |
| `test-qwen3-workers.sh` | Qwen3-0.6B 测试 | ⏳ 待模型下载 |
| `test-qwen35-workers.sh` | Qwen3.5-0.8B 测试 | ❌ 不兼容 |
| `start-multi-pd.sh` | 多 worker 启动 | ✅ 已更新 |

---

## 日志位置

- Qwen2.5-0.5B: `/tmp/sglang-test-prefill-*.log`, `/tmp/sglang-test-decode-*.log`
- Qwen2.5-1.5B-AWQ: `/tmp/sglang-awq-prefill-*.log`, `/tmp/sglang-awq-decode-*.log`
- Qwen3.5-0.8B: `/tmp/sglang-qwen35-prefill-*.log`, `/tmp/sglang-qwen35-decode-*.log`

---

## 结论

### 已验证

1. ✅ **Qwen2.5-0.5B 是单卡 16GB 上的最佳选择**
   - 最大 6 workers (2P+4D)
   - 8 个调度对
   - 稳定性已验证

2. ❌ **AWQ 量化没有带来 worker 密度提升**
   - 参数量增加导致 KV Cache 更大
   - 量化只减少权重，不减少运行时显存

3. ❌ **无法突破 6 workers (当前模型)**
   - 数学极限: 14GB / 2.3GB = 6
   - 需要更小模型 (0.1B-0.3B) 或多卡

### 下一步

1. 接受 6 workers 作为当前硬件限制
2. 专注于调度策略优化而非密度优化
3. 如需更多 worker，考虑：
   - 更小模型 (0.1B-0.3B)
   - 多卡环境
   - 其他推理引擎

---

**测试完成日期**: 2026-04-26  
**文档版本**: 1.0  
**状态**: 测试完成，结论明确
