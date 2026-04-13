# PD Disaggregation 测试记录 - 完整修复版

## 📅 测试信息

- **测试日期**: 2026-04-13
- **测试环境**: WSL2 + RTX 4070 Ti SUPER (16GB)
- **模型**: Qwen2.5-7B-Instruct-AWQ
- **模型路径**: `/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ`
- **SGLang 版本**: 0.5.8
- **Python 版本**: 3.12.3

## 📋 问题诊断

### 之前测试失败的原因

从之前的日志 (`sglang-prefill.log`) 分析，测试失败的主要原因：

1. **模型路径问题**: 使用了错误的模型路径或模型文件不完整
2. **启动参数错误**: 使用了 `--disaggregation-bootstrap-port` 而不是正确的参数
3. **显存配置**: 可能没有正确配置 `--mem-fraction-static` 导致显存不足
4. **PD 模式参数**: 缺少 `--pd prefill` 和 `--pd decode` 参数

### 环境验证结果

```bash
# GPU 状态 - 正常
NVIDIA GeForce RTX 4070 Ti SUPER
总显存: 16376 MiB
可用显存: ~14430 MiB (测试前)

# 模型文件 - 已确认存在
/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ

# Python 虚拟环境 - 正常
~/qwen_env (Python 3.12.3)
```

## ✅ 修复方案

### 创建的测试脚本

已在 `model_deploy/` 目录下创建以下脚本：

1. **start-pd-test.sh** - 一键启动 Prefill 和 Decode Servers
   - 自动检查 GPU 环境
   - 自动验证模型文件
   - 正确配置 PD 模式参数
   - 自动健康检查

2. **start-gateway.sh** - 启动 Gateway
   - 自动检查 Servers 状态
   - 自动编译 Gateway（如需要）
   - 配置 PD 路由

3. **test-pd-requests.sh** - 执行测试请求
   - 5 种不同类型的测试
   - 包含并发测试
   - 自动验证响应

4. **cleanup-pd-test.sh** - 清理环境
   - 停止所有相关进程
   - 清理临时文件
   - 验证显存释放

5. **05-PD测试完整指南.md** - 完整文档
   - 详细步骤说明
   - 故障排查指南
   - 性能调优建议

### 关键修复点

#### 1. Prefill Server 启动参数（正确版本）

```bash
python3 -m sglang.launch_server \
    --model-path /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ \
    --port 30000 \
    --mem-fraction-static 0.3 \
    --tp 1 \
    --pd prefill \
    --disaggregation-bootstrap-port 9000 \
    --host 127.0.0.1
```

**关键参数说明：**
- `--pd prefill`: 指定为 Prefill 角色（必需）
- `--disaggregation-bootstrap-port 9000`: KV Cache 传输端口
- `--mem-fraction-static 0.3`: 使用 30% 显存（约 4.8GB）

#### 2. Decode Server 启动参数（正确版本）

```bash
python3 -m sglang.launch_server \
    --model-path /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ \
    --port 30001 \
    --mem-fraction-static 0.3 \
    --tp 1 \
    --pd decode \
    --host 127.0.0.1
```

**关键参数说明：**
- `--pd decode`: 指定为 Decode 角色（必需）
- 使用相同的 `--mem-fraction-static 0.3`

#### 3. Gateway 启动参数（正确版本）

```bash
./target/debug/sgl-model-gateway \
    --pd-disaggregation \
    --prefill http://127.0.0.1:30000 9000 \
    --decode http://127.0.0.1:30001 \
    --host 127.0.0.1 \
    --port 3000 \
    --policy round_robin \
    --log-level debug
```

**关键参数说明：**
- `--prefill http://127.0.0.1:30000 9000`: URL + Bootstrap Port
- `--decode http://127.0.0.1:30001`: Decode Server URL

## 🚀 执行步骤

### 快速开始（推荐）

在 WSL2 中打开 3 个终端：

#### 终端 1: 启动 SGLang Servers

```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash start-pd-test.sh
```

**预期输出：**
```
========================================
PD Disaggregation 测试 - 7B-AWQ 模型
========================================

[1/7] 激活 Python 虚拟环境...
✓ Python 虚拟环境已激活

[2/7] 检查 GPU 环境...
✓ GPU 环境正常

[3/7] 检查模型文件...
✓ 模型路径存在: /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ

[4/7] 清理旧进程...
✓ 旧进程已清理

[5/7] 启动 Prefill Server (端口: 30000)...
Prefill Server PID: 12345
等待 Prefill Server 启动 (30秒)...
✓ Prefill Server 启动成功

[6/7] 启动 Decode Server (端口: 30001)...
Decode Server PID: 12346
等待 Decode Server 启动 (30秒)...
✓ Decode Server 启动成功

当前显存使用情况:
  12345  python  4800 MiB
  12346  python  4800 MiB

========================================
Prefill 和 Decode Servers 已就绪!
========================================
```

#### 终端 2: 启动 Gateway

```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash start-gateway.sh
```

**预期输出：**
```
========================================
启动 Gateway - PD 模式
========================================

检查 Prefill Server...
✓ Prefill Server 可访问

检查 Decode Server...
✓ Decode Server 可访问

启动 Gateway...
配置:
  Prefill: http://127.0.0.1:30000 (bootstrap: 9000)
  Decode:  http://127.0.0.1:30001
  Gateway: http://127.0.0.1:3000
  Policy:  round_robin

SGLang Router starting...
Host: 127.0.0.1:3000
Mode: PD Disaggregated
Prefill nodes: [("http://127.0.0.1:30000", Some(9000))]
Decode nodes: ["http://127.0.0.1:30001"]
```

