import requests
import json

url = "http://localhost:30000/v1/chat/completions"

data = {
    "model": "default",
    "messages": [
        {"role": "system", "content": "你是一个有帮助的AI助手。"},
        {"role": "user", "content": "你好！请简单介绍一下你自己。"}
    ],
    "temperature": 0.7,
    "max_tokens": 512
}

response = requests.post(url, json=data)
result = response.json()

print("=" * 50)
print("SGLang 服务测试结果:")
print("=" * 50)
print(f"状态码: {response.status_code}")
print(f"\n模型回答:\n{result['choices'][0]['message']['content']}")
print("=" * 50)
print(f"Token统计: 输入={result['usage']['prompt_tokens']}, 输出={result['usage']['completion_tokens']}")
