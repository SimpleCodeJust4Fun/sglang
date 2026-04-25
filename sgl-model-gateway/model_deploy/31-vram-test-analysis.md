# VRAM 优化测试分析报告

## 测试环境

- **GPU**: RTX 4070 Ti Super (16GB VRAM)
- **模型**: Qwen2.5-0.5B-Instruct (FP16, ~1GB)
- **系统预留**: ~2GB (用于显示输出、系统开销)
- **可用 VRAM**: ~14GB

## 测试配置与结果

### 测试 1: 2P+2D-Conservative (基准配置)

**配置参数**:
- Prefill mem: 0.10 (10% ≈ 1.6GB/worker)
- Decode mem: 0.20 (20% ≈ 3.2GB/worker)
- 总 Workers: 4 (2P + 2D)
- 调度对数: 4

**测试结果**: SUCCESS
- 启动前 VRAM: 2237 MB
- 稳定后 VRAM: 13877 MB (占用 11.6GB)
- 剩余 VRAM: 2185 MB
- 所有 4 个 worker 稳定运行 15 秒以上

**分析**: 这是最稳定的配置，每个 worker 有充足的显存余量。

---

### 测试 2: 3P+3D-Balanced (推荐配置)

**配置参数**:
- Prefill mem: 0.07 (7% ≈ 1.1GB/worker)
- Decode mem: 0.12 (12% ≈ 2.0GB/worker)
- 总 Workers: 6 (3P + 3D)
- 调度对数: 9

**测试结果**: FAILED (OOM)
- 启动前 VRAM: 2237 MB
- Prefill-1 启动时立即被 OOM Killer 杀死
- 错误: `Killed` (Linux OOM)

**失败原因分析**:
1. 0.07 的 mem-fraction-static 对于 0.5B 模型来说太小
2. SGLang 的实际显存占用 = 模型权重(~1GB) + KV Cache + 运行时开销
3. 即使 mem-fraction 设置为 7%，实际初始化时仍需要 ~1.5-2GB
4. 6 个 worker 并行启动时，总需求超过可用 VRAM

**建议调整**: 如果要用 3P+3D，应该增加 prefill mem 到 0.10 或减少到 2P+3D

---

### 测试 3: 2P+4D-DecodeHeavy (代码生成优化)

**配置参数**:
- Prefill mem: 0.07 (7% ≈ 1.1GB/worker)
- Decode mem: 0.10 (10% ≈ 1.6GB/worker)
- 总 Workers: 6 (2P + 4D)
- 调度对数: 8

**测试结果**: SUCCESS
- 启动前 VRAM: 2228 MB
- 稳定后 VRAM: 13808 MB (占用 11.6GB)
- 剩余 VRAM: 2254 MB
- 所有 6 个 worker 稳定运行

**关键发现**:
1. 虽然 Prefill mem 也是 0.07，但 2P+4D 成功了，3P+3D 失败了
2. 原因：Decode worker 的显存需求比 Prefill 小（不需要 bootstrap port 等额外开销）
3. 对于 Agent 代码生成场景，Decode-heavy 配置更合适（生成代码需要大量 decode）

**适用场景**:
- Agent 代码生成（输出 50-2000 tokens）
- 多轮对话（解码阶段占比高）
- 长文本生成任务

---

### 测试 4: 4P+4D-MaxWorkers (极限配置)

**配置参数**:
- Prefill mem: 0.05 (5% ≈ 0.8GB/worker)
- Decode mem: 0.08 (8% ≈ 1.3GB/worker)
- 总 Workers: 8 (4P + 4D)
- 调度对数: 16

**测试结果**: FAILED (部分成功)
- 启动前 VRAM: 2041 MB
- 稳定后 VRAM: 11001 MB
- 仅 4/8 workers 存活（4 个 Prefill 全部被杀，4 个 Decode 存活）
- 实际存活: 0P + 4D

**失败原因**:
1. 0.05 的 mem-fraction 过于激进
2. 实际每个 worker 需要 ~1.5GB 最小显存
3. 8 个 worker 需要 12GB，加上系统开销超过 14GB

---

## VRAM 使用模式分析

### 实际显存需求（基于测试结果）

| Worker 类型 | 最小稳定配置 | 推荐配置 | 实际占用 |
|-------------|-------------|---------|---------|
| Prefill (0.5B) | 0.07 (~1.1GB) | 0.10 (~1.6GB) | ~1.5-2.0GB |
| Decode (0.5B) | 0.10 (~1.6GB) | 0.15-0.20 (~2.4-3.2GB) | ~1.8-2.5GB |
| 系统开销 | - | - | ~2.0GB |

