#!/bin/bash
# Run all strategy combinations

SCRIPT_DIR="/mnt/e/dev/sglang/sgl-model-gateway/model_deploy"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
GATEWAY="/mnt/e/dev/sglang/sgl-model-gateway/target/release/sgl-model-gateway"

# 剩余 19 种策略组合
COMBOS=(
    "random:round_robin:8001"
    "round_robin:round_robin:8002"
    "prefix_hash:round_robin:8003"
    "cache_aware:cache_aware:8004"
    "power_of_two:round_robin:8005"
    "bucket:round_robin:8006"
    "performance_aware:round_robin:8007"
    "request_size_bucket:round_robin:8008"
    "request_classification:round_robin:8009"
    "cache_aware:random:8010"
    "cache_aware:power_of_two:8011"
    "prefix_hash:prefix_hash:8012"
    "prefix_hash:cache_aware:8013"
    "power_of_two:power_of_two:8014"
    "performance_aware:performance_aware:8015"
    "consistent_hashing:consistent_hashing:8016"
    "manual:manual:8017"
    "bucket:power_of_two:8018"
    "request_classification:performance_aware:8019"
)

source ~/qwen_env/bin/activate

success=0
fail=0

for combo in "${COMBOS[@]}"; do
    p_policy=$(echo $combo | cut -d: -f1)
    d_policy=$(echo $combo | cut -d: -f2)
    port=$(echo $combo | cut -d: -f3)
    output_file="$RESULTS_DIR/bench_${p_policy}_${d_policy}.jsonl"
    
    echo ""
    echo "============================================================"
    echo "Testing: Prefill=$p_policy, Decode=$d_policy (port $port)"
    echo "============================================================"
    
    # 停止旧 gateway
    killall sgl-model-gateway 2>/dev/null || true
    sleep 2
    
    # 启动新 gateway
    $GATEWAY \
        --pd-disaggregation \
        --prefill http://127.0.0.1:30000 9000 \
        --prefill http://127.0.0.1:30001 9001 \
        --prefill http://127.0.0.1:30002 9002 \
        --prefill http://127.0.0.1:30003 9003 \
        --decode http://127.0.0.1:31000 \
        --decode http://127.0.0.1:31001 \
        --prefill-policy "$p_policy" \
        --decode-policy "$d_policy" \
        --host 127.0.0.1 \
        --port "$port" \
        --log-level warn &
    
    # 等待启动
    echo "Waiting for gateway..."
    for i in $(seq 1 15); do
        if curl -sf "http://127.0.0.1:$port/v1/models" > /dev/null 2>&1; then
            echo "Gateway ready"
            break
        fi
        if [ $i -eq 15 ]; then
            echo "ERROR: Gateway failed to start"
            fail=$((fail + 1))
            continue 2
        fi
        sleep 1
    done
    
    # 运行 benchmark
    cd "$SCRIPT_DIR"
    python3 -m sglang.bench_serving \
        --backend sglang-oai \
        --base-url "http://127.0.0.1:$port" \
        --dataset-path datasets/ShareGPT_V3_unfiltered_cleaned_split.json \
        --dataset-name sharegpt \
        --num-prompts 50 \
        --request-rate 5 \
        --output-file "$output_file" 2>&1 | tail -35
    
    if [ $? -eq 0 ]; then
        success=$((success + 1))
        echo "SUCCESS: $p_policy + $d_policy"
    else
        fail=$((fail + 1))
        echo "FAILED: $p_policy + $d_policy"
    fi
    
    echo "Result saved to: $output_file"
    echo "Progress: $((success + fail)) / 19 (Success: $success, Failed: $fail)"
done

echo ""
echo "============================================================"
echo "All tests complete!"
echo "============================================================"
echo "Successful: $success / 19"
echo "Failed: $fail"
echo "Results directory: $RESULTS_DIR"
echo ""
echo "To generate HTML report:"
echo "  cd $SCRIPT_DIR"
echo "  python3 generate-benchmark-report.py"
