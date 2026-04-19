# SGLang Model Gateway 实验文档汇总

## 📋 文档索引

本目录包含SGLang Model Gateway的完整实验文档和演示工具。

---

## 🎯 快速开始

### 对于Presentation准备

**推荐阅读顺序**:
1. 📊 [11-Presentation-基于实验的技术分享.md](11-Presentation-基于实验的技术分享.md) - **主要Presentation文档**
2. 📖 [12-完整实验报告-端到端日志分析.md](12-完整实验报告-端到端日志分析.md) - **详细日志分析**
3. 🖼️ `assets/pd-architecture.png` - PD架构图

### 对于深入学习

**推荐阅读顺序**:
1. [00-文档索引.md](00-文档索引.md) - 完整文档导航
2. [01-部署总结.md](01-部署总结.md) - 环境部署
3. [07-多PD测试报告.md](07-多PD测试报告.md) - 测试报告
4. [08-快速参考指南.md](08-快速参考指南.md) - 常用命令
5. [09-深入学习实验指南.md](09-深入学习实验指南.md) - 实验设计
6. [10-SGlang-Model-Gateway学习报告.md](10-SGlang-Model-Gateway学习报告.md) - 技术分享报告

---

## 📊 核心实验数据

### 实验环境

| 组件 | 配置 |
|------|------|
| 操作系统 | Windows 11 + WSL2 (Ubuntu 24.04) |
| 显卡 | NVIDIA RTX 4070 Ti SUPER (16GB) |
| SGLang版本 | 0.5.8 |
| Gateway | sgl-model-gateway (Rust, debug build) |
| 模型 | Qwen2.5-0.5B-Instruct (~1GB) |

### 架构配置

```
2 Prefill + 2 Decode

Prefill-1: Port 30000, Bootstrap 9000, 可用显存11.69 GB
Prefill-2: Port 30001, Bootstrap 9001, 可用显存11.69 GB
Decode-1:  Port 30010, 可用显存1.28 GB
Decode-2:  Port 30011, 可用显存1.30 GB

Gateway:   Port 3000
```

### 关键实验结果

#### 1. PD分离架构验证

**正确流程** (基于真实日志验证):
```
Client → Gateway → [Prefill-2计算KV] → Bootstrap传输 → [Decode-2生成响应] → Gateway → Client
                                                                    ↓
                                                            直接返回，不经过Prefill
```

**时间线** (真实请求 "Say hello"):
```
T0:   Client发送请求
T2ms: Gateway接收并路由到Prefill-2 + Decode-2
T5ms: Prefill-2开始计算KV cache (31 tokens)
T35ms: Prefill-2完成，通过Bootstrap传输108KB给Decode-2
T50ms: Decode-2接收KV cache，开始自回归生成
T50-400ms: Decode-2生成10个token (~35ms/token)
T460ms: Decode-2返回响应给Gateway
T474ms: Client接收响应 "Hello! How can I assist you today?"

总耗时: 474ms
```

#### 2. 调度策略对比

| 策略 | 首次延迟 | 并发延迟 | 特点 |
|------|---------|---------|------|
| Round Robin | 961ms | ~300ms | 均匀分配，首次慢 |
| Cache Aware | - | 302ms | 缓存感知，性能最好 |
| Random | - | 301ms | 随机分配，性能稳定 |

#### 3. 显存使用分析

**Decode启动显存变化**:

| 阶段 | 可用显存 | 说明 |
|------|---------|------|
| 启动前 | 14.70 GB | 初始状态 |
| 加载权重 | 13.72 GB | 模型0.98 GB |
| KV Cache | 3.10 GB | KV Cache ~10.2 GB |
| **最终** | **1.28 GB** | 显存紧张 |

**关键发现**: Decode显存使用率远高于Prefill，是显存瓶颈

#### 4. 性能分析

**请求各阶段耗时**:

| 阶段 | 耗时 | 占比 |
|------|------|------|
| Prefill (KV计算+传输) | ~45ms | 9.6% |
| **Decode (token生成)** | **~365ms** | **78.0%** |
| Gateway开销 | ~21ms | 4.5% |
| 网络传输 | ~38ms | 8.1% |

