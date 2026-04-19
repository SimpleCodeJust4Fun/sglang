# 异构GPU调度策略文档

本文档介绍 SGLang Model Gateway 新增的三种面向异构GPU环境的调度策略。

## 背景

在异构GPU混部场景中，不同的GPU有不同的特性：
- **高端卡** (如 A100/H100): 计算快但显存可能受限
- **中端卡** (如 V100/4090): 均衡的计算和显存
- **低端卡** (如 T4/3090): 显存大但计算较慢

为了充分利用不同GPU的优势，需要智能的请求调度策略。

## 新增策略概述

### 1. RequestSizeBucket - 基于请求长度的分桶策略

**适用场景**: 根据请求prompt长度路由到不同GPU

**策略原理**:
- 将请求按输入长度分为三类：短、中、长
- 自动将worker按 priority/cost 比例分配到不同桶
- 每个桶独立跟踪负载，避免过载

**配置示例**:
```json
{
  "policy": {
    "type": "request_size_bucket",
    "short_threshold": 100,
    "medium_threshold": 500,
    "track_load_per_bucket": true
  }
}
```

**参数说明**:
- `short_threshold`: 短请求阈值（默认100字符）
- `medium_threshold`: 中等请求阈值（默认500字符）
- `track_load_per_bucket`: 是否分桶跟踪负载（默认true）

**Worker分配逻辑**:
```
Score = priority / cost

高分数 (score > 5.0) → 短请求桶（低延迟优化）
中分数 (1.0-5.0)    → 中等请求桶（均衡型）
低分数 (score < 1.0) → 长请求桶（大显存优化）
```

### 2. PerformanceAware - 性能感知策略

**适用场景**: 根据历史性能指标动态选择最优worker

**策略原理**:
- 收集每个worker的 TTFT、TPOT、吞吐量指标
- 归一化指标并计算加权分数
- 定期刷新分数以适配性能变化
- 考虑当前负载进行最终决策

**配置示例**:
```json
{
  "policy": {
    "type": "performance_aware",
    "weight_ttft": 0.3,
    "weight_tpot": 0.3,
    "weight_throughput": 0.4,
    "score_refresh_interval_secs": 60,
    "consider_load": true
  }
}
```

**参数说明**:
- `weight_ttft`: TTFT权重（默认0.3）
- `weight_tpot`: TPOT权重（默认0.3）
- `weight_throughput`: 吞吐量权重（默认0.4）
- `score_refresh_interval_secs`: 分数刷新间隔（默认60秒）
- `consider_load`: 是否考虑当前负载（默认true）

**评分公式**:
```
normalized_ttft = 1.0 - (ttft - min_ttft) / (max_ttft - min_ttft)
normalized_tpot = 1.0 - (tpot - min_tpot) / (max_tpot - min_tpot)
normalized_throughput = (throughput - min_throughput) / (max_throughput - min_throughput)

score = (weight_ttft * normalized_ttft +
         weight_tpot * normalized_tpot +
         weight_throughput * normalized_throughput) * load_factor

load_factor = 1.0 / (1.0 + current_load)
```

### 3. RequestClassification - 请求分类策略

**适用场景**: 根据请求的计算/内存特征智能路由

**策略原理**:
- 分析请求的输入长度和预期输出长度
- 分类为三种类型：
  - **计算密集型**: 短输入 + 长输出（如创意写作）
  - **内存密集型**: 长输入 + 短输出（如文档摘要）
  - **均衡型**: 中等输入 + 中等输出
- 自动将worker分类到适合的处理类型

**配置示例**:
```json
{
  "policy": {
    "type": "request_classification",
    "short_input_threshold": 100,
    "medium_input_threshold": 500,
    "small_output_threshold": 100,
    "medium_output_threshold": 500,
    "auto_assign_workers": true
  }
}
```

**参数说明**:
- `short_input_threshold`: 短输入阈值（默认100字符）
- `medium_input_threshold`: 中等输入阈值（默认500字符）
- `small_output_threshold`: 小输出阈值（默认100 tokens）
- `medium_output_threshold`: 中等输出阈值（默认500 tokens）
- `auto_assign_workers`: 是否自动分配worker（默认true）

