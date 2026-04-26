# Agent 对话场景调度优化方案

> **版本**: v1.0  
> **日期**: 2026-04-26  
> **目标**: 针对 Agent 对话场景优化 PD 分离架构的调度策略

---

## 1. Agent 对话场景特征分析

### 1.1 Token 输入输出特征

Agent 对话场景具有以下显著的 token 特征：

| 特征维度 | 典型值范围 | 说明 |
|---------|-----------|------|
| **系统提示词** | 200-2000 tokens | 角色定义、工具描述、行为约束 |
| **工具描述** | 50-500 tokens/tool | JSON Schema 格式的工具参数 |
| **用户查询** | 10-200 tokens | 通常较短，但可能附带上下文 |
| **工具调用输出** | 50-5000 tokens | 工具返回的 JSON 或文本结果 |
| **模型回复** | 20-500 tokens | 基于工具结果的生成 |
| **对话历史** | 累积增长 | 每轮增加 100-2000 tokens |

### 1.2 典型 Agent 对话模式

#### 模式 A：单轮工具调用 (Simple Tool Use)

```
用户: "今天的天气怎么样？"
  → Prefill: 50 tokens (prompt + system + tool desc)
  → 模型: function_call("get_weather", {"location": "Paris"})
  → 工具执行: 返回 JSON (100 tokens)
  → Prefill: 150 tokens (tool output)
  → 模型: "今天巴黎天气晴朗，温度 22°C" (20 tokens)
  
总 Prefill: 200 tokens (2 次)
总 Decode: 120 tokens (2 次)
```

**特点**：
- Prefill 阶段多（需要处理工具输出）
- Decode 阶段短（简洁回复）
- **Prefill 密集，Decode 轻量**

---

#### 模式 B：多轮工具链 (Multi-Step Tool Chain)

```
用户: "帮我分析这家公司的财务状况"
  → 工具 1: fetch_financial_report(company) → 5000 tokens
  → 工具 2: calculate_ratios(report_data) → 1000 tokens
  → 工具 3: generate_chart(ratios) → 200 tokens (base64 image)
  → 模型: 综合分析报告 (500 tokens)

总 Prefill: 6200 tokens (累积处理工具输出)
总 Decode: 500 tokens (最终生成)
```

**特点**：
- Prefill 阶段非常重（大量工具输出需要处理）
- Decode 阶段相对短（总结性回复）
- **Prefill 极度密集，Decode 中等**

---

#### 模式 C：代码生成/编辑 (Code Generation)

```
用户: "写一个 Python web scraper"
  → 模型: 生成 200 行代码 (800 tokens)
  → 用户: "添加错误处理"
  → 模型: 重写代码 (1000 tokens)
  
总 Prefill: 50 tokens (初始) + 850 tokens (含历史)
总 Decode: 1800 tokens (大量代码生成)
```

**特点**：
- Decode 阶段非常重（长代码生成）
- Prefill 阶段逐步增长（对话历史累积）
- **Decode 密集，Prefill 逐步增长**

---

#### 模式 D：长文档分析 (Document Analysis)

```
用户: [上传 50 页 PDF] "总结这份文档"
  → Prefill: 20000 tokens (文档内容)
  → 模型: 摘要 (500 tokens)
  → 用户: "详细说明第三章"
  → Prefill: 20500 tokens (文档 + 对话历史)
  → 模型: 详细分析 (1000 tokens)
  
总 Prefill: 40500 tokens (超长上下文)
总 Decode: 1500 tokens
```

**特点**：
- Prefill 极端密集（超长文档处理）
- Decode 相对轻量
- **Prefill 占绝对主导**

---

### 1.3 Token 分布统计

根据上述模式，我们可以得到以下分布：

