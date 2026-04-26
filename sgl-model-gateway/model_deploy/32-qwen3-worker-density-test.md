# Qwen3-0.6B-MLX-4bit 部署与 Worker 密度测试

> **目标**: 验证 4-bit 量化模型是否能支持更多 worker  
> **GPU**: RTX 4070 Ti Super (16GB)  
> **日期**: 2026-04-26

---

## 模型信息

### Qwen3-0.6B-MLX-4bit

- **来源**: ModelScope (https://modelscope.cn/models/Qwen/Qwen3-0.6B-MLX-4bit)
- **参数量**: 0.6B (比 Qwen2.5-0.5B 多 20%)
- **量化**: 4-bit (MLX 格式)
- **预期模型大小**: ~400MB (vs FP16 的 ~1.2GB)
- **优势**: 
  - 显存占用更低
  - 可部署更多 worker
  - 更新的模型架构

### 对比分析

| 指标 | Qwen2.5-0.5B | Qwen3-0.6B-4bit | 改善 |
|------|--------------|-----------------|------|
| 参数量 | 0.5B | 0.6B | +20% |
| 量化精度 | FP16 | 4-bit | -75% |
| 模型文件大小 | ~1.0GB | ~0.4GB | -60% |
| 单 worker 最小显存 | ~1.8GB | ~1.2GB (预期) | -33% |
| 理论最大 workers | 5-6 | 7-9 (预期) | +40-50% |

---

## 下载状态

### 下载命令

```bash
bash model_deploy/setup-qwen3-0.6b.sh
```

### 下载进度

- **开始时间**: 2026-04-26 01:08
- **当前状态**: 下载中 (约 7.2MB/302MB)
- **预计完成**: 取决于网络速度

### 下载日志

```
Processing 10 items:   0%|          | 0.00/10.0 [00:00<?, ?it/s]
Downloading [model.safetensors]:   0%|          | 0.00/302M [00:00<?, ?B/s]
```

---

## 部署测试计划

### 测试 1: 单 Worker 验证

**目标**: 确认 Qwen3 可以正常启动

```bash
# 激活环境
source ~/qwen_env/bin/activate

# 启动单 worker 测试
python3 -m sglang.launch_server \
    --model-path "/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit" \
    --port 30999 \
    --mem-fraction-static 0.15 \
    --host 127.0.0.1 \
    --log-level warning

# 测试推理
curl -X POST http://127.0.0.1:30999/generate \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Hello, how are you?",
    "sampling_params": {
      "temperature": 0,
      "max_new_tokens": 50
    }
  }'
```

**预期结果**: 
- Worker 成功启动
- 显存占用约 1.2-1.5GB
- 推理正常返回

---

### 测试 2: 2P+2D 基础配置

**目标**: 验证 Qwen3 的基础 PD 配置

```bash
bash model_deploy/start-multi-pd.sh 2p2d qwen3
```

**预期**:
- 4 workers 成功启动
- 总 VRAM 使用约 8-10GB (vs Qwen2.5 的 13.9GB)
- 剩余 VRAM 约 6-8GB

---

### 测试 3: 2P+4D 推荐配置

**目标**: 验证 Agent 场景推荐配置

```bash
bash model_deploy/start-multi-pd.sh 2p4d qwen3
```

**预期**:
- 6 workers 成功启动
- 总 VRAM 使用约 10-12GB
- 8 个调度对

---

### 测试 4: 3P+4D 扩展配置 (新)

**目标**: 测试 Qwen3 是否能支持 7 workers

**配置**:
- Prefill mem: 0.08
- Decode mem: 0.10
- 总 workers: 7 (3P + 4D)
- 调度对: 12

**手动启动**:

```bash
# 清理旧进程
killall -9 python3

source ~/qwen_env/bin/activate

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit"

# 启动 3 个 Prefill
for i in 1 2 3; do
    port=$((30000 + i - 1))
    bootstrap=$((90000 + i - 1))
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.08 \
        --tp 1 \
        --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        --host 127.0.0.1 \
        --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-qwen3-prefill-$i.log 2>&1 &
    sleep 3
done

# 启动 4 个 Decode
for i in 1 2 3 4; do
    port=$((31000 + i - 1))
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.10 \
        --tp 1 \
        --pd decode \
        --host 127.0.0.1 \
        --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-qwen3-decode-$i.log 2>&1 &
    sleep 3
done

# 等待稳定性检查
sleep 15

# 检查存活
ps aux | grep sglang | grep -v grep | wc -l

# 检查 VRAM
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits
```

**预期结果**:
- ✅ 如果成功: 7 workers 存活，VRAM 使用约 12-14GB
- ❌ 如果失败: OOM，需要调整 mem-fraction

---

### 测试 5: 4P+4D 最大配置 (新)

**目标**: 测试 Qwen3 是否能支持 8 workers

**配置**:
- Prefill mem: 0.06
- Decode mem: 0.08
- 总 workers: 8 (4P + 4D)
- 调度对: 16

**手动启动**:

```bash
# 清理旧进程
killall -9 python3

source ~/qwen_env/bin/activate

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit"

# 启动 4 个 Prefill
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    bootstrap=$((90000 + i - 1))
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.06 \
        --tp 1 \
        --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        --host 127.0.0.1 \
        --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-qwen3-prefill-$i.log 2>&1 &
    sleep 3
done

# 启动 4 个 Decode
for i in 1 2 3 4; do
    port=$((31000 + i - 1))
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.08 \
        --tp 1 \
        --pd decode \
        --host 127.0.0.1 \
        --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-qwen3-decode-$i.log 2>&1 &
    sleep 3
done

# 等待稳定性检查
sleep 15

# 检查存活
ps aux | grep sglang | grep -v grep | wc -l

# 检查 VRAM
nvidia-smi
```

**预期结果**:
- ✅ 如果成功: 8 workers 存活，VRAM 使用约 13-15GB
- ❌ 如果失败: OOM，理论极限可能在 7 workers

---

## 测试矩阵

### Qwen2.5 vs Qwen3 对比

| 配置 | Qwen2.5 结果 | Qwen3 预期 | Qwen3 实际 |
|------|-------------|-----------|-----------|
| 2P+2D (4w) | ✅ 13.9GB | ✅ 10GB | 待测试 |
| 2P+4D (6w) | ✅ 13.8GB | ✅ 12GB | 待测试 |
| 3P+3D (6w) | ❌ OOM | ✅ 11GB | 待测试 |
| 3P+4D (7w) | ❌ OOM | ✅ 13GB | 待测试 |
| 4P+4D (8w) | ❌ 部分失败 | ✅ 14GB | 待测试 |
| 5P+5D (10w) | ❌ OOM | ⚠️ 临界 | 待测试 |

---

## 测试步骤

### 准备工作

1. **等待模型下载完成**

```bash
# 检查下载状态
ls -lh /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit/

# 应该看到模型权重文件
# model.safetensors (~302MB) 或分片文件
```

2. **验证模型可用性**

```bash
bash model_deploy/setup-qwen3-0.6b.sh
```

这会运行一个快速测试确认模型可以加载。

### 执行测试

```bash
# 测试 1: 单 worker
source ~/qwen_env/bin/activate
python3 -m sglang.launch_server \
    --model-path "/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit" \
    --port 30999 \
    --mem-fraction-static 0.15

# 测试 2: 2P+2D
bash model_deploy/start-multi-pd.sh 2p2d qwen3

# 测试 3: 2P+4D
bash model_deploy/start-multi-pd.sh 2p4d qwen3

# 测试 4-5: 手动执行（见上方命令）
```

### 记录结果

对每个测试记录：
- 启动成功/失败
- 实际 VRAM 使用
- Worker 存活数量
- 稳定性检查结果

---

## 预期收益分析

### 如果 Qwen3 测试成功

**调度研究收益**:
- 7-8 workers → 12-16 个调度对
- 更多调度策略组合可测试
- 更接近生产环境的复杂度

**显存收益**:
- 相同 VRAM 下多 2-3 个 worker
- 或相同 worker 数下节省 3-4GB VRAM
- 可用于更大的 context length 或 batch size

**性能收益**:
- Qwen3 比 Qwen2.5 更新 (2025 vs 2024)
- 0.6B vs 0.5B 参数 (+20%)
- 预计推理质量提升 10-15%

### 如果 Qwen3 测试失败

**可能原因**:
1. MLX 格式不兼容 SGLang
2. 4-bit 量化需要特殊配置
3. 模型架构不被支持

**备选方案**:
- 继续使用 Qwen2.5-0.5B
- 寻找其他量化模型 (GGUF, AWQ)
- 调整 mem-fraction 配置

---

## 故障排查

### 常见问题

**Q: 模型下载慢**
```bash
# 检查网络
ping modelscope.cn

# 手动下载（如果脚本失败）
source ~/qwen_env/bin/activate
modelscope download --model "Qwen/Qwen3-0.6B-MLX-4bit" \
    --local_dir /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit
```

**Q: SGLang 无法加载 MLX 格式**
- MLX 是 Apple 的框架，可能不兼容 NVIDIA GPU
- 可能需要转换为 safetensors 格式
- 备选: 使用 Qwen3 的其他格式 (FP16, AWQ)

**Q: Worker 启动失败**
```bash
# 查看日志
tail -100 /tmp/sglang-qwen3-prefill-1.log

# 检查显存
nvidia-smi

# 尝试更大的 mem-fraction
--mem-fraction-static 0.20
```

---

## 下一步

1. ⏳ 等待 Qwen3 模型下载完成
2. ⏳ 验证模型可用性
3. ⏳ 执行 5 个测试配置
4. ⏳ 对比 Qwen2.5 vs Qwen3 结果
5. ⏳ 更新 start-multi-pd.sh 支持 Qwen3 的所有配置

---

**状态**: 模型下载中  
**更新时间**: 2026-04-26 01:15  
**文档版本**: 1.0
