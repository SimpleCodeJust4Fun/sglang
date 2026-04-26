#!/bin/bash
# Comprehensive Benchmark Script for All Scheduling Strategies
# Tests all routing strategies and generates HTML report

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET_PATH="$SCRIPT_DIR/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
GATEWAY_PORT=8000

# Strategies to test
declare -A STRATEGIES=(
    ["cache_aware"]="Cache-Aware routing based on prefix cache locality"
    ["random"]="Random routing across workers"
)

echo "============================================================"
echo "Comprehensive Benchmark: All Scheduling Strategies"
echo "============================================================"
echo ""
echo "Dataset: $DATASET_PATH"
echo "Results: $RESULTS_DIR"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Function to run benchmark for a strategy
run_benchmark() {
    local strategy=$1
    local port=$2
    local num_prompts=$3
    local request_rate=$4
    local output_file="$RESULTS_DIR/bench_${strategy}.jsonl"
    
    echo ""
    echo "============================================================"
    echo "Testing Strategy: $strategy (port $port)"
    echo "Prompts: $num_prompts, Request Rate: $request_rate/s"
    echo "============================================================"
    
    source ~/qwen_env/bin/activate
    
    python3 -m sglang.bench_serving \
        --backend sglang-oai \
        --base-url "http://127.0.0.1:$port" \
        --dataset-path "$DATASET_PATH" \
        --dataset-name sharegpt \
        --num-prompts "$num_prompts" \
        --request-rate "$request_rate" \
        --output-file "$output_file" 2>&1 | tail -40
    
    echo ""
    echo "Results saved to: $output_file"
    echo ""
}

# Check if gateways are running
echo "Checking gateways..."
if ! curl -s "http://127.0.0.1:$GATEWAY_PORT/v1/models" > /dev/null 2>&1; then
    echo "ERROR: Gateway at port $GATEWAY_PORT is not running!"
    echo "Please start the gateway first."
    exit 1
fi

# Find all running gateways
GATEWAY_PORTS=()
for port in 8000 8001 8002 8003 8004 8005; do
    if curl -s "http://127.0.0.1:$port/v1/models" > /dev/null 2>&1; then
        GATEWAY_PORTS+=($port)
        echo "  Found gateway at port $port"
    fi
done

if [ ${#GATEWAY_PORTS[@]} -eq 0 ]; then
    echo "ERROR: No running gateways found!"
    exit 1
fi

echo ""
echo "Found ${#GATEWAY_PORTS[@]} running gateway(s)"
echo ""

# Run benchmarks for each gateway
for port in "${GATEWAY_PORTS[@]}"; do
    # Determine strategy name based on port or other logic
    # For now, use port number as identifier
    strategy_name="gateway_port${port}"
    run_benchmark "$strategy_name" "$port" 50 5
done

echo ""
echo "============================================================"
echo "All Benchmarks Complete!"
echo "============================================================"
echo ""
echo "Results directory: $RESULTS_DIR"
echo ""
echo "To generate HTML report:"
echo "  python3 generate-benchmark-report.py"
echo ""
