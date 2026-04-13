# SGLang 框架学习与进阶指南

## 📚 学习路径

```
基础入门 → API使用 → 高级特性 → 性能优化 → 源码研究
```

## 🎯 第一阶段: 基础入门 (1-2天)

### 1.1 理解 SGLang 核心概念

**SGLang (Structured Generation Language)** 是一个专为大语言模型设计的高性能推理引擎。

**核心优势**:
- 🚀 高吞吐量: 比 vLLM 快 1.5-3 倍
- 💾 高效的 KV 缓存管理 (Radix Attention)
- 🔄 支持复杂的结构化生成
- 🛠️ 丰富的约束解码功能

**三大核心模块**:
1. **Backend (后端)**: 负责模型加载、推理计算
2. **Frontend (前端)**: 提供编程接口和 API 服务
3. **Runtime (运行时)**: 管理请求调度、内存分配

### 1.2 基本使用方式

SGLang 提供两种主要使用方式:

#### 方式 1: 作为 API 服务器（你当前的方式）
```bash
# 启动服务
python -m sglang.launch_server \
  --model-path <模型路径> \
  --port 30000
```

#### 方式 2: 作为 Python 库
```python
import sglang as sgl

# 在代码中直接使用
@sgl.function
def multi_turn_chat(s, question):
    s += sgl.system("You are a helpful assistant.")
    s += sgl.user(question)
    s += sgl.assistant(sgl.gen("answer", max_tokens=256))

state = multi_turn_chat.run(question="What is SGLang?")
print(state["answer"])
```

### 1.3 实践练习

**练习 1: 基础对话测试**
```bash
# 创建测试脚本: basic_test.py
cat > ~/basic_test.py << 'EOF'
import requests

url = "http://localhost:30000/v1/chat/completions"
data = {
    "model": "default",
    "messages": [
        {"role": "user", "content": "用一句话介绍北京"}
    ],
    "temperature": 0.7,
    "max_tokens": 100
}

response = requests.post(url, json=data)
print(response.json()["choices"][0]["message"]["content"])
EOF

# 运行测试
~/qwen_env/bin/python3 ~/basic_test.py
```

**练习 2: 流式输出测试**
```python
import requests
import json

url = "http://localhost:30000/v1/chat/completions"
data = {
    "model": "default",
    "messages": [{"role": "user", "content": "写一首关于春天的诗"}],
    "stream": True  # 启用流式输出
}

with requests.post(url, json=data, stream=True) as response:
    for line in response.iter_lines():
        if line:
            line = line.decode('utf-8')
            if line.startswith('data: '):
                line = line[6:]  # 移除 "data: " 前缀
                if line != '[DONE]':
                    chunk = json.loads(line)
                    delta = chunk['choices'][0]['delta']
                    if 'content' in delta:
                        print(delta['content'], end='', flush=True)
```

## 🚀 第二阶段: API 深度使用 (2-3天)

### 2.1 OpenAI 兼容 API

SGLang 提供完整的 OpenAI API 兼容层，可以直接使用 OpenAI 客户端:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:30000/v1",
    api_key="EMPTY"  # SGLang 默认不需要 API key
)

# 方式1: 标准对话
response = client.chat.completions.create(
    model="default",
    messages=[
        {"role": "system", "content": "你是一个专业的Python程序员"},
        {"role": "user", "content": "写一个快速排序算法"}
    ]
)
print(response.choices[0].message.content)

# 方式2: 流式对话
stream = client.chat.completions.create(
    model="default",
    messages=[{"role": "user", "content": "讲个笑话"}],
    stream=True
)
for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end='')
```

### 2.2 高级采样参数

```python
response = client.chat.completions.create(
    model="default",
    messages=[{"role": "user", "content": "写一个故事"}],
    
    # 温度控制（0-2，越高越随机）
    temperature=0.8,
    
    # Top-p 采样（核采样）
    top_p=0.9,
    
    # Top-k 采样
    top_k=50,
    
    # 频率惩罚（-2.0 到 2.0）
    frequency_penalty=0.5,
    
    # 存在惩罚（-2.0 到 2.0）
    presence_penalty=0.3,
    
    # 重复惩罚（SGLang 特有）
    repetition_penalty=1.05,
    
    # 最大输出 tokens
    max_tokens=512,
    
    # 停止词
    stop=["故事结束", "\n\n\n"]
)
```

### 2.3 批量请求优化

```python
import asyncio
from openai import AsyncOpenAI

