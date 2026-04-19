# PD 测试快速参考卡

## 🎯 一键测试（3个终端）

### 终端 1 - 启动 Servers
```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash start-pd-test.sh
```

### 终端 2 - 启动 Gateway
```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash start-gateway.sh
```

### 终端 3 - 执行测试
```bash
cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
bash test-pd-requests.sh
```

## 🧹 清理
```bash
bash cleanup-pd-test.sh
```

## 🔍 快速检查

### 检查 Servers
```bash
curl http://127.0.0.1:30000/health  # Prefill
curl http://127.0.0.1:30001/health  # Decode
```

### 检查 Gateway
```bash
curl http://127.0.0.1:3000/health
```

### 检查 GPU
```bash
nvidia-smi
```

### 查看日志
```bash
tail -f /tmp/sglang-prefill.log
tail -f /tmp/sglang-decode.log
```

## 📝 手动测试请求

```bash
# 简单测试
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen2.5-7b-awq", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 50}'

# 中文测试
curl -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model": "qwen2.5-7b-awq", "messages": [{"role": "user", "content": "你好，请介绍一下自己"}], "max_tokens": 100}'
```

## ⚙️ 配置参数

| 组件 | 端口 | 显存 | 说明 |
|------|------|------|------|
| Prefill Server | 30000 | 30% (4.8GB) | Bootstrap: 9000 |
| Decode Server | 30001 | 30% (4.8GB) | - |
| Gateway | 3000 | - | Policy: round_robin |

## 🚨 常见问题

### Q: 启动失败？
```bash
# 查看详细日志
tail -100 /tmp/sglang-prefill.log
tail -100 /tmp/sglang-decode.log
```

### Q: 显存不足？
```bash
# 降低显存配置：修改 start-pd-test.sh
MEM_FRACTION=0.25  # 从 0.3 改为 0.25
```

### Q: 端口占用？
```bash
# 查看端口占用
lsof -i :30000
lsof -i :30001
lsof -i :3000

# 或清理所有进程
bash cleanup-pd-test.sh
```

## 📚 文档

- 完整指南: [05-PD测试完整指南.md](./05-PD测试完整指南.md)
- 测试记录: [../real-pd-testing-record.md](../real-pd-testing-record.md)
- 原始文档: [../docs/pd-disaggregation-testing-guide.md](../docs/pd-disaggregation-testing-guide.md)

---

**提示**: 首次启动需要 1-2 分钟加载模型，请耐心等待！