**结论**: Decode是主要耗时阶段（自回归生成特性）

---

## 🛠️ 工具脚本

### 启动和管理

| 脚本 | 用途 | 命令 |
|------|------|------|
| `start-multi-pd.sh` | 启动2P+2D环境 | `bash start-multi-pd.sh` |
| `start-gateway-multi.sh` | 启动Gateway | `bash start-gateway-multi.sh round_robin` |
| `cleanup-pd-test.sh` | 清理所有服务 | `bash cleanup-pd-test.sh` |

### 测试和演示

| 脚本 | 用途 | 命令 |
|------|------|------|
| `test-multi-pd.sh` | 自动化测试所有策略 | `bash test-multi-pd.sh` |
| `presentation-demo.sh` | 交互式演示 | `bash presentation-demo.sh` |
| `实验演示脚本.sh` | 基于实验的演示 | `bash 实验演示脚本.sh` |

---

## 📚 日志文件位置

| 日志文件 | 内容 | 大小 |
|---------|------|------|
| `/tmp/sglang-prefill-1.log` | Prefill-1完整日志 | ~15 KB |
| `/tmp/sglang-prefill-2.log` | Prefill-2完整日志 | ~15 KB |
| `/tmp/sglang-decode-1.log` | Decode-1完整日志 | ~14 KB |
| `/tmp/sglang-decode-2.log` | Decode-2完整日志 | ~14 KB |
| `/tmp/sgl-gateway-round_robin.log` | Gateway日志 | ~5 KB |

---

## 🔍 常用命令

### 查看日志

```bash
# Gateway请求日志
cat /tmp/sgl-gateway-round_robin.log | grep -E "(started|finished|latency)"

# Prefill处理日志
cat /tmp/sglang-prefill-2.log | grep -E "(Prefill batch|POST)"

# Decode处理日志
cat /tmp/sglang-decode-2.log | grep -E "(Prefill batch|POST)"

# 显存监控
watch -n 1 nvidia-smi
```

### 测试请求

```bash
# 简单请求
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen2.5-0.5b-instruct", 
         "messages": [{"role": "user", "content": "Hello"}], 
         "max_tokens": 30}'
```

---

## 📖 文档说明

### 主要文档

| 文档 | 页数 | 适合场景 |
|------|------|---------|
| [11-Presentation-基于实验的技术分享.md](11-Presentation-基于实验的技术分享.md) | ~20页 | **团队Presentation** |
| [12-完整实验报告-端到端日志分析.md](12-完整实验报告-端到端日志分析.md) | ~30页 | **深度学习日志分析** |
| [10-SGlang-Model-Gateway学习报告.md](10-SGlang-Model-Gateway学习报告.md) | ~15页 | 技术分享 |
| [09-深入学习实验指南.md](09-深入学习实验指南.md) | ~25页 | 实验设计参考 |

### 快速参考

| 文档 | 内容 |
|------|------|
| [00-文档索引.md](00-文档索引.md) | 所有文档导航 |
| [08-快速参考指南.md](08-快速参考指南.md) | 常用命令速查 |

---

## 🎓 学习路径建议

### 快速了解 (30分钟)
1. 阅读 [11-Presentation-基于实验的技术分享.md](11-Presentation-基于实验的技术分享.md) 前3部分
2. 查看架构图 `assets/pd-architecture.png`
3. 运行 `bash presentation-demo.sh` 选择步骤3和4

### 深入学习 (2小时)
1. 阅读 [12-完整实验报告-端到端日志分析.md](12-完整实验报告-端到端日志分析.md)
2. 分析真实日志文件
3. 运行 [09-深入学习实验指南.md](09-深入学习实验指南.md) 中的实验

### 准备Presentation (1小时)
1. 使用 [11-Presentation-基于实验的技术分享.md](11-Presentation-基于实验的技术分享.md) 作为主线
2. 引用 [12-完整实验报告-端到端日志分析.md](12-完整实验报告-端到端日志分析.md) 中的日志数据
3. 使用 `实验演示脚本.sh` 进行实时演示

---

**最后更新**: 2026-04-14  
**维护者**: AI Assistant  
**基于**: 真实实验数据和日志
