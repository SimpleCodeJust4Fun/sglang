#!/bin/bash
# SLO 测试 - 全策略组合批量测试脚本
# 测试 Prefill × Decode 策略组合，记录结果到 benchmark-results/

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASET_PATH="$SCRIPT_DIR/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
GATEWAY_BIN="/mnt/e/dev/sglang/sgl-model-gateway/target/release/sgl-model-gateway"

# Worker 配置
PREFILL_WORKERS=(
    "http://127.0.0.1:30000:90000"
    "http://127.0.0.1:30001:90001"
    "http://127.0.0.1:30002:90002"
    "http://127.0.0.1:30003:90003"
)
DECODE_WORKERS=(
    "http://127.0.0.1:31000"
    "http://127.0.0.1:31001"
)

# 测试策略组合 (P0 + P1 优先级，共 20 种核心组合)
# 格式: "prefill_policy:decode_policy"
COMBINATIONS=(
    # P0 - 必测
    "cache_aware:round_robin"
    "random:round_robin"
    "round_robin:round_robin"
    "prefix_hash:round_robin"
    "cache_aware:cache_aware"
    
    # P1 - 重要
    "power_of_two:round_robin"
    "bucket:round_robin"
    "performance_aware:round_robin"
    "request_size_bucket:round_robin"
    "request_classification:round_robin"
    
    # P2 - 扩展
    "cache_aware:random"
    "cache_aware:power_of_two"
    "prefix_hash:prefix_hash"
    "prefix_hash:cache_aware"
    "power_of_two:power_of_two"
    "performance_aware:performance_aware"
    "consistent_hashing:consistent_hashing"
    "manual:manual"
    "bucket:power_of_two"
    "request_classification:performance_aware"
)

# Benchmark 参数
NUM_PROMPTS=50
REQUEST_RATE=5
BASE_PORT=8000

echo "============================================================"
echo "SGLang SLO 测试 - 全策略组合批量测试"
echo "============================================================"
echo ""
echo "Workers: 4 Prefill + 2 Decode (6 total)"
echo "Dataset: ShareGPT V3"
echo "Prompts: $NUM_PROMPTS per strategy"
echo "Request Rate: $REQUEST_RATE req/s"
echo "Combinations: ${#COMBINATIONS[@]}"
echo "Results: $RESULTS_DIR"
echo ""

# 创建结果目录
mkdir -p "$RESULTS_DIR"

# 激活 Python 环境
echo "Activating Python environment..."
source ~/qwen_env/bin/activate

# 检查 Workers 是否运行
echo "Checking workers health..."
WORKER_COUNT=0
for worker in "${PREFILL_WORKERS[@]}"; do
    url=$(echo $worker | cut -d: -f1-3)
    if curl -sf "$url/health" > /dev/null 2>&1; then
        WORKER_COUNT=$((WORKER_COUNT + 1))
    fi
done
for worker in "${DECODE_WORKERS[@]}"; do
    if curl -sf "$worker/health" > /dev/null 2>&1; then
        WORKER_COUNT=$((WORKER_COUNT + 1))
    fi
done

if [ $WORKER_COUNT -lt 6 ]; then
    echo "ERROR: Only $WORKER_COUNT / 6 workers are running!"
    echo "Please start workers first: ./start-6workers-stable.sh"
    exit 1
fi
echo "All 6 workers are healthy ✓"
echo ""

# 测试函数
run_combination() {
    local combo=$1
    local port=$2
    
    local p_policy=$(echo $combo | cut -d: -f1)
    local d_policy=$(echo $combo | cut -d: -f2)
    local output_file="$RESULTS_DIR/bench_${p_policy}_${d_policy}.jsonl"
    
    echo ""
    echo "============================================================"
    echo "Testing: Prefill=$p_policy, Decode=$d_policy (port $port)"
    echo "============================================================"
    
    # 停止旧 Gateway
    echo "Stopping old gateway..."
    pkill -f 'sgl-model-gateway' 2>/dev/null || true
    sleep 3
    
    # 构建 Gateway 参数
    local gateway_args="--pd-disaggregation"
    for worker in "${PREFILL_WORKERS[@]}"; do
        local url=$(echo $worker | cut -d: -f1-3)
        local bootstrap_port=$(echo $worker | cut -d: -f4)
        gateway_args="$gateway_args --prefill $url $bootstrap_port"
    done
    for worker in "${DECODE_WORKERS[@]}"; do
        gateway_args="$gateway_args --decode $worker"
    done
    gateway_args="$gateway_args --prefill-policy $p_policy --decode-policy $d_policy"
    gateway_args="$gateway_args --host 127.0.0.1 --port $port --log-level warn"
    
    # 启动 Gateway
    echo "Starting gateway with: $p_policy / $d_policy"
    $GATEWAY_BIN $gateway_args > /tmp/sgl-gateway-${p_policy}-${d_policy}.log 2>&1 &
    GATEWAY_PID=$!
    
    # 等待启动
    echo "Waiting for gateway to start (PID: $GATEWAY_PID)..."
    local ready=false
    for i in {1..15}; do
        if curl -sf "http://127.0.0.1:$port/v1/models" > /dev/null 2>&1; then
            echo "Gateway ready on port $port ✓"
            ready=true
            break
        fi
        sleep 1
    done
    
    if [ "$ready" = false ]; then
        echo "ERROR: Gateway failed to start on port $port"
        echo "Check log: /tmp/sgl-gateway-${p_policy}-${d_policy}.log"
        tail -20 /tmp/sgl-gateway-${p_policy}-${d_policy}.log
        return 1
    fi
    
    # 运行 Benchmark
    echo ""
    echo "Running benchmark ($NUM_PROMPTS prompts @ $REQUEST_RATE req/s)..."
    python3 -m sglang.bench_serving \
        --backend sglang-oai \
        --base-url "http://127.0.0.1:$port" \
        --dataset-path "$DATASET_PATH" \
        --dataset-name sharegpt \
        --num-prompts "$NUM_PROMPTS" \
        --request-rate "$REQUEST_RATE" \
        --output-file "$output_file" 2>&1 | tail -45
    
    echo ""
    echo "Results saved to: $output_file"
    
    # 清理 Gateway
    echo "Stopping gateway..."
    kill $GATEWAY_PID 2>/dev/null || true
    sleep 2
    
    return 0
}

# 主循环
echo "============================================================"
echo "Starting Strategy Combination Tests"
echo "============================================================"

port=$BASE_PORT
success_count=0
fail_count=0

for combo in "${COMBINATIONS[@]}"; do
    p_policy=$(echo $combo | cut -d: -f1)
    d_policy=$(echo $combo | cut -d: -f2)
    
    if run_combination "$combo" "$port"; then
        success_count=$((success_count + 1))
    else
        fail_count=$((fail_count + 1))
        echo "WARNING: Failed to test $p_policy:$d_policy"
    fi
    
    port=$((port + 1))
done

echo ""
echo "============================================================"
echo "All Strategy Combination Tests Complete!"
echo "============================================================"
echo "Successful: $success_count / ${#COMBINATIONS[@]}"
echo "Failed: $fail_count"
echo ""
echo "Results directory: $RESULTS_DIR"
echo ""
echo "To generate HTML report:"
echo "  cd $SCRIPT_DIR"
echo "  python3 generate-benchmark-report.py"
echo ""
