#!/bin/bash
# 单个策略组合测试脚本
# 用法: ./run-single-test.sh <prefill_policy> <decode_policy> [port]
# 示例: ./run-single-test.sh cache_aware round_robin 8000

set -e

P_POLICY=${1:-"cache_aware"}
D_POLICY=${2:-"round_robin"}
PORT=${3:-8000}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/benchmark-results"
DATASET_PATH="$SCRIPT_DIR/datasets/ShareGPT_V3_unfiltered_cleaned_split.json"
GATEWAY_BIN="/mnt/e/dev/sglang/sgl-model-gateway/target/release/sgl-model-gateway"

OUTPUT_FILE="$RESULTS_DIR/bench_${P_POLICY}_${D_POLICY}.jsonl"

echo "============================================================"
echo "SGLang SLO 测试 - 单个策略组合"
echo "============================================================"
echo "Prefill Policy: $P_POLICY"
echo "Decode Policy:  $D_POLICY"
echo "Gateway Port:   $PORT"
echo "Output File:    $OUTPUT_FILE"
echo "============================================================"
echo ""

cd /mnt/e/dev/sglang/sgl-model-gateway

# 停止旧 Gateway
echo "Stopping old gateway..."
pkill -f 'sgl-model-gateway' 2>/dev/null || true
sleep 3

# 启动新 Gateway (注意: bootstrap 端口是 4 位数: 9000-9003)
echo "Starting gateway..."
$GATEWAY_BIN \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --prefill http://127.0.0.1:30002 9002 \
  --prefill http://127.0.0.1:30003 9003 \
  --decode http://127.0.0.1:31000 \
  --decode http://127.0.0.1:31001 \
  --prefill-policy $P_POLICY \
  --decode-policy $D_POLICY \
  --host 127.0.0.1 \
  --port $PORT \
  --log-level warn > /tmp/sgl-gateway-${P_POLICY}-${D_POLICY}.log 2>&1 &

# 等待启动
echo "Waiting for gateway to start..."
for i in {1..15}; do
    if curl -sf "http://127.0.0.1:$PORT/v1/models" > /dev/null 2>&1; then
        echo "Gateway ready ✓"
        break
    fi
    if [ $i -eq 15 ]; then
        echo "ERROR: Gateway failed to start after 15 seconds"
        echo "Check log: /tmp/sgl-gateway-${P_POLICY}-${D_POLICY}.log"
        tail -20 /tmp/sgl-gateway-${P_POLICY}-${D_POLICY}.log
        exit 1
    fi
    sleep 1
done

# 运行 Benchmark
echo ""
echo "Running benchmark (50 prompts @ 5 req/s)..."
source ~/qwen_env/bin/activate
cd "$SCRIPT_DIR"

python3 -m sglang.bench_serving \
    --backend sglang-oai \
    --base-url "http://127.0.0.1:$PORT" \
    --dataset-path "$DATASET_PATH" \
    --dataset-name sharegpt \
    --num-prompts 50 \
    --request-rate 5 \
    --output-file "$OUTPUT_FILE" 2>&1 | tail -45

echo ""
echo "Results saved to: $OUTPUT_FILE"

# 清理 Gateway
echo "Stopping gateway..."
pkill -f 'sgl-model-gateway' 2>/dev/null || true
sleep 2

echo ""
echo "Test complete!"
