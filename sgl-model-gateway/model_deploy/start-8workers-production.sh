#!/bin/bash
# Start 8 Workers (4P+4D) with GPTQ-Int4
# Production environment for SLO testing

set -e

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo "=========================================="
echo "Starting 8 Workers (4P+4D) - GPTQ-Int4"
echo "Production Environment for SLO Testing"
echo "=========================================="
echo ""

# Activate environment
source ~/qwen_env/bin/activate

# Cleanup
echo "Cleaning up old processes..."
killall -9 python3 2>/dev/null || true
sleep 3

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
        > /tmp/sglang-8w-prefill-$i.log 2>&1 &
    sleep 5
done

# Start 4 Decode Workers
echo "Starting 4 Decode workers..."
for i in 1 2 3 4; do
    port=$((31000 + i - 1))
    echo "  Decode-$i: port=$port"
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.08 \
        --tp 1 --pd decode \
        --host 127.0.0.1 --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-8w-decode-$i.log 2>&1 &
    sleep 5
done

echo ""
echo "Waiting 40 seconds for workers to stabilize..."
sleep 40

# Check
count=$(ps aux | grep sglang | grep -v grep | wc -l)
echo ""
echo "Workers running: $count / 8"
echo ""
echo "GPU Memory:"
nvidia-smi --query-gpu=memory.used --format=csv,noheader
echo ""

if [ $count -eq 8 ]; then
    echo "SUCCESS! All 8 workers are stable."
    echo ""
    echo "To start gateway with RANDOM strategy:"
    echo "./target/debug/sgl-model-gateway \\"
    echo "  --pd-disaggregation \\"
    echo "  --prefill http://127.0.0.1:30000 90000 \\"
    echo "  --prefill http://127.0.0.1:30001 90001 \\"
    echo "  --prefill http://127.0.0.1:30002 90002 \\"
    echo "  --prefill http://127.0.0.1:30003 90003 \\"
    echo "  --decode http://127.0.0.1:31000 \\"
    echo "  --decode http://127.0.0.1:31001 \\"
    echo "  --decode http://127.0.0.1:31002 \\"
    echo "  --decode http://127.0.0.1:31003 \\"
    echo "  --prefill-policy random --decode-policy random"
    echo ""
    echo "To start gateway with CACHE_AWARE strategy:"
    echo "./target/debug/sgl-model-gateway \\"
    echo "  --pd-disaggregation \\"
    echo "  --prefill http://127.0.0.1:30000 90000 \\"
    echo "  --prefill http://127.0.0.1:30001 90001 \\"
    echo "  --prefill http://127.0.0.1:30002 90002 \\"
    echo "  --prefill http://127.0.0.1:30003 90003 \\"
    echo "  --decode http://127.0.0.1:31000 \\"
    echo "  --decode http://127.0.0.1:31001 \\"
    echo "  --decode http://127.0.0.1:31002 \\"
    echo "  --decode http://127.0.0.1:31003 \\"
    echo "  --prefill-policy cache_aware --decode-policy round_robin"
else
    echo "FAILED: Only $count / 8 workers survived."
    echo "Check logs: /tmp/sglang-8w-*.log"
    killall -9 python3 2>/dev/null || true
fi
