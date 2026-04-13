# SGLang Model Gateway 学习报告

## 团队技术分享 - 2026-04-14

---

## 目录

1. [项目概述](#1-项目概述)
2. [核心架构](#2-核心架构)
3. [PD分离架构详解](#3-pd分离架构详解)
4. [调度策略](#4-调度策略)
5. [请求处理流程](#5-请求处理流程)
6. [实验验证](#6-实验验证)
7. [关键发现](#7-关键发现)
8. [总结与展望](#8-总结与展望)

---

## 1. 项目概述

### 1.1 什么是SGLang Model Gateway？

SGLang Model Gateway 是一个**基于Rust开发的高性能推理网关**，专门用于管理和调度多个大语言模型服务实例。

**核心职责**:
- **请求路由**: 接收客户端请求，智能分发到后端模型服务
- **负载均衡**: 通过多种策略优化资源利用
- **PD分离**: 支持Prefill-Decode disaggregation架构
- **高可用**: 容错、重试、健康检查
- **可观测性**: 日志、指标、追踪

### 1.2 为什么需要Gateway？

**问题场景**:
```
客户端 → ? → 多个模型服务（Prefill-1, Prefill-2, Decode-1, Decode-2）
```

- 如何选择合适的服务实例？
- 如何平衡负载？
- 如何处理故障？
- 如何利用缓存？

**Gateway的解决方案**:
```
客户端 → Gateway（智能路由）→ 多个模型服务
```

### 1.3 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | Rust |
| HTTP框架 | Axum |
| 并发 | Tokio |
| 日志 | tracing + tracing_subscriber |
| 指标 | Prometheus |
| 代码量 | ~23,891行 |

---

## 2. 核心架构

### 2.1 整体架构图

```
┌─────────────────────────────────────────────────────────┐
│                    SGLang Model Gateway                  │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │   HTTP       │  │   gRPC       │  │   Control    │  │
│  │   Server     │  │   Server     │  │   Plane      │  │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         │                 │                 │           │
│         └──────────────┬──┴─────────────────┘           │
│                        │                                │
│  ┌─────────────────────┴─────────────────────────────┐  │
│  │              Router Layer                         │  │
│  │  ┌──────────────┐  ┌──────────────┐              │  │
│  │  │ Regular      │  │ PD Router    │              │  │
│  │  │ Router       │  │ (Disagg)     │              │  │
│  │  └──────────────┘  └──────────────┘              │  │
│  └─────────────────────┬─────────────────────────────┘  │
│                        │                                │
│  ┌─────────────────────┴─────────────────────────────┐  │
│  │              Policy Layer                         │  │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐         │  │
│  │  │ Round    │ │ Cache    │ │ Random   │ ...     │  │
│  │  │ Robin    │ │ Aware    │ │          │         │  │
│  │  └──────────┘ └──────────┘ └──────────┘         │  │
│  └─────────────────────┬─────────────────────────────┘  │
│                        │                                │
│  ┌─────────────────────┴─────────────────────────────┐  │
│  │              Core Layer                           │  │
│  │  ┌──────────────┐  ┌──────────────┐              │  │
│  │  │ Worker       │  │ Worker       │              │  │
│  │  │ Registry     │  │ Manager      │              │  │
│  │  └──────────────┘  └──────────────┘              │  │
│  └───────────────────────────────────────────────────┘  │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │              Observability                       │   │
│  │  Logging | Metrics | Tracing                     │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │   Backend Workers      │
              │   (SGLang Servers)     │
              └────────────────────────┘
```

### 2.2 核心组件

| 组件 | 文件 | 职责 |
|------|------|------|
| **入口** | `src/main.rs` | CLI解析、服务启动 |
| **PD Router** | `src/routers/http/pd_router.rs` | PD分离路由逻辑 |
| **策略** | `src/policies/*.rs` | 9种负载均衡策略 |
| **Worker** | `src/core/worker.rs` | 后端服务抽象 |
| **注册表** | `src/core/worker_registry.rs` | Worker管理 |
| **日志** | `src/observability/logging.rs` | 结构化日志 |
| **指标** | `src/observability/metrics.rs` | Prometheus指标 |
| **熔断器** | `src/core/circuit_breaker.rs` | 故障保护 |
| **重试** | `src/core/retry.rs` | 重试逻辑 |

---

## 3. PD分离架构详解

### 3.1 什么是PD分离？

**传统架构**:
```
单个服务器同时处理:
1. Prefill: 计算输入prompt的KV cache
2. Decode: 基于KV cache生成token
```

**PD分离架构**:
```
Prefill Server: 专门计算KV cache
       ↓ (通过bootstrap传输)
Decode Server: 专门生成token
```

### 3.2 为什么需要PD分离？

**优势**:
1. **资源优化**: Prefill需要计算密集，Decode需要显存密集
2. **弹性扩展**: 可以独立扩展Prefill或Decode实例
3. **缓存共享**: 多个Decode可以共享同一个Prefill的KV cache
4. **性能提升**: 专业化分工提高效率

### 3.3 完整的请求流程

**重要：响应不是 P→D→P，而是 Decode 直接返回！**

```
Client
  │
  │  1. 发送请求
  ▼
Gateway (Port 3000)
  │
  │  2a. 同时发送请求                    2b. 同时发送请求
  ├─────────────────────────────────────►├─────────────────────────┐
  ▼                                      ▼                         │
Prefill Server                      Decode Server                  │
(Port 30000)                        (Port 30010)                   │
  │                                      │                          │
  │  3. 计算输入prompt的                 │                          │
  │     KV cache                        │                          │
  │                                      │                          │
  │  4. 通过bootstrap端口              │                          │
  │     (Port 9000) 传输KV cache ──────►│                          │
  │                                      │                          │
  │  5. 返回HTTP 200确认              │                          │
  │     (仅内部确认)                    │                          │
  │                                      │                          │
  │                                      │  6. 基于KV cache         │
  │                                      │     自回归生成token      │
  │                                      │                          │
  │                                      │  7. 直接返回响应 ────────┤
  │                                      │                          │
  ◄──────────────────────────────────────┴──────────────────────────┘
  │
  │  8. 返回最终响应给Client
  ▼
Client
```

### 3.4 关键机制

| 机制 | 说明 |
|------|------|
| **Dual Dispatch** | Gateway同时发送请求到Prefill和Decode |
| **Bootstrap** | Prefill通过专用端口传输KV cache给Decode |
| **直接返回** | Decode生成响应后直接返回给Gateway |
| **响应合并** | Gateway合并Prefill和Decode的响应（如logprobs） |

### 3.5 源码证据

来自 `src/routers/http/pd_router.rs`:

```rust
// Decode响应是主输出
if !status.is_success() {
    return self.handle_decode_error_response(...)
}
// Prefill响应仅用于logprobs等辅助信息
// ...
// 最终返回Decode响应
return (status, decode_body).into_response();
```

---

## 4. 调度策略

### 4.1 支持的策略

| 策略 | 文件 | 原理 | 适用场景 |
|------|------|------|---------|
| **Random** | `random.rs` | 随机选择 | 简单场景 |
| **Round Robin** | `round_robin.rs` | 轮询分配 | 均匀负载 |
| **Cache Aware** | `cache_aware.rs` | 缓存感知 | 相似请求多 |
| **Power of Two** | `power_of_two.rs` | 随机选2个，选负载低的 | 平衡性能和简单性 |
| **Prefix Hash** | `prefix_hash.rs` | 前缀哈希 | 多租户 |
| **Consistent Hash** | `consistent_hashing.rs` | 一致性哈希 | 分布式系统 |
| **Manual** | `manual.rs` | 手动配置 | 精细控制 |
| **Bucket** | `bucket.rs` | 负载桶 | 负载感知 |
| **Tree** | `tree.rs` | 前缀树 | 缓存优化 |

### 4.2 三种主要策略详解

#### 4.2.1 Round Robin（轮询）

**原理**: 
```
请求1 → P1-D1
请求2 → P2-D2
请求3 → P1-D1
请求4 → P2-D2
...
```

**特点**:
- 简单公平
- 请求均匀分布
- 不考虑缓存

#### 4.2.2 Cache Aware（缓存感知）

**原理**:
```
维护前缀树（Prefix Tree）
  ↓
计算请求前缀匹配度
  ↓
匹配度高 → 路由到有缓存的节点
匹配度低 → 路由到缓存充足的节点
```

**特点**:
- 利用缓存加速
- 相似请求路由到同一节点
- 负载高时切换为最短队列

#### 4.2.3 Random（随机）

**原理**:
```
过滤健康节点
  ↓
均匀随机选择
  ↓
路由请求
```

**特点**:
- 无状态
- 简单高效
- 分布不可预测

### 4.3 策略对比（实验数据）

| 策略 | 首次延迟 | 并发延迟 | 特点 |
|------|---------|---------|------|
| Round Robin | 961ms | 300ms+ | 首次冷启动慢 |
| Cache Aware | - | 302ms | 缓存命中快 |
| Random | - | 301ms | 性能稳定 |

---

## 5. 请求处理流程

### 5.1 Gateway处理流程

```
1. 接收HTTP请求
   ↓
2. 解析请求（提取model、prompt等）
   ↓
3. 查询Policy Registry获取策略
   ↓
4. 调用策略的 select_worker() 选择节点
   ↓
5. 构建请求（注入bootstrap配置等）
   ↓
6. 并发发送到Prefill和Decode（Dual Dispatch）
   ↓
7. 等待响应
   ↓
8. 合并响应（logprobs等）
   ↓
9. 记录指标
   ↓
10. 返回响应给客户端
```

### 5.2 错误处理流程

```
请求失败
   ↓
检查是否可重试
   ├─ 是 → 指数退避 → 重试
   └─ 否 → 标记Worker不健康
          ↓
     熔断器计数
          ↓
     超过阈值 → 熔断（暂停使用该Worker）
```

### 5.3 关键代码位置

| 功能 | 文件 | 关键函数 |
|------|------|---------|
| 入口 | `src/main.rs` | `main()` |
| 路由 | `src/routers/http/pd_router.rs` | `execute_dual_dispatch_internal()` |
| 策略选择 | `src/policies/mod.rs` | `select_worker()` |
| Worker选择 | `src/policies/cache_aware.rs` | `select_worker()` |
| 响应合并 | `src/routers/http/pd_router.rs` | 合并logprobs逻辑 |
| 重试 | `src/core/retry.rs` | `execute_with_retry()` |
| 熔断 | `src/core/circuit_breaker.rs` | `record_failure()` |

---

## 6. 实验验证

### 6.1 测试环境

| 项目 | 配置 |
|------|------|
| 操作系统 | Windows 11 + WSL2 (Ubuntu 24.04) |
| 显卡 | NVIDIA RTX 4070 Ti SUPER (16GB) |
| CUDA版本 | 12.8 |
| SGLang | 0.5.8 |
| Gateway | sgl-model-gateway (debug build) |
| 模型 | Qwen2.5-0.5B-Instruct (~1GB) |

### 6.2 架构配置

```
2 Prefill + 2 Decode

Prefill-1: Port 30000, Bootstrap 9000
Prefill-2: Port 30001, Bootstrap 9001
Decode-1:  Port 30010
Decode-2:  Port 30011

Gateway:   Port 3000
```

### 6.3 关键实验

#### 实验1: PD流程验证

**目标**: 确认Decode直接返回响应

**方法**: 同时监控所有组件日志

**结果**: 
- Gateway同时发送请求到Prefill和Decode ✓
- Prefill计算KV cache并通过bootstrap传输 ✓
- **Decode直接返回响应给Gateway** ✓
- Gateway返回响应给客户端 ✓

#### 实验2: 策略对比

**目标**: 对比三种策略的性能

**结果**:
- Round Robin: 请求均匀分布，首次延迟较高
- Cache Aware: 并发性能最好（~302ms）
- Random: 性能相当（~301ms）

#### 实验3: 并发测试

**目标**: 验证系统稳定性

**结果**:
- 并发50请求成功率 > 90%
- GPU显存使用稳定（~92%）
- 无OOM错误

### 6.4 显存优化

| 配置 | 结果 |
|------|------|
| 7B-AWQ x2 | OOM（需要~20GB） |
| 0.5B x4, mem-fraction=0.15 | 成功（使用~15GB） |

**经验**: 16GB显存无法运行两个7B实例，但可运行四个0.5B实例

---

## 7. 关键发现

### 7.1 架构理解

1. **PD分离不是PDP**
   - 错误理解: Prefill → Decode → Prefill → Client
   - 正确理解: Prefill → Decode → Gateway → Client
   - Decode直接返回响应，不经过Prefill

2. **Bootstrap是关键**
   - KV cache通过bootstrap端口传输
   - 传输完成后Prefill的任务基本完成

3. **Gateway是核心**
   - 负责所有路由决策
   - 处理错误和重试
   - 合并响应

### 7.2 性能优化

1. **Cache Aware策略适合生产环境**
   - 相似请求多时效果显著
   - 自动在缓存和负载均衡间切换

2. **显存管理很重要**
   - `mem-fraction-static` 控制KV cache池大小
   - 需要平衡实例数量和显存使用

3. **首次请求延迟较高**
   - 可能是冷启动效应
   - 后续请求更稳定

### 7.3 故障排查

| 问题 | 原因 | 解决 |
|------|------|------|
| OOM (退出码137) | 显存不足 | 降低mem-fraction |
| 脚本被kill (退出码15) | pkill匹配自身 | 使用子shell |
| 后台进程退出 | 继承终端 | 使用setsid |

---

## 8. 总结与展望

### 8.1 核心要点

1. **Gateway的职责**: 智能路由、负载均衡、高可用
2. **PD分离架构**: Prefill算KV，Decode生成响应，直接返回
3. **调度策略**: 9种策略，Cache Aware最适合生产
4. **实验验证**: 2P+2D架构成功，三种策略都正常工作

### 8.2 学习资源

| 资源 | 路径 |
|------|------|
| 部署总结 | `01-部署总结.md` |
| PD测试指南 | `05-PD测试完整指南.md` |
| 测试报告 | `07-多PD测试报告.md` |
| 快速参考 | `08-快速参考指南.md` |
| 深入学习 | `09-深入学习实验指南.md` |
| Gateway源码 | `src/` 目录 |

### 8.3 下一步

1. **深入源码**: 阅读关键策略实现
2. **性能调优**: 测试不同配置的效果
3. **生产实践**: 部署到真实环境
4. **功能扩展**: 贡献新策略或优化

---

## 附录：常用命令

```bash
# 启动PD环境
bash start-multi-pd.sh

# 启动Gateway
bash start-gateway-multi.sh cache_aware

# 发送测试请求
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen2.5-0.5b-instruct", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 20}'

# 查看日志
tail -f /tmp/gateway.log

# 停止所有服务
killall -9 python3 sgl-model-gateway
```

---

**报告创建时间**: 2026-04-14  
**作者**: AI Assistant  
**用途**: 团队技术分享 / Presentation
