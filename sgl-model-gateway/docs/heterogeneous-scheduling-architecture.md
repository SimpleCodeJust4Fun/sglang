# 异构 GPU 调度系统——模块架构与工作规划

> 项目目标：在 H800 + H20 / RTX 4090 等异构 GPU 集群上，通过调度策略优化，
> 证明异构卡组合的性价比优于纯高端卡方案。

---

## 一、现有 SMG 调度架构

### 1.1 总体架构

```
┌─────────────────────────────────────────────────────────────┐
│                    CLI / Config                              │
│  --policy <POLICY> --prefill-policy <P> --decode-policy <D> │
└──────────────────────────┬──────────────────────────────────┘
                           │
                    ┌──────▼──────┐
                    │ RouterFactory│
                    │ (factory.rs) │
                    └──────┬──────┘
                           │
           ┌───────────────┼───────────────┐
           │               │               │
    ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
    │ HTTP Router │ │ PD Router   │ │ gRPC Router │
    │ (router.rs) │ │(pd_router.rs)│ │             │
    └──────┬──────┘ └──────┬──────┘ └─────────────┘
           │               │
           │    ┌──────────▼──────────┐
           │    │  PolicyRegistry      │
           │    │  (registry.rs)       │
           │    │  - model_policies    │
           │    │  - prefill_policy    │
           │    │  - decode_policy     │
           │    └──────────┬──────────┘
           │               │
    ┌──────▼───────────────▼──────────┐
    │     LoadBalancingPolicy trait    │
    │     (mod.rs)                     │
    │     - select_worker()            │
    │     - on_request_complete()      │
    │     - update_loads()             │
    │     - needs_request_text()       │
    └──────────────┬──────────────────┘
                   │
     ┌─────────────┼─────────────┬──────────────┐
     │             │             │              │
┌────▼────┐ ┌──────▼──────┐ ┌───▼────┐  ┌──────▼──────┐
│ Random   │ │ RoundRobin  │ │ ...    │  │Composite   │
│Policy    │ │Policy       │ │        │  │Policy (新)  │
└─────────┘ └─────────────┘ └────────┘  └─────────────┘
```

### 1.2 核心 Trait

**文件**: `src/policies/mod.rs` (220 行)

```rust
#[async_trait]
pub trait LoadBalancingPolicy: Send + Sync + Debug {
    /// 从可用 workers 中选择一个
    async fn select_worker(
        &self,
        workers: &[Arc<dyn Worker>],
        info: &SelectWorkerInfo<'_>,
    ) -> Option<usize>;

    /// 请求完成后的回调（更新状态）
    fn on_request_complete(&self, _worker_url: &str, _success: bool);

    /// 返回策略名称（用于 metric 标签）
    fn name(&self) -> &'static str;

    /// 是否需要请求文本（如 CacheAware 需要）
    fn needs_request_text(&self) -> bool { false }

    /// 接收负载更新（LoadMonitor 定时推送）
    fn update_loads(&self, _loads: &HashMap<String, isize>);

    /// 设置 Mesh 同步（分布式部署场景）
    fn set_mesh_sync(&mut self, _mesh_sync: OptionalMeshSyncManager);

    /// 重置内部状态
    fn reset(&self);

    /// 向下转型（用于 CacheAware/Bucket 等特殊初始化）
    fn as_any(&self) -> &dyn std::any::Any;
}
```

**SelectWorkerInfo** 携带的信息：

```rust
pub struct SelectWorkerInfo<'a> {
    pub request_text: Option<&'a str>,   // 请求文本（CacheAware）
    pub tokens: Option<&'a [u32]>,       // Token 序列（PrefixHash）
    pub headers: Option<&'a HeaderMap>,  // HTTP 头（Manual、X-SMG-Routing-Key）
    pub hash_ring: Option<Arc<HashRing>>,// 一致性哈希环
}
```

### 1.3 PolicyRegistry 策略注册中心

**文件**: `src/policies/registry.rs` (512 行)

| 字段 | 类型 | 用途 | 是否可运行时切换 |
|------|------|------|:---:|
| `model_policies` | `DashMap<String, Arc<dyn Policy>>` | 模型→策略映射 | ❌ 无 set API |
| `default_policy` | `Arc<dyn Policy>` | 默认策略 | ❌ 构造后不可变 |
| `prefill_policy` | `Arc<OnceLock<Arc<dyn Policy>>>` | PD Prefill 策略 | ❌ OnceLock 写死 |
| `decode_policy` | `Arc<OnceLock<Arc<dyn Policy>>>` | PD Decode 策略 | ❌ OnceLock 写死 |
| `model_worker_counts` | `DashMap<String, usize>` | 模型 worker 计数 | — |
| `mesh_sync` | `Arc<RwLock<OptionalMeshSyncManager>>` | 分布式同步 | — |