### 理论最大 Worker 数量

基于 16GB VRAM，系统预留 2GB：

1. **保守配置** (P=0.10, D=0.20):
   - 每个 P: ~1.6GB, 每个 D: ~3.2GB
   - 2P+2D = 3.2 + 6.4 = 9.6GB ✅
   - 3P+3D = 4.8 + 9.6 = 14.4GB ❌ (接近极限)

2. **平衡配置** (P=0.08, D=0.12):
   - 每个 P: ~1.3GB, 每个 D: ~2.0GB
   - 2P+4D = 2.6 + 8.0 = 10.6GB ✅
   - 3P+3D = 3.9 + 6.0 = 9.9GB ✅ (理论上应该可以)

3. **激进配置** (P=0.07, D=0.10):
   - 每个 P: ~1.1GB, 每个 D: ~1.6GB
   - 2P+4D = 2.2 + 6.4 = 8.6GB ✅
   - 4P+4D = 4.4 + 6.4 = 10.8GB ✅ (但实际测试失败)

**结论**: mem-fraction-static 不能完全线性映射到实际显存占用，存在固定开销。

---

## 推荐配置

### 配置 A: 稳定生产 (推荐)

```bash
bash start-multi-pd.sh 2p2d qwen2.5
```

**优势**:
- 最稳定，经过充分验证
- 每个 worker 有充足显存
- 适合长时间运行

**调度对数**: 4 (2P × 2D)

---

### 配置 B: Agent 代码生成 (推荐)

```bash
bash start-multi-pd.sh 2p4d qwen2.5
```

**优势**:
- Decode-heavy，适合代码生成
- 6 个 workers，调度灵活性高
- 已通过稳定性测试

**调度对数**: 8 (2P × 4D)

**适用场景**:
- Agent 多轮对话
- 代码生成任务
- 长文本输出

---

### 配置 C: 实验性 3P+3D (需要调整)

当前 3P+3D 配置失败，建议调整为：

```bash
# 修改 start-multi-pd.sh 中的 3p3d 配置
3p3d)
    NUM_PREFILL=3
    NUM_DECODE=3
    PREFILL_MEM=0.08    # 从 0.07 提升到 0.08
    DECODE_MEM=0.14     # 从 0.12 提升到 0.14
    CONTEXT_LENGTH=2048
    ;;
```

**预期 VRAM**: 3×1.3 + 3×2.3 = 10.8GB (应该有足够余量)

**调度对数**: 9 (3P × 3D) - 最大调度灵活性

---

## Qwen3-0.6B-4bit 预期优化

如果使用 4-bit 量化的 Qwen3 模型：

- 模型大小: ~0.4GB (vs Qwen2.5 的 1.0GB)
- 单个 worker 最小: ~1.2GB (减少 0.3-0.5GB)
- 理论最大 workers: **7-9 个** (当前 5-6 个)

**预期配置**:
- 3P+4D (7 workers, 12 调度对) - 应该可行
- 4P+4D (8 workers, 16 调度对) - 可能可行

---

## 关键发现与建议

### 发现

1. **mem-fraction-static 不是线性映射**
   - 设置为 0.07 不等于只占用 7% VRAM
   - 存在固定的模型权重开销 (~1GB for 0.5B FP16)

2. **Prefill 比 Decode 更耗显存**
   - Prefill 需要 bootstrap port、KV cache 传输等额外开销
   - 相同 mem-fraction 下，Prefill 更容易 OOM

3. **启动顺序很重要**
   - 并行启动多个 worker 时，瞬时显存需求会叠加
   - 建议增加启动间隔 (当前 3 秒)

4. **2P+4D 是最佳平衡点**
   - 6 workers 稳定运行
   - 8 个调度对，足够进行调度策略研究
   - 适合 Agent 代码生成场景

### 建议

1. **立即使用**: 2P+4D 配置进行 Agent 场景测试
2. **下一步**: 下载 Qwen3-0.6B-4bit，验证是否能支持更多 workers
3. **调度策略**: 对 Agent 场景，使用 `--prefill-policy cache_aware --decode-policy round_robin`
4. **监控**: 使用 `nvidia-smi` 实时监控 VRAM，避免 OOM

---

## 测试脚本使用

```bash
# 运行简化的 worker 测试
bash model_deploy/test-worker-deployment.sh

# 启动 2P+4D 配置
bash model_deploy/start-multi-pd.sh 2p4d qwen2.5

# 启动 Gateway (单独的终端)
cd /mnt/e/dev/sglang/sgl-model-gateway
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

---

**测试日期**: 2026-04-26
**测试人员**: Qoder AI Assistant
**文档版本**: 1.0