| 对话模式 | Prefill 占比 | Decode 占比 | Prefill/Decode 比值 |
|---------|-------------|------------|-------------------|
| 单轮工具调用 | 62% | 38% | 1.6:1 |
| 多轮工具链 | 93% | 7% | 12.4:1 |
| 代码生成 | 35% | 65% | 0.54:1 |
| 长文档分析 | 96% | 4% | 27:1 |
| **平均** | **72%** | **28%** | **2.6:1** |

**关键发现**：
- Agent 场景中 **Prefill 是主要瓶颈**（平均占 72%）
- 传统对话（无工具）通常是 Decode 密集
- Agent 场景需要**优先优化 Prefill 性能**

---

## 2. 2P+2D 架构资源分配

### 2.1 当前架构约束

```
GPU: RTX 4070 Ti Super (16GB VRAM)

Prefill-1: 2.4GB (15%)
Prefill-2: 2.4GB (15%)
Decode-1:  2.4GB (15%)
Decode-2:  2.4GB (15%)
剩余:      6.4GB (40%)
```

### 2.2 针对 Agent 场景的资源优化

#### 方案 A：Prefill 重型配置（推荐用于工具链场景）

```
Prefill-1: 3.2GB (20%) ← 增加显存，支持更长 prompt
Prefill-2: 3.2GB (20%)
Decode-1:  1.6GB (10%)
Decode-2:  1.6GB (10%)
剩余:      6.4GB (40%)

优势:
- Prefill 可处理更长上下文（4000+ tokens）
- 适合文档分析和多轮工具链
- Radix Cache 容量更大

劣势:
- Decode 并发能力降低
- 不适合长代码生成场景
```

#### 方案 B：均衡配置（推荐用于混合场景）

```
Prefill-1: 2.4GB (15%) ← 保持现状
Prefill-2: 2.4GB (15%)
Decode-1:  2.4GB (15%)
Decode-2:  2.4GB (15%)
剩余:      6.4GB (40%)

优势:
- 通用性好，适合多种场景
- Prefill 和 Decode 平衡

劣势:
- 不是任何场景的最优解
```

#### 方案 C：Decode 重型配置（推荐用于代码生成）

```
Prefill-1: 1.6GB (10%)
Prefill-2: 1.6GB (10%)
Decode-1:  3.2GB (20%) ← 增加显存，支持长生成
Decode-2:  3.2GB (20%)
剩余:      6.4GB (40%)

优势:
- Decode 可生成更长内容
- 适合代码生成和创意写作

劣势:
- Prefill 上下文长度受限
- 不适合长文档分析
```

---

## 3. 调度策略设计方案

### 3.1 方案概览

基于 Agent 场景特征，我们设计了以下调度方案：

| 方案编号 | 方案名称 | 适用场景 | 核心策略 | 预期效果 |
|---------|---------|---------|---------|---------|
| **S1** | 缓存优先 | 多轮对话、工具链 | cache_aware | 高缓存命中率 |
| **S2** | 负载均衡 | 短查询、简单工具 | round_robin | 均匀分布 |
| **S3** | 性能感知 | 异构硬件 | performance_aware | 最优性能 |
| **S4** | 混合策略 | 混合负载 | cache_aware + power_of_two | 平衡性能与均衡 |

---

### 3.2 方案 S1：缓存优先策略（推荐）

**适用场景**：多轮工具调用、长文档分析

**配置**：
```bash
--policy cache_aware \
  --cache-threshold 0.3 \
  --balance-abs-threshold 16 \
  --balance-rel-threshold 1.2 \
  --eviction-interval 120 \
  --max-tree-size 2000000
```

**调度逻辑**：
```
if (max_load - min_load) > 16 AND max_load > min_load * 1.2:
   # 负载不均衡：选择队列短的 Worker
   route to worker with min(queue_length)
else:
   # 负载均衡：使用缓存亲和性
   match_rate = prefix_match(system_prompt + conversation_history)
   if match_rate > 0.3:
      route to worker with highest prefix match
   else:
      route to worker with most cache space
```