client = AsyncOpenAI(
    base_url="http://localhost:30000/v1",
    api_key="EMPTY"
)

async def generate_one(prompt):
    response = await client.chat.completions.create(
        model="default",
        messages=[{"role": "user", "content": prompt}]
    )
    return response.choices[0].message.content

async def batch_generate():
    prompts = [
        "介绍一下北京",
        "介绍一下上海",
        "介绍一下广州",
        "介绍一下深圳"
    ]
    
    tasks = [generate_one(p) for p in prompts]
    results = await asyncio.gather(*tasks)
    
    for prompt, result in zip(prompts, results):
        print(f"问题: {prompt}")
        print(f"回答: {result}\n")

# 运行批量请求
asyncio.run(batch_generate())
```

## 🎨 第三阶段: 高级特性探索 (3-5天)

### 3.1 约束生成 (Constrained Decoding)

SGLang 支持多种约束生成模式:

#### JSON 格式约束
```python
response = client.chat.completions.create(
    model="default",
    messages=[
        {"role": "user", "content": "生成一个人物信息，包含姓名、年龄、职业"}
    ],
    response_format={
        "type": "json_schema",
        "json_schema": {
            "name": "person",
            "schema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "age": {"type": "integer"},
                    "occupation": {"type": "string"}
                },
                "required": ["name", "age", "occupation"]
            }
        }
    }
)
```

#### 正则表达式约束
```python
import requests

response = requests.post(
    "http://localhost:30000/generate",
    json={
        "text": "生成一个中国手机号码:",
        "sampling_params": {
            "max_tokens": 20,
            "regex": r"1[3-9]\d{9}"  # 手机号正则
        }
    }
)
```

### 3.2 多模态输入（如果模型支持）

```python
# 图像输入示例（需要多模态模型）
response = client.chat.completions.create(
    model="default",
    messages=[
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "这张图片里有什么?"},
                {
                    "type": "image_url",
                    "image_url": {
                        "url": "https://example.com/image.jpg"
                    }
                }
            ]
        }
    ]
)
```

### 3.3 使用 SGLang 原生 API

```python
import sglang as sgl

# 初始化运行时
runtime = sgl.Runtime(
    model_path="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ"
)

# 定义生成函数
@sgl.function
def character_generation(s, character_name):
    s += f"请详细描述角色 {character_name} 的特征:\n"
    s += "外貌:" + sgl.gen("appearance", max_tokens=100, stop="\n")
    s += "\n性格:" + sgl.gen("personality", max_tokens=100, stop="\n")
    s += "\n背景:" + sgl.gen("background", max_tokens=150)

# 执行生成
state = character_generation.run(
    character_name="李白",
    runtime=runtime
)

print("外貌:", state["appearance"])
print("性格:", state["personality"])
print("背景:", state["background"])

# 关闭运行时
runtime.shutdown()
```

## ⚡ 第四阶段: 性能优化与监控 (3-5天)

### 4.1 性能参数调优

#### 显存优化
```bash
# 降低显存占用
--mem-fraction-static 0.6  # 降低静态显存分配

# 启用 CPU offload（部分模型支持）
--cpu-offload-gb 4  # 将 4GB 参数卸载到 CPU
```

#### 吞吐量优化
```bash
# 增加并发请求数
--max-running-requests 8

# 调整 chunked prefill
--chunked-prefill-size 4096  # 增大可提升长文本处理速度

# 启用 CUDA Graph（如果显存充足）
# 移除 --disable-cuda-graph 参数
```

#### 延迟优化
```bash
# 减少批处理延迟
--max-running-requests 2

# 启用 continuous batching
# SGLang 默认启用，无需额外配置
```

### 4.2 性能监控

#### 使用内置指标
```bash
# 启动时添加监控参数
--enable-metrics \
--log-requests
```

#### 查看实时统计
```python
import requests

# 获取服务器统计信息
stats = requests.get("http://localhost:30000/get_server_info").json()
print(f"运行中的请求: {stats['num_running_requests']}")
print(f"队列中的请求: {stats['num_waiting_requests']}")
print(f"显存使用: {stats['memory_used']} / {stats['memory_total']}")
```

### 4.3 压力测试

```python
import time
import asyncio
from openai import AsyncOpenAI

client = AsyncOpenAI(
    base_url="http://localhost:30000/v1",
    api_key="EMPTY"
)

async def single_request(id):
    start = time.time()
    await client.chat.completions.create(
        model="default",
        messages=[{"role": "user", "content": f"测试请求 {id}"}],
        max_tokens=50
    )
    return time.time() - start

