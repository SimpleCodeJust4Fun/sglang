# 异构GPU请求调度策略研究计划

## 研究主题

**"异构混部GPU大模型应用中合适的请求调度策略"**

---

## 1. 问题定义

### 1.1 场景描述

在真实生产环境中，GPU集群通常是**异构的**：
- **高端卡** (如A100/H100): 计算快，但显存可能有限
- **中端卡** (如4070Ti/3090): 计算中等，显存适中
- **低端卡** (如V100/T4): 计算慢，但显存可能很大

**核心问题**: 如何将不同特征的请求调度到最合适的GPU上，使得：
- TTFT (Time To First Token) 最小化
- TPOT (Time Per Output Token) 最优
- GPU利用率最大化
- 总体吞吐量最高

### 1.2 用户请求特征

请求可以分为不同类型：

| 请求类型 | Prompt长度 | 生成长度 | 特点 | 适合的GPU |
|---------|-----------|---------|------|----------|
| **短对话** | 短 (<100 tokens) | 短 (<50 tokens) | TTFT敏感 | 计算快的GPU |
| **长对话** | 长 (>500 tokens) | 长 (>200 tokens) | TPOT敏感 | 显存大+计算快的GPU |
| **短Prompt长生成** | 短 | 长 (>500 tokens) | TPOT敏感 | 计算快的GPU |
| **长Prompt短生成** | 长 (>1000 tokens) | 短 | Prefill敏感 | Prefill用快卡 |
| **批量推理** | 中等 | 中等 | 吞吐量敏感 | 显存大的GPU |

### 1.3 关键性能指标

| 指标 | 定义 | 优化目标 |
|------|------|---------|
| **TTFT** | Time To First Token | 越小越好（用户体验） |
| **TPOT** | Time Per Output Token | 越小越好（生成速度） |
| **E2E Latency** | 端到端延迟 | 越小越好 |
| **Throughput** | tokens/second | 越大越好 |
| **GPU利用率** | SM利用率/显存利用率 | 越高越好 |

---

## 2. 现有策略分析

### 2.1 SGLang Model Gateway已有策略

根据源码分析，现有9种策略：

| 策略 | 异构感知 | 缓存感知 | 适用场景 | 局限性 |
|------|---------|---------|---------|--------|
| **Random** | ❌ | ❌ | 基准测试 | 完全随机 |
| **Round Robin** | ❌ | ❌ | 同质环境 | 不考虑性能差异 |
| **Power of Two** | ✅ (token负载) | ❌ | 异构Worker | 仅考虑负载，不考虑能力 |
| **Cache-Aware** | ✅ (双策略) | ✅ (完整) | PD缓存优化 | 复杂，不考虑GPU差异 |
| **Prefix Hash** | ✅ (有回退) | ✅ (轻量) | PD轻量缓存 | 精度不如Cache-Aware |
| **Bucket** | ✅ (字符) | ❌ | PD Prefill | 仅用于Prefill |
| **Consistent Hash** | ❌ | ❌ | 会话保持 | 不考虑负载 |
| **Tree** | ❌ | ✅ | 内部结构 | 不直接使用 |
| **Manual** | 可选 | ❌ | 手动控制 | 需要人工干预 |

### 2.2 关键发现

**已有的基础设施**：
- ✅ Worker有`priority`和`cost`字段（但未使用）
- ✅ LoadMonitor可以收集token级负载
- ✅ TTFT/TPOT指标已定义（但仅用于观测）
- ✅ 策略框架支持扩展

**缺失的机制**：
- ❌ 没有基于Worker性能的动态调度
- ❌ 没有GPU能力描述
- ❌ 没有请求分类机制
- ❌ 没有性能历史追踪

---

## 3. 学界研究成果

### 3.1 异构GPU调度相关论文

根据调研，学界主要方向：

1. **性能感知调度 (Performance-Aware Scheduling)**
   - 根据GPU计算能力分配请求
   - 使用历史性能数据预测
   - 关键指标：tokens/sec per GPU type

2. **请求分类调度 (Request Classification Scheduling)**
   - 根据prompt长度分类
   - 短请求→快卡，长请求→大显存卡
   - 关键指标：prompt length distribution

3. **自适应权重调度 (Adaptive Weight Scheduling)**
   - 动态调整Worker权重
   - 基于最近TTFT/TPOT
   - 关键指标：recent performance window

4. **PD分离异构调度 (Heterogeneous PD Scheduling)**
   - Prefill用计算快的GPU
   - Decode用显存大的GPU
   - 关键指标：prefill speed vs decode memory

### 3.2 业界最佳实践

**NVIDIA Triton Inference Server**:
- 使用instance grouping
- 不同GPU类型配置不同batch size

**vLLM**:
- Prefix caching + load balancing
- 但不考虑异构GPU

