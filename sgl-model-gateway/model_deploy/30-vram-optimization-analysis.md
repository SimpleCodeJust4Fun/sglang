# VRAM 优化分析报告

> **GPU**: RTX 4070 Ti Super (16GB)  
> **模型**: Qwen2.5-0.5B-Instruct  
> **日期**: 2026-04-26

---

## 1. 当前显存使用分析

### 1.1 Qwen2.5-0.5B 模型大小

```
模型参数量: 0.5B (500M)
FP16 精度: 500M × 2 bytes = 1.0GB
模型权重: ~1.0GB
```

### 1.2 当前配置 (2P+2D)

```
Prefill: 1.6GB (10%) × 2 = 3.2GB
Decode:  3.2GB (20%) × 2 = 6.4GB
总计:    9.6GB (60%)
剩余:    6.4GB (40%)
```

**问题**：为什么还有 6.4GB 剩余，但不能增加 Worker？

---

## 2. 显存组成分析

### 2.1 SGLang Worker 显存组成

```
总显存 = 模型权重 + KV Cache + 激活值 + 框架开销

模型权重 (固定):     ~1.0GB
KV Cache (可变):     0.5GB - 2.0GB (取决于 context_length 和 batch_size)
激活值 (可变):       0.2GB - 0.5GB
框架开销 (固定):     ~0.3GB (Python, CUDA context, etc.)
```

### 2.2 实际最小显存需求

```
单 Worker 最小显存:
  模型权重: 1.0GB
  最小 KV Cache: 0.3GB (context_length=512, batch_size=1)
  激活值: 0.2GB
  框架开销: 0.3GB
  -------------------------
  最小总计: 1.8GB

单 Worker 推荐显存:
  模型权重: 1.0GB
  推荐 KV Cache: 0.8GB (context_length=2048, batch_size=4)
  激活值: 0.3GB
  框架开销: 0.3GB
  -------------------------
  推荐总计: 2.4GB
```

---

## 3. 理论最大 Worker 数

### 3.1 计算公式

```
可用显存 = 总显存 - 系统保留
         = 16GB - 2GB (驱动/系统)
         = 14GB

最大 Worker 数 = floor(可用显存 / 单 Worker 最小显存)
              = floor(14GB / 1.8GB)
              = 7 个
```

### 3.2 实际可行配置

| 配置 | Worker 数 | 总显存 | 单 Worker 显存 | 可行性 |
|------|----------|-------|---------------|-------|
| 2P+2D | 4 | 9.6GB | 2.4GB | ✅ 当前 |
| 3P+3D | 6 | 14.4GB | 2.4GB | ⚠️ 极限 |
| 4P+4D | 8 | 19.2GB | 2.4GB | ❌ 超出 |
| 2P+3D | 5 | 12.0GB | 2.4GB | ✅ 可行 |
| 3P+2D | 5 | 12.0GB | 2.4GB | ✅ 可行 |

---

## 4. 优化方案

### 4.1 方案 A：降低单 Worker 显存（推荐）

**策略**：减少 `--mem-fraction-static` 和 `--context-length`

```bash
# 当前
--mem-fraction-static 0.10  # 1.6GB
--context-length 2048

# 优化
--mem-fraction-static 0.08  # 1.3GB
--context-length 1024       # 减少 KV Cache
```

**效果**：
```
单 Worker 显存: 1.6GB → 1.3GB (-18%)
最大 Worker 数: 8 个 (14GB / 1.3GB ≈ 10.7)
实际可行: 3P+3D = 6 个 (7.8GB)
剩余显存: 6.2GB (可用于突发负载)
```

---

### 4.2 方案 B：混合显存分配

**策略**：Prefill 和 Decode 使用不同的显存比例

```bash
# Prefill (需要较少显存，因为只做 prompt 处理)
--mem-fraction-static 0.06  # ~1.0GB

# Decode (需要更多显存，因为要存储生成历史)
--mem-fraction-static 0.12  # ~1.9GB
```

**效果 (3P+3D)**：
```
Prefill: 1.0GB × 3 = 3.0GB
Decode:  1.9GB × 3 = 5.7GB
总计:    8.7GB (54%)
剩余:    7.3GB (46%)
```

---

### 4.3 方案 C：极致优化（实验性）

**策略**：最小化所有参数

```bash
--mem-fraction-static 0.05      # ~0.8GB
--context-length 512            # 最小上下文
--schedule-conservativeness 0.8 # 更激进的调度
```

**效果 (4P+4D)**：
```
单 Worker: 0.8GB
8 Workers: 6.4GB
剩余: 9.6GB (60%)
```

**风险**：
- 上下文长度极短（512 tokens ≈ 250 中文字符）
- 容易 OOM
- 实用性低

---

## 5. 推荐配置

### 5.1 代码生成场景（Decode 密集）

```bash
# 2P+4D
Prefill: 0.08 (1.3GB) × 2 = 2.6GB
Decode:  0.15 (2.4GB) × 4 = 9.6GB
总计: 12.2GB (76%)
```

**启动命令**：
```bash
bash start-multi-pd.sh 2p4d
```

---

### 5.2 Agent 场景（Prefill 密集）

```bash
# 4P+2D
Prefill: 0.08 (1.3GB) × 4 = 5.2GB
Decode:  0.15 (2.4GB) × 2 = 4.8GB
总计: 10.0GB (62%)
```

**启动命令**：
```bash
bash start-multi-pd.sh 4p2d
```

---

### 5.3 平衡场景（推荐）

```bash
# 3P+3D
Prefill: 0.07 (1.1GB) × 3 = 3.3GB
Decode:  0.12 (1.9GB) × 3 = 5.7GB
总计: 9.0GB (56%)
```

**启动命令**：
```bash
bash start-multi-pd.sh 3p3d
```

---

## 6. 验证步骤

### 6.1 运行显存优化测试

```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash test-vram-optimization.sh
```

### 6.2 检查显存使用

```bash
# 启动后检查
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# 持续监控
watch -n 1 nvidia-smi
```

### 6.3 压力测试

```bash
# 发送长请求测试是否 OOM
python model_deploy/pd-test.py \
  "Write a complete Python function..." \
  --max-tokens 1000
```

---

## 7. 结论

### 7.1 关键发现

1. **当前配置有优化空间**：
   - 2P+2D 使用 9.6GB，剩余 6.4GB
   - 可以降低单 Worker 显存来增加 Worker 数

2. **理论最大 Worker 数**：
   - 最小配置 (0.8GB/Worker): 最多 10 个
   - 推荐配置 (1.3GB/Worker): 最多 7 个
   - 保守配置 (2.4GB/Worker): 最多 5 个

3. **推荐配置**：
   - **3P+3D** 是最优选择（6 Workers）
   - 调度配对从 4 增加到 9（+125%）
   - 显存使用 9.0GB（56%），剩余充足

### 7.2 下一步

1. 运行 `test-vram-optimization.sh` 验证理论分析
2. 选择最适合你场景的配置
3. 修改 `start-multi-pd.sh` 支持多配置切换

---

## 8. 风险提示

| 风险 | 缓解措施 |
|------|---------|
| OOM | 监控显存，设置合理的 `--mem-fraction-static` |
| 上下文过短 | 根据需求调整 `--context-length` |
| 性能下降 | 压力测试验证 |

---

*分析日期: 2026-04-26*
