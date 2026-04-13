#!/bin/bash
# Gateway starter for multi-PD environment
# Usage: start-gateway-multi.sh <policy>

set -e

POLICY=${1:-"round_robin"}
GATEWAY_PORT=3000

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Starting Gateway - Policy: $POLICY${NC}"
echo -e "${BLUE}========================================${NC}"

# Kill old gateway
(killall -9 sgl-model-gateway 2>/dev/null) || true
sleep 1

cd /mnt/e/dev/sglang/sgl-model-gateway

echo -e "\n${YELLOW}Starting Gateway on port $GATEWAY_PORT...${NC}"
setsid ./target/debug/sgl-model-gateway \
    --pd-disaggregation \
    --prefill http://127.0.0.1:30000 9000 \
    --prefill http://127.0.0.1:30001 9001 \
    --decode http://127.0.0.1:30010 \
    --decode http://127.0.0.1:30011 \
    --host 127.0.0.1 \
    --port $GATEWAY_PORT \
    --policy $POLICY \
    --log-level info \
    > /tmp/sgl-gateway-$POLICY.log 2>&1 < /dev/null &

echo "Waiting for Gateway..."
for i in {1..30}; do
    if curl -sf http://127.0.0.1:$GATEWAY_PORT/health >/dev/null 2>&1; then
        echo -e "${GREEN}Gateway ready! Policy: $POLICY${NC}"
        echo -e "${BLUE}URL: http://127.0.0.1:$GATEWAY_PORT${NC}"
        exit 0
    fi
    sleep 1
done

echo -e "${RED}Gateway timeout!${NC}"
tail -30 /tmp/sgl-gateway-$POLICY.log
exit 1
