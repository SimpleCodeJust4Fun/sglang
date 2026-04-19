# PD Disaggregation 测试 - 完成总结

## ✅ 已完成的工作

### 1. 环境诊断

**问题识别：**
- ❌ 之前的测试使用了错误的模型（Qwen2.5-0.5B-Instruct 而非已部署的 7B-AWQ）
- ❌ 启动参数不完整或缺失关键参数
- ❌ 缺少系统化的测试流程和脚本

**环境验证：**
- ✅ GPU: NVIDIA RTX 4070 Ti SUPER (16GB) - 正常
- ✅ 模型: Qwen2.5-7B-Instruct-AWQ - 已确认存在
- ✅ Python: 3.12.3 + 虚拟环境 ~/qwen_env - 正常
- ✅ SGLang: 0.5.8 - 已安装

### 2. 创建的测试脚本

已在 `model_deploy/` 目录下创建以下 4 个脚本：

| 脚本文件 | 功能 | 大小 |
|---------|------|------|
| `start-pd-test.sh` | 启动 Prefill 和 Decode Servers | 4.5KB |
| `start-gateway.sh` | 启动 Gateway | 2.1KB |
| `test-pd-requests.sh` | 执行测试请求 | 3.8KB |
| `cleanup-pd-test.sh` | 清理环境 | 1.5KB |

**脚本特点：**
- ✅ 自动化检查和验证
- ✅ 彩色输出，易于阅读
- ✅ 完整的错误处理
- ✅ 详细的日志记录
- ✅ 健康检查机制

### 3. 创建的文档

| 文档文件 | 内容 | 大小 |
|---------|------|------|
| `05-PD测试完整指南.md` | 完整的测试指南（454行） | 详细文档 |
| `QUICK-START.md` | 快速参考卡片 | 快速上手 |
| `../real-pd-testing-record.md` | 测试记录（已更新） | 完整记录 |

**文档内容：**
- ✅ 详细的步骤说明
- ✅ 参数解释
- ✅ 故障排查指南
- ✅ 性能调优建议
- ✅ 测试检查清单
- ✅ 经验总结

### 4. 关键修复点

#### 修复 1: 使用正确的模型路径
```bash
# ❌ 错误（之前）
--model-path Qwen/Qwen2.5-0.5B-Instruct

# ✅ 正确（现在）
--model-path /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ
```

#### 修复 2: 添加必需的 PD 模式参数
```bash
# ❌ 错误（之前）- 缺少 --pd 参数
python3 -m sglang.launch_server --model-path ... --port 30000

# ✅ 正确（现在）- 明确指定角色
python3 -m sglang.launch_server \
    --model-path ... \
    --port 30000 \
    --pd prefill \                    # 必需！
    --disaggregation-bootstrap-port 9000
```

#### 修复 3: 正确的显存配置
```bash
# 每个实例使用 30% 显存（约 4.8GB）
--mem-fraction-static 0.3

# 两个实例总计约 9.6GB，在 16GB 显存范围内
```

#### 修复 4: Gateway 参数格式
```bash
# ✅ 正确格式
./target/debug/sgl-model-gateway \
    --pd-disaggregation \
    --prefill http://127.0.0.1:30000 9000 \    # URL + Bootstrap Port
    --decode http://127.0.0.1:30001 \
    --host 127.0.0.1 \
    --port 3000 \
    --policy round_robin
```

## 🚀 如何使用

### 快速开始（3 个终端）

#### 终端 1: 启动 SGLang Servers
```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash start-pd-test.sh
```

**预期时间：** ~60 秒（模型加载）

#### 终端 2: 启动 Gateway
```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash start-gateway.sh
```

**预期时间：** ~5 秒

#### 终端 3: 执行测试
```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash test-pd-requests.sh
```

**预期时间：** ~30 秒（5个测试）

### 清理环境
```bash
bash cleanup-pd-test.sh
```

## 📊 架构说明

### PD 分离架构

