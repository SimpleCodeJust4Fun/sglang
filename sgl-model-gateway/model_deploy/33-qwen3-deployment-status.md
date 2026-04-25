# Qwen3 模型部署状态记录

> **日期**: 2026-04-26  
> **目标**: 部署 Qwen3 并测试能否支持更多 worker

---

## 模型下载状态

### 正在下载的模型

1. **Qwen3-0.6B-MLX-4bit** (原始计划)
   - 路径: `/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit`
   - 状态: 下载中 (MLX 格式，可能不兼容 NVIDIA)
   - 问题: **MLX 是 Apple 专用格式**

2. **Qwen3-0.6B** (新选择 - FP16)
   - 路径: `/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3-0___6B`
   - 状态: 下载中 (标准 FP16 格式)
   - 优势: 完全兼容 SGLang

### 下载命令

```bash
# MLX-4bit (原始，可能不兼容)
modelscope download --model "Qwen/Qwen3-0.6B-MLX-4bit" \
    --local_dir /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit

# FP16 (新，推荐)
source ~/qwen_env/bin/activate
python3 -c "from modelscope import snapshot_download; print(snapshot_download('Qwen/Qwen3-0.6B'))"
```

---

## 已完成的准备工作

### 1. 脚本更新

✅ `start-multi-pd.sh` - 已更新支持 Qwen3 FP16
```bash
qwen3)
    MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3-0___6B"
    MODEL_DISPLAY="Qwen3-0.6B-FP16"
    ;;
```

✅ `setup-qwen3-0.6b.sh` - 已更新为 FP16 模型

✅ `test-qwen3-workers.sh` - 新创建的 Qwen3 专用测试脚本

### 2. 测试文档

✅ `32-qwen3-worker-density-test.md` - 详细的测试计划

---

## 预期对比分析

### Qwen2.5-0.5B vs Qwen3-0.6B-FP16

| 指标 | Qwen2.5-0.5B | Qwen3-0.6B-FP16 | 差异 |
|------|--------------|-----------------|------|
| 参数量 | 0.5B | 0.6B | +20% |
| 量化 | FP16 | FP16 | 相同 |
| 模型大小 | ~1.0GB | ~1.2GB | +20% |
| 单 worker 显存 | ~1.8GB | ~2.0GB | +11% |
| 最大 workers | 5-6 | 5-6 | **相似** |

### 关键发现预期

**如果 Qwen3 FP16 与 Qwen2.5 显存需求相似**:
- Worker 数量不会显著增加
- 优势在于推理质量提升（更新的模型）
- 适合验证模型质量而非密度优化

**如果想测试更高密度**:
- 需要真正的量化模型 (4-bit, 8-bit)
- 寻找 GGUF 或 AWQ 格式的 Qwen3
- 或使用更小的模型 (0.1B, 0.3B)

---

## 测试计划

### 下载完成后立即执行

```bash
# 1. 验证模型完整性
bash model_deploy/setup-qwen3-0.6b.sh

# 2. 运行 worker 密度测试
bash model_deploy/test-qwen3-workers.sh

# 3. 对比结果
# 查看文档: model_deploy/32-qwen3-worker-density-test.md
```

### 测试配置

1. **2P+2D** - 基线测试 (预期成功)
2. **2P+4D** - Agent 场景 (预期成功)
3. **3P+3D** - 边界测试 (Qwen2.5 在此失败)

### 如果 3P+3D 成功

继续测试：
- 3P+4D (7 workers)
- 4P+4D (8 workers)

### 如果 3P+3D 失败

结论：
- Qwen3 FP16 与 Qwen2.5 显存需求相似
- 需要量化版本才能支持更多 worker
- 记录实际 VRAM 使用数据

---

## 下一步行动

### 立即可做

1. ⏳ 等待模型下载完成
2. ⏳ 运行 `test-qwen3-workers.sh`
3. ⏳ 记录测试结果

### 下载完成后的分析

1. 对比 Qwen2.5 vs Qwen3 的 VRAM 使用
2. 分析 worker 密度差异
3. 决定是否寻找量化版本
4. 更新文档和脚本

### 长期优化

1. 寻找 Qwen3 的 4-bit/8-bit 版本 (非 MLX)
2. 测试其他小模型 (0.1B, 0.3B)
3. 优化 mem-fraction-static 配置
4. 探索 vLLM 或其他推理引擎的密度优化

---

## 故障排查

### 如果模型下载失败

```bash
# 检查网络
ping modelscope.cn

# 手动重试
source ~/qwen_env/bin/activate
modelscope download --model "Qwen/Qwen3-0.6B"

# 或使用 huggingface
# (需要配置代理)
```

### 如果 MLX 格式不兼容

```bash
# 使用 FP16 版本（已准备）
bash model_deploy/start-multi-pd.sh 2p2d qwen3

# 或寻找 GGUF/AWQ 格式
```

---

## 日志位置

- Qwen3 Prefill: `/tmp/sglang-qwen3-prefill-*.log`
- Qwen3 Decode: `/tmp/sglang-qwen3-decode-*.log`
- 测试输出: `/tmp/qwen3-test-output.log`

---

**状态**: 等待模型下载完成  
**更新时间**: 2026-04-26 01:30  
**文档版本**: 1.0
