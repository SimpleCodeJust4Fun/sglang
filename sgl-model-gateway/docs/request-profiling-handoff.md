# RequestProfilingPolicy 实现交接文档

> **日期**: 2026-05-16
> **分支**: `feat/pd-enhanced-logs-experiments`
> **状态**: 代码已完成，待编译验证和测试

---

## 一、项目文档索引

### 核心架构文档

| 文档 | 路径 | 说明 |
|------|------|------|
| 异构调度架构总设计 | `docs/heterogeneous-scheduling-architecture.md` | **最重要**，835行，含9个模块设计、策略审计、合并规划、工作分工 |
| 文档索引 | `model_deploy/00-文档索引.md` | 全部文档的导航入口 |

### 环境与部署

| 文档 | 路径 | 说明 |
|------|------|------|
| 部署总结 | `model_deploy/01-部署总结.md` | **环境信息**：Win11+WSL2+RTX4070TiS, CUDA 12.8, Rust 1.94+ |
| 服务启停手册 | `model_deploy/02-服务启停手册.md` | SGLang worker 和 Gateway 的启停命令 |
| 快速参考 | `model_deploy/08-快速参考指南.md` | 日常命令速查 |

### 实验与测试

| 文档 | 路径 | 说明 |
|------|------|------|
| 实验复现指南 | `model_deploy/22-实验复现验证指南.md` | **实测可用命令**：WSL内执行的完整测试流程 |
| PD测试指南 | `model_deploy/05-PD测试完整指南.md` | PD分离测试详细步骤 |
| SLO测试报告 | `model_deploy/40-slo-test-results-report.md` | 4P+2D架构SLO测试结果 |

### 策略研究

| 文档 | 路径 | 说明 |
|------|------|------|
| 调度策略选型 | `model_deploy/24-请求调度策略专题-原理与选型指南.md` | 策略原理与选型分析 |
| 异构混部策略 | `model_deploy/23-异构混部策略选型-H800-H20.md` | H800+H20场景策略 |
| 新策略验证报告 | `model_deploy/16-新增策略代码验证报告.md` | 之前AI生成策略的验证 |

### 关键脚本

| 脚本 | 路径 | 说明 |
|------|------|------|
| PD测试工具 | `model_deploy/pd-test.py` | 请求发送+日志关联分析 |
| 批量测试 | `model_deploy/pd-batch-test.py` | 批量策略组合测试 |
| 多PD启动 | `model_deploy/start-multi-pd.sh` | 启动2P+2D/4P+2D环境 |
| Gateway启动 | `model_deploy/start-gateway.sh` | 启动Gateway（可指定策略） |
| SLO测试 | `model_deploy/run-slo-tests.sh` | SLO测试脚本 |

---

## 二、环境信息

- **操作系统**: Windows 11 + WSL2 Ubuntu 24.04
- **GPU**: NVIDIA RTX 4070 Ti SUPER (16GB)
- **Rust**: 1.94+ (仅在 WSL 中可用，Windows 本机无 cargo)
- **Python**: WSL 中通过 conda 管理
- **模型**: Qwen2.5-0.5B-Instruct（测试用小模型）/ Qwen2.5-7B-Instruct-AWQ（4-bit量化）
- **PD端口**: Prefill(30000/30001), Decode(30010/30011), Gateway(3000)

### 编译命令

```bash
# 必须在 WSL 内执行
cd /mnt/e/dev/sglang/sgl-model-gateway
RUSTFLAGS='-A dead_code -A unused' cargo build
RUSTFLAGS='-A dead_code -A unused' cargo test
```

> **注意**: `RUSTFLAGS='-A dead_code -A unused'` 是必须的，规避 Rust 1.94.1 在 `policies::request_classification` 模块的 ICE 问题。

---

## 三、本次实现内容

### 3.1 新增文件

**`src/policies/request_profiling.rs`** (~430行)

RequestProfilingPolicy：基于请求特征分类 + Worker 亲和绑定的调度策略。

核心设计：

```
请求到达
  │
  ├─ 1. classify_request(): 分类请求
  │     ├─ 输入长度: Short(<500字符) / Medium / Long(>=4000字符)
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
  │     ├─ Worker 通过 label "profile=xxx" 声明所属分桶
  │     ├─ 组内 least-loaded 选择
  │     ├─ Fallback 1: "default" profile 组
  │     └─ Fallback 2: 任意健康 worker
  │
  └─ 返回 worker index
```

关键类型：