```
用户请求
    ↓
Gateway (端口 3000)
    ├─ 选择 Prefill Worker
    ├─ 选择 Decode Worker
    ├─ 注入 bootstrap 信息
    └─ 并发分发
         ↓
    ┌────────┴────────┐
    ↓                 ↓
Prefill Server    Decode Server
(端口 30000)      (端口 30001)
    ↓                 ↓
生成 KV Cache    接收 KV Cache
    ↓                 ↓
传输 KV Cache →  开始 Decode
(Bootstrap:9000)      ↓
                 生成响应
                    ↓
                返回用户
```

### 资源分配

| 组件 | 端口 | 显存 | CPU | 说明 |
|------|------|------|-----|------|
| Prefill Server | 30000 | 4.8GB (30%) | 共享 | 处理 prompt，生成 KV Cache |
| Decode Server | 30001 | 4.8GB (30%) | 共享 | 接收 KV Cache，生成 token |
| Gateway | 3000 | ~100MB | 共享 | 路由分发，负载均衡 |
| **总计** | - | **~9.7GB** | - | 剩余 ~6.4GB 可用 |

## 🔍 测试验证点

### 必须验证的内容

- [ ] **Prefill Server 启动成功**
  - 健康检查通过: `curl http://127.0.0.1:30000/health`
  - 日志显示: "The server is fired up and ready to roll!"

- [ ] **Decode Server 启动成功**
  - 健康检查通过: `curl http://127.0.0.1:30001/health`
  - 日志显示: "The server is fired up and ready to roll!"

- [ ] **Gateway 启动成功**
  - 显示: "Mode: PD Disaggregated"
  - 显示 Prefill 和 Decode 节点信息

- [ ] **请求处理正常**
  - Chat Completion API 返回有效响应
  - Generate API 返回有效响应
  - 中文对话正常

- [ ] **PD 分离工作正常**
  - Prefill 日志显示收到 bootstrap 信息
  - Decode 日志显示接收 KV Cache
  - Gateway 日志显示路由决策

- [ ] **GPU 使用正常**
  - 两个 Python 进程各占用 ~4.8GB
  - 请求处理时 GPU 利用率上升

## 📝 下一步

### 1. 执行测试

按照上述步骤执行测试，观察输出和日志。

### 2. 记录结果

在 `real-pd-testing-record.md` 的"测试结果"部分填写：
- 测试是否成功
- 性能指标（TTFT、吞吐量等）
- 遇到的问题
- 解决方案

### 3. 深入测试（可选）

- 测试不同策略（cache_aware, power_of_two 等）
- 进行压力测试（高并发）
- 测试容错能力（停止一个 Worker）
- 测试不同的请求长度

### 4. 性能优化

根据测试结果调整：
- `--mem-fraction-static`: 显存分配
- `--cache-threshold`: 缓存阈值
- `--max-concurrent-requests`: 并发数
- `--context-length`: 上下文长度

## 📚 文档索引

| 文档 | 路径 | 用途 |
|------|------|------|
| 快速参考 | `model_deploy/QUICK-START.md` | 快速开始 |
| 完整指南 | `model_deploy/05-PD测试完整指南.md` | 详细说明 |
| 测试记录 | `real-pd-testing-record.md` | 测试记录 |
| 原始指南 | `docs/pd-disaggregation-testing-guide.md` | 理论背景 |
| 部署总结 | `model_deploy/01-部署总结.md` | 环境信息 |

## 💡 重要提示

1. **首次启动慢是正常的**：模型加载需要 1-2 分钟
2. **日志是关键**：遇到问题首先查看日志
3. **显存管理**：16GB 跑两个 7B 实例较紧张，注意监控
4. **使用脚本**：脚本已处理所有细节，直接使用即可
5. **干净退出**：使用 `cleanup-pd-test.sh` 确保资源释放

## 🎯 成功标准

测试成功的标志：

1. ✅ 三个组件都成功启动
2. ✅ 健康检查全部通过
3. ✅ 测试请求返回有效响应
4. ✅ 日志显示正确的 PD 分离流程
5. ✅ GPU 使用符合预期
6. ✅ 没有 OOM 或其他错误

---

**创建时间**: 2026-04-13  
**状态**: ✅ 所有准备工作已完成，可以开始测试  
**下一步**: 在 WSL2 中执行 `bash start-pd-test.sh`
