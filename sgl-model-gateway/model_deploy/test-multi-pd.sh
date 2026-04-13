#!/bin/bash
# Multi-PD Test Script - Tests all scheduling policies
# Tests: round_robin, cache_aware, random

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

GATEWAY_URL="http://127.0.0.1:3000"
MODEL_NAME="qwen2.5-0.5b-instruct"
RESULTS_FILE="/mnt/e/dev/sglang/sgl-model-gateway/model_deploy/multi-pd-results.md"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Multi-PD Policy Tests${NC}"
echo -e "${BLUE}========================================${NC}"

# Initialize results file
cat > "$RESULTS_FILE" << 'HEADER'
# Multi-PD 测试结果

## 测试环境
- **模型**: Qwen2.5-0.5B-Instruct
- **Prefill实例**: 2 (端口 30000, 30001)
- **Decode实例**: 2 (端口 30010, 30011)
- **Gateway端口**: 3000
- **GPU**: RTX 4070 Ti SUPER (16GB)

---

HEADER

# Function to run tests for a policy
test_policy() {
    local policy=$1
    echo -e "\n${CYAN}========================================${NC}"
    echo -e "${CYAN}Testing Policy: $policy${NC}"
    echo -e "${CYAN}========================================${NC}"

    # Start gateway with policy
    bash /mnt/e/dev/sglang/sgl-model-gateway/model_deploy/start-gateway-multi.sh $policy

    sleep 2

    echo -e "\n${YELLOW}[Test 1] Simple Request${NC}"
    local resp1=$(curl -s -X POST $GATEWAY_URL/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$MODEL_NAME\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 30}")
    local content1=$(echo "$resp1" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "ERROR")
    local tokens1=$(echo "$resp1" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"prompt={d['usage']['prompt_tokens']}, completion={d['usage']['completion_tokens']}\")" 2>/dev/null || echo "N/A")
    echo "Response: $content1"
    echo "Tokens: $tokens1"

    echo -e "\n${YELLOW}[Test 2] Chinese Request${NC}"
    local resp2=$(curl -s -X POST $GATEWAY_URL/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$MODEL_NAME\", \"messages\": [{\"role\": \"user\", \"content\": \"你好，请用一句话介绍自己\"}], \"max_tokens\": 50}")
    local content2=$(echo "$resp2" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "ERROR")
    echo "Response: $content2"

    echo -e "\n${YELLOW}[Test 3] Concurrent Requests (5)${NC}"
    local start_time=$(date +%s%N)
    for i in 1 2 3 4 5; do
        curl -s -X POST $GATEWAY_URL/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"$MODEL_NAME\", \"messages\": [{\"role\": \"user\", \"content\": \"Request number $i\"}], \"max_tokens\": 20}" \
            > /tmp/concurrent_$policy_$i.json &
    done
    wait
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))

    local success_count=0
    for i in 1 2 3 4 5; do
        if python3 -c "import json; json.load(open('/tmp/concurrent_$policy_$i.json'))" 2>/dev/null; then
            success_count=$((success_count + 1))
        fi
        rm -f /tmp/concurrent_$policy_$i.json
    done
    echo "Concurrent results: $success_count/5 succeeded in ${duration}ms"

    # Write results to file
    cat >> "$RESULTS_FILE" << EOF
## 策略: $policy

| 测试项 | 结果 |
|--------|------|
| 简单请求 | $content1 |
| 中文请求 | $content2 |
| 并发(5) | $success_count/5 成功, 耗时${duration}ms |
| Token使用 | $tokens1 |

EOF

    # Stop gateway
    killall sgl-model-gateway 2>/dev/null || true
    sleep 2
}

# Run tests for each policy
test_policy "round_robin"
sleep 3
test_policy "cache_aware"
sleep 3
test_policy "random"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All tests completed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Results saved to: $RESULTS_FILE"
echo -e "\n${YELLOW}Summary:${NC}"
cat "$RESULTS_FILE"
