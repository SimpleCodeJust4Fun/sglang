#!/bin/bash
# Multi-PD Test Environment - 2 Prefill + 2 Decode
# Uses Qwen2.5-0.5B-Instruct model (~1GB)
# Target: 16GB VRAM can fit 4 instances

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct"
MEM_FRACTION=0.15
CONTEXT_LENGTH=2048

# Prefill servers
PREFILL_1_PORT=30000
PREFILL_2_PORT=30001
BOOTSTRAP_1_PORT=9000
BOOTSTRAP_2_PORT=9001

# Decode servers
DECODE_1_PORT=30010
DECODE_2_PORT=30011

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Multi-PD Environment: 2P + 2D${NC}"
echo -e "${BLUE}Model: Qwen2.5-0.5B-Instruct${NC}"
echo -e "${BLUE}========================================${NC}"

# Activate env
source ~/qwen_env/bin/activate

# Kill old processes (use subshell to avoid self-kill)
echo -e "\n${YELLOW}Cleaning old processes...${NC}"
(killall -9 python3 2>/dev/null; killall -9 sgl-model-gateway 2>/dev/null) || true
sleep 3

# Check GPU
echo -e "\n${YELLOW}GPU Memory before start:${NC}"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader

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
    tail -30 /tmp/sglang-$name.log 2>/dev/null | grep -E "(error|Error|fired|exception|avail)" || true
    return 1
}

# Start Prefill 1
echo -e "\n${YELLOW}[1/4] Starting Prefill-1 (port $PREFILL_1_PORT)...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $PREFILL_1_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd prefill \
    --disaggregation-bootstrap-port $BOOTSTRAP_1_PORT \
    --host 127.0.0.1 \
    --context-length $CONTEXT_LENGTH \
    --log-level debug \
    --log-requests \
    --log-requests-level 2 \
    > /tmp/sglang-prefill-1.log 2>&1 < /dev/null &

# Start Prefill 2
echo -e "${YELLOW}[2/4] Starting Prefill-2 (port $PREFILL_2_PORT)...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $PREFILL_2_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd prefill \
    --disaggregation-bootstrap-port $BOOTSTRAP_2_PORT \
    --host 127.0.0.1 \
    --context-length $CONTEXT_LENGTH \
    --log-level debug \
    --log-requests \
    --log-requests-level 2 \
    > /tmp/sglang-prefill-2.log 2>&1 < /dev/null &

# Wait for Prefills
sleep 5
echo "Waiting for Prefill servers..."
wait_for_server $PREFILL_1_PORT "prefill-1"
wait_for_server $PREFILL_2_PORT "prefill-2"

# Start Decode 1
echo -e "\n${YELLOW}[3/4] Starting Decode-1 (port $DECODE_1_PORT)...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $DECODE_1_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd decode \
    --host 127.0.0.1 \
    --context-length $CONTEXT_LENGTH \
    --log-level debug \
    --log-requests \
    --log-requests-level 2 \
    > /tmp/sglang-decode-1.log 2>&1 < /dev/null &

# Start Decode 2
echo -e "${YELLOW}[4/4] Starting Decode-2 (port $DECODE_2_PORT)...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $DECODE_2_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd decode \
    --host 127.0.0.1 \
    --context-length $CONTEXT_LENGTH \
    --log-level debug \
    --log-requests \
    --log-requests-level 2 \
    > /tmp/sglang-decode-2.log 2>&1 < /dev/null &

# Wait for Decodes
echo "Waiting for Decode servers..."
wait_for_server $DECODE_1_PORT "decode-1"
wait_for_server $DECODE_2_PORT "decode-2"

# Show GPU status
echo -e "\n${YELLOW}GPU Memory after start:${NC}"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader

echo -e "\n${YELLOW}GPU Processes:${NC}"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All servers ready!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Prefill-1:${NC} http://127.0.0.1:$PREFILL_1_PORT (bootstrap: $BOOTSTRAP_1_PORT)"
echo -e "${BLUE}Prefill-2:${NC} http://127.0.0.1:$PREFILL_2_PORT (bootstrap: $BOOTSTRAP_2_PORT)"
echo -e "${BLUE}Decode-1:${NC}  http://127.0.0.1:$DECODE_1_PORT"
echo -e "${BLUE}Decode-2:${NC}  http://127.0.0.1:$DECODE_2_PORT"
echo ""
echo -e "${YELLOW}Next step - Start Gateway:${NC}"
echo "  cd /mnt/e/dev/sglang/sgl-model-gateway"
echo "  ./target/debug/sgl-model-gateway \\"
echo "    --pd-disaggregation \\"
echo "    --prefill http://127.0.0.1:$PREFILL_1_PORT $BOOTSTRAP_1_PORT \\"
echo "    --prefill http://127.0.0.1:$PREFILL_2_PORT $BOOTSTRAP_2_PORT \\"
echo "    --decode http://127.0.0.1:$DECODE_1_PORT \\"
echo "    --decode http://127.0.0.1:$DECODE_2_PORT \\"
echo "    --host 127.0.0.1 --port 3000 \\"
echo "    --policy round_robin"
