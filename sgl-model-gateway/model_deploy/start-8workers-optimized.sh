#!/bin/bash
# Start 8 Workers (4P+4D) with OPTIMIZED disk I/O
# Key optimizations:
# 1. Sequential startup with 10s interval (avoid disk thrashing)
# 2. Reduced context-length (512 vs 2048)
# 3. Minimal logging (--log-level warning)
# 4. Lower mem-fraction-static
# 5. Host binding to 127.0.0.1

set -e

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo "=========================================="
echo "Starting 8 Workers (4P+4D) - OPTIMIZED"
echo "Disk I/O Optimization Applied"
echo "=========================================="
echo ""
echo "Optimizations:"
echo "  - Sequential startup: 10s interval"
echo "  - Context length: 512 (reduced from 2048)"
echo "  - Log level: warning (reduced I/O)"
echo "  - Mem fraction: 0.05 (all workers, minimal)"
echo "  - Host: 127.0.0.1 (local only)"
echo ""

# Activate environment
source ~/qwen_env/bin/activate

# Cleanup
echo "Cleaning up old processes..."
killall -9 python3 2>/dev/null || true
sleep 3

# Common arguments for all workers
# context-length 512 (reuced from 1024 to save GPU VRAM)
COMMON_ARGS="--model-path $MODEL --host 127.0.0.1 --context-length 512 --log-level warning"

# Start 4 Prefill Workers SEQUENTIALLY
echo "Starting 4 Prefill workers (10s interval)..."
for i in 1 2 3 4; do
    port=$((30000 + i - 1))
    bootstrap=$((90000 + i - 1))
    echo "  [$(( (i-1)*10 ))s] Prefill-$i: port=$port bootstrap=$bootstrap"
    
    python3 -m sglang.launch_server \
        $COMMON_ARGS \
        --port $port \
        --mem-fraction-static 0.05 \
        --tp 1 --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        > /tmp/sglang-opt-prefill-$i.log 2>&1 &
    
    # Wait 10 seconds before next worker (CRITICAL for disk I/O)
    if [ $i -lt 4 ]; then
        echo "    Waiting 10s for disk I/O..."
        sleep 10
    fi
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
    echo "Check logs: /tmp/sglang-opt-prefill-*.log"
    tail -20 /tmp/sglang-opt-prefill-1.log
    killall -9 python3 2>/dev/null || true
    exit 1
fi

echo "Prefill workers stable. Starting Decode workers..."
echo ""

# Start 4 Decode Workers SEQUENTIALLY
echo "Starting 4 Decode workers (10s interval)..."
for i in 1 2 3 4; do
    port=$((31000 + i - 1))
    echo "  [$(( (i-1)*10 ))s] Decode-$i: port=$port"
    
    python3 -m sglang.launch_server \
        $COMMON_ARGS \
        --port $port \
        --mem-fraction-static 0.05 \
        --tp 1 --pd decode \
        > /tmp/sglang-opt-decode-$i.log 2>&1 &
    
    # Wait 10 seconds before next worker
    if [ $i -lt 4 ]; then
        echo "    Waiting 10s for disk I/O..."
        sleep 10
    fi
done

echo ""
echo "All 8 workers started."
echo "Waiting 40s for full stabilization..."
sleep 40

# Final check
total_count=$(ps aux | grep '[s]glang' | grep -c 'port')
prefill_count=$(ps aux | grep '[s]glang' | grep 'prefill' | wc -l)
decode_count=$(ps aux | grep '[s]glang' | grep 'decode' | wc -l)

echo ""
echo "=========================================="
echo "Final Status"
echo "=========================================="
echo "Total workers: $total_count / 8"
echo "  Prefill: $prefill_count / 4"
echo "  Decode: $decode_count / 4"
echo ""
echo "GPU Memory:"
nvidia-smi --query-gpu=memory.used --format=csv,noheader
echo ""

if [ $total_count -eq 8 ]; then
    echo "SUCCESS! All 8 workers are stable."
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
    echo "  --decode http://127.0.0.1:31002 \\"
    echo "  --decode http://127.0.0.1:31003 \\"
    echo "  --prefill-policy cache_aware \\"
    echo "  --decode-policy round_robin \\"
    echo "  --log-level warning"
    echo ""
else
    echo "WARNING: Only $total_count / 8 workers survived."
    echo "  Prefill: $prefill_count / 4"
    echo "  Decode: $decode_count / 4"
    echo ""
    echo "Check logs:"
    echo "  Prefill: /tmp/sglang-opt-prefill-*.log"
    echo "  Decode: /tmp/sglang-opt-decode-*.log"
    echo ""
    
    # Show last 10 lines of first failed worker
    if [ $prefill_count -lt 4 ]; then
        echo "=== Prefill-1 log (last 10 lines) ==="
        tail -10 /tmp/sglang-opt-prefill-1.log 2>/dev/null || echo "Log not found"
    fi
fi
