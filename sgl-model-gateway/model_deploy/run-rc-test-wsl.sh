#!/bin/bash
# RequestClassification test - WSL native version
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STRATEGY="request_classification"

mkdir -p "$RESULTS_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}RequestClassification PD Test (WSL Native)${NC}"
echo -e "${BLUE}Date: $(date)${NC}"
echo -e "${BLUE}========================================${NC}"

# Step 1: Start PD environment
echo -e "\n${YELLOW}Starting PD Environment...${NC}"
cd "$SCRIPT_DIR"
bash start-multi-pd.sh

echo -e "\n${GREEN}PD Environment ready!${NC}"

# Step 2: Start Gateway
echo -e "\n${YELLOW}Starting Gateway with $STRATEGY...${NC}"
cd /mnt/e/dev/sglang/sgl-model-gateway

./target/debug/sgl-model-gateway \
    --pd-disaggregation \
    --prefill http://127.0.0.1:30000 9000 \
    --prefill http://127.0.0.1:30001 9001 \
    --decode http://127.0.0.1:30010 \
    --decode http://127.0.0.1:30011 \
    --host 127.0.0.1 \
    --port 3000 \
    --policy $STRATEGY \
    --log-level info \
    > "/tmp/sgl-gateway-${STRATEGY}-${TIMESTAMP}.log" 2>&1 &

GATEWAY_PID=$!

# Wait for Gateway
echo "Waiting for Gateway..."
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:3000/health >/dev/null 2>&1; then
        echo -e "${GREEN}Gateway ready!${NC}"
        break
    fi
    sleep 1
done

sleep 5  # Wait for worker discovery

# Step 3: Send test requests
echo -e "\n${YELLOW}Sending test requests...${NC}"

# Short request
echo -e "${CYAN}Short request...${NC}"
START_NS=$(date +%s%N)
curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen2.5-0.5b-instruct","messages":[{"role":"user","content":"Say hello"}],"max_tokens":10}' \
    -o "$RESULTS_DIR/${STRATEGY}_short_${TIMESTAMP}.json" \
    --max-time 120
END_NS=$(date +%s%N)
LATENCY=$(( (END_NS - START_NS) / 1000000 ))
echo -e "${GREEN}Short done: ${LATENCY}ms${NC}"
sleep 2

# Medium request
echo -e "${CYAN}Medium request...${NC}"
START_NS=$(date +%s%N)
curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen2.5-0.5b-instruct","messages":[{"role":"user","content":"What is the difference between CPU, GPU and TPU? Please explain in detail."}],"max_tokens":200}' \
    -o "$RESULTS_DIR/${STRATEGY}_medium_${TIMESTAMP}.json" \
    --max-time 120
END_NS=$(date +%s%N)
LATENCY=$(( (END_NS - START_NS) / 1000000 ))
echo -e "${GREEN}Medium done: ${LATENCY}ms${NC}"
sleep 2

# Long request
echo -e "${CYAN}Long request...${NC}"
START_NS=$(date +%s%N)
curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"model":"qwen2.5-0.5b-instruct","messages":[{"role":"user","content":"I need to build a distributed machine learning system for training large-scale models. The system should support data parallelism, model parallelism, and pipeline parallelism. Please provide a comprehensive guide covering: 1) Architecture design principles 2) Communication optimization techniques 3) Fault tolerance mechanisms 4) Performance monitoring and debugging tools 5) Best practices for production deployment. Please include code examples and explain the tradeoffs between different approaches."}],"max_tokens":500}' \
    -o "$RESULTS_DIR/${STRATEGY}_long_${TIMESTAMP}.json" \
    --max-time 120
END_NS=$(date +%s%N)
LATENCY=$(( (END_NS - START_NS) / 1000000 ))
echo -e "${GREEN}Long done: ${LATENCY}ms${NC}"

# Step 4: Show results
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Results${NC}"
echo -e "${BLUE}========================================${NC}"

for f in short medium long; do
    RESULT_FILE="$RESULTS_DIR/${STRATEGY}_${f}_${TIMESTAMP}.json"
    if [ -f "$RESULT_FILE" ]; then
        echo -e "\n${GREEN}${f} response:${NC}"
        python3 -c "
import json
with open('$RESULT_FILE') as f:
    data = json.load(f)
    usage = data.get('usage', {})
    print(f\"  HTTP 200 | Tokens: prompt={usage.get('prompt_tokens', 0)}, completion={usage.get('completion_tokens', 0)}, total={usage.get('total_tokens', 0)}\")
    print(f\"  Content preview: {data['choices'][0]['message']['content'][:100]}...\")
" 2>/dev/null || echo "  Failed to parse"
    else
        echo -e "\n${RED}${f}: No result file${NC}"
    fi
done

# Cleanup
echo -e "\n${YELLOW}Cleaning up...${NC}"
kill $GATEWAY_PID 2>/dev/null || killall -9 sgl-model-gateway 2>/dev/null || true
killall -9 python3 2>/dev/null || true

echo -e "\n${GREEN}Test complete!${NC}"
