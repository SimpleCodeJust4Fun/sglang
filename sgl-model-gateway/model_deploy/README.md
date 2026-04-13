# model-deploy

## 项目简介

基于 Windows 11 + WSL2 + SGLang 的本地大模型部署方案。使用 Qwen2.5-7B-Instruct-AWQ 模型，提供 OpenAI 兼容的 API 服务。

## 系统环境

- **操作系统**: Windows 11 (25H2) + WSL2 Ubuntu 24.04
- **显卡**: NVIDIA RTX 4070 Ti SUPER (16GB)
- **推理引擎**: SGLang 0.5.8
- **模型**: Qwen2.5-7B-Instruct-AWQ (4-bit量化)

## 快速开始

### 1. 启动服务

```bash
wsl -d Ubuntu bash /mnt/e/dev/model-deploy/start_sglang.sh
```

### 2. 测试 API

```bash
curl http://localhost:30000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "default",
    "messages": [{"role": "user", "content": "你好"}],
    "max_tokens": 100
  }'
```

### 3. Python 调用

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:30000/v1",
    api_key="EMPTY"
)

response = client.chat.completions.create(
    model="default",
    messages=[{"role": "user", "content": "你好"}]
)
print(response.choices[0].message.content)
```

## 文档目录

### 基础部署方案
- [01-部署总结.md](./01-部署总结.md) - 完整部署过程与系统配置
- [02-服务启停手册.md](./02-服务启停手册.md) - 服务管理与常见问题排查
- [03-SGLang学习指南.md](./03-SGLang学习指南.md) - SGLang 框架学习路径
- [04-调试技巧.md](./04-调试技巧.md) - 性能调优与问题诊断

### 高级部署方案 (Kubernetes + Hami vGPU)
- [hami-sglang-deployment/README.md](./hami-sglang-deployment/README.md) - Hami vGPU + SGLang PD 分离方案概述
- [hami-sglang-deployment/ARCHITECTURE.md](./hami-sglang-deployment/ARCHITECTURE.md) - 架构设计详解
- [hami-sglang-deployment/DEPLOYMENT_GUIDE.md](./hami-sglang-deployment/DEPLOYMENT_GUIDE.md) - 完整部署流程
- [hami-sglang-deployment/QUICK_REFERENCE.md](./hami-sglang-deployment/QUICK_REFERENCE.md) - 快速参考手册

## 核心脚本

- `start_sglang.sh` - SGLang 服务启动脚本
- `test_sglang_api.py` - API 测试脚本
- `download_awq.py` - 模型下载脚本

## 性能指标

- **显存占用**: ~10.9GB (模型5.4GB + KV缓存4.9GB)
- **上下文长度**: 32768 tokens
- **KV缓存池**: 91924 tokens
- **服务端口**: 30000

## 主要特性

- ✅ OpenAI 兼容 API
- ✅ 流式输出支持
- ✅ AWQ 4-bit 量化
- ✅ FlashInfer 高性能后端
- ✅ Radix Attention KV 缓存
- ✅ 自动批处理调度

## 资源链接

- [SGLang GitHub](https://github.com/sgl-project/sglang)
- [Qwen2.5 模型](https://modelscope.cn/models/qwen/Qwen2.5-7B-Instruct-AWQ)
- [FlashInfer 文档](https://flashinfer.ai/)

## License

MIT

---

**创建时间**: 2026-01-25
