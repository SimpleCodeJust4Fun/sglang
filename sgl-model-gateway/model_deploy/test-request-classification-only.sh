#!/bin/bash
# Test script for RequestClassification strategy only

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
STRATEGY="request_classification"

mkdir -p "$RESULTS_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Testing RequestClassification Strategy${NC}"
echo -e "${BLUE}Date: $(date)${NC}"
echo -e "${BLUE}========================================${NC}"

# Function to wait for server
wait_for_server() {
    local port=$1
    local name=$2
    local max_wait=$3
    for i in $(seq 1 $max_wait); do
        if curl -sf http://127.0.0.1:$port/health >/dev/null 2>&1; then
            echo -e "${GREEN}✓ $name ready (port $port)${NC}"
            return 0
        fi
        if [ $((i % 10)) -eq 0 ]; then
            echo -n "."
        fi
        sleep 1
    done
    echo -e "${RED}✗ $name timeout${NC}"
    return 1
}

# Step 1: Start PD Environment
echo -e "\n${YELLOW}Step 1: Starting PD Environment (2P + 2D)...${NC}"
cd "$SCRIPT_DIR"
bash start-multi-pd.sh

if [ $? -ne 0 ]; then
    echo -e "${RED}Failed to start PD environment!${NC}"
    exit 1
fi

echo -e "\n${GREEN}PD Environment ready!${NC}"

# Step 2: Wait for all servers
echo -e "\n${YELLOW}Waiting for all servers to be ready...${NC}"
wait_for_server 30000 "Prefill-0" 80
wait_for_server 30001 "Prefill-1" 80
wait_for_server 30010 "Decode-0" 80
wait_for_server 30011 "Decode-1" 80
sleep 5

# Step 3: Start Gateway
echo -e "\n${YELLOW}Starting Gateway with policy: $STRATEGY${NC}"
cd /mnt/e/dev/sglang/sgl-model-gateway

LOG_FILE="/tmp/sgl-gateway-${STRATEGY}.log"

setsid ./target/debug/sgl-model-gateway \
    --pd-disaggregation \
    --prefill http://127.0.0.1:30000 9000 \
    --prefill http://127.0.0.1:30001 9001 \
    --decode http://127.0.0.1:30010 \
    --decode http://127.0.0.1:30011 \
    --host 127.0.0.1 \
    --port $GATEWAY_PORT \
    --policy $STRATEGY \
    --log-level debug \
    > "$LOG_FILE" 2>&1 < /dev/null &

# Wait for Gateway
echo "Waiting for Gateway..."
wait_for_server $GATEWAY_PORT "Gateway" 40

# Wait for worker discovery
echo "Waiting for worker discovery..."
sleep 5

# Step 4: Send test requests
echo -e "\n${YELLOW}Running test requests...${NC}"

# Short request
echo -e "  ${CYAN}Sending short request...${NC}"
START_TIME=$(date +%s%N)
HTTP_CODE=$(curl -s -o "$RESULTS_DIR/${STRATEGY}_short_${TIMESTAMP}.json" -w "%{http_code}" \
    -X POST "$GATEWAY_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@$TEST_REQUESTS_DIR/short.json")
END_TIME=$(date +%s%N)
LATENCY=$(( (END_TIME - START_TIME) / 1000000 ))

if [ "$HTTP_CODE" = "200" ]; then
    TOKENS=$(python3 -c "
import json
with open('$RESULTS_DIR/${STRATEGY}_short_${TIMESTAMP}.json') as f:
    data = json.load(f)
    usage = data.get('usage', {})
    print(f\"prompt={usage.get('prompt_tokens', 0)}, completion={usage.get('completion_tokens', 0)}, total={usage.get('total_tokens', 0)}\")
" 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✓ Short Success${NC} | HTTP $HTTP_CODE | Latency: ${LATENCY}ms | Tokens: $TOKENS"
fi

sleep 2

# Medium request
echo -e "  ${CYAN}Sending medium request...${NC}"
START_TIME=$(date +%s%N)
HTTP_CODE=$(curl -s -o "$RESULTS_DIR/${STRATEGY}_medium_${TIMESTAMP}.json" -w "%{http_code}" \
    -X POST "$GATEWAY_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@$TEST_REQUESTS_DIR/medium.json")
END_TIME=$(date +%s%N)
LATENCY=$(( (END_TIME - START_TIME) / 1000000 ))

if [ "$HTTP_CODE" = "200" ]; then
    TOKENS=$(python3 -c "
import json
with open('$RESULTS_DIR/${STRATEGY}_medium_${TIMESTAMP}.json') as f:
    data = json.load(f)
    usage = data.get('usage', {})
    print(f\"prompt={usage.get('prompt_tokens', 0)}, completion={usage.get('completion_tokens', 0)}, total={usage.get('total_tokens', 0)}\")
" 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✓ Medium Success${NC} | HTTP $HTTP_CODE | Latency: ${LATENCY}ms | Tokens: $TOKENS"
fi

sleep 2

# Long request
echo -e "  ${CYAN}Sending long request...${NC}"
START_TIME=$(date +%s%N)
HTTP_CODE=$(curl -s -o "$RESULTS_DIR/${STRATEGY}_long_${TIMESTAMP}.json" -w "%{http_code}" \
    -X POST "$GATEWAY_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "@$TEST_REQUESTS_DIR/long.json")
END_TIME=$(date +%s%N)
LATENCY=$(( (END_TIME - START_TIME) / 1000000 ))

if [ "$HTTP_CODE" = "200" ]; then
    TOKENS=$(python3 -c "
import json
with open('$RESULTS_DIR/${STRATEGY}_long_${TIMESTAMP}.json') as f:
    data = json.load(f)
    usage = data.get('usage', {})
    print(f\"prompt={usage.get('prompt_tokens', 0)}, completion={usage.get('completion_tokens', 0)}, total={usage.get('total_tokens', 0)}\")
" 2>/dev/null || echo "unknown")
    echo -e "  ${GREEN}✓ Long Success${NC} | HTTP $HTTP_CODE | Latency: ${LATENCY}ms | Tokens: $TOKENS"
fi

sleep 2

# Step 5: Collect results
echo -e "\n${YELLOW}Collecting results...${NC}"
cp "$LOG_FILE" "$RESULTS_DIR/gateway_${STRATEGY}_${TIMESTAMP}.log"

echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}RequestClassification Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${CYAN}Results files:${NC}"
ls -lh "$RESULTS_DIR/${STRATEGY}_"* 2>/dev/null

echo -e "\n${CYAN}Gateway Log:${NC}"
ls -lh "$RESULTS_DIR/gateway_${STRATEGY}_${TIMESTAMP}.log"

# Step 6: Stop Gateway
echo -e "\n${YELLOW}Stopping Gateway...${NC}"
killall -9 sgl-model-gateway 2>/dev/null || true
sleep 5

echo -e "\n${YELLOW}Stopping PD Environment...${NC}"
(killall -9 python3 2>/dev/null) || true

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}RequestClassification test complete!${NC}"
echo -e "${GREEN}========================================${NC}"