- `RequestProfilingConfig` — 可配置的分类阈值
- `ProfileRule` — 路由规则（name + match条件 + priority）
- `InputCategory` / `OutputCategory` — 请求分类枚举
- `ProfileWorkerCache` — profile→worker映射缓存（`parking_lot::RwLock`）

### 3.2 修改文件

| 文件 | 改动 |
|------|------|
| `src/policies/mod.rs` | +2行：`mod request_profiling` + `pub use` 导出 |
| `src/policies/factory.rs` | +15行：import、`create_from_config` match arm、`create_by_name` match arm |
| `src/config/types.rs` | +25行：`PolicyConfig::RequestProfiling` variant + 3个默认值函数 + `name()` match |

### 3.3 单元测试 (10个)

| 测试 | 覆盖点 |
|------|--------|
| `test_input_classification` | Short/Medium/Long 输入分类 |
| `test_max_tokens_extraction` | max_tokens / max_completion_tokens 提取 |
| `test_stream_extraction` | stream 字段提取 |
| `test_profile_matching` | ProfileRule 优先级匹配 |
| `test_worker_profile_binding` | Worker label 亲和绑定 |
| `test_fallback_to_default` | 无匹配 profile 时 fallback 到 default |
| `test_fallback_to_any_healthy` | 无任何 profile 时 fallback 到任意健康 worker |
| `test_least_loaded_within_profile` | 组内 least-loaded 选择 |
| `test_unhealthy_worker_skipped` | 跳过不健康 worker |
| `test_no_healthy_workers` | 全部不健康返回 None |
| `test_output_based_routing` | 大输出路由到 large_output profile |
| `test_custom_config` | 自定义配置 + stream 匹配 |

---

## 四、待完成事项

### 必须完成（编译+测试）

```bash
# 1. 编译
cd /mnt/e/dev/sglang/sgl-model-gateway
RUSTFLAGS='-A dead_code -A unused' cargo check

# 2. 运行新策略单元测试
RUSTFLAGS='-A dead_code -A unused' cargo test request_profiling -- --nocapture

# 3. 全量测试确保无回归
RUSTFLAGS='-A dead_code -A unused' cargo test

# 4. 修复编译或测试中发现的问题
```

### 可选增强

1. **factory.rs 测试补充**：在 `test_create_from_config` 和 `test_create_by_name` 中添加 `request_profiling` case
2. **config 校验**：在 `src/config/validation.rs` 中对 `RequestProfiling` 增加校验（`short_input_threshold < long_input_threshold`）
3. **Commit & Push**：验证通过后提交到 `feat/pd-enhanced-logs-experiments` 分支

---

## 五、使用方式

```bash
# 启动 Gateway 时指定策略
./target/release/sgl-model-gateway --policy request_profiling

# Worker 注册时通过 label 声明 profile
# Worker 1: 处理短文本
--worker-url http://w1:30000 --worker-label profile=short

# Worker 2: 处理长上下文
--worker-url http://w2:30000 --worker-label profile=long

# Worker 3: 通用
--worker-url http://w3:30000 --worker-label profile=default

# 无 label 的 worker 自动归入 "default" profile
```

---

## 六、设计决策说明

| 决策 | 原因 |
|------|------|
| 用 `parking_lot::RwLock` | 与 `tree.rs` 一致，无 poison 问题 |
| `extract_max_tokens` 用字符串搜索非 JSON parse | 避免每请求 full parse 的性能开销 |
| 默认 `max_tokens=512`（非200） | 修复了 RequestClassificationPolicy 的 bug |
| Profile 缓存基于 worker 数量失效 | 简化实现，与 RequestSizeBucketPolicy 模式一致 |
| `update_loads` 触发缓存失效 | LoadMonitor 推送负载时强制刷新 worker 健康状态 |
| ProfileRule 按 priority 排序 | 允许精确规则（如 stream+short）优先于通用规则 |

---

## 七、与架构文档的关系

本实现对应 `docs/heterogeneous-scheduling-architecture.md` 中的：

- **Section 3, 模块 0.2**：RequestClassification → RequestProfiling 合并（已完成分类框架保留 + GpuCapability 预留接口）
- **Section 3, 模块 4**：RequestProfilingPolicy 详细设计
- **Section 4**：工作分工中"同学B"的任务
- **Section 5, M0 + M2**：里程碑中的前置修复 + 静态策略实现

后续与 `GpuCapability`（模块1）集成后，可将 worker 分类从 label 手动声明升级为自动 GPU tier 匹配。