**预期效果**：
- 多轮对话缓存命中率：85-95%
- 单轮 Prefill 延迟降低：40-60%
- Prefill Worker 负载均衡：45/55 到 55/45

**测试方法**：
```bash
# 模拟多轮工具调用
python model_deploy/pd-batch-test.py \
  --policy cache_aware \
  --num-requests 100 \
  --prompts-file prompts/agent_multi_turn.txt \
  --max-tokens 200
```

---

### 3.3 方案 S2：负载均衡策略

**适用场景**：短查询、简单工具调用、高并发场景

**配置**：
```bash
--policy round_robin
```

**调度逻辑**：
```
counter++ mod healthy_workers.len()
prefill_index = counter % num_prefills
decode_index = (counter + offset) % num_decodes
```

**预期效果**：
- 完美的 50/50 负载分布
- 无缓存优化
- 适合短请求（<100 tokens）

**测试方法**：
```bash
python model_deploy/pd-batch-test.py \
  --policy round_robin \
  --num-requests 100 \
  --prompts-file prompts/agent_short.txt \
  --max-tokens 50
```

---

### 3.4 方案 S3：性能感知策略

**适用场景**：异构硬件（不同型号 GPU）

**配置**：
```bash
--policy performance_aware \
  --weight-ttft 0.2 \
  --weight-tpot 0.5 \
  --weight-throughput 0.3 \
  --score-refresh-interval 30 \
  --consider-load true
```

**调度逻辑**：
```
score = (0.2 * norm_ttft + 
         0.5 * norm_tpot +      # Agent 场景更关注 TPOT（生成速度）
         0.3 * norm_throughput) * load_factor

route to worker with highest score
```

**预期效果**：
- 所有请求路由到性能最优的 Worker
- 吞吐量最大化
- 负载可能不均衡（100/0）

**测试方法**：
```bash
python model_deploy/pd-batch-test.py \
  --policy performance_aware \
  --num-requests 100 \
  --prompts-file prompts/agent_mixed.txt
```

---

### 3.5 方案 S4：混合策略（高级）

**适用场景**：混合负载（同时有短查询和长文档）

**配置**：
```bash
# 使用 cache_aware 作为基础
--policy cache_aware \
  --cache-threshold 0.5

# 配合外部监控脚本动态调整
```

**调度逻辑**：
```python
# 伪代码：外部监控逻辑
def hybrid_routing(request):
    input_length = len(request.prompt)
    
    if input_length < 100:
        # 短请求：使用 power_of_two 快速路由
        return power_of_two.select_worker()
    elif input_length < 1000:
        # 中等请求：使用 cache_aware
        return cache_aware.select_worker(request.prompt)
    else:
        # 长请求：选择缓存最多的 Worker
        return cache_aware.select_worker_with_most_cache()
```

**预期效果**：
- 短请求延迟最低
- 长请求缓存命中率最高
- 整体负载均衡

---

## 4. 测试场景设计

### 4.1 测试 Prompts 生成

创建以下测试文件：

#### `prompts/agent_short.txt`（短查询）
```
What is AI?
Define ML
Explain NLP
What is API?
How to code?
```

**特征**：
- 输入: 2-10 tokens
- 输出: 20-50 tokens
- Prefill/Decode 比值: 0.2:1

---

#### `prompts/agent_multi_turn.txt`（多轮工具调用）
```
[SYSTEM] You are a helpful assistant with tools: get_weather, search_web
[USER] What's the weather in Paris?
[TOOL OUTPUT] {"temperature": 22, "condition": "sunny"}
[ASSISTANT] It's sunny in Paris...
[USER] How about Tokyo?
```

**特征**：
- 输入: 50-200 tokens（含历史）
- 输出: 30-100 tokens
- Prefill/Decode 比值: 2:1

---

