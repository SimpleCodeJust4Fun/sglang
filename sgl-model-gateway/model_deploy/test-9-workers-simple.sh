#!/bin/bash
# Direct test for 9-12 workers using successful approach
MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo "=== GPTQ-Int4 Worker Limit Test ==="

# Kill old processes
pkill -9 -f sglang 2>/dev/null || true
sleep 3

# Test 9 workers (4P+5D)
echo ""
echo "Testing 9 workers (4P+5D)..."
echo "Starting Prefill workers..."

source /home/tyliu/qwen_env/bin/activate

for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    boot=$((90000 + i - 1))
    nohup python3 -m sglang.launch_server --model-path "$MODEL" --port $port --mem-fraction-static 0.05 --tp 1 --pd prefill --disaggregation-bootstrap-port $boot --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/p-$i.log 2>&1 &
    echo "  Started Prefill-$i on port $port (PID: $!)"
    sleep 3
done

echo "Starting Decode workers..."
for i in 1 2 3 4 5; do
    port=$((31000 + i - 1))
    nohup python3 -m sglang.launch_server --model-path "$MODEL" --port $port --mem-fraction-static 0.07 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/d-$i.log 2>&1 &
    echo "  Started Decode-$i on port $port (PID: $!)"
    sleep 3
done

echo "Waiting 30 seconds for stabilization..."
sleep 30

count=$(ps aux | grep '[p]ython3 -m sglang' | wc -l)
echo "9 workers test: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -ge 7 ]; then
    echo "SUCCESS - 9 workers stable!"
else
    echo "FAILED - only $count/9 workers"
    pkill -9 -f sglang 2>/dev/null || true
    exit 1
fi

echo ""
echo "Test complete. Cleaning up..."
pkill -9 -f sglang 2>/dev/null || true
sleep 3
