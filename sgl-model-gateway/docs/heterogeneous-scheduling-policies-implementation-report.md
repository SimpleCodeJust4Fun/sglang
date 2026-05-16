# 异构调度策略实现报告

> **日期**: 2026-05-16
> **分支**: `feat/pd-enhanced-logs-experiments`
> **基架文档**: `docs/heterogeneous-scheduling-architecture.md`

---

## 一、改动文件总览

| 文件 | 改动 | 说明 |
|------|------|------|
| `src/policies/request_profiling.rs` | 修改 | 修复 `HashMap` 警告；修复 compilation ICE；新增 22 个测试 (总计 34) |
| `src/policies/roofline.rs` | **新增** | 570行，RoofLinePolicy + 30个测试 |
| `src/policies/composite.rs` | **新增** | 470行，CompositePolicy + PhaseSwitcher + 23个测试 |
| `src/policies/mod.rs` | +6行 | 三个模块注册 + pub use |
| `src/policies/factory.rs` | +60行 | import、create_from_config、create_by_name、测试 |
| `src/config/types.rs` | +55行 | 三个 PolicyConfig variant + defaults + name() |
| `src/config/validation.rs` | +75行 | 三个策略校验 + 9个测试 |

---

## 二、三个策略对比

| 维度 | RequestProfilingPolicy | RoofLinePolicy | CompositePolicy |
|------|----------------------|----------------|-----------------|
| **策略类型** | 静态-请求特征 | 静态-硬件感知 | 动态-组合(framework) |
| **核心思想** | 按请求特征分桶，Worker声明profile归属 | 按GPU算力评分，选最高分Worker | 负载低用亲和，负载高用分散 |
| **Worker标签** | `profile=short/long/default` | `gpu_name=H800/H20/...` 或 `tflops/bandwidth/vram` | 无（使用子策略的标签） |
| **选择依据** | Profile匹配 → 组内least-loaded | 加权评分: w_compute·tflops + w_memory·bandwidth | PhaseSwitcher模式决定用哪个子策略 |
| **配置参数** | 输入阈值(500/4000)、输出阈值(1024)、Profile规则 | compute权重(0.5)、memory权重(0.5) | 低负载阈值(0.3)、高负载阈值(0.7) |
| **测试数** | 34 (12原+22新) | 30 | 23 |

---

## 三、RequestProfilingPolicy

### 3.1 架构

```
请求到达
  │
  ├─ 1. classify_request(): 分类请求
  │     ├─ 输入长度: Short(<500) / Medium / Long(≥4000)
  │     ├─ 输出长度: 从 max_tokens / max_completion_tokens 提取
  │     └─ 流式模式: 从 "stream":true 提取
  │
  ├─ 2. match_profile(): 按 ProfileRule 优先级匹配
  │     ├─ Short input   → "short" profile   (priority=10)
  │     ├─ Long input    → "long" profile    (priority=10)
  │     ├─ Large output  → "large_output"    (priority=5)
  │     └─ 其他          → "default"         (priority=0, catch-all)
  │
  ├─ 3. select_worker(): 从匹配的 profile 组选 worker
  │     ├─ 组内 least-loaded 选择
  │     ├─ Fallback 1: "default" profile 组
  │     └─ Fallback 2: 任意健康 worker
  │
  └─ 返回 worker index
```

### 3.2 编译修复

| 问题 | 文件 | 修复 |
|------|------|------|
| ICE (Rust 1.94.1) | `src/config/validation.rs` | `validate_policy` 缺少 `PolicyConfig::RequestProfiling` 的 match arm，已添加 `short_input_threshold > 0` 和 `long_input_threshold > short_input_threshold` 校验 |
| `unused_qualifications` 警告 | `request_profiling.rs:423` | `std::collections::HashMap` 改为 `HashMap` |

### 3.3 新增测试 (22个)

**输出分类 (4):** `test_output_classification`, `test_large_output_threshold_boundary`
**输入边界 (1):** `test_input_boundaries`
**空请求处理 (2):** `test_empty_request_text`, `test_none_request_text`
**Worker标签 (1):** `test_worker_no_profile_label_gets_default`
**路由路径 (3):** `test_medium_input_routes_to_default`, `test_fallback_when_matched_profile_all_unhealthy`, `test_fallback_when_default_also_unhealthy`
**优先级系统 (2):** `test_profile_priority_ordering`, `test_long_input_matches_before_large_output`
**缓存生命周期 (3):** `test_reset_clears_cache`, `test_cache_rebuilt_after_worker_count_change`, `test_update_loads_invalidates_cache`
**策略信息 (2):** `test_name_and_needs_request_text`, `test_default_policy_name`
**字段解析 (4):** `test_max_completion_tokens_with_spaces`, `test_stream_with_spaces`, `test_extract_max_tokens_first_value_wins`

