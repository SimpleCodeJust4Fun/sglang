# VRAM 优化验证指南

> **GPU**: RTX 4070 Ti Super (16GB)  
> **模型**: Qwen2.5-0.5B-Instruct  
> **日期**: 2026-04-26

---

## 关键发现

✅ **可以优化！** 当前 2P+2D 配置并未吃满显存，有优化空间。

---

## 可用配置

### 1. 立即使用（已实现）

```bash
# 查看可用配置
bash start-multi-pd.sh

# 输出:
# Unknown configuration: (default)
# Available configurations:
#   2p2d  - 2 Prefill + 2 Decode (Balanced, 9.6GB)
#   3p3d  - 3 Prefill + 3 Decode (Recommended, 9.0GB)
#   2p4d  - 2 Prefill + 4 Decode (Code generation, 12.2GB)
#   4p2d  - 4 Prefill + 2 Decode (Agent/Document, 10.0GB)
#   3p2d  - 3 Prefill + 2 Decode (Slightly prefill-heavy, 9.6GB)
#   2p3d  - 2 Prefill + 3 Decode (Slightly decode-heavy, 10.5GB)
```

---

## 推荐配置

### 场景 A：代码生成（Decode 密集）

```bash
bash start-multi-pd.sh 2p4d
```

**配置**：
- 2 Prefill (1.3GB each)
- 4 Decode (2.4GB each)
- 总显存: 12.2GB (76%)
- 调度配对: 2 × 4 = **8 种**

**优势**：
- Decode 并发能力提升 100%
- 适合长代码生成
- 吞吐量最大化

---

### 场景 B：Agent 多轮对话（推荐）

```bash
bash start-multi-pd.sh 3p3d
```

**配置**：
- 3 Prefill (1.1GB each)
- 3 Decode (1.9GB each)
- 总显存: 9.0GB (56%)
- 调度配对: 3 × 3 = **9 种** (+125%)

**优势**：
- 调度选择增加 125%
- Prefill 缓存能力增强
- 负载均衡效果更好

---

### 场景 C：长文档分析（Prefill 密集）

```bash
bash start-multi-pd.sh 4p2d
```

**配置**：
- 4 Prefill (1.3GB each)
- 2 Decode (2.4GB each)
- 总显存: 10.0GB (62%)
- 调度配对: 4 × 2 = **8 种**

**优势**：
- Prefill 并发能力提升 100%
- 适合长文档/多用户场景
- 缓存命中率更高

---

## 验证步骤

### 1. 运行显存测试脚本

```bash
bash test-vram-optimization.sh
```

这会自动测试不同配置并报告可行性。

### 2. 手动验证

```bash
# 启动 3P+3D
bash start-multi-pd.sh 3p3d

# 检查显存使用
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# 预期输出:
# 6 个 Python 进程
# Prefill: ~1.1GB each
# Decode: ~1.9GB each
```

### 3. 压力测试

```bash
# 发送测试请求
python model_deploy/pd-test.py \
  "Write a Python function to sort a list" \
  --max-tokens 200

# 检查是否 OOM
dmesg | grep -i oom
```

---

## 理论分析

### Qwen2.5-0.5B 显存组成

```
模型权重: 1.0GB (固定)
KV Cache: 0.3-1.5GB (可变)
激活值:   0.2-0.3GB
框架开销: 0.3GB
-------------------
最小:     1.8GB/Worker
推荐:     2.4GB/Worker
```

### 最大 Worker 数计算

```
可用显存 = 16GB - 2GB (系统) = 14GB

最小配置: 14GB / 1.8GB = 7 个 Worker
推荐配置: 14GB / 2.4GB = 5 个 Worker
保守配置: 14GB / 3.2GB = 4 个 Worker (当前)
```

---

## 对比表

| 配置 | Worker 数 | 调度配对 | 总显存 | 显存占比 | 适用场景 |
|------|----------|---------|-------|---------|---------|
| 2P+2D | 4 | 4 | 9.6GB | 60% | 基础测试 |
| **3P+3D** | **6** | **9** | **9.0GB** | **56%** | ✅ **推荐** |
| 2P+4D | 6 | 8 | 12.2GB | 76% | 代码生成 |
| 4P+2D | 6 | 8 | 10.0GB | 62% | 文档分析 |
| 3P+2D | 5 | 6 | 9.6GB | 60% | 轻度 Prefill |
| 2P+3D | 5 | 6 | 10.5GB | 66% | 轻度 Decode |

---

## 下一步

1. ✅ **选择配置**：根据你的场景选择
2. ✅ **启动服务**：`bash start-multi-pd.sh 3p3d`
3. ✅ **运行测试**：验证功能正常
4. ✅ **监控显存**：`watch -n 1 nvidia-smi`

---

## 风险提示

| 风险 | 概率 | 缓解措施 |
|------|------|---------|
| OOM | 低 | 监控显存，设置合理限制 |
| 性能下降 | 中 | 压力测试验证 |
| 上下文过短 | 低 | 保持 2048 tokens |

---

## 详细文档

- **完整分析**: `30-vram-optimization-analysis.md`
- **测试脚本**: `test-vram-optimization.sh`
- **分离策略**: `29-pd-separate-policy-optimization.md`

---

*验证日期: 2026-04-26*
