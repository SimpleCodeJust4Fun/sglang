#!/bin/bash
# Start 6 Workers (4P+2D) - STABLE CONFIG
# This config is proven stable with GPTQ-Int4
# context-length 512 for reduced VRAM usage

set -e

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo "=========================================="
echo "Starting 6 Workers (4P+2D) - STABLE"
echo "=========================================="
echo ""
echo "Config:"
echo "  - Context length: 512"
echo "  - Mem fraction: 0.05 (Prefill) / 0.07 (Decode)"
echo "  - Parallel startup (no wait)"
echo ""

# Activate environment
source ~/qwen_env/bin/activate

# Cleanup
echo "Cleaning up old processes..."
killall -9 python3 2>/dev/null || true
sleep 3

# Common arguments for all workers
COMMON_ARGS="--model-path $MODEL --host 127.0.0.1 --context-length 512 --log-level warning"

# Start 4 Prefill Workers IN PARALLEL
echo "Starting 4 Prefill workers (parallel)..."
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    bootstrap=$((9000 + i - 1))
    echo "  Prefill-$i: port=$port bootstrap=$bootstrap"
    
    python3 -m sglang.launch_server \
        $COMMON_ARGS \
        --port $port \
        --mem-fraction-static 0.05 \
        --tp 1 --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        > /tmp/sglang-prefill-$i.log 2>&1 &
done

echo ""
echo "All 4 Prefill workers started."
echo "Waiting 30s for them to stabilize..."
sleep 30

# Check Prefill workers
prefill_count=$(ps aux | grep '[s]glang' | grep 'prefill' | wc -l)
echo "Prefill workers alive: $prefill_count / 4"

if [ $prefill_count -lt 3 ]; then
    echo "WARNING: Less than 3 Prefill workers survived!"
    echo "Check logs: /tmp/sglang-prefill-*.log"
    tail -20 /tmp/sglang-prefill-1.log
    killall -9 python3 2>/dev/null || true
    exit 1
fi

echo "Prefill workers stable. Starting Decode workers..."
echo ""

# Start 2 Decode Workers IN PARALLEL
echo "Starting 2 Decode workers (parallel)..."
for i in 1 2; do
    port=$((31000 + i - 1))
    echo "  Decode-$i: port=$port"
    
    python3 -m sglang.launch_server \
        $COMMON_ARGS \
        --port $port \
        --mem-fraction-static 0.07 \
        --tp 1 --pd decode \
        > /tmp/sglang-decode-$i.log 2>&1 &
done

echo ""
echo "All 6 workers started."
echo "Waiting 30s for full stabilization..."
sleep 30

# Final check
total_count=$(ps aux | grep '[s]glang' | grep -E '(prefill|decode)' | wc -l)
prefill_count=$(ps aux | grep '[s]glang' | grep 'prefill' | wc -l)
decode_count=$(ps aux | grep '[s]glang' | grep 'decode' | wc -l)

echo ""
echo "=========================================="
echo "Final Status"
echo "=========================================="
echo "Total workers: $total_count / 6"
echo "  Prefill: $prefill_count / 4"
echo "  Decode: $decode_count / 2"
echo ""
echo "GPU Memory:"
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv,noheader
echo ""

if [ $total_count -eq 6 ]; then
    echo "SUCCESS! All 6 workers are stable."
    echo ""
    echo "To start gateway with CACHE_AWARE strategy:"
    echo ""
    echo "./target/debug/sgl-model-gateway \\"
    echo "  --pd-disaggregation \\"
    echo "  --prefill http://127.0.0.1:30000 90000 \\"
    echo "  --prefill http://127.0.0.1:30001 90001 \\"
    echo "  --prefill http://127.0.0.1:30002 90002 \\"
    echo "  --prefill http://127.0.0.1:30003 90003 \\"
    echo "  --decode http://127.0.0.1:31000 \\"
    echo "  --decode http://127.0.0.1:31001 \\"
    echo "  --prefill-policy cache_aware \\"
    echo "  --decode-policy round_robin \\"
    echo "  --log-level warning"
    echo ""
else
    echo "WARNING: Only $total_count / 6 workers survived."
    echo "  Prefill: $prefill_count / 4"
    echo "  Decode: $decode_count / 2"
    echo ""
    echo "Check logs:"
    echo "  Prefill: /tmp/sglang-prefill-*.log"
    echo "  Decode: /tmp/sglang-decode-*.log"
fi

# Disown all background processes so they survive shell exit
disown -a
echo ""
echo "All workers disowned from shell. They will continue running."
