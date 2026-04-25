#!/bin/bash
# Test script for new heterogeneous GPU scheduling strategies
# Tests: RequestSizeBucket, PerformanceAware, RequestClassification
# Architecture: 2P + 2D PD separation

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

GATEWAY_PORT=3000
GATEWAY_URL="http://127.0.0.1:$GATEWAY_PORT"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_REQUESTS_DIR="$SCRIPT_DIR/test-requests"
RESULTS_DIR="$SCRIPT_DIR/test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$RESULTS_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}New Strategy PD Separation Test${NC}"
echo -e "${BLUE}Date: $(date)${NC}"
echo -e "${BLUE}========================================${NC}"

# Function to wait for server
wait_for_server() {
    local port=$1
    local name=$2
    local max_wait=80
    for i in $(seq 1 $max_wait); do
        if curl -sf http://127.0.0.1:$port/health >/dev/null 2>&1; then
            echo -e "${GREEN}✓ $name ready (port $port)${NC}"
            return 0
        fi
        if [ $((i % 10)) -eq 0 ]; then
            echo -n "."
        fi
        sleep 2
    done
    echo -e "${RED}✗ $name timeout${NC}"
    return 1
}

# Function to send test request and measure latency
send_test_request() {
    local request_file=$1
    local strategy=$2
    local request_type=$3
    local result_file="$RESULTS_DIR/${strategy}_${request_type}_${TIMESTAMP}.json"

    echo -e "  ${CYAN}Sending $request_type request...${NC}"

    local start_time=$(date +%s%N)
    local http_code=$(curl -s -o "$result_file" -w "%{http_code}" \
        -X POST "$GATEWAY_URL/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "@$request_file")
    local end_time=$(date +%s%N)

    local latency_ms=$(( (end_time - start_time) / 1000000 ))

    if [ "$http_code" = "200" ]; then
        local tokens=$(python3 -c "
import json
with open('$result_file') as f:
    data = json.load(f)
    usage = data.get('usage', {})
    print(f\"prompt={usage.get('prompt_tokens', 0)}, completion={usage.get('completion_tokens', 0)}, total={usage.get('total_tokens', 0)}\")
" 2>/dev/null || echo "unknown")

        echo -e "  ${GREEN}✓ Success${NC} | HTTP $http_code | Latency: ${latency_ms}ms | Tokens: $tokens"
        echo "$strategy,$request_type,$latency_ms,$http_code,$tokens" >> "$RESULTS_DIR/results_${TIMESTAMP}.csv"
    else
        echo -e "  ${RED}✗ Failed${NC} | HTTP $http_code | Latency: ${latency_ms}ms"
        echo "$strategy,$request_type,$latency_ms,$http_code,error" >> "$RESULTS_DIR/results_${TIMESTAMP}.csv"
    fi
}

# Function to test a strategy
test_strategy() {
    local strategy=$1
    local log_file="/tmp/sgl-gateway-${strategy}.log"

    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}Testing Strategy: $strategy${NC}"
    echo -e "${BLUE}========================================${NC}"

    # Start Gateway
    echo -e "\n${YELLOW}Starting Gateway with policy: $strategy${NC}"
    cd /mnt/e/dev/sglang/sgl-model-gateway

    setsid ./target/debug/sgl-model-gateway \
        --pd-disaggregation \
        --prefill http://127.0.0.1:30000 9000 \
        --prefill http://127.0.0.1:30001 9001 \
        --decode http://127.0.0.1:30010 \
        --decode http://127.0.0.1:30011 \
        --host 127.0.0.1 \
        --port $GATEWAY_PORT \
        --policy $strategy \
        --log-level debug \
        > "$log_file" 2>&1 < /dev/null &

    # Wait for Gateway
    echo "Waiting for Gateway..."
    local ready=false
    for i in {1..30}; do
        if curl -sf "$GATEWAY_URL/health" >/dev/null 2>&1; then
            echo -e "${GREEN}Gateway ready!${NC}"
            ready=true
            break
        fi
        sleep 1
    done

    if [ "$ready" = false ]; then
        echo -e "${RED}Gateway failed to start!${NC}"
        tail -50 "$log_file"
        return 1
    fi

    # Wait for workers to be discovered
    echo "Waiting for worker discovery..."
    sleep 5

    # Send test requests
    echo -e "\n${YELLOW}Running test requests...${NC}"

    # Short request
    send_test_request "$TEST_REQUESTS_DIR/short.json" "$strategy" "short"

    # Wait between requests
    sleep 2

    # Medium request
    send_test_request "$TEST_REQUESTS_DIR/medium.json" "$strategy" "medium"

    # Wait between requests
    sleep 2

    # Long request
    send_test_request "$TEST_REQUESTS_DIR/long.json" "$strategy" "long"

    # Wait for metrics to be recorded
    sleep 2

    # Collect gateway logs
    echo -e "\n${YELLOW}Collecting gateway logs...${NC}"
    cp "$log_file" "$RESULTS_DIR/gateway_${strategy}_${TIMESTAMP}.log"

    # Stop Gateway
    echo -e "\n${YELLOW}Stopping Gateway...${NC}"
    killall -9 sgl-model-gateway 2>/dev/null || true
    sleep 2

    echo -e "${GREEN}Strategy $strategy test complete!${NC}"
}

# Main execution
echo -e "\n${YELLOW}Step 1: Starting PD Environment (2P + 2D)...${NC}"

# Source the multi-PD starter (but don't wait for it to finish)
cd "$SCRIPT_DIR"
bash start-multi-pd.sh

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to start PD environment!${NC}"
    exit 1
fi

echo -e "\n${GREEN}PD Environment ready!${NC}"

# Initialize results CSV
echo "strategy,request_type,latency_ms,http_code,tokens" > "$RESULTS_DIR/results_${TIMESTAMP}.csv"

# Test each strategy
echo -e "\n${YELLOW}Step 2: Testing New Strategies...${NC}"

# Strategy 1: RequestSizeBucket
test_strategy "request_size_bucket"

# Strategy 2: PerformanceAware
test_strategy "performance_aware"

# Strategy 3: RequestClassification
test_strategy "request_classification"

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${CYAN}Results CSV:${NC} $RESULTS_DIR/results_${TIMESTAMP}.csv"
echo -e "${CYAN}Log files:${NC} $RESULTS_DIR/"

echo -e "\n${YELLOW}Results:${NC}"
cat "$RESULTS_DIR/results_${TIMESTAMP}.csv"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All tests complete!${NC}"
echo -e "${GREEN}========================================${NC}"

# Cleanup PD environment
echo -e "\n${YELLOW}Cleaning up PD environment...${NC}"
(killall -9 python3 2>/dev/null; killall -9 sgl-model-gateway 2>/dev/null) || true

echo -e "${GREEN}Done!${NC}"