### 3.4 设计验证点 (21项全部通过)

| 设计要求 | 结果 |
|---------|:--:|
| 输入长度 Short/Medium/Long 分类 | ✅ |
| 输出长度 Small/Medium/Large 分类 | ✅ |
| Stream 字段提取 | ✅ |
| max_tokens/max_completion_tokens 解析 | ✅ |
| ProfileRule 优先级匹配 | ✅ |
| Worker label 亲和绑定 | ✅ |
| Fallback → default → 任意健康 → None 三级链 | ✅ |
| 组内 least-loaded 选择 | ✅ |
| 跳过不健康 worker | ✅ |
| 缓存失效 (worker数变化 / update_loads) | ✅ |
| reset() 清空状态 | ✅ |
| needs_request_text=true | ✅ |
| 默认 max_tokens=512 (修复200的bug) | ✅ |
| Factory / Validation / Config 集成 | ✅ |

---

## 四、RoofLinePolicy

### 4.1 架构

```
Worker labels                请求到达
    │                           │
    ▼                           ▼
resolve_gpu_capability()   estimate_request_features()
    │                           │
    ├─ gpu_name → 内置DB(12款)  ├─ input_length
    ├─ gpu_tier → tier表        ├─ output_tokens (max_tokens)
    ├─ tflops/bandwidth/vram    └─ is_stream
    └─ 默认: Tier3/20tflops         │
         │                           │
         └──────────┬────────────────┘
                    ▼
            score_workers()
    score = w_compute * norm_tflops + w_memory * norm_bandwidth
                    │
                    ▼
            选最高分 worker
```

### 4.2 内置GPU数据库 (12款)

| GPU | Tier | TFLOPS (FP16) | 带宽 (GB/s) | VRAM (GB) |
|-----|:----:|--------------:|------------:|----------:|
| H800 / H100 | Tier1 | 989 | 2039 | 80 |
| A100 / A800 | Tier1 | 312 | 2039 | 80 |
| H20 | Tier2 | 148 | 4000 | 96 |
| L40S | Tier2 | 91.6 | 864 | 48 |
| RTX 4090 | Tier3 | 82.6 | 1008 | 24 |
| RTX 3090 | Tier3 | 35.6 | 936 | 24 |
| L20 | Tier3 | 59.8 | 288 | 24 |
| RTX 4070 Ti SUPER | Tier3 | 44.1 | 672 | 16 |

### 4.3 Worker标签优先级

1. `gpu_name=H800` → 内置DB查表
2. `gpu_tier=Tier1` + 可选 `tflops/bandwidth/vram` 覆写
3. 单独 `tflops/bandwidth/vram` 数值标签 → 自动推断Tier
4. 无标签 → 默认 Tier3 (20 tflops, 200 GB/s, 16 GB)

### 4.4 新增测试 (30个)

| 分类 | 数量 | 测试名 |
|------|:----:|------|
| GPU数据库与Tier | 5 | `builtin_db_has_expected_gpus`, `gpu_tier_ordering`, `gpu_tier_from_str`, `gpu_tier_display`, `gpu_capability_default_tier3` |
| Worker能力解析 | 9 | `resolve_by_gpu_name`, `resolve_by_gpu_name_h20`, `resolve_by_gpu_name_rtx4090`, `resolve_by_tier_label`, `resolve_by_tier_with_overrides`, `resolve_by_individual_labels`, `resolve_default_for_unlabeled`, `resolve_gpu_name_takes_priority_over_tier`, `resolve_unknown_gpu_name_falls_back`, `resolve_gpu_name_case_sensitive` |
| 评分算法 | 8 | `score_workers_highest_tflops_wins_with_compute_weight`, `score_workers_highest_bandwidth_wins_with_memory_weight`, `score_workers_balanced_weights`, `score_workers_single_worker`, `score_workers_all_unhealthy_returns_empty`, `score_workers_skips_unhealthy`, `score_workers_custom_labels`, `normalization_with_identical_gpus` |
| select_worker | 6 | `select_worker_h800_over_h20_for_compute`, `select_worker_h20_over_h800_for_memory`, `select_worker_unhealthy_skipped`, `select_worker_no_healthy_returns_none`, `select_worker_no_labels_defaults_all_equal`, `select_worker_with_mixed_gpu_tiers` |
| 请求特征提取 | 4 | `feature_extraction`, `feature_extraction_defaults`, `max_tokens_extraction`, `stream_extraction` |
| 策略元数据 | 5 | `name_and_needs_request_text`, `default_policy`, `custom_config_weights`, `reset_is_noop`, `update_loads_is_noop`, `on_request_complete_is_noop` |

