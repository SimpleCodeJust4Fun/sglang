#!/bin/bash
# Step-by-step worker increase test
# Start with 8 workers, then add 1 at a time

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo "=== Step-by-Step Worker Limit Test ==="
echo "Starting with 8 workers, then adding 1 at a time"
echo ""

# Activate environment
source ~/qwen_env/bin/activate

# Kill old processes
killall -9 python3 2>/dev/null || true
sleep 3

# Start with 8 workers (4P+4D) - known to work
echo "Step 1: Starting 8 workers (4P+4D) - baseline..."
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    boot=$((90000 + i - 1))
    python3 -m sglang.launch_server --model-path "$MODEL" --port $port --mem-fraction-static 0.05 --tp 1 --pd prefill --disaggregation-bootstrap-port $boot --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/step-p$i.log 2>&1 &
    echo "  Started Prefill-$i (port $port)"
    sleep 5  # Wait 5s between each worker
done

for i in 1 2 3 4; do
    port=$((31000 + i - 1))
    python3 -m sglang.launch_server --model-path "$MODEL" --port $port --mem-fraction-static 0.08 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/step-d$i.log 2>&1 &
    echo "  Started Decode-$i (port $port)"
    sleep 5
done

echo "Waiting 30s for 8 workers to stabilize..."
sleep 30

count=$(ps aux | grep '[p]ython3 -m sglang' | wc -l)
echo "8 workers baseline: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -lt 6 ]; then
    echo "FAILED at baseline 8 workers"
    killall -9 python3 2>/dev/null || true
    exit 1
fi

echo "SUCCESS - 8 workers stable!"
echo ""

# Add 1 more Decode worker (total 9: 4P+5D)
echo "Step 2: Adding 1 Decode worker (total 9: 4P+5D)..."
port=31004
python3 -m sglang.launch_server --model-path "$MODEL" --port $port --mem-fraction-static 0.07 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/step-d5.log 2>&1 &
echo "  Added Decode-5 (port $port)"

sleep 20
count=$(ps aux | grep '[p]ython3 -m sglang' | wc -l)
echo "9 workers: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -ge 8 ]; then
    echo "SUCCESS - 9 workers stable!"
else
    echo "FAILED at 9 workers (only $count)"
    killall -9 python3 2>/dev/null || true
    exit 0
fi

echo ""
sleep 10

# Add 1 more Decode worker (total 10: 4P+6D)
echo "Step 3: Adding 1 Decode worker (total 10: 4P+6D)..."
port=31005
python3 -m sglang.launch_server --model-path "$MODEL" --port $port --mem-fraction-static 0.06 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/step-d6.log 2>&1 &
echo "  Added Decode-6 (port $port)"

sleep 20
count=$(ps aux | grep '[p]ython3 -m sglang' | wc -l)
echo "10 workers: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -ge 8 ]; then
    echo "SUCCESS - 10 workers stable!"
else
    echo "FAILED at 10 workers (only $count)"
    killall -9 python3 2>/dev/null || true
    exit 0
fi

echo ""
sleep 10

# Add 1 more Prefill worker (total 11: 5P+6D)
echo "Step 4: Adding 1 Prefill worker (total 11: 5P+6D)..."
port=30004
boot=90004
python3 -m sglang.launch_server --model-path "$MODEL" --port $port --mem-fraction-static 0.04 --tp 1 --pd prefill --disaggregation-bootstrap-port $boot --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/step-p5.log 2>&1 &
echo "  Added Prefill-5 (port $port)"

sleep 20
count=$(ps aux | grep '[p]ython3 -m sglang' | wc -l)
echo "11 workers: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -ge 9 ]; then
    echo "SUCCESS - 11 workers stable!"
else
    echo "FAILED at 11 workers (only $count)"
    killall -9 python3 2>/dev/null || true
    exit 0
fi

echo ""
echo "=== Test Complete ==="
echo "Final worker count: $count"
killall -9 python3 2>/dev/null || true