**分类逻辑**:
```
if input < 100 chars and output > 100 tokens:
    → 计算密集型 → 高端GPU
elif input > 500 chars and output < 500 tokens:
    → 内存密集型 → 大显存GPU
else:
    → 均衡型 → 中端GPU
```

## PD分离架构下的配置

在Prefill-Decode分离架构中，可以为两个阶段分别配置不同策略：

```json
{
  "mode": {
    "type": "prefill_decode",
    "prefill_urls": [
      ["http://prefill-1:8000", 8001],
      ["http://prefill-2:8000", 8002]
    ],
    "decode_urls": [
      "http://decode-1:8000",
      "http://decode-2:8000",
      "http://decode-3:8000"
    ],
    "prefill_policy": {
      "type": "request_size_bucket",
      "short_threshold": 100,
      "medium_threshold": 500
    },
    "decode_policy": {
      "type": "performance_aware",
      "weight_ttft": 0.2,
      "weight_tpot": 0.5,
      "weight_throughput": 0.3
    }
  }
}
```

**配置说明**:
- Prefill阶段使用 RequestSizeBucket：根据prompt长度分配到不同prefill实例
- Decode阶段使用 PerformanceAware：根据token生成性能选择最优decode实例

## 测试方法

### 1. 启动Gateway

```bash
cargo run -- --config config.json
```

### 2. 发送测试请求

**短请求测试**:
```bash
curl -X POST http://localhost:3001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "test",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

**长请求测试**:
```bash
curl -X POST http://localhost:3001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "test",
    "messages": [{"role": "user", "content": "'$(python3 -c "print('a' * 1000)")'"}]
  }'
```

**带max_tokens的请求**:
```bash
curl -X POST http://localhost:3001/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "X-SM-Max-Tokens: 500" \
  -d '{
    "model": "test",
    "messages": [{"role": "user", "content": "Write a long essay"}]
  }'
```

### 3. 查看路由日志

```bash
# 查看RequestSizeBucket的决策
tail -f /tmp/sglang-gateway.log | grep RequestSizeBucket

# 查看PerformanceAware的决策
tail -f /tmp/sglang-gateway.log | grep PerformanceAware

# 查看RequestClassification的决策
tail -f /tmp/sglang-gateway.log | grep RequestClassification
```

## 策略选择建议

| 场景 | 推荐策略 | 原因 |
|------|---------|------|
| GPU性能差异明显 | PerformanceAware | 基于实际性能指标 |
| Prompt长度变化大 | RequestSizeBucket | 按长度隔离负载 |
| 请求类型多样 | RequestClassification | 智能分类路由 |
| 简单负载均衡 | PowerOfTwo | 基础负载感知 |
| 需要KV Cache优化 | CacheAware | Cache亲和性 |

## 性能调优技巧

1. **RequestSizeBucket**:
   - 根据实际prompt分布调整阈值
   - 如果大多数请求集中在某个范围，调整阈值使其均匀分布

2. **PerformanceAware**:
   - 对于延迟敏感场景，增加 `weight_ttft`
   - 对于吞吐量敏感场景，增加 `weight_throughput`
   - 缩短 `score_refresh_interval_secs` 以更快适应性能变化

3. **RequestClassification**:
   - 根据业务场景调整输入/输出阈值
   - 如果worker特性不明显，关闭 `auto_assign_workers` 手动分配

## 已知限制

1. PerformanceAware 策略需要请求运行一段时间后才能积累足够的性能指标
2. RequestSizeBucket 和 RequestClassification 依赖 worker 的 priority/cost 元数据
3. 在worker频繁上下线的场景中，自动分配可能需要重新初始化

## 未来改进方向

1. 支持从Prometheus等监控系统导入性能指标
2. 支持基于强化学习的自动策略优化
3. 支持基于请求语义的更深层次分类（如代码、对话、摘要等）
4. 支持多目标优化（成本、延迟、吞吐量的帕累托最优）
