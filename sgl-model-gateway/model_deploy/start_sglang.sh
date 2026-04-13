#!/bin/bash
export CUDA_HOME=/usr/local/cuda
export PATH=$CUDA_HOME/bin:$PATH
export LD_LIBRARY_PATH=$CUDA_HOME/lib64:$LD_LIBRARY_PATH

cd /home/tyliu
~/qwen_env/bin/python3 -m sglang.launch_server \
  --model-path /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ \
  --port 30000 \
  --host 0.0.0.0 \
  --mem-fraction-static 0.7 \
  --disable-cuda-graph
