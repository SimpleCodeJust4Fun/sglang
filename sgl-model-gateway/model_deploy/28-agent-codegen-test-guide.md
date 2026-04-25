# Agent 代码生成场景测试使用指南

> **创建日期**: 2026-04-26  
> **目标**: 测试不同调度策略在代码生成场景（Decode 密集型）的表现

---

## 1. 场景概述

代码生成场景的特点：
- **Decode 密集型**：Prefill/Decode 比值约 0.1:1
- **长输出**：需要生成 500-2000 tokens 的代码
- **对 Decode 性能要求高**

### 显存配置（已修改）

```
Prefill-1: 1.6GB (10%)
Prefill-2: 1.6GB (10%)
Decode-1:  3.2GB (20%)  ← 增加显存支持长生成
Decode-2:  3.2GB (20%)
```

---

## 2. 快速开始

### 步骤 1：启动 PD 服务（Decode 重型配置）

```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash start-multi-pd.sh
```

**验证启动**：
```bash
# 检查显存使用
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# 预期输出:
# Prefill ~1.6GB, Decode ~3.2GB
```

---

### 步骤 2：运行测试

#### 方式 A：测试所有策略（推荐）

```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
python test-agent-codegen.py
```

脚本会：
1. 提示你重启 Gateway 并指定策略
2. 运行 50 个代码生成请求
3. 生成 HTML 和 JSON 报告
4. 重复以上步骤测试所有 4 种策略

#### 方式 B：测试单个策略

```bash
# 只测试 round_robin
python test-agent-codegen.py --policy round_robin

# 只测试 cache_aware
python test-agent-codegen.py --policy cache_aware
```

#### 方式 C：预览测试计划

```bash
python test-agent-codegen.py --dry-run
```

---

### 步骤 3：查看结果

测试完成后，查看报告：

```bash
# 打开 HTML 报告
firefox strategy-results/codegen_round_robin/pd-batch-report.html
firefox strategy-results/codegen_cache_aware/pd-batch-report.html
firefox strategy-results/codegen_performance_aware/pd-batch-report.html
firefox strategy-results/codegen_power_of_two/pd-batch-report.html
```

---

## 3. 测试 Prompts

测试使用的 Prompts 文件：`prompts/agent_code_gen.txt`

包含 15 个代码生成任务：
- 简单函数（50-100 tokens 输出）
- 完整类实现（200-500 tokens 输出）
- 复杂系统（500-1000 tokens 输出）

**示例**：
```
Write a Python function that implements binary search on a sorted array.
The function should return the index of the target if found, or -1 if not found.
Include type hints and docstring.

Create a REST API using Flask that implements CRUD operations for a Todo list.
Include endpoints for: create, read, update, delete.
Use SQLite for storage.
```

---

## 4. 预期结果

### 4.1 round_robin

**预期**：
- Prefill 分布: 50/50 完美均衡
- Decode 分布: 50/50 完美均衡
- 平均延迟: 中等
- 缓存命中率: 低

**适用场景**：需要严格负载均衡

---

### 4.2 cache_aware

**预期**：
- Prefill 分布: 45/55 到 55/45
- Decode 分布: 45/55 到 55/45
- 平均延迟: 较低（缓存优化）
- 缓存命中率: 高（系统提示词复用）

**适用场景**：多轮对话、重复系统提示词

---

### 4.3 performance_aware

**预期**：
- Prefill 分布: 可能 100/0
- Decode 分布: 可能 100/0
- 平均延迟: 最低（最优性能）
- 负载不均衡

**适用场景**：异构硬件

---

### 4.4 power_of_two

**预期**：
- Prefill 分布: 60/40 到 40/60
- Decode 分布: 60/40 到 40/60
- 平均延迟: 中等
- 负载均衡性: 中等

**适用场景**：大规模集群

---

## 5. 关键指标

### 5.1 性能指标

| 指标 | 目标值 | 查看位置 |
|------|-------|---------|
| 成功率 | 100% | HTML 报告摘要 |
| 平均延迟 | <2.0s | HTML 报告统计 |
| 最长生成 | 无截断 | JSON 数据中的 `completion_tokens` |
| 吞吐量 | >100 tokens/s | Decode 日志 |

### 5.2 负载均衡指标

| 指标 | 目标值 | 说明 |
|------|-------|------|
| Prefill 分布偏差 | <20% | `max-min` / `total` |
| Decode 分布偏差 | <20% | 同上 |
| 热点 Worker 比例 | <60% | 单个 Worker 的请求占比 |

---

## 6. 故障排查

### 问题 1：服务启动失败

**症状**：`start-multi-pd.sh` 报错

**解决**：
```bash
# 检查显存是否足够
nvidia-smi

# 清理旧进程
killall -9 python3
killall -9 sgl-model-gateway

# 重新启动
bash start-multi-pd.sh
```

---

### 问题 2：测试超时

**症状**：单个请求超过 120 秒

**可能原因**：
- GPU 显存不足
- 模型加载失败
- Gateway 未正确连接

**解决**：
```bash
# 检查日志
tail -100 /tmp/sglang-prefill-1.log
tail -100 /tmp/sglang-decode-1.log

# 检查 Gateway 连接
curl http://127.0.0.1:3000/health
```

---

### 问题 3：生成截断

**症状**：`completion_tokens` 远小于预期

**解决**：
```bash
# 增加 max_tokens 参数
python test-agent-codegen.py --max-tokens 1000
```

---

## 7. 下一步

测试完成后：

1. **分析结果**：对比 4 种策略的表现
2. **选择最优策略**：根据你的需求（性能 vs 均衡）
3. **继续测试其他场景**：
   - 多轮工具调用：`prompts/agent_multi_turn.txt`
   - 长文档分析：`prompts/agent_long_context.txt`
4. **实现动态调度**：根据请求类型自动选择策略

---

## 8. 文件清单

### 新增文件
- `prompts/agent_code_gen.txt` - 15 个代码生成 Prompts
- `test-agent-codegen.py` - 测试脚本
- `27-agent-scenario-scheduling-optimization.md` - 完整分析文档

### 修改文件
- `start-multi-pd.sh` - 显存配置（Prefill 0.10, Decode 0.20）

### 输出文件
- `strategy-results/codegen_*/pd-batch-report.html` - HTML 报告
- `strategy-results/codegen_*/pd-batch-data.json` - JSON 数据

---

*文档版本: v1.0*  
*最后更新: 2026-04-26*