### 1.4 策略分类与状态

#### 1.4.1 官方文档策略（README 明确列出）

| 策略 | 文件 | 规模 | 核心机制 | 状态 |
|------|------|------|---------|:----:|
| **Random** | `random.rs` (85行) | 3.5KB | 均匀随机选一个 | ✅ 稳定 |
| **RoundRobin** | `round_robin.rs` (115行) | 4.4KB | 原子计数器，顺序轮转 | ✅ 稳定 |
| **CacheAware** | `cache_aware.rs` (850行) | 31.1KB | Radix Tree 前缀匹配，优先缓存命中 | ✅ 稳定 |
| **PowerOfTwo** | `power_of_two.rs` (330行) | 13.0KB | 随机选 2 个，取负载低的 | ✅ 稳定 |
| **Bucket** | `bucket.rs` (1200行) | 45.3KB | 请求文本分桶，类似缓存亲和 | ✅ 稳定 |

#### 1.4.2 代码中存在但未在 README 列出（社区贡献/未完成）

| 策略 | 文件 | 规模 | 核心机制 | 状态 |
|------|------|------|---------|:----:|
| **PrefixHash** | `prefix_hash.rs` (360行) | 13.7KB | Token 前缀 Hash + 负载均衡 | ⚠️ 未文档化 |
| **Manual** | `manual.rs` (850行) | 32.4KB | Routing Key 黏性会话 | ⚠️ 未文档化 |
| **ConsistentHashing** | `consistent_hashing.rs` (480行) | 18.3KB | Hash Ring 路由 | ⚠️ 未文档化 |
| **RequestSizeBucket** | `request_size_bucket.rs` (390行) | 14.9KB | 按输入/输出 token 数分桶 | ⚠️ 未文档化 |

#### 1.4.3 AI 生成策略（本项目先前添加，存在集成缺陷）

| 策略 | 文件 | 规模 | 核心机制 | 状态 |
|------|------|------|---------|:----:|
| **PerformanceAware** | `performance_aware.rs` (375行) | 14.4KB | TTFT/TPOT/吞吐量 加权评分 | ❌ 退化 |
| **RequestClassification** | `request_classification.rs` (475行) | 18.1KB | 按输入/输出长度 + worker priority/cost 分类 | ❌ 退化 |

#### 1.4.4 PerformanceAwarePolicy 已知问题

| 问题 | 严重度 | 说明 |
|------|:------:|------|
| `record_metrics()` 从未被调用 | 🔴 致命 | 策略有 `record_metrics(ttft, tpot, throughput)` 方法，但 Router 层（HTTP Router / PD Router）没有任何地方调用它。这是**唯一的指标录入入口**。 |
| Score 永久为 0，退化为 first-worker-wins | 🔴 致命 | `calculate_scores()` 依赖 `worker_metrics` 计算评分，但因为从未录入指标，所有 worker score = 0.0。`select_worker()` 在全部 score 相等时选第一个 healthy worker。 |
| `on_request_complete()` 不记录指标 | 🟡 中等 | 只在失败时打 log，不调用 `record_metrics()`。错过了一个天然的数据录入时机。 |
| 缺少集成点 | 🟡 中等 | PD Router 的 `execute_dual_dispatch()` 返回了 decode 响应（含 usage/timing），但未提取 TTFT/TPOT 喂给策略。 |

**退化效果**：名义上是"性能感知策略"，实际等价于"始终发给第一个健康的 worker"。

#### 1.4.5 RequestClassificationPolicy 已知问题

| 问题 | 严重度 | 说明 |
|------|:------:|------|
| Worker 分类基于 priority/cost 比率 | 🔴 致命 | 用 `priority/cost > 5.0` 判定"计算型"、`< 1.0` 判定"内存型"。用户必须手动设置 priority 和 cost 标签来间接表达 GPU 能力，极不可靠且不直观。 |
| 分类逻辑简化为仅靠输入长度 | 🟡 中等 | 默认 `max_tokens=200` 导致输出长度始终为 "medium"，最终分类几乎完全由输入长度决定。 |
| Worker 分派是静态的 | 🟡 中等 | `initialize_workers()` 只在首次 `select_worker()` 时调用一次。Worker 增删后分派表不会更新。 |
| `increment_processed()` 在 fallback 路径重复调用 | 🟢 轻微 | 两个 fallback 分支（无分派 worker / 无健康 worker）各自调用一次，正常路径再调用一次，导致 fallback 时计数额外 +1。 |

**退化效果**：Worker 分派表依赖无实际意义的 label 数值，实际分类维度单一。

### 1.5 Worker 元数据结构

**文件**: `src/core/worker.rs`

