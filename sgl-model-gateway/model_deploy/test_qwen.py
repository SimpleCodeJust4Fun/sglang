import torch
from modelscope import snapshot_download
from transformers import AutoModelForCausalLM, AutoTokenizer

model_id = 'qwen/Qwen2.5-7B-Instruct'

print(f"开始从 ModelScope 下载模型: {model_id}...")
model_dir = snapshot_download(model_id)
print(f"模型下载完成，路径: {model_dir}")

print("正在以 4-bit 模式加载模型和分词器...")
tokenizer = AutoTokenizer.from_pretrained(model_dir)
model = AutoModelForCausalLM.from_pretrained(
    model_dir,
    device_map="auto",
    torch_dtype="auto",
    load_in_4bit=True  # 使用 bitsandbytes 进行 4-bit 量化，以适配 16GB 显存
)

prompt = "你好，请介绍一下你自己以及 Qwen 2.5 系列模型的特点。"
messages = [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": prompt}
]
text = tokenizer.apply_chat_template(
    messages,
    tokenize=False,
    add_generation_prompt=True
)
model_inputs = tokenizer([text], return_tensors="pt").to(model.device)

print("正在生成回答...")
generated_ids = model.generate(
    **model_inputs,
    max_new_tokens=512
)
generated_ids = [
    output_ids[len(input_ids):] for input_ids, output_ids in zip(model_inputs.input_ids, generated_ids)
]

response = tokenizer.batch_decode(generated_ids, skip_special_tokens=True)[0]
print("\n回答如下：\n" + "-"*50)
print(response)
print("-"*50)
