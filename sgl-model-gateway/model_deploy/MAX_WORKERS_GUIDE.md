# PD Worker 最大化部署指南

> **GPU**: RTX 4070 Ti Super (16GB)  
> **日期**: 2026-04-26  
> **目标**: 最大化 Worker 数量以优化调度研究

---

## 快速开始

### 1. 验证最大 Worker 数

```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash test-max-workers.sh
```

这将自动测试 9 种配置，找到最优解。

---

### 2. 下载 Qwen3-0.6B 模型（可选）

```bash
bash setup-qwen3-0.6b.sh
```

**Qwen3 vs Qwen2.5 对比**：
- 参数量: 0.6B vs 0.5B (+20%)
- 更新: 2025 vs 2024
- 性能: 预计提升 10-15%
- 显存需求: 相似（4bit 量化）

---

### 3. 启动服务

#### 使用 Qwen2.5

```bash
# 3P+3D (推荐)
bash start-multi-pd.sh 3p3d

# 2P+4D (代码生成)
bash start-multi-pd.sh 2p4d

# 4P+2D (文档分析)
bash start-multi-pd.sh 4p2d
```

#### 使用 Qwen3

```bash
bash start-multi-pd.sh 3p3d qwen3
```

---

## 测试的配置矩阵

| 配置 ID | 名称 | P | D | 总 Worker | 配对数 | Prefill% | Decode% | 预估显存 |
|---------|------|---|---|----------|-------|----------|---------|---------|
| 1 | 2P+2D-Baseline | 2 | 2 | 4 | 4 | 10% | 20% | 9.6GB |
| 2 | 3P+3D-Balanced | 3 | 3 | 6 | 9 | 7% | 12% | 9.0GB |
| 3 | 2P+4D-DecodeHeavy | 2 | 4 | 6 | 8 | 8% | 15% | 12.2GB |
| 4 | 4P+2D-PrefillHeavy | 4 | 2 | 6 | 8 | 8% | 15% | 10.0GB |
| 5 | 3P+4D-MoreWorkers | 3 | 4 | 7 | 12 | 6% | 10% | 11.2GB |
| 6 | 4P+4D-MaxBalanced | 4 | 4 | 8 | 16 | 6% | 10% | 12.8GB |
| 7 | 2P+6D-ExtremeDecode | 2 | 6 | 8 | 12 | 8% | 8% | 12.8GB |
| 8 | 6P+2D-ExtremePrefill | 6 | 2 | 8 | 12 | 8% | 8% | 12.8GB |
| 9 | 5P+5D-Maximum | 5 | 5 | 10 | 25 | 5% | 5% | 16.0GB |

---

## 预期结果

### 保守估计（必成功）
- **3P+3D**: 6 Workers, 9 配对
- 显存使用: ~9GB (56%)
- 适合所有场景

### 乐观估计（可能成功）
- **4P+4D**: 8 Workers, 16 配对
- 显存使用: ~12.8GB (78%)
- 调度空间增加 300%

### 极限估计（实验性）
- **5P+5D**: 10 Workers, 25 配对
- 显存使用: ~16GB (100%)
- 最大调度空间

---

## 显存计算

### Qwen2.5-0.5B

```
模型权重 (FP16): 1.0GB
最小 KV Cache:   0.3GB
激活值:          0.2GB
框架开销:        0.3GB
-------------------------
单 Worker 最小:  1.8GB
单 Worker 推荐:  2.4GB
```

### Qwen3-0.6B (4bit)

```
模型权重 (4bit): 0.4GB (量化!)
最小 KV Cache:   0.3GB
激活值:          0.2GB
框架开销:        0.3GB
-------------------------
单 Worker 最小:  1.2GB
单 Worker 推荐:  1.6GB
```

**优势**: Qwen3 使用 4bit 量化，显存需求更低！

---

## 推荐配置

### 用于调度研究（推荐）

```bash
# 最大配对数
bash start-multi-pd.sh 4p4d

# 或
bash start-multi-pd.sh 5p5d  # 如果显存允许
```

**优势**:
- 16-25 种调度配对
- 充分验证策略差异
- 适合性能基准测试

---

### 用于生产部署

```bash
# 稳定配置
bash start-multi-pd.sh 3p3d
```

**优势**:
- 显存使用合理 (56%)
- 留有充足余量
- 适合长期使用

---

## 监控和验证

### 检查 Worker 状态

```bash
# 查看进程
ps aux | grep sglang | grep -v grep

# 检查显存
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# 持续监控
watch -n 1 nvidia-smi
```

### 验证功能

```bash
# 测试单个请求
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'
```

---

## 故障排查

### 问题 1: Worker 启动失败

**症状**: OOM 错误

**解决**:
```bash
# 降低显存比例
# 编辑 start-multi-pd.sh
PREFILL_MEM=0.05  # 从 0.06 降低
DECODE_MEM=0.08   # 从 0.10 降低
```

---

### 问题 2: Qwen3 模型加载失败

**症状**: 模型格式错误

**解决**:
```bash
# 检查是否是 MLX 格式
ls -lh /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit/

# 如果 SGLang 不支持 MLX 格式，需要转换
# 或下载 PyTorch 版本
modelscope download --model "Qwen/Qwen3-0.6B" --local_dir /path/to/qwen3-pytorch
```

---

## 下一步

1. ✅ 运行 `test-max-workers.sh` 验证可行性
2. ✅ 选择最优配置用于你的研究
3. ✅ 下载 Qwen3 模型对比性能
4. ✅ 运行调度策略测试

---

## 相关文档

- **VRAM 优化**: `VRAM_OPTIMIZATION_GUIDE.md`
- **分离策略**: `29-pd-separate-policy-optimization.md`
- **代码生成**: `28-agent-codegen-test-guide.md`

---

*创建日期: 2026-04-26*