```rust
pub struct WorkerMetadata {
    pub url: String,
    pub worker_type: WorkerType,      // Regular | Prefill | Decode
    pub connection_mode: ConnectionMode, // Http | Grpc
    pub labels: HashMap<String, String>, // 自由标签（目前用于 priority/cost）
    pub bootstrap_host: String,       // PD 模式 KV cache 传输地址
    pub bootstrap_port: Option<u16>,  // PD 模式 KV cache 传输端口
    pub models: Vec<ModelCard>,       // 支持的模型列表
    pub default_provider: Option<ProviderType>,
    pub default_model_type: ModelType,
    // ← 缺少：GPU 型号、计算能力、显存带宽、显存容量
}
```

### 1.6 PD Router 调度流程

**文件**: `src/routers/http/pd_router.rs` (1550行)

```
请求到达
  │
  ├─ 1. 提取 batch_size + request_text
  ├─ 2. policy_registry.get_prefill_policy().select_worker(prefill_workers, info)
  │      └─ 选中 Prefill worker (如 prefill-2)
  ├─ 3. 注入 bootstrap_host + bootstrap_port + bootstrap_room 到请求体
  ├─ 4. 发送给 Prefill worker → 计算 KV cache
  ├─ 5. 从 Prefill 响应中提取 bootstrap_room
  ├─ 6. policy_registry.get_decode_policy().select_worker(decode_workers, info)
  │      └─ 选中 Decode worker (如 decode-2)
  ├─ 7. 发送给 Decode worker → 生成文本
  └─ 8. 返回响应给客户端
```

**关键点**: Prefill 和 Decode 策略是**独立选择**的，两者之间没有协同——这对异构场景是重要优化点。

---

## 二、新模块体系总览

```
┌──────────────────────────────────────────────────────────────────┐
│                    异构 GPU 调度系统（新增模块）                      │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────────────────┐ │
│  │ GPU 画像层   │  │ 指标采集层    │  │ 策略框架层               │ │
│  │ GpuCapability│  │MetricsCollector│ │ CompositePolicy        │ │
│  │ RooflineModel│  │ LoadReporter  │  │ PhaseAwareSwitcher     │ │
│  └──────┬──────┘  └──────┬───────┘  └───────────┬─────────────┘ │
│         │                │                      │                │
│         └────────────────┼──────────────────────┘                │
│                          │                                       │
│  ┌───────────────────────┼───────────────────────────────────┐  │
│  │       策略实现层                                           │  │
│  │  ┌──────────────┐ ┌─────────────┐ ┌───────────────────┐  │  │
│  │  │RoofLinePolicy │ │LoadAwarePol │ │HeteroCostPolicy   │  │  │
│  │  │(静态-硬件感知) │ │(动态-负载)   │ │(成本感知)          │  │  │
│  │  └──────────────┘ └─────────────┘ └───────────────────┘  │  │
│  │  ┌──────────────────────────────────────────────────┐   │  │
│  │  │RequestProfilingPolicy (静态-请求特征)             │   │  │
│  │  └──────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │             运行时策略切换 (Online Switch)                  │  │
│  │  OnceLock→RwLock + Admin API + 渐进式灰度切流              │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              SGLang 侧改动                                 │  │
│  │  - Metrics 端点增强: 暴露 queue_depth, kv_cache_usage      │  │
│  │  - PD Transfer 优化: KV cache 跨机传输调度                  │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 三、新增模块详细设计

### 模块 0：现有策略修复与合并

在实施新模块之前，首先需要修复并合并两个 AI 生成的退化策略（详见 1.4.4 和 1.4.5）。

#### 0.1 PerformanceAwarePolicy → 合并到 LoadAwarePolicy

**合并方案**：

| 保留 | 丢弃 | 说明 |
|------|------|------|
| TTFT/TPOT/throughput 加权评分公式 | 独立的 `record_metrics()` 调用入口 | 评分逻辑融入 LoadAwarePolicy |
| WorkerPerformanceMetrics EWMA 平滑 | 独立 `WorkerPerformanceMetrics` 结构体 | 改为 LoadAwarePolicy 内部 `DashMap<String, PerfWindow>` |
| 滑动窗口统计 | `Arc<RwLock<HashMap>>` 全局锁 | 改为 `DashMap`（无锁并发） |

**需要新增的 Router 集成点**（当前缺失，导致 score 永久为 0）：

```
// PD Router execute_dual_dispatch() 返回后:
let ttft_ms = extract_ttft_from_decode_response(&response);
let tpot_ms = extract_tpot_from_decode_response(&response);
policy_registry.get_decode_policy().record_perf(worker_url, ttft_ms, tpot_ms);