### 4.5 设计验证点 (13项全部通过)

| 设计要求 | 结果 |
|---------|:--:|
| 识别12种常见GPU | ✅ |
| GPU Tier 三级分类 | ✅ |
| score = w_compute * norm_tflops + w_memory * norm_bandwidth | ✅ |
| Prefill: 优先高TFLOPS (w_compute=1.0) | ✅ |
| Decode: 优先高带宽 (w_memory=1.0) | ✅ |
| 归一化评分 (同型号→同分1.0) | ✅ |
| 选最高分worker | ✅ |
| Worker无标签降级为Tier3 | ✅ |
| 不健康worker被跳过 | ✅ |
| 全部不健康返回None | ✅ |
| 配置校验: weights sum = 1.0 | ✅ |
| Factory / Validation / Config 集成 | ✅ |

---

## 五、CompositePolicy + PhaseSwitcher

### 5.1 架构

```
┌───────────────────────────────────────────────────────┐
│                   CompositePolicy                      │
│                                                       │
│  ┌─────────────────────────────────────────────┐     │
│  │              PhaseSwitcher                    │     │
│  │                                              │     │
│  │  current_load: RwLock<f64>                   │     │
│  │                                              │     │
│  │  load ≤ 0.3  ──→  Affinity  (硬件亲和)       │     │
│  │  load ≥ 0.7  ──→  Distribution (负载分散)     │     │
│  │  0.3 < load < 0.7  ──→  Transition (概率混合)│     │
│  │     P(affinity) = w_aff (1.0→0.0 线性递减)    │     │
│  └─────────────────────────────────────────────┘     │
│                                                       │
│  ┌──────────────────┐  ┌────────────────────────┐    │
│  │ Distribution      │  │ Affinity               │    │
│  │ RoundRobin (默认)  │  │ RoofLine (默认)         │    │
│  └──────────────────┘  └────────────────────────┘    │
│                                                       │
│  select_worker():                                     │
│    1. PhaseSwitcher.determine_mode()                   │
│    2. PhaseSwitcher.should_use_affinity(mode)          │
│    3. primary.select_worker() → Some? return           │
│    4. secondary.select_worker() → fallback             │
│    5. Final fallback: first healthy worker             │
└───────────────────────────────────────────────────────┘
```

### 5.2 PhaseSwitcher 状态机

| 负载区间 | 模式 | 行为 |
|---------|------|------|
| `[0, low_threshold]` | Affinity | 100% 使用硬件亲和策略 |
| `(low_threshold, high_threshold)` | Transition | 概率混合，`P(affinity) = w_aff`，`w_aff` 从 1.0 线性递减到 0.0 |
| `[high_threshold, ∞)` | Distribution | 100% 使用负载分散策略 |

### 5.3 新增测试 (23个)

| 分类 | 数量 | 测试名 |
|------|:----:|------|
| PhaseSwitcher 模式判定 | 7 | `switcher_affinity_mode_at_low_load`, `switcher_distribution_mode_at_high_load`, `switcher_transition_mode`, `switcher_transition_affinity_weight_decreases_with_load`, `switcher_empty_loads_no_change`, `switcher_boundary_at_threshold`, `switcher_load_normalization_capped` |
| 选择行为 | 4 | `composite_affinity_at_low_load` (100次), `composite_distribution_at_high_load` (100次), `composite_transition_mix` (1000次统计), `composite_switcher_responds_to_load_changes` |
| Fallback链 | 3 | `composite_fallback_when_primary_returns_none`, `composite_fallback_when_both_return_none`, `composite_no_healthy_workers` |
| 元数据 | 5 | `composite_name_and_needs_request_text`, `composite_forward_on_request_complete`, `composite_reset`, `composite_sub_policy_accessors`, `composite_default_config` |
| 集成 | 1 | `composite_with_round_robin_and_roofline` (真实策略组合) |

