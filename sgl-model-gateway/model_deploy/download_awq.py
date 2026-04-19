from modelscope import snapshot_download
import os

model_id = 'qwen/Qwen2.5-7B-Instruct-AWQ'
print(f"正在下载模型 {model_id}...")
model_dir = snapshot_download(model_id)
print(f"MODEL_PATH:{model_dir}")