// HTTP Router 流式响应结束后:
policy_registry.get_model_policy(model).record_perf(worker_url, ttft_ms, tpot_ms);
```

**合并后的 LoadAwarePolicy 评分公式**：

```
score = w_queue     * (1 - norm_queue_depth)        // 实时负载
      + w_kvcache   * (1 - norm_kvcache_usage)      // 显存压力
      + w_ttft      * (1 - norm_ttft_p50)           // ← 合并自 PerformanceAware
      + w_tpot      * (1 - norm_tpot_p50)           // ← 合并自 PerformanceAware
      + w_throughput * norm_throughput               // ← 合并自 PerformanceAware
```

**标记原文件**：`src/policies/performance_aware.rs` 头部添加 `// DEPRECATED: merged into LoadAwarePolicy`，后续可安全删除。

#### 0.2 RequestClassificationPolicy → 合并到 RequestProfilingPolicy

**合并方案**：

| 保留 | 丢弃 | 说明 |
|------|------|------|
| `classify_request()` 请求分类框架 | `priority/cost > 5.0` worker 分类机制 | 改为基于 `GpuCapability` 实时匹配 |
| 输入长度/输出长度字段提取 | 静态 `worker_types` 分派表（一次初始化不刷新） | 每次 `select_worker()` 动态匹配 |
| `RequestType` 枚举 | `initialize_workers()` + `increment_processed()` | 不再需要预分类和计数 |

**修复的 Bug**：

| Bug | 修复 |
|-----|------|
| `max_tokens` 默认 200 导致输出分类恒为 "medium" | 改为从 `request_text` 解析 `max_tokens` 参数；若无则从 `GpuCapability` 推导合理默认值 |
| Worker 分派静态不更新 | 每次 `select_worker()` 基于 `GpuCapability` + 实时负载动态匹配 |
| Fallback 路径 `increment_processed()` 重复调用 | 计数统一在 `on_request_complete()` 中处理 |

**新 RequestProfilingPolicy 分类 → 匹配逻辑**：

```
请求分类:
  ├─ stream=true                  → 低延迟型 → 优先 max(tflops) + min(queue_depth)
  ├─ input_len > 8K               → 大上下文型 → 优先 max(vram_gb) + min(kv_cache_usage)
  ├─ output_len > 2K              → 长输出型 → 优先 max(vram_gb)
  ├─ batch_size > 4 (仅 Prefill)  → 计算密集型 → 优先 max(tflops)
  └─ default                      → 经济型 → 优先 min(cost_per_hour)

Worker 分类 (基于 GpuCapability.tier()):
  ├─ Tier 1 (H800)  → 低延迟、计算密集型请求
  ├─ Tier 2 (H20)   → 大上下文、长输出请求
  └─ Tier 3 (4090)  → 默认/经济型请求
```

**标记原文件**：`src/policies/request_classification.rs` 头部添加 `// DEPRECATED: merged into RequestProfilingPolicy (with GpuCapability integration)`。

#### 0.3 合并后的策略注册（factory.rs 变更）

```
// 移除注册（保留原文件但标记 DEPRECATED）:
"performance_aware"       → 不再注册（合并入 load_aware）
"request_classification"  → 不再注册（合并入 request_profiling）

// 新增注册（合并后版本）:
"load_aware"              → LoadAwarePolicy（含 TTFT/TPOT 性能反馈）
"request_profiling"       → RequestProfilingPolicy（含 GpuCapability 感知分类）
```

---

### 模块 1：GPU 画像系统

**文件**: `src/core/gpu_profile.rs` (新增)

```
┌──────────────────────────────────────┐
│            GpuCapability              │
├──────────────────────────────────────┤
│ + gpu_name: String                   │  e.g. "NVIDIA H800"
│ + fp16_tflops: f64                   │  e.g. 989.0
│ + mem_bandwidth_gb_s: f64            │  e.g. 2039.0
│ + vram_gb: f64                       │  e.g. 80.0
│ + sm_count: u32                      │  e.g. 132
│ + compute_capability: (u32, u32)     │  e.g. (9, 0)
├──────────────────────────────────────┤
│ + arithmetic_intensity(tokens,       │
│     param_size) -> f64               │  计算算术强度
│ + is_compute_bound(task) -> bool     │  判断瓶颈类型
│ + roofline_performance(task) -> f64  │  Roofline 性能上界
│ + tier() -> GpuTier                  │  High | Mid | Low
└──────────────────────────────────────┘
```

**WorkerMetadata 扩展**:

```rust
// src/core/worker.rs 中 WorkerMetadata 新增字段:
pub gpu_profile: Option<GpuCapability>,  // GPU 能力画像
```

**集成方式**:
- SGLang worker 启动时已知 GPU 型号（`nvidia-smi` 可查）
- Worker 注册到 SMG 时通过 `/get_server_info` 携带 GPU 信息
- 也支持手动配置（CLI `--worker-gpu-type H800`）

