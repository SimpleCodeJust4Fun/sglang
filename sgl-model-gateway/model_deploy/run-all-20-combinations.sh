#!/bin/bash
# 批量测试 20 种核心策略组合
# 用法: ./run-all-20-combinations.sh
# 
# 依赖: 
#   1. Workers 必须已启动 (./start-6workers-stable.sh)
#   2. 数据集存在 (datasets/ShareGPT_V3_unfiltered_cleaned_split.json)
#   3. Python 环境 (~/qwen_env)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"

# 20 种核心策略组合 (格式: prefill_policy:decode_policy:port)
# 注意: Gateway 的 bootstrap 端口是 4 位数 (9000-9003)
COMBINATIONS=(
    "cache_aware:round_robin:8000"
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

echo "============================================================"
echo "SGLang SLO 测试 - 20 种核心策略组合"
echo "============================================================"
echo ""
echo "Workers: 4 Prefill + 2 Decode (6 total)"
echo "Prefill ports: 30000-30003 (bootstrap: 9000-9003)"
echo "Decode ports:  31000-31001"
echo "Dataset: ShareGPT V3"
echo "Prompts: 50 per strategy"
echo "Request Rate: 5 req/s"
echo "Total combinations: ${#COMBINATIONS[@]}"
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
for port in 30000 30001 30002 30003 31000 31001; do
    if curl -sf "http://127.0.0.1:$port/health" > /dev/null 2>&1; then
        WORKER_COUNT=$((WORKER_COUNT + 1))
    fi
done

if [ $WORKER_COUNT -lt 6 ]; then
    echo "ERROR: Only $WORKER_COUNT / 6 workers are running!"
    echo "Please start workers first:"
    echo "  cd $SCRIPT_DIR"
    echo "  ./start-6workers-stable.sh"
    exit 1
fi
echo "All 6 workers are healthy ✓"
echo ""

# 主循环
success=0
fail=0

for combo in "${COMBINATIONS[@]}"; do
    p_policy=$(echo $combo | cut -d: -f1)
    d_policy=$(echo $combo | cut -d: -f2)
    port=$(echo $combo | cut -d: -f3)
    
    echo ""
    echo "============================================================"
    echo ">>> Testing: Prefill=$p_policy, Decode=$d_policy (port $port)"
    echo "============================================================"
    
    if "$SCRIPT_DIR/run-single-test.sh" "$p_policy" "$d_policy" "$port"; then
        success=$((success + 1))
        echo ">>> SUCCESS: $p_policy + $d_policy"
    else
        fail=$((fail + 1))
        echo ">>> FAILED: $p_policy + $d_policy"
    fi
    
    echo ""
    echo "Progress: $((success + fail)) / ${#COMBINATIONS[@]} (Success: $success, Failed: $fail)"
    echo ""
done

echo ""
echo "============================================================"
echo "All Tests Complete!"
echo "============================================================"
echo "Successful: $success / ${#COMBINATIONS[@]}"
echo "Failed: $fail"
echo ""
echo "Results directory: $RESULTS_DIR"
echo ""
echo "To generate HTML report:"
echo "  cd $SCRIPT_DIR"
echo "  python3 generate-benchmark-report.py"
echo ""
