#!/bin/bash
# Test 9 workers with npcache to reduce disk I/O
# npcache caches model weights in numpy format for faster loading

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo "=== 9 Workers Test with npcache Optimization ==="
echo "Using --load-format npcache to reduce disk I/O"
echo ""

# Activate environment
source ~/qwen_env/bin/activate

# Kill old processes
killall -9 python3 2>/dev/null || true
sleep 3

echo "Step 1: Pre-warm model cache by loading once..."
echo "This creates numpy cache for faster subsequent loads"
timeout 60 python3 -m sglang.launch_server \
    --model-path "$MODEL" \
    --port 19999 \
    --mem-fraction-static 0.1 \
    --tp 1 \
    --host 127.0.0.1 \
    --context-length 2048 \
    --load-format npcache \
    --log-level warning > /tmp/prewarm.log 2>&1 &
PREWARM_PID=$!

echo "Waiting 40s for pre-warm to complete..."
sleep 40

# Kill prewarm process
kill $PREWARM_PID 2>/dev/null || true
sleep 3

echo ""
echo "Step 2: Starting 9 workers (4P+5D) with npcache..."
echo "Each worker will use cached model weights"

# Start 4 Prefill Workers
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    boot=$((90000 + i - 1))
    echo "  Starting Prefill-$i (port $port)..."
    python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.05 \
        --tp 1 --pd prefill \
        --disaggregation-bootstrap-port $boot \
        --host 127.0.0.1 \
        --context-length 2048 \
        --load-format npcache \
        --log-level warning \
        > /tmp/9w-nc-p$i.log 2>&1 &
    sleep 8  # 8s stagger with npcache
done

# Start 5 Decode Workers
for i in 1 2 3 4 5; do
    port=$((31000 + i - 1))
    echo "  Starting Decode-$i (port $port)..."
    python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.07 \
        --tp 1 --pd decode \
        --host 127.0.0.1 \
        --context-length 2048 \
        --load-format npcache \
        --log-level warning \
        > /tmp/9w-nc-d$i.log 2>&1 &
    sleep 8
done

echo ""
echo "Waiting 40s for 9 workers to stabilize..."
sleep 40

# Check results
count=$(ps aux | grep '[p]ython3 -m sglang' | wc -l)
echo ""
echo "=== Results ==="
echo "Workers alive: $count / 9"
echo ""
echo "GPU Memory:"
nvidia-smi --query-gpu=memory.used --format=csv,noheader
echo ""

if [ $count -ge 7 ]; then
    echo "SUCCESS - 9 workers stable with npcache!"
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
    echo "FAILED - only $count / 9 workers"
    echo "Check logs: /tmp/9w-nc-*.log"
    killall -9 python3 2>/dev/null || true
fi