#### 终端 3: 执行测试

```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash test-pd-requests.sh
```

**预期输出：**
```
========================================
PD Disaggregation 测试请求
========================================

检查 Gateway 状态...
✓ Gateway 运行中

[测试 1] 简单 Chat Completion
请求: Hello, world!
{
    "id": "chatcmpl-xxx",
    "object": "chat.completion",
    "choices": [
        {
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "Hello! How can I assist you today?"
            },
            "finish_reason": "stop"
        }
    ],
    "usage": {
        "prompt_tokens": 10,
        "completion_tokens": 9,
        "total_tokens": 19
    }
}

[测试 2] 中文对话测试
请求: 用一句话解释什么是 PD 分离架构
{
    "choices": [
        {
            "message": {
                "content": "PD分离架构是将大语言模型的推理过程分为Prefill（预填充）和Decode（解码）两个阶段，分别由不同的GPU处理，以提高推理效率和吞吐量。"
            }
        }
    ]
}

...

========================================
所有测试完成!
========================================
```

## 🔍 验证要点

### 1. 检查 Prefill Server 日志

```bash
tail -f /tmp/sglang-prefill.log
```

**应该看到：**
- 收到包含 `bootstrap_host`, `bootstrap_port`, `bootstrap_room` 的请求
- Prefill 计算完成
- KV Cache 传输开始

### 2. 检查 Decode Server 日志

```bash
tail -f /tmp/sglang-decode.log
```

**应该看到：**
- 收到请求
- 等待 KV Cache
- KV Cache 接收完成
- Decode 计算开始
- Token 生成

### 3. 检查 Gateway 日志

在 Gateway 终端观察：

**应该看到：**
- Worker 注册成功
- Health check 通过
- 请求路由决策
- Bootstrap 信息注入

### 4. 监控 GPU 使用

```bash
watch -n 1 nvidia-smi
```

**预期行为：**
- 两个 Python 进程各占用 ~4.8GB 显存
- 请求处理时 GPU 利用率上升
- Prefill 和 Decode 阶段 GPU 利用模式不同

## ❌ 故障排查

### 问题 1: Prefill Server 启动失败

**症状：** 启动后立即退出

**解决方法：**
```bash
# 查看详细错误
tail -100 /tmp/sglang-prefill.log

# 常见原因：
# 1. 显存不足 -> 降低 --mem-fraction-static 到 0.25
# 2. 模型路径错误 -> 确认路径存在
# 3. 端口占用 -> 更改端口号
```

### 问题 2: Gateway 无法连接 Worker

**症状：** Health check 失败

**解决方法：**
```bash
# 检查 Workers 是否运行
curl http://127.0.0.1:30000/health
curl http://127.0.0.1:30001/health

# 如果失败，重启 Workers
bash cleanup-pd-test.sh
bash start-pd-test.sh
```

### 问题 3: 请求超时

**症状：** curl 长时间无响应

**解决方法：**
```bash
# 增加超时时间
curl --max-time 120 -X POST http://127.0.0.1:3000/v1/chat/completions ...

# 检查 GPU 负载
nvidia-smi

# 查看日志
tail -f /tmp/sglang-prefill.log
tail -f /tmp/sglang-decode.log
```

## 🧹 清理环境

```bash
# 停止所有服务
bash cleanup-pd-test.sh

# 或手动停止
pkill -f "sglang.launch_server"
pkill -f "sgl-model-gateway"

# 验证清理
nvidia-smi  # 应无 Python 进程占用大量显存
```

## 📊 测试结果

### 待填充（执行测试后填写）

- [ ] Prefill Server 启动成功
- [ ] Decode Server 启动成功
- [ ] Gateway 启动成功
- [ ] 简单对话测试通过
- [ ] 中文对话测试通过
- [ ] Generate API 测试通过
- [ ] 并发测试通过
- [ ] 日志验证通过（bootstrap 信息）
- [ ] GPU 使用符合预期

### 性能指标（待填写）

- 首次 Token 延迟 (TTFT): ___ ms
- 生成速度: ___ tokens/sec
- 并发处理能力: ___ requests/sec
- 显存占用: Prefill ___ MB, Decode ___ MB

## 📝 经验总结

### 关键教训

1. **PD 模式参数是必需的**: `--pd prefill` 和 `--pd decode` 不能省略
2. **显存管理很重要**: 16GB 显存跑两个 7B 实例需要精细配置
3. **Bootstrap Port 配置**: Prefill 必须指定 `--disaggregation-bootstrap-port`
4. **启动顺序**: Prefill -> Decode -> Gateway
5. **健康检查**: 每个阶段都要验证是否成功

### 最佳实践

1. 使用脚本自动化启动流程
2. 每个阶段都进行健康检查
3. 保留详细日志用于调试
4. 监控 GPU 使用情况
5. 使用 `cleanup-pd-test.sh` 确保干净退出

## 🔗 相关文档

- [部署总结](./model_deploy/01-部署总结.md)
- [PD 测试完整指南](./model_deploy/05-PD测试完整指南.md)
- [PD 分离测试指南](./docs/pd-disaggregation-testing-guide.md)

---

**记录人**: AI Assistant  
**创建时间**: 2026-04-13  
**状态**: ✅ 脚本和文档已准备就绪，等待执行测试