---

### 模块 2：SGLang 指标采集器

**文件**: `src/core/metrics_collector.rs` (新增)

**方案：在 SMG 的 LoadMonitor 中扩展**

```
现有 LoadMonitor:
  interval_timer.tick()
    → 对每个 worker: GET /health
    → 更新 healthy 状态

扩展后 LoadMonitor:
  interval_timer.tick()
    → 对每个 worker:
        ├─ GET /health
        ├─ GET /get_server_info    ← 获取 GPU 信息
        └─ GET /metrics (Prometheus) ← 获取运行指标
    → 解析指标:
        ├─ sglang:num_running_reqs     → 当前运行请求
        ├─ sglang:num_queue_reqs       → 排队请求
        ├─ sglang:kv_cache_usage_ratio → KV cache 使用率
        ├─ sglang:gen_throughput       → 生成吞吐量
        └─ sglang:token_usage          → Token 使用率
    → 推送到所有策略: policy.update_loads(metrics)
```

**SGLang 侧配合**（提 PR）:
- 确保 `--enable-metrics` 暴露的 Prometheus 指标包含上述字段
- 或者新增 `/get_load` 轻量端点（比全量 `/metrics` 更快）

---

### 模块 3：RoofLinePolicy（硬件感知静态策略）

**文件**: `src/policies/roofline.rs` (新增)

**策略逻辑**:

```
输入: workers[], SelectWorkerInfo
输出: 选中的 worker index

算法:
  1. 读取每个 worker 的 GpuCapability
  2. 估算请求的计算特征:
     - Prefill: 计算密集型 → 优先高 TFLOPS GPU
     - Decode:  内存密集型 → 优先高带宽 GPU
  3. 计算 Score:
     score = w_compute * normalized_tflops + w_memory * normalized_bandwidth
  4. 选 Score 最高的 worker
```

**简化版（比严格 roofline 模型更工程化）**:

```
GPU Tier 分级:
  Tier 1 (H800):  适合大 batch Prefill + 高吞吐 Decode
  Tier 2 (H20):   大显存适合长上下文 Decode
  Tier 3 (4090):  低成本适合短文本、批量推理

路由规则:
  - Prefill && batch_size > 4  → Tier 1
  - Decode  && context > 4096  → Tier 2
  - Decode  && context <= 4096 → Tier 3 (节省成本)
```

---

### 模块 4：RequestProfilingPolicy（请求特征静态策略）

**文件**: `src/policies/request_profiling.rs` (新增)

> **命名注意**: 与已有的 `RequestClassificationPolicy` (按 token 长度分桶) 区分。

**策略逻辑**:

```
输入: workers[], SelectWorkerInfo + 扩展的请求元数据

请求分类维度:
  ┌──────────────┬─────────────────┬──────────────────┐
  │ 维度          │ 类型            │ 适合 GPU          │
  ├──────────────┼─────────────────┼──────────────────┤
  │ stream       │ 流式            │ 低延迟 → H800     │
  │ batch_size   │ >4              │ 高吞吐 → H800     │
  │ context_len  │ >8K             │ 大显存 → H20      │
  │ expected_len │ >2K             │ 大显存 → H20      │
  │ embedding    │ 是              │ 高带宽 → H800     │
  │ default      │ —               │ 低成本 → 4090     │
  └──────────────┴─────────────────┴──────────────────┘
```

---

### 模块 5：LoadAwarePolicy（负载感知动态策略）

**文件**: `src/policies/load_aware.rs` (新增)

**与已有 PerformanceAwarePolicy 的区别**:

| 维度 | PerformanceAware | LoadAware (新) |
|------|-----------------|----------------|
| 数据来源 | 历史 TTFT/TPOT 平均值 | 实时队列深度、KV cache 使用率 |
| 更新频率 | 60s（可配） | 5s（实时） |
| 关注点 | 谁历史上更快 | 谁现在最空闲 |
| 适用场景 | 稳态调度 | 突发流量、动态负载 |

**评分模型**:

```
load_score = w_queue * (1 - norm_queue_depth)
           + w_kvcache * (1 - norm_kvcache_usage)
           + w_throughput * norm_throughput

最终选择 load_score 最高的 worker
```

---

### 模块 6：HeteroCostPolicy（成本感知策略）

**文件**: `src/policies/hetero_cost.rs` (新增)

**核心公式**:

```
value_score = α * performance_score + β * (1 / cost_ratio) + γ * sla_score

其中:
  performance_score = 硬件能力 + 当前负载 的综合评分
  cost_ratio        = 该 GPU 的每小时成本 / 最便宜 GPU 的成本
  sla_score         = 满足 SLO 的概率

权重:
  α: 性能权重（默认 0.4）
  β: 成本权重（默认 0.4）
  γ: SLO 保障权重（默认 0.2）
```