**DistServe** (OSDI '24):
- 专门针对PD分离的异构调度
- Prefill用A100，Decode用A10
- 通过profiling建立性能模型

---

## 4.  proposed 解决方案

### 4.1 方案概述

**名称**: `PerformanceAware Cache-Aware Scheduling (PACAS)`

**核心思想**:
1. **请求分类**: 根据prompt长度和预期生成长度分类
2. **性能画像**: 定期profiling获取每个GPU的TTFT/TPOT
3. **缓存感知**: 保留Cache-Aware的KV cache优化
4. **自适应权重**: 动态调整Worker权重

### 4.2 实现策略

**方案A: 扩展Power of Two (最简单)**

修改 `power_of_two.rs`，在选择Worker时考虑性能：

```rust
// 当前: 选择负载低的
if load_a < load_b { worker_a } else { worker_b }

// 改进: 选择有效负载低的
effective_load_a = load_a / performance_score_a
effective_load_b = load_b / performance_score_b
if effective_load_a < effective_load_b { worker_a } else { worker_b }
```

**方案B: 扩展Cache-Aware (最全面)**

在 `cache_aware.rs` 的负载均衡模式中加入性能感知：

```rust
// 当前: 选择最短队列
workers.iter().min_by_key(|w| w.load())

// 改进: 选择性价比最高的
workers.iter().min_by_key(|w| {
    w.load() as f32 / w.performance_score()
})
```

**方案C: 新建PerformanceAware策略 (最灵活)**

创建新策略 `performance_aware.rs`：

```rust
pub struct PerformanceAwarePolicy {
    // 性能画像
    worker_profiles: HashMap<String, WorkerProfile>,
    // 请求分类器
    request_classifier: RequestClassifier,
    // 缓存树
    prefix_trees: HashMap<String, PrefixTree>,
}

struct WorkerProfile {
    gpu_type: String,
    ttft_history: Vec<f64>,      // 最近10次TTFT
    tpot_history: Vec<f64>,      // 最近10次TPOT
    avg_tokens_per_sec: f64,     // 平均吞吐量
    memory_capacity: usize,      // 显存容量
}
```

### 4.3 推荐方案

**选择方案B (扩展Cache-Aware)**，原因：
1. 复用已有的缓存机制
2. 改动最小，风险低
3. Cache-Aware已有双策略切换
4. 可以快速验证效果

---

## 5. 实验设计

### 5.1 实验环境

**模拟异构GPU** (由于只有1张4070Ti，需要模拟)：

| Worker | 模拟方式 | 预期性能 |
|--------|---------|---------|
| Prefill-1 (Port 30000) | 正常启动 | 快计算 |
| Prefill-2 (Port 30001) | 限制batch size | 慢计算 |
| Decode-1 (Port 30010) | 正常启动 | 正常 |
| Decode-2 (Port 30011) | 限制mem-fraction | 小显存 |

**模拟方法**:
- 通过`--cuda-graph-max-bs`限制最大batch size
- 通过`--mem-fraction-static`限制可用显存

### 5.2 实验步骤

#### 实验1: 基准测试 - 各策略性能对比

**测试策略**:
1. Round Robin (基准)
2. Cache Aware (当前最优)
3. Performance-Aware Cache Aware (新策略)

**测试负载**:
- 短请求: prompt=20, max_tokens=20 (100次)
- 中请求: prompt=200, max_tokens=100 (50次)
- 长请求: prompt=1000, max_tokens=300 (20次)

**测量指标**:
- TTFT (P50, P95, P99)
- TPOT (P50, P95, P99)
- 平均吞吐量 (tokens/sec)
- GPU利用率

#### 实验2: 请求分类效果

**目标**: 验证不同类型请求是否被正确调度

**方法**:
- 发送混合请求 (短/中/长)
- 观察路由决策
- 验证短请求是否路由到快卡

#### 实验3: 负载不均衡场景

**目标**: 验证自适应能力

**方法**:
- 给某个Worker施加压力
- 观察是否自动切换到其他Worker
- 测量恢复时间

### 5.3 预期结果

| 策略 | TTFT | TPOT | Throughput | GPU利用率 |
|------|------|------|-----------|----------|
| Round Robin | 基准 | 基准 | 基准 | 60% |
| Cache Aware | -10% | -5% | +15% | 75% |
| Performance-Aware | **-20%** | **-15%** | **+30%** | **85%** |

---

## 6. 实现计划

### Phase 1: 基础设施 (Week 1)

1. **Worker性能画像**
   - 扩展Worker metadata
   - 添加TTFT/TPOT收集
   - 实现性能评分

2. **请求分类器**
   - 根据prompt长度分类
   - 根据max_tokens预估生成长度

### Phase 2: 策略实现 (Week 2)

3. **扩展Cache-Aware策略**
   - 修改Worker选择逻辑
   - 添加性能权重
   - 保持缓存感知

4. **配置系统**
   - 添加性能感知参数
   - 支持动态调整

### Phase 3: 实验验证 (Week 3)

5. **测试脚本**
   - 自动化基准测试
   - 混合负载测试
   - 数据收集

6. **数据分析**
   - 对比各策略
   - 生成图表
   - 撰写报告

### Phase 4: 优化和文档 (Week 4)

7. **参数调优**
   - 调整权重公式
   - 优化阈值

8. **文档**
   - 实现文档
   - 使用指南
   - 最佳实践

---

## 7. 关键代码位置

| 文件 | 修改内容 |
|------|---------|
| `src/policies/cache_aware.rs` | 添加性能感知Worker选择 |
| `src/core/worker.rs` | 添加性能画像 |
| `src/core/worker_manager.rs` | 扩展LoadMonitor |
| `src/observability/metrics.rs` | 添加Worker性能指标 |

---

## 8. 风险和缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| 无法模拟真实异构 | 实验效果有限 | 用配置差异模拟 |
| 性能画像不准确 | 调度错误 | 定期更新+滑动窗口 |
| 策略过于复杂 | 延迟增加 | 简化权重计算 |
| 缓存命中率下降 | 性能退化 | 保留缓存优先 |

---

**下一步**: 开始Phase 1实现，扩展Worker性能画像