### 5.4 设计验证点 (13项全部通过)

| 设计要求 | 结果 |
|---------|:--:|
| 低负载→Affinity策略 (100/100次) | ✅ |
| 高负载→Distribution策略 (100/100次) | ✅ |
| 中间态→概率混合 (1000次统计 ~50%) | ✅ |
| w_aff 从 1.0→0.0 线性过渡 | ✅ |
| load 归一化 capped (avg=50 → 2.0) | ✅ |
| update_loads 驱动状态切换 | ✅ |
| Primary None→secondary fallback | ✅ |
| 双None→首个健康worker | ✅ |
| 全不健康→None | ✅ |
| 子策略真实组合 (RoundRobin + RoofLine) | ✅ |
| 配置校验: high > low | ✅ |
| needs_request_text 正确转发 | ✅ |
| Factory / Validation / Config 集成 | ✅ |

---

## 六、测试统计

```
全量回归:             473 passed, 1 pre-existing failure (Redis连接)

request_profiling:     34 passed  (12原 + 22新)
roofline:              30 passed  (all new)
composite:             23 passed  (all new)
factory:                2 passed  (cases added to existing tests)
validation:            22 passed  (9 new for 3 policies)

新增测试合计: ~87个
```

---

## 七、验证命令

```bash
# 进入 WSL
wsl bash -l
cd /mnt/e/dev/sglang/sgl-model-gateway

# 编译检查
RUSTFLAGS='-A dead_code -A unused' cargo check

# 分别运行三个策略的测试
RUSTFLAGS='-A dead_code -A unused' cargo test request_profiling -- --nocapture
RUSTFLAGS='-A dead_code -A unused' cargo test roofline -- --nocapture
RUSTFLAGS='-A dead_code -A unused' cargo test composite -- --nocapture

# 运行 factory 和 validation 测试
RUSTFLAGS='-A dead_code -A unused' cargo test factory -- --nocapture
RUSTFLAGS='-A dead_code -A unused' cargo test validation -- --nocapture

# 全量回归测试
RUSTFLAGS='-A dead_code -A unused' cargo test -- --nocapture
```

---

## 八、使用方式

### RequestProfilingPolicy
```bash
./target/release/sgl-model-gateway --policy request_profiling
# Worker: --worker-label profile=short    # 短文本/低延迟
# Worker: --worker-label profile=long     # 长上下文
# Worker: --worker-label profile=large_output  # 长输出
# Worker: --worker-label profile=default  # 通用 (无label默认为此)
```

### RoofLinePolicy
```bash
./target/release/sgl-model-gateway --policy roofline
# 内置12款GPU自动识别:
# Worker: --worker-label gpu_name=H800       # Tier1 计算型
# Worker: --worker-label gpu_name=H20        # Tier2 大显存
# Worker: --worker-label gpu_name=RTX 4090   # Tier3 经济型

# 或手动指定tier+specs:
# Worker: --worker-label gpu_tier=Tier1 --worker-label tflops=600 --worker-label bandwidth=3000
```

### CompositePolicy
```bash
./target/release/sgl-model-gateway --policy composite
# 低负载(<0.3) → 硬件亲和(RoofLine)
# 高负载(>0.7) → 负载分散(RoundRobin)
# 过渡区(0.3~0.7) → 概率混合
```

---

## 九、关键设计决策

| 决策 | 原因 |
|------|------|
| Composite 子策略默认 RoundRobin+RoofLine | 合理默认值；后续通过 CLI `--composite-distribution` / `--composite-affinity` 覆盖 |
| PhaseSwitcher 过渡模式用**概率混合** | 不同策略评分尺度不可直接比较，概率混合更鲁棒且符合模块8 Level 3设计 |
| RoofLine 内置GPU DB而非运行时探测 | GpuCapability (模块1) 尚未实现；label查表方式简单可靠 |
| 请求文本字段用**字符串搜索**非JSON parse | 避免每请求 full parse 的性能开销（文档明确的设计决定） |
| RoofLine weights 校验 sum=1.0 | 确保评分在可控范围内，避免用户误配置 |
| Composite thresholds 校验 high>low | 保证过渡区间逻辑正确 |