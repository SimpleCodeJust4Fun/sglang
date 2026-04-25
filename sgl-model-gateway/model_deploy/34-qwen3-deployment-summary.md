# Qwen3 模型部署与 Worker 密度测试总结

> **日期**: 2026-04-26  
> **状态**: 模型下载中，准备工作已完成

---

## 当前状态

### 模型下载进度

1. **Qwen3-0.6B-FP16** (推荐)
   - 状态: 下载中
   - 路径: `/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3-0___6B`
   - 预计完成: 取决于网络速度

2. **Qwen3-0.6B-MLX-4bit** (原始计划)
   - 状态: 下载中
   - 问题: MLX 是 Apple 专用，可能不兼容

### 已完成的准备工作

✅ **脚本更新**
- `start-multi-pd.sh`: 支持 Qwen3 FP16
- `setup-qwen3-0.6b.sh`: 更新为 FP16 模型路径
- `test-qwen3-workers.sh`: 新创建的 Qwen3 测试脚本

✅ **文档创建**
- `32-qwen3-worker-density-test.md`: 详细测试计划
- `33-qwen3-deployment-status.md`: 状态记录

---

## 关键发现

### MLX 格式问题

**发现**: MLX (Machine Learning Exchange) 是 Apple 专用的模型格式

**影响**:
- 不兼容 NVIDIA GPU + CUDA
- SGLang 可能无法加载
- 需要使用标准格式 (FP16, GGUF, AWQ)

**解决方案**:
- 已切换到 `Qwen3-0.6B` (FP16 格式)
- 完全兼容，但显存需求与 Qwen2.5 相似

### 预期对比结果

基于模型大小分析：

| 模型 | 参数 | 格式 | 大小 | 单 Worker | 最大 Workers |
|------|------|------|------|-----------|--------------|
| Qwen2.5-0.5B | 0.5B | FP16 | ~1.0GB | ~1.8GB | 5-6 |
| Qwen3-0.6B-FP16 | 0.6B | FP16 | ~1.2GB | ~2.0GB | 5-6 (相似) |

**结论预期**:
- Qwen3 FP16 **不会**显著增加 worker 数量
- 优势在于推理质量提升（更新模型）
- 如需更高密度，需要量化版本 (4-bit GGUF/AWQ)

---

## 下载完成后的测试步骤

### 步骤 1: 验证模型

```bash
bash model_deploy/setup-qwen3-0.6b.sh
```

这会：
1. 检查模型文件完整性
2. 启动单 worker 测试
3. 运行推理验证

### 步骤 2: 运行 Worker 密度测试

```bash
bash model_deploy/test-qwen3-workers.sh
```

这将测试：
1. 2P+2D (基线，预期成功)
2. 2P+4D (Agent 场景，预期成功)
3. 3P+3D (边界测试，关键对比点)

### 步骤 3: 对比分析

对比 Qwen2.5 和 Qwen3 的测试结果：

| 配置 | Qwen2.5 VRAM | Qwen3 VRAM | 差异 |
|------|-------------|-----------|------|
| 2P+2D | 13.9GB | 待测试 | ? |
| 2P+4D | 13.8GB | 待测试 | ? |
| 3P+3D | OOM | 待测试 | ? |

---

## 如果需要更高 Worker 密度

### 方案 A: 使用量化模型

寻找 Qwen3 的其他格式：

```bash
# GGUF 格式 (4-bit/8-bit)
modelscope download --model "Qwen/Qwen3-0.6B-GGUF"

# AWQ 格式 (4-bit)
modelscope download --model "Qwen/Qwen3-0.6B-AWQ"
```

预期收益：
- 4-bit: 模型 ~0.4GB，单 worker ~1.2GB
- 理论最大 workers: 7-9 个

### 方案 B: 使用更小模型

```bash
# 0.1B 或 0.3B 模型（如果可用）
modelscope download --model "Qwen/Qwen3-0.1B"
```

### 方案 C: 优化现有配置

继续使用 Qwen2.5-0.5B，但优化配置：

```bash
# 激进配置 (可能支持 7 workers)
# Prefill: 0.06, Decode: 0.10
# 2P+5D = 2×1.0 + 5×1.6 = 10GB (理论可行)
```

---

## 立即可执行的测试

### 使用 Qwen2.5 测试激进配置

```bash
# 清理
killall -9 python3

# 启动 2P+5D 测试
source ~/qwen_env/bin/activate
MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct"

# 2 Prefill
for i in 1 2; do
    port=$((30000 + i - 1))
    bootstrap=$((90000 + i - 1))
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.07 \
        --tp 1 \
        --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        --host 127.0.0.1 \
        --context-length 2048 \
        --log-level warning > /tmp/test-2p5d-prefill-$i.log 2>&1 &
    sleep 3
done

# 5 Decode
for i in 1 2 3 4 5; do
    port=$((31000 + i - 1))
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.10 \
        --tp 1 \
        --pd decode \
        --host 127.0.0.1 \
        --context-length 2048 \
        --log-level warning > /tmp/test-2p5d-decode-$i.log 2>&1 &
    sleep 3
done

# 等待稳定性
sleep 15

# 检查存活
ps aux | grep sglang | grep -v grep | wc -l

# 检查 VRAM
nvidia-smi
```

**预期**:
- 如果成功: 7 workers, 10 调度对
- VRAM 使用: ~12-14GB

---

## 文档索引

### 相关文档

1. `31-vram-test-analysis.md` - Qwen2.5 VRAM 测试详细分析
2. `32-qwen3-worker-density-test.md` - Qwen3 测试计划
3. `33-qwen3-deployment-status.md` - 部署状态记录
4. `MAX_WORKERS_GUIDE.md` - Worker 最大化部署指南

### 测试脚本

1. `test-worker-deployment.sh` - 简化 worker 测试 (已验证)
2. `test-qwen3-workers.sh` - Qwen3 专用测试 (待使用)
3. `start-multi-pd.sh` - 多 worker 启动脚本 (已更新)

---

## 下一步行动

### 等待模型下载完成后

1. ✅ 运行 `setup-qwen3-0.6b.sh` 验证模型
2. ✅ 运行 `test-qwen3-workers.sh` 执行测试
3. ✅ 对比 Qwen2.5 vs Qwen3 结果
4. ✅ 更新文档记录实际数据

### 如果想立即测试更高密度

1. 使用 Qwen2.5 测试 2P+5D 或 3P+4D 配置
2. 寻找 Qwen3 的量化版本 (GGUF/AWQ)
3. 考虑使用更小的模型 (0.1B, 0.3B)

---

**总结**: 
- 准备工作已全部完成
- 脚本已更新支持 Qwen3
- 等待模型下载完成即可开始测试
- 预期 Qwen3 FP16 与 Qwen2.5 显存需求相似
- 如需更高密度，需要量化模型

**更新时间**: 2026-04-26 01:35  
**文档版本**: 1.0
