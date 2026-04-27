#!/bin/bash
# Quick start workers without killall

cd /mnt/e/dev/sglang/sgl-model-gateway/model_deploy
source ~/qwen_env/bin/activate

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

# Start 4 Prefill Workers
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    bootstrap=$((9000 + i - 1))
    echo "Starting Prefill-$i: port=$port bootstrap=$bootstrap"
    
    python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --host 127.0.0.1 \
        --context-length 512 \
        --log-level info \
        --port $port \
        --mem-fraction-static 0.05 \
        --tp 1 --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        > /tmp/sglang-prefill-$i.log 2>&1 &
done

echo "Waiting 20s for prefill workers..."
sleep 20

prefill_count=$(ps aux | grep '[s]glang' | grep 'prefill' | wc -l)
echo "Prefill workers: $prefill_count / 4"

# Start 2 Decode Workers
for i in 1 2; do
    port=$((31000 + i - 1))
    echo "Starting Decode-$i: port=$port"
    
    python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --host 127.0.0.1 \
        --context-length 512 \
        --log-level info \
        --port $port \
        --mem-fraction-static 0.07 \
        --tp 1 --pd decode \
        > /tmp/sglang-decode-$i.log 2>&1 &
done

echo "Waiting 20s for decode workers..."
sleep 20

total=$(ps aux | grep '[s]glang' | grep -E '(prefill|decode)' | wc -l)
echo "Total workers: $total / 6"

# Test health
echo ""
echo "Health checks:"
for port in 30000 30001 30002 30003 31000 31001; do
    if curl -s http://127.0.0.1:$port/health > /dev/null 2>&1; then
        echo "  Port $port: OK"
    else
        echo "  Port $port: FAIL"
    fi
done