**配套需求**: WorkerMetadata 需要 `cost_per_hour: f64` 字段（可在 labels 中配置）。

---

### 模块 7：CompositePolicy + PhaseSwitcher（组合策略框架）★核心★

**文件**: `src/policies/composite.rs` (新增)

**架构**:

```
┌─────────────────────────────────────────────────────┐
│                CompositePolicy                       │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │           PhaseSwitcher                       │   │
│  │                                              │   │
│  │  load < low_threshold  ──→  Affinity Policy  │   │
│  │  load > high_threshold ──→  Distribution     │   │
│  │  中间状态             ──→  加权混合           │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  ┌──────────────────┐  ┌────────────────────────┐  │
│  │ Distribution      │  │ Affinity               │  │
│  │ (负载均衡)         │  │ (亲和匹配)              │  │
│  │                   │  │                        │  │
│  │ · RoundRobin      │  │ · RoofLine             │  │
│  │ · LoadAware       │  │ · RequestProfile       │  │
│  │ · LeastConn       │  │ · CacheAware           │  │
│  └──────────────────┘  └────────────────────────┘  │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**配置接口**:

```bash
# CLI
--policy composite \
--composite-distribution load_aware \
--composite-affinity roofline \
--composite-switch-low-threshold 0.3 \   # 低负载阈值
--composite-switch-high-threshold 0.7    # 高负载阈值

# 也支持 JSON 配置
{
  "policy": "composite",
  "composite": {
    "distribution": { "type": "load_aware", "config": { ... } },
    "affinity": { "type": "roofline", "config": { ... } },
    "switcher": {
      "low_threshold": 0.3,
      "high_threshold": 0.7,
      "ramp_duration_secs": 30
    }
  }
}
```

**PhaseSwitcher 状态机**:

```
          load < low_threshold
    ┌──────────────────────────────┐
    │                              │
    ▼                              │
┌─────────┐  load > high_threshold  ┌──────────────┐
│Affinity │ ──────────────────────→ │ Distribution  │
│ Mode    │ ←────────────────────── │ Mode          │
└─────────┘  load < low_threshold   └──────────────┘
    │                              │
    └──────────────────────────────┘
          中间态: 加权混合
       score = w_aff * affinity_score + w_dist * dist_score
       w_aff 从 1.0 → 0.0 平滑过渡
```

---

### 模块 8：运行时策略切换（Online Switch）

**文件**: 修改 `src/policies/registry.rs`

**现状分析**:

| 组件 | 当前存储 | 可切换? | 原因 |
|------|---------|:-----:|------|
| PD Prefill Policy | `OnceLock` | ❌ | 只能 set 一次 |
| PD Decode Policy | `OnceLock` | ❌ | 只能 set 一次 |
| Model Policy | `DashMap` | ❌ | 无 update API |
| Default Policy | `Arc` (不可变) | ❌ | 构造后不可变 |

**改造方案**:

#### Level 1: PD 策略切换（最小改动）

```rust
// Before (registry.rs:30-33):
prefill_policy: Arc<OnceLock<Arc<dyn LoadBalancingPolicy>>>,
decode_policy: Arc<OnceLock<Arc<dyn LoadBalancingPolicy>>>,

// After:
prefill_policy: Arc<RwLock<Option<Arc<dyn LoadBalancingPolicy>>>>,
decode_policy: Arc<RwLock<Option<Arc<dyn LoadBalancingPolicy>>>>,
```

新增方法:

```rust
/// 运行时切换 Prefill 策略（零停机）
pub fn switch_prefill_policy(&self, policy: Arc<dyn LoadBalancingPolicy>) {
    let mut guard = self.prefill_policy.write().unwrap();
    let old_name = guard.as_ref().map(|p| p.name()).unwrap_or("none");
    let new_name = policy.name();
    *guard = Some(policy);
    info!("Switched prefill policy: {} -> {}", old_name, new_name);
}

/// 运行时切换 Decode 策略
pub fn switch_decode_policy(&self, policy: Arc<dyn LoadBalancingPolicy>) {
    let mut guard = self.decode_policy.write().unwrap();
    *guard = Some(policy);
}

/// 运行时切换 Model 策略
pub fn switch_model_policy(&self, model_id: &str, policy: Arc<dyn LoadBalancingPolicy>) {
    self.model_policies.insert(model_id.to_string(), policy);
}
```

**安全性保证**: `Arc` 引用计数——正在处理的请求继续用旧策略，新请求自动用新策略。

#### Level 2: Admin API

```
POST /admin/policy
{
  "action": "switch",
  "target": "prefill",      // prefill | decode | model:<id> | default
  "policy": "roofline",
  "config": {
    "weight_compute": 0.6,
    "weight_memory": 0.4
  }
}

