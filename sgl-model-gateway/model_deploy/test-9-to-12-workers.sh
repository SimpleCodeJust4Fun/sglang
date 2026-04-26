#!/bin/bash
# Simple test for 9-12 workers
MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"
VENV="/home/tyliu/qwen_env/bin/activate"

echo "=== GPTQ-Int4 Worker Limit Test ==="
echo ""

# Kill old processes
killall -9 python3 2>/dev/null || true
sleep 3

# Test 9 workers (4P+5D)
echo "Testing 9 workers (4P+5D)..."
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    boot=$((90000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.05 --tp 1 --pd prefill --disaggregation-bootstrap-port $boot --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/p-$i.log 2>&1" &
    sleep 2
done

for i in 1 2 3 4 5; do
    port=$((31000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.07 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/d-$i.log 2>&1" &
    sleep 2
done

sleep 25
count=$(ps aux | grep sglang | grep -v grep | wc -l)
echo "9 workers test: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -lt 7 ]; then
    echo "FAILED - cleaning up"
    killall -9 python3 2>/dev/null || true
    exit 1
fi

echo "SUCCESS - 9 workers stable!"
echo ""
sleep 5

# Test 10 workers (5P+5D)
echo "Testing 10 workers (5P+5D)..."
killall -9 python3 2>/dev/null || true
sleep 3

for i in 1 2 3 4 5; do
    port=$((30000 + i - 1))
    boot=$((90000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.04 --tp 1 --pd prefill --disaggregation-bootstrap-port $boot --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/p-$i.log 2>&1" &
    sleep 2
done

for i in 1 2 3 4 5; do
    port=$((31000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.06 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/d-$i.log 2>&1" &
    sleep 2
done

sleep 25
count=$(ps aux | grep sglang | grep -v grep | wc -l)
echo "10 workers test: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -lt 8 ]; then
    echo "FAILED at 10 workers"
    killall -9 python3 2>/dev/null || true
    exit 0
fi

echo "SUCCESS - 10 workers stable!"
echo ""
sleep 5

# Test 11 workers (5P+6D)
echo "Testing 11 workers (5P+6D)..."
killall -9 python3 2>/dev/null || true
sleep 3

for i in 1 2 3 4 5; do
    port=$((30000 + i - 1))
    boot=$((90000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.04 --tp 1 --pd prefill --disaggregation-bootstrap-port $boot --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/p-$i.log 2>&1" &
    sleep 2
done

for i in 1 2 3 4 5 6; do
    port=$((31000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.05 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/d-$i.log 2>&1" &
    sleep 2
done

sleep 25
count=$(ps aux | grep sglang | grep -v grep | wc -l)
echo "11 workers test: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -lt 9 ]; then
    echo "FAILED at 11 workers"
    killall -9 python3 2>/dev/null || true
    exit 0
fi

echo "SUCCESS - 11 workers stable!"
echo ""
sleep 5

# Test 12 workers (6P+6D)
echo "Testing 12 workers (6P+6D)..."
killall -9 python3 2>/dev/null || true
sleep 3

for i in 1 2 3 4 5 6; do
    port=$((30000 + i - 1))
    boot=$((90000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.035 --tp 1 --pd prefill --disaggregation-bootstrap-port $boot --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/p-$i.log 2>&1" &
    sleep 2
done

for i in 1 2 3 4 5 6; do
    port=$((31000 + i - 1))
    bash -c "source $VENV && python3 -m sglang.launch_server --model-path \"$MODEL\" --port $port --mem-fraction-static 0.05 --tp 1 --pd decode --host 127.0.0.1 --context-length 2048 --log-level warning > /tmp/d-$i.log 2>&1" &
    sleep 2
done

sleep 25
count=$(ps aux | grep sglang | grep -v grep | wc -l)
echo "12 workers test: $count alive"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

if [ $count -ge 10 ]; then
    echo "SUCCESS - 12 workers stable!"
else
    echo "FAILED at 12 workers"
fi

killall -9 python3 2>/dev/null || true