#### `prompts/agent_long_context.txt`（长文档分析）
```
[SYSTEM] You are a document analyzer...
[USER] Please summarize the following document:

[DOCUMENT CONTENT - 5000 words]
... (long text) ...

[USER] What are the key points?
```

**特征**：
- 输入: 2000-10000 tokens
- 输出: 100-500 tokens
- Prefill/Decode 比值: 20:1

---

#### `prompts/agent_code_gen.txt`（代码生成）
```
[USER] Write a Python web scraper that:
1. Fetches pages from a list of URLs
2. Extracts headlines using CSS selectors
3. Saves results to CSV
4. Handles errors and retries
5. Respects robots.txt

Provide complete, production-ready code.
```

**特征**：
- 输入: 50-100 tokens
- 输出: 500-2000 tokens
- Prefill/Decode 比值: 0.1:1

---

### 4.2 测试矩阵

| 测试 ID | Prompts 文件 | 策略 | 预期结果 |
|---------|-------------|------|---------|
| T1 | agent_short.txt | round_robin | 完美均衡，延迟稳定 |
| T2 | agent_short.txt | cache_aware | 低缓存命中，类似 round_robin |
| T3 | agent_multi_turn.txt | cache_aware | 高缓存命中 (80%+) |
| T4 | agent_multi_turn.txt | round_robin | 均衡，但无缓存优化 |
| T5 | agent_long_context.txt | cache_aware | 极高缓存命中 (95%+) |
| T6 | agent_long_context.txt | performance_aware | 全部到最优 Worker |
| T7 | agent_code_gen.txt | round_robin | 均衡，Decode 负载高 |
| T8 | agent_code_gen.txt | cache_aware | Prefill 缓存系统提示词 |

---

### 4.3 测试执行脚本

创建 `test-agent-scenarios.py`：

```python
#!/usr/bin/env python3
"""Agent 场景调度测试"""

import subprocess
import json
from pathlib import Path

# 测试配置
TESTS = [
    {
        "name": "T1_short_round_robin",
        "prompts": "prompts/agent_short.txt",
        "policy": "round_robin",
        "max_tokens": 50,
        "num_requests": 50,
    },
    {
        "name": "T3_multi_turn_cache_aware",
        "prompts": "prompts/agent_multi_turn.txt",
        "policy": "cache_aware",
        "max_tokens": 100,
        "num_requests": 50,
    },
    # ... 其他测试
]

def run_test(test_config):
    """执行单个测试"""
    cmd = [
        "python", "model_deploy/pd-batch-test.py",
        "--policy", test_config["policy"],
        "--num-requests", str(test_config["num_requests"]),
        "--prompts-file", test_config["prompts"],
        "--max-tokens", str(test_config["max_tokens"]),
        "--output-dir", f"strategy-results/{test_config['name']}",
    ]
    
    print(f"Running {test_config['name']}...")
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"  FAILED: {result.stderr}")
        return None
    
    # 分析结果
    report_path = Path(f"strategy-results/{test_config['name']}/pd-batch-data.json")
    if report_path.exists():
        with open(report_path) as f:
            report = json.load(f)
        
        print(f"  Success rate: {report['summary']['success_rate']}%")
        print(f"  Avg latency: {report['summary']['avg_duration']:.3f}s")
        print(f"  Prefill dist: {report['prefill_distribution']}")
        print(f"  Decode dist: {report['decode_distribution']}")
        
        return report
    
    return None

def main():
    results = {}
    
    for test in TESTS:
        result = run_test(test)
        if result:
            results[test["name"]] = result
    
    # 生成对比报告
    generate_comparison_report(results)

if __name__ == "__main__":
    main()
```

---

## 5. 优化建议

### 5.1 立即可以做的优化

#### 优化 1：调整 Prefill 显存分配

**问题**：Agent 场景 Prefill 密集，但当前显存分配均衡

