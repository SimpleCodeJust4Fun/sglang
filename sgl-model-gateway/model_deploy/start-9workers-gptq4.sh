#!/bin/bash
# Start 9 Workers (4P+5D) with GPTQ-Int4
# Testing upper limit

set -e

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo "Starting 9 Workers (4P+5D) - GPTQ-Int4"
echo "Prefill mem: 0.05, Decode mem: 0.07"
echo "Scheduling Pairs: 20"
echo "========================================"

# Activate environment
source ~/qwen_env/bin/activate

# Cleanup
echo "Cleaning up..."
killall -9 python3 2>/dev/null || true
sleep 2

# Start 4 Prefill Workers
echo "Starting 4 Prefill workers..."
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    bootstrap=$((90000 + i - 1))
    echo "  Prefill-$i: port=$port bootstrap=$bootstrap"
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.05 \
        --tp 1 --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        --host 127.0.0.1 --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-9w-prefill-$i.log 2>&1 &
    sleep 3
done

# Start 5 Decode Workers
echo "Starting 5 Decode workers..."
for i in 1 2 3 4 5; do
    port=$((31000 + i - 1))
    echo "  Decode-$i: port=$port"
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.07 \
        --tp 1 --pd decode \
        --host 127.0.0.1 --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-9w-decode-$i.log 2>&1 &
    sleep 3
done

echo ""
echo "Waiting 30 seconds for stabilization..."
sleep 30

# Check
count=$(ps aux | grep sglang | grep -v grep | wc -l)
echo ""
echo "Workers running: $count / 9"
echo ""
echo "GPU Memory:"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -eq 9 ]; then
    echo ""
    echo "SUCCESS! All 9 workers are stable."
    echo ""
    echo "To start gateway:"
    echo "./target/debug/sgl-model-gateway \\"
    echo "  --pd-disaggregation \\"
    for i in 1 2 3 4; do
        port=$((30000 + i - 1))
        boot=$((90000 + i - 1))
        echo "  --prefill http://127.0.0.1:$port $boot \\"
    done
    for i in 1 2 3 4 5; do
        port=$((31000 + i - 1))
        echo "  --decode http://127.0.0.1:$port \\"
    done
    echo "  --prefill-policy cache_aware --decode-policy round_robin"
else
    echo ""
    echo "FAILED: Only $count / 9 workers survived."
    echo "Check logs: /tmp/sglang-9w-*.log"
    killall -9 python3 2>/dev/null || true
fi
