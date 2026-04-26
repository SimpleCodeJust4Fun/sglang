#!/bin/bash
# Start 7 Workers (3P+4D) with GPTQ-Int4
# This is the NEW RECORD configuration

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Start 7 Workers (3P+4D) - GPTQ-Int4${NC}"
echo -e "${BLUE}Model: Qwen2.5-0.5B-GPTQ-Int4 (450MB)${NC}"
echo -e "${BLUE}Workers: 3 Prefill + 4 Decode = 7${NC}"
echo -e "${BLUE}Scheduling Pairs: 12${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Activate environment
source ~/qwen_env/bin/activate

# Cleanup
echo -e "${YELLOW}Cleaning up old processes...${NC}"
killall -9 python3 2>/dev/null || true
sleep 2

# Check GPU
echo -e "${YELLOW}GPU before start:${NC}"
nvidia-smi --query-gpu=memory.used --format=csv,noheader

# Start Prefill workers
echo -e "\n${YELLOW}Starting Prefill workers...${NC}"
for i in 1 2 3; do
    port=$((30000 + i - 1))
    bootstrap=$((90000 + i - 1))
    echo -e "  Prefill-$i: port $port, bootstrap $bootstrap"
    
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.06 \
        --tp 1 --pd prefill \
        --disaggregation-bootstrap-port $bootstrap \
        --host 127.0.0.1 --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-gptq4-prefill-$i.log 2>&1 &
    
    sleep 3
done

# Wait for Prefill
echo -e "\n${YELLOW}Waiting for Prefill workers...${NC}"
for i in 1 2 3; do
    port=$((30000 + i - 1))
    for attempt in $(seq 1 40); do
        if curl -sf http://127.0.0.1:$port/health >/dev/null 2>&1; then
            echo -e "${GREEN}  ✓ Prefill-$i ready (port $port)${NC}"
            break
        fi
        if [ $((attempt % 10)) -eq 0 ]; then
            echo -n "."
        fi
        sleep 2
    done
done

# Start Decode workers
echo -e "\n${YELLOW}Starting Decode workers...${NC}"
for i in 1 2 3 4; do
    port=$((31000 + i - 1))
    echo -e "  Decode-$i: port $port"
    
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL" \
        --port $port \
        --mem-fraction-static 0.10 \
        --tp 1 --pd decode \
        --host 127.0.0.1 --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-gptq4-decode-$i.log 2>&1 &
    
    sleep 3
done

# Wait for Decode
echo -e "\n${YELLOW}Waiting for Decode workers...${NC}"
for i in 1 2 3 4; do
    port=$((31000 + i - 1))
    for attempt in $(seq 1 40); do
        if curl -sf http://127.0.0.1:$port/health >/dev/null 2>&1; then
            echo -e "${GREEN}  ✓ Decode-$i ready (port $port)${NC}"
            break
        fi
        if [ $((attempt % 10)) -eq 0 ]; then
            echo -n "."
        fi
        sleep 2
    done
done

# Final check
echo -e "\n${YELLOW}Final stability check (15s)...${NC}"
sleep 15

count=$(ps aux | grep sglang | grep -v grep | wc -l)
echo -e "\n${BLUE}========================================${NC}"

if [ $count -eq 7 ]; then
    echo -e "${GREEN}✓ SUCCESS! All 7 workers are running${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "\n${YELLOW}GPU after start:${NC}"
    nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
    
    echo -e "\n${GREEN}Workers:${NC}"
    echo "  Prefill-1: http://127.0.0.1:30000 (bootstrap: 90000)"
    echo "  Prefill-2: http://127.0.0.1:30001 (bootstrap: 90001)"
    echo "  Prefill-3: http://127.0.0.1:30002 (bootstrap: 90002)"
    echo "  Decode-1:  http://127.0.0.1:31000"
    echo "  Decode-2:  http://127.0.0.1:31001"
    echo "  Decode-3:  http://127.0.0.1:31002"
    echo "  Decode-4:  http://127.0.0.1:31003"
    
    echo -e "\n${YELLOW}Next: Start Gateway${NC}"
    echo "  cd /mnt/e/dev/sglang/sgl-model-gateway"
    echo "  ./target/debug/sgl-model-gateway \\"
    echo "    --pd-disaggregation \\"
    echo "    --prefill http://127.0.0.1:30000 90000 \\"
    echo "    --prefill http://127.0.0.1:30001 90001 \\"
    echo "    --prefill http://127.0.0.1:30002 90002 \\"
    echo "    --decode http://127.0.0.1:31000 \\"
    echo "    --decode http://127.0.0.1:31001 \\"
    echo "    --decode http://127.0.0.1:31002 \\"
    echo "    --decode http://127.0.0.1:31003 \\"
    echo "    --host 127.0.0.1 --port 3000 \\"
    echo "    --prefill-policy cache_aware \\"
    echo "    --decode-policy round_robin"
else
    echo -e "${RED}✗ FAILED: Only $count/7 workers survived${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "\n${YELLOW}Check logs:${NC}"
    echo "  tail -100 /tmp/sglang-gptq4-prefill-*.log"
    echo "  tail -100 /tmp/sglang-gptq4-decode-*.log"
fi