**方案**：
```bash
# 修改 start-multi-pd.sh
PREFILL_MEM=0.20  # 从 0.15 增加到 0.20
DECODE_MEM=0.10   # 从 0.15 降低到 0.10

# Prefill: 3.2GB (可处理 4000+ tokens)
# Decode: 1.6GB (可生成 500+ tokens)
```

**预期效果**：
- Prefill 可处理更长上下文
- 减少 Prefill OOM 风险
- 适合文档分析场景

---

#### 优化 2：使用 cache_aware 作为默认策略

**问题**：round_robin 无法利用 Agent 场景的缓存特性

**方案**：
```bash
# Gateway 启动参数
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --decode http://127.0.0.1:30010 \
  --decode http://127.0.0.1:30011 \
  --policy cache_aware \
  --cache-threshold 0.3
```

**预期效果**：
- 多轮对话缓存命中率提升 30-50%
- Prefill 延迟降低 40-60%

---

#### 优化 3：增加对话历史缓存

**问题**：Agent 对话的系统提示词和工具描述在每轮都重复

**方案**：
```python
# 在应用层维护对话历史
# 只发送增量部分给 Prefill

# 当前方式（低效）:
# Round 1: [System + Tool + User1] → Prefill
# Round 2: [System + Tool + User1 + Assistant1 + User2] → Prefill
# Round 3: [System + Tool + User1 + Assistant1 + User2 + Assistant2 + User3] → Prefill

# 优化方式（高效）:
# Round 1: [System + Tool + User1] → Prefill → 缓存 KV
# Round 2: [Assistant1 + User2] → Prefill → 复用缓存 + 增量
# Round 3: [Assistant2 + User3] → Prefill → 复用缓存 + 增量
```

**预期效果**：
- Prefill 计算量减少 70-90%
- 缓存命中率从 34/35 提升到 99%+

---

### 5.2 中期优化（需要代码修改）

#### 优化 4：实现请求分类路由

**问题**：不同 Agent 场景需要不同的调度策略

**方案**：
```rust
// 在 request_classification.rs 中添加 Agent 感知分类
enum AgentRequestType {
    ToolCall,        // 工具调用（Prefill 密集）
    CodeGeneration,  // 代码生成（Decode 密集）
    DocumentAnalysis,// 文档分析（超长 Prefill）
    SimpleChat,      // 简单对话（均衡）
}

fn classify_agent_request(request: &Request) -> AgentRequestType {
    let has_tools = request.tools.is_some();
    let input_len = request.prompt.len();
    let output_len = request.max_tokens.unwrap_or(100);
    
    if has_tools && input_len > 1000 {
        AgentRequestType::DocumentAnalysis
    } else if has_tools {
        AgentRequestType::ToolCall
    } else if output_len > 500 {
        AgentRequestType::CodeGeneration
    } else {
        AgentRequestType::SimpleChat
    }
}
```

**调度决策**：
```
ToolCall → cache_aware (利用工具输出缓存)
CodeGeneration → round_robin (均匀分配 Decode 负载)
DocumentAnalysis → performance_aware (选择最优 Prefill)
SimpleChat → power_of_two (快速负载均衡)
```

---

#### 优化 5：实现动态策略切换

**问题**：固定策略无法适应负载变化

**方案**：
```python
# 外部监控脚本
class DynamicScheduler:
    def __init__(self):
        self.metrics = WorkerMetrics()
        self.current_policy = "cache_aware"
    
    def decide_policy(self, request):
        load_ratio = self.metrics.get_load_ratio()
        cache_hit_rate = self.metrics.get_cache_hit_rate()
        
        if load_ratio > 2.0:
            # 负载严重不均衡：使用 round_robin
            return "round_robin"
        elif cache_hit_rate < 0.5:
            # 缓存命中率低：使用 performance_aware
            return "performance_aware"
        else:
            # 正常情况：使用 cache_aware
            return "cache_aware"
```

---

## 6. 执行计划

### 阶段 1：立即可做（今天）