GET /admin/policy
→ 返回当前所有策略配置

POST /admin/policy
{
  "action": "gradual_switch",
  "target": "prefill",
  "policy": "load_aware",
  "gradual": {
    "new_policy_ratio": 0.1,      // 起始 10% 流量
    "ramp_duration_secs": 300,     // 5 分钟内平滑到 100%
    "final_ratio": 1.0
  }
}
```

#### Level 3: 灰度切流（集成到 CompositePolicy）

在 CompositePolicy 内部实现流量分配:

```
select_worker() {
    let ratio = self.gradual_switcher.current_ratio();
    if rand::random::<f64>() < ratio {
        self.new_policy.select_worker(...)
    } else {
        self.old_policy.select_worker(...)
    }
}
```

---

### 模块 9：SGLang 侧改动

#### 9a. Metrics 端点增强（提 PR 给 SGLang）

目前 SGLang 的 `--enable-metrics` 暴露的指标可能不完整。需要确认/新增：

```
# 需要暴露的关键指标
sglang:num_running_reqs        # 当前运行的请求数
sglang:num_queue_reqs          # 排队中的请求数
sglang:kv_cache_usage_ratio    # KV cache 使用比例 (0.0 ~ 1.0)
sglang:gen_throughput_tokens   # 生成吞吐量 (tokens/s)
sglang:prefill_latency_ms      # Prefill 延迟
sglang:decode_latency_ms       # Decode 延迟
```

#### 9b. PD Transfer 优化（可选，深度工作）

异构场景下 Prefill→Decode 的 KV cache 传输可能成为瓶颈：
- H800 算完 Prefill 后跨机传给 4090，网络带宽可能不够
- 需要智能 P-D 配对：同一台机器或同机架的 P 和 D 配对
- KV cache 分块异步传输：Prefill 还没算完就开始传

---

## 四、工作分工建议

| 角色 | 模块 | 代码量 | 难度 | 依赖 |
|------|------|--------|:----:|------|
| **你（项目负责人）** | **Module 0**: PerformanceAware→LoadAware merge + Router 集成点 | ~150行(改) | ⭐⭐⭐⭐ | — |
| | **Module 0**: RequestClassification→RequestProfiling merge + factory 清理 | ~100行(改) | ⭐⭐⭐ | — |
| | CompositePolicy + PhaseSwitcher | ~500行 | ⭐⭐⭐⭐⭐ | GpuProfile |
| | Runtime Policy Switch (registry: OnceLock→RwLock + admin API) | ~300行 | ⭐⭐⭐ | — |
| | PD Router 集成改造 (TTFT/TPOT 提取) | ~200行 | ⭐⭐⭐⭐ | LoadAwarePolicy |
| | 整体架构评审 + 测试框架 | — | ⭐⭐⭐⭐ | — |
| **同学 A（Rust 熟练）** | GpuProfile + RoofLinePolicy | ~500行 | ⭐⭐⭐ | — |
| | MetricsCollector + LoadAwarePolicy (含合并后的性能反馈) | ~500行 | ⭐⭐⭐⭐ | GpuProfile |
| | LoadMonitor 扩展 | ~200行 | ⭐⭐⭐ | MetricsCollector |
| **同学 B** | RequestProfilingPolicy (含合并后的 GpuCapability 分类) | ~350行 | ⭐⭐⭐ | GpuProfile |
| | HeteroCostPolicy | ~200行 | ⭐⭐ | GpuProfile |
| | 实验脚本 + 基准测试 | ~400行(Python) | ⭐⭐ | — |
| | 策略效果可视化 | — | ⭐⭐ | — |

**依赖图**:

```
                    ┌────────────────────────────────┐
                    │ Module 0: 修复 & 合并           │
                    │ perf_aware → load_aware         │
                    │ req_class → request_profiling   │
                    └───────────────┬────────────────┘
                                    │
                              GpuProfile
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
               RoofLinePolicy       │    RequestProfilingPolicy
                    │               │               │
                    ├───────────────┘               │
                    │                               │
               MetricsCollector                     │
                    │                               │
               LoadAwarePolicy                      │
              (含 TTFT/TPOT)                        │
                    │                               │
                    └─────────────┬─────────────────┘
                                  │
                            CompositePolicy
                                  │
                          Runtime Policy Switch
                                  │
                             实验验证
