# Multi-PD 测试结果

## 测试环境
- **模型**: Qwen2.5-0.5B-Instruct
- **Prefill实例**: 2 (端口 30000, 30001)
- **Decode实例**: 2 (端口 30010, 30011)
- **Gateway端口**: 3000
- **GPU**: RTX 4070 Ti SUPER (16GB)

---

## 策略: round_robin

| 测试项 | 结果 |
|--------|------|
| 简单请求 | Hello! How can I assist you today? |
| 中文请求 | 我是由阿里云开发的超大规模语言模型，我叫通义千问。 |
| 并发(5) | 5/5 成功, 耗时961ms |
| Token使用 | prompt=30, completion=10 |

## 策略: cache_aware

| 测试项 | 结果 |
|--------|------|
| 简单请求 | Hello! How can I assist you today? |
| 中文请求 | 我是来自阿里云的超大规模语言模型，我叫通义千问。 |
| 并发(5) | 5/5 成功, 耗时302ms |
| Token使用 | prompt=30, completion=10 |

## 策略: random

| 测试项 | 结果 |
|--------|------|
| 简单请求 | Hello! How can I assist you today? Please let me know if you have any questions or if there's anything specific you'd like to discuss. |
| 中文请求 | 你好，我是来自阿里云的大规模语言模型，我叫通义千问。 |
| 并发(5) | 5/5 成功, 耗时301ms |
| Token使用 | prompt=30, completion=30 |