async def benchmark(num_requests=50, concurrency=10):
    print(f"开始压测: {num_requests} 个请求, 并发 {concurrency}")
    
    start_time = time.time()
    tasks = []
    
    for i in range(num_requests):
        tasks.append(single_request(i))
        if len(tasks) >= concurrency:
            await asyncio.gather(*tasks)
            tasks = []
    
    if tasks:
        await asyncio.gather(*tasks)
    
    total_time = time.time() - start_time
    print(f"总耗时: {total_time:.2f}s")
    print(f"平均延迟: {total_time/num_requests:.2f}s")
    print(f"吞吐量: {num_requests/total_time:.2f} req/s")

asyncio.run(benchmark())
```

## 🔬 第五阶段: 源码研究与定制 (进阶)

### 5.1 理解 SGLang 架构

```
┌─────────────────────────────────────┐
│         Frontend (API Server)        │
│  - FastAPI HTTP Server               │
│  - OpenAI Compatible Endpoints       │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│         Scheduler (调度器)           │
│  - Request Queue Management         │
│  - Batch Scheduling                 │
│  - Radix Cache (KV缓存)             │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│      Model Runner (执行器)           │
│  - Model Forward Pass               │
│  - Attention Computation            │
│  - Sampling                         │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│      Backends (后端实现)             │
│  - FlashInfer / FlashAttention      │
│  - CUDA Kernels                     │
│  - Quantization Support             │
└─────────────────────────────────────┘
```

### 5.2 核心代码位置

```bash
# 进入 SGLang 源码目录
cd ~/qwen_env/lib/python3.12/site-packages/sglang/

# 关键模块
ls -l srt/
# ├── managers/          # 调度器和工作器
# ├── model_executor/    # 模型执行
# ├── layers/            # 自定义层实现
# ├── models/            # 支持的模型架构
# └── server_args.py     # 服务器参数定义
```

### 5.3 自定义采样策略

```python
# 示例: 创建自定义采样函数
from sglang import function, gen, Runtime

@function
def creative_writing(s, topic):
    # 第一阶段: 高温度创意生成
    s += f"关于 {topic} 的创意点子:\n"
    s += gen("ideas", temperature=1.2, max_tokens=200)
    
    # 第二阶段: 低温度精炼
    s += "\n基于以上创意，写一个结构化的故事:\n"
    s += gen("story", temperature=0.5, max_tokens=500)
    
    return s

# 使用自定义函数
runtime = Runtime(model_path="...")
result = creative_writing.run(topic="AI 的未来", runtime=runtime)
```

### 5.4 集成到现有项目

#### 作为 LangChain 后端
```python
from langchain.llms.base import LLM
from typing import Optional, List

class SGLangLLM(LLM):
    base_url: str = "http://localhost:30000"
    
    @property
    def _llm_type(self) -> str:
        return "sglang"
    
    def _call(
        self,
        prompt: str,
        stop: Optional[List[str]] = None
    ) -> str:
        import requests
        response = requests.post(
            f"{self.base_url}/generate",
            json={
                "text": prompt,
                "sampling_params": {
                    "max_tokens": 512,
                    "stop": stop
                }
            }
        )
        return response.json()["text"]

# 使用
llm = SGLangLLM()
result = llm("解释一下量子计算")
```

## 📖 学习资源

### 官方资源
- **GitHub**: https://github.com/sgl-project/sglang
- **文档**: https://sgl-project.github.io/
- **论文**: [Efficiently Programming Large Language Models using SGLang](https://arxiv.org/abs/2312.07104)

### 推荐阅读
1. **FlashInfer 论文**: 理解高效注意力计算
2. **Radix Attention 原理**: 理解 KV 缓存复用机制
3. **vLLM 对比**: 了解不同推理引擎的设计权衡

### 实践项目建议
1. **构建 RAG 系统**: 结合 SGLang + 向量数据库
2. **多轮对话机器人**: 利用 KV 缓存加速
3. **结构化数据提取**: 使用约束生成功能
4. **批量内容生成**: 优化吞吐量和成本

## 🎯 进阶挑战

1. **性能调优**: 使你的部署达到最优 tokens/s
2. **自定义模型**: 部署其他 Qwen 系列或 Llama 模型
3. **分布式部署**: 尝试多卡 Tensor Parallelism
4. **生产化**: 添加负载均衡、健康检查、日志系统

---

**持续更新中...**  
**最后更新**: 2026-01-25