```

---

## 五、里程碑规划

| 阶段 | 内容 | 产出 |
|------|------|------|
| **M0** (前置) | **Module 0**: PerformanceAware→LoadAware merge + Router 集成点补全 | 修复后的 LoadAwarePolicy 原型 |
| | **Module 0**: RequestClassification→RequestProfiling merge + GpuCapability 集成 | 修复后的 RequestProfilingPolicy 原型 |
| | factory.rs 清理（移除退化策略注册，添加合并版注册） | 干净策略注册表 |
| **M1** (第1周) | GpuProfile + WorkerMetadata 扩展 | GPU 画像数据结构 + CLI |
| | MetricsCollector + LoadMonitor 扩展 | 实时指标采集 |
| **M2** (第2周) | RoofLinePolicy + RequestProfilingPolicy | 2 个静态策略 |
| | LoadAwarePolicy (含 TTFT/TPOT 性能反馈) | 1 个动态策略 |
| **M3** (第3周) | CompositePolicy + PhaseSwitcher | 组合框架 |
| | HeteroCostPolicy | 成本感知策略 |
| **M4** (第4周) | Runtime Policy Switch (registry + admin API) | 零停机策略切换 |
| | SGLang Metrics PR（如需要） | 上游贡献 |
| **M5** (第5周) | H800+H20/4090 实验 | 实验数据 |
| | 性价比分析报告 | 项目结题材料 |
| **M6** (第6周) | SMG PR 整理 + 提交 | 上游贡献 |

---

## 六、关键代码文件索引

### 现有文件（需要修改）

| 文件 | 行数 | 改动内容 |
|------|------|---------|
| `src/policies/mod.rs` | 220 | 扩展 SelectWorkerInfo（增加 gpu_tier、slo_target 等）；LoadBalancingPolicy trait 新增 `record_perf()` 方法 |
| `src/policies/registry.rs` | 512 | OnceLock→RwLock，新增 switch_* 方法 |
| `src/policies/factory.rs` | 183 | 移除 `PerformanceAware` / `RequestClassification` 注册；注册 `LoadAware` / `RequestProfiling`（合并版） |
| `src/config/types.rs` | 1300+ | 新增 PolicyConfig variant（roofline / load_aware / request_profiling / hetero_cost / composite） |
| `src/core/worker.rs` | 2017 | WorkerMetadata 扩展 GpuCapability + cost_per_hour 字段 |
| `src/core/worker_manager.rs` | ~500 | LoadMonitor 扩展 Prometheus `/metrics` 指标采集 |
| `src/routers/http/pd_router.rs` | 1550 | **Module 0**: 新增 TTFT/TPOT 提取 → `policy.record_perf()` 集成点；P-D 配对逻辑（可选） |
| `src/routers/http/router.rs` | — | **Module 0**: 新增 `on_request_complete()` 中调用 `policy.record_perf()` |
| `src/main.rs` | — | 新增 CLI 参数 `--composite-distribution` / `--composite-affinity` 等 |
| `src/app_context.rs` | 480 | Admin API 路由注册（`POST /admin/policy`） |

### 标记废弃文件（Module 0 合并后不再使用）

| 文件 | 行数 | 处理方式 |
|------|------|---------|
| `src/policies/performance_aware.rs` | 375 | 头添加 `// DEPRECATED` 注释，合并入 `load_aware.rs` |
| `src/policies/request_classification.rs` | 475 | 头添加 `// DEPRECATED` 注释，合并入 `request_profiling.rs` |

### 新增文件

| 文件 | 预计行数 | 内容 |
|------|---------|------|
| `src/core/gpu_profile.rs` | ~200 | GpuCapability + RooflineModel |
| `src/core/metrics_collector.rs` | ~300 | SGLang 指标采集与解析 |
| `src/policies/roofline.rs` | ~300 | RoofLinePolicy |
| `src/policies/request_profiling.rs` | ~250 | RequestProfilingPolicy（合并 RequestClassification 分类框架） |
| `src/policies/load_aware.rs` | ~300 | LoadAwarePolicy（合并 PerformanceAware TTFT/TPOT 反馈） |
| `src/policies/hetero_cost.rs` | ~200 | HeteroCostPolicy |
| `src/policies/composite.rs` | ~400 | CompositePolicy + PhaseSwitcher |
| `docs/heterogeneous-scheduling-architecture.md` | — | 本文档 |

---

## 七、待确认 / 待调研事项

1. **SGLang 的 `/get_server_info` 当前返回什么？** 是否包含 GPU 型号信息？还是需要提 PR 扩展？
2. **SGLang 的 Prometheus metrics 实际暴露了哪些字段？** 需要对照检查 `--enable-metrics` 输出。
3. **H800 vs H20 vs 4090 的实际成本数据**——从云厂商或内部采购获取。
4. **SGLang 的 PD transfer 延迟**——跨机型传输 KV cache 的实际耗时是多少？是否是瓶颈？
5. **SMG 的 gRPC router 是否需要同样的改造？** 目前分析限于 HTTP router。