1. ✅ 创建 Agent 测试 Prompts 文件
2. ✅ 修改 start-multi-pd.sh 调整显存分配
3. ✅ 运行 8 个测试场景（测试矩阵）
4. ✅ 生成对比报告

**预计时间**：2-3 小时

---

### 阶段 2：短期优化（本周）

1. 实现对话历史缓存优化
2. 测试 cache_aware 策略在多轮对话中的表现
3. 调整 cache_aware 参数找到最优值
4. 更新综合分析报告

**预计时间**：1-2 天

---

### 阶段 3：中期优化（本月）

1. 修改 request_classification 策略，添加 Agent 感知
2. 实现动态策略切换
3. 创建自动化测试框架
4. 性能基准测试

**预计时间**：1-2 周

---

## 7. 关键指标

### 7.1 性能指标

| 指标 | 目标值 | 测量方法 |
|------|-------|---------|
| Prefill 缓存命中率 | >80% | 日志中的 `#cached-token / #total-token` |
| 端到端延迟（短查询） | <500ms | HTTP 响应时间 |
| 端到端延迟（长文档） | <5s | HTTP 响应时间 |
| 吞吐量（tokens/s） | >100 | Decode 日志中的 `gen throughput` |

### 7.2 负载均衡指标

| 指标 | 目标值 | 测量方法 |
|------|-------|---------|
| Prefill 分布偏差 | <10% | `max(prefill_count) - min(prefill_count)` |
| Decode 分布偏差 | <15% | 同上 |
| 热点 Worker 比例 | <60% | 单个 Worker 的请求占比 |

---

## 8. 总结

### 8.1 核心发现

1. **Agent 场景 Prefill 密集**：平均占 72% 的计算量
2. **多轮对话缓存利用率高**：可达 85-95%
3. **当前均衡配置不适合 Agent**：需要 Prefill 重型配置
4. **cache_aware 是最佳默认策略**：兼顾性能和均衡

### 8.2 推荐行动

1. **立即**：使用 cache_aware 策略 + Prefill 重型显存
2. **短期**：实现对话历史缓存优化
3. **中期**：开发 Agent 感知的动态调度

### 8.3 预期收益

| 优化项 | 预期收益 |
|-------|---------|
| cache_aware 策略 | Prefill 延迟降低 40-60% |
| Prefill 重型显存 | 支持 2 倍上下文长度 |
| 对话历史缓存 | Prefill 计算减少 70-90% |
| 动态策略切换 | 整体吞吐提升 30-50% |

---

## 附录

### A. 相关文件清单

```
model_deploy/
├── start-multi-pd.sh              # 启动脚本（需修改显存分配）
├── pd-test.py                     # 单请求测试
├── pd-batch-test.py               # 批量测试
├── test-all-strategies.py         # 策略对比
├── test-agent-scenarios.py        # Agent 场景测试（新建）
└── prompts/
    ├── agent_short.txt            # 短查询 Prompts（新建）
    ├── agent_multi_turn.txt       # 多轮对话 Prompts（新建）
    ├── agent_long_context.txt     # 长文档 Prompts（新建）
    └── agent_code_gen.txt         # 代码生成 Prompts（新建）

strategy-results/
├── T1_short_round_robin/          # 测试结果
├── T3_multi_turn_cache_aware/
└── ... (共 8 个测试)
```

### B. 快速开始命令

```bash
# 1. 修改显存分配
cd model_deploy
vim start-multi-pd.sh  # 修改 MEM_FRACTION

# 2. 启动服务
bash start-multi-pd.sh

# 3. 启动 Gateway
cd /mnt/e/dev/sglang/sgl-model-gateway
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --decode http://127.0.0.1:30010 \
  --decode http://127.0.0.1:30011 \
  --policy cache_aware

# 4. 运行 Agent 测试
python model_deploy/test-agent-scenarios.py
```

---

*文档版本: v1.0*  
*最后更新: 2026-04-26*
