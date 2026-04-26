#!/bin/bash
# 快速测试剩余的 P0 优先级策略
# 测试: round_robin, prefix_hash, cache_aware+cache_aware

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET_PATH="$SCRIPT_DIR/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
GATEWAY_BIN="/mnt/e/dev/sglang/sgl-model-gateway/target/release/sgl-model-gateway"

# 激活 Python 环境
source ~/qwen_env/bin/activate

# Worker 参数
PREFILL_ARGS=(
    "--prefill http://127.0.0.1:30000 90000"
    "--prefill http://127.0.0.1:30001 90001"
    "--prefill http://127.0.0.1:30002 90002"
    "--prefill http://127.0.0.1:30003 90003"
)
DECODE_ARGS=(
    "--decode http://127.0.0.1:31000"
    "--decode http://127.0.0.1:31001"
)

# 测试函数
test_strategy() {
    local p_policy=$1
    local d_policy=$2
    local port=$3
    local output_file="$RESULTS_DIR/bench_${p_policy}_${d_policy}.jsonl"
    
    echo ""
    echo "============================================================"
    echo "Testing: Prefill=$p_policy, Decode=$d_policy (port $port)"
    echo "============================================================"
    
    # 停止旧 Gateway
    pkill -f 'sgl-model-gateway' 2>/dev/null || true
    sleep 3
    
    # 启动 Gateway
    $GATEWAY_BIN \
        --pd-disaggregation \
        --prefill http://127.0.0.1:30000 90000 \
        --prefill http://127.0.0.1:30001 90001 \
        --prefill http://127.0.0.1:30002 90002 \
        --prefill http://127.0.0.1:30003 90003 \
        --decode http://127.0.0.1:31000 \
        --decode http://127.0.0.1:31001 \
        --prefill-policy $p_policy \
        --decode-policy $d_policy \
        --host 127.0.0.1 \
        --port $port \
        --log-level warn > /tmp/sgl-gateway-${p_policy}-${d_policy}.log 2>&1 &
    
    # 等待启动
    echo "Waiting for gateway..."
    for i in {1..15}; do
        if curl -sf "http://127.0.0.1:$port/v1/models" > /dev/null 2>&1; then
            echo "Gateway ready ✓"
            break
        fi
        sleep 1
    done
    
    # 运行 Benchmark
    echo "Running benchmark..."
    python3 -m sglang.bench_serving \
        --backend sglang-oai \
        --base-url "http://127.0.0.1:$port" \
        --dataset-path "$DATASET_PATH" \
        --dataset-name sharegpt \
        --num-prompts 50 \
        --request-rate 5 \
        --output-file "$output_file" 2>&1 | tail -45
    
    echo "Saved to: $output_file"
    
    # 清理
    pkill -f 'sgl-model-gateway' 2>/dev/null || true
    sleep 2
}

echo "============================================================"
echo "P0 Priority Strategy Tests"
echo "============================================================"
echo "Remaining tests:"
echo "  1. round_robin + round_robin"
echo "  2. prefix_hash + round_robin"
echo "  3. cache_aware + cache_aware"
echo ""

# P0 剩余测试
test_strategy "round_robin" "round_robin" 8000
test_strategy "prefix_hash" "round_robin" 8000
test_strategy "cache_aware" "cache_aware" 8000

echo ""
echo "============================================================"
echo "All P0 Tests Complete!"
echo "============================================================"
echo ""
echo "Generate report:"
echo "  python3 generate-benchmark-report.py"
