#!/bin/bash
# PD Test with Qwen2.5-1.5B-Instruct-AWQ model
# This smaller model fits better in 16GB VRAM for PD disaggregation testing

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-1___5B-Instruct-AWQ"
PREFILL_PORT=30000
DECODE_PORT=30001
BOOTSTRAP_PORT=9000
MEM_FRACTION=0.35

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}PD Test with Qwen2.5-1.5B-AWQ${NC}"
echo -e "${BLUE}========================================${NC}"

# Activate env
source ~/qwen_env/bin/activate

# Kill old processes
echo -e "\n${YELLOW}Cleaning old processes...${NC}"
pkill -f "sglang.launch_server" 2>/dev/null || true
sleep 2

# Check GPU
echo -e "\n${YELLOW}GPU Memory before start:${NC}"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader

# Start Prefill
echo -e "\n${YELLOW}[1/2] Starting Prefill Server on port $PREFILL_PORT...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $PREFILL_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd prefill \
    --disaggregation-bootstrap-port $BOOTSTRAP_PORT \
    --host 127.0.0.1 \
    --context-length 8192 \
    > /tmp/sglang-prefill.log 2>&1 < /dev/null &

echo "Waiting for Prefill Server..."
for i in {1..60}; do
    if curl -sf http://127.0.0.1:$PREFILL_PORT/health >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Prefill Server ready!${NC}"
        break
    fi
    echo -n "."
    sleep 2
done

# Start Decode
echo -e "\n${YELLOW}[2/2] Starting Decode Server on port $DECODE_PORT...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $DECODE_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd decode \
    --host 127.0.0.1 \
    --context-length 8192 \
    > /tmp/sglang-decode.log 2>&1 < /dev/null &

echo "Waiting for Decode Server..."
for i in {1..60}; do
    if curl -sf http://127.0.0.1:$DECODE_PORT/health >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Decode Server ready!${NC}"
        break
    fi
    echo -n "."
    sleep 2
done

# Show GPU status
echo -e "\n${YELLOW}GPU Memory after start:${NC}"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader

echo -e "\n${YELLOW}GPU Processes:${NC}"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Both servers ready!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Prefill: http://127.0.0.1:$PREFILL_PORT"
echo -e "Decode:  http://127.0.0.1:$DECODE_PORT"
echo -e "Bootstrap: $BOOTSTRAP_PORT"
