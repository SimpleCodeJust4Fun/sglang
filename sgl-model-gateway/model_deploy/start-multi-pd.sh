#!/bin/bash
# Multi-PD Test Environment - Configurable Worker Topology
# Uses Qwen2.5-0.5B-Instruct model (~1GB)
# Target: 16GB VRAM - supports multiple configurations

set -e

# Configuration selection
CONFIG=${1:-2p2d}  # Default to 2P+2D

case "$CONFIG" in
    2p2d)
        # Original balanced config
        NUM_PREFILL=2
        NUM_DECODE=2
        PREFILL_MEM=0.10
        DECODE_MEM=0.20
        CONTEXT_LENGTH=2048
        ;;
    3p3d)
        # Recommended balanced config
        NUM_PREFILL=3
        NUM_DECODE=3
        PREFILL_MEM=0.07
        DECODE_MEM=0.12
        CONTEXT_LENGTH=2048
        ;;
    2p4d)
        # Decode-heavy for code generation
        NUM_PREFILL=2
        NUM_DECODE=4
        PREFILL_MEM=0.08
        DECODE_MEM=0.15
        CONTEXT_LENGTH=2048
        ;;
    4p2d)
        # Prefill-heavy for agent/document analysis
        NUM_PREFILL=4
        NUM_DECODE=2
        PREFILL_MEM=0.08
        DECODE_MEM=0.15
        CONTEXT_LENGTH=2048
        ;;
    3p2d)
        # Slightly prefill-heavy
        NUM_PREFILL=3
        NUM_DECODE=2
        PREFILL_MEM=0.08
        DECODE_MEM=0.18
        CONTEXT_LENGTH=2048
        ;;
    2p3d)
        # Slightly decode-heavy
        NUM_PREFILL=2
        NUM_DECODE=3
        PREFILL_MEM=0.10
        DECODE_MEM=0.15
        CONTEXT_LENGTH=2048
        ;;
    *)
        echo -e "\033[0;31mUnknown configuration: $CONFIG\033[0m"
        echo -e "\033[0;36mAvailable configurations:\033[0m"
        echo "  2p2d  - 2 Prefill + 2 Decode (Balanced, 9.6GB)"
        echo "  3p3d  - 3 Prefill + 3 Decode (Recommended, 9.0GB)"
        echo "  2p4d  - 2 Prefill + 4 Decode (Code generation, 12.2GB)"
        echo "  4p2d  - 4 Prefill + 2 Decode (Agent/Document, 10.0GB)"
        echo "  3p2d  - 3 Prefill + 2 Decode (Slightly prefill-heavy, 9.6GB)"
        echo "  2p3d  - 2 Prefill + 3 Decode (Slightly decode-heavy, 10.5GB)"
        exit 1
        ;;
esac

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Model selection
MODEL=${2:-qwen2.5}  # Default to qwen2.5

case "$MODEL" in
    qwen2.5)
        MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct"
        MODEL_DISPLAY="Qwen2.5-0.5B-Instruct"
        ;;
    qwen3)
        MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3-0___6B"
        MODEL_DISPLAY="Qwen3-0.6B-FP16"
        ;;
    *)
        echo -e "\033[0;31mUnknown model: $MODEL\033[0m"
        echo -e "\033[0;36mAvailable models:\033[0m"
        echo "  qwen2.5  - Qwen2.5-0.5B-Instruct"
        echo "  qwen3    - Qwen3-0.6B-FP16"
        exit 1
        ;;
esac

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Multi-PD Environment: ${NUM_PREFILL}P + ${NUM_DECODE}D${NC}"
echo -e "${BLUE}Model: $MODEL_DISPLAY${NC}"
echo -e "${BLUE}Prefill Mem: $(echo "$PREFILL_MEM * 16384 / 100" | bc | cut -d. -f1)MB (${PREFILL_MEM})${NC}"
echo -e "${BLUE}Decode Mem: $(echo "$DECODE_MEM * 16384 / 100" | bc | cut -d. -f1)MB (${DECODE_MEM})${NC}"
echo -e "${BLUE}Context: ${CONTEXT_LENGTH} tokens${NC}"
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

# Start Prefill workers
for i in $(seq 1 $NUM_PREFILL); do
    local_port=$((30000 + i - 1))
    local_bootstrap=$((90000 + i - 1))
    echo -e "\n${YELLOW}[$i/$NUM_PREFILL] Starting Prefill-$i (port $local_port, bootstrap $local_bootstrap)...${NC}"
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL_PATH" \
        --port $local_port \
        --mem-fraction-static $PREFILL_MEM \
        --tp 1 \
        --pd prefill \
        --disaggregation-bootstrap-port $local_bootstrap \
        --host 127.0.0.1 \
        --context-length $CONTEXT_LENGTH \
        --log-level debug \
        --log-requests \
        --log-requests-level 2 \
        > /tmp/sglang-prefill-$i.log 2>&1 < /dev/null &
done

# Wait for all Prefill workers
echo -e "\n${YELLOW}Waiting for Prefill servers...${NC}"
for i in $(seq 1 $NUM_PREFILL); do
    local_port=$((30000 + i - 1))
    wait_for_server $local_port "prefill-$i"
done

# Start Decode workers
for i in $(seq 1 $NUM_DECODE); do
    local_port=$((31000 + i - 1))
    echo -e "\n${YELLOW}[$i/$NUM_DECODE] Starting Decode-$i (port $local_port)...${NC}"
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL_PATH" \
        --port $local_port \
        --mem-fraction-static $DECODE_MEM \
        --tp 1 \
        --pd decode \
        --host 127.0.0.1 \
        --context-length $CONTEXT_LENGTH \
        --log-level debug \
        --log-requests \
        --log-requests-level 2 \
        > /tmp/sglang-decode-$i.log 2>&1 < /dev/null &
done

# Wait for all Decode workers
echo -e "\n${YELLOW}Waiting for Decode servers...${NC}"
for i in $(seq 1 $NUM_DECODE); do
    local_port=$((31000 + i - 1))
    wait_for_server $local_port "decode-$i"
done

# Show GPU status
echo -e "\n${YELLOW}GPU Memory after start:${NC}"
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader

echo -e "\n${YELLOW}GPU Processes:${NC}"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All servers ready!${NC}"
echo -e "${GREEN}========================================${NC}"

# Show Prefill workers
for i in $(seq 1 $NUM_PREFILL); do
    local_port=$((30000 + i - 1))
    local_bootstrap=$((90000 + i - 1))
    echo -e "${BLUE}Prefill-$i:${NC} http://127.0.0.1:$local_port (bootstrap: $local_bootstrap)"
done

# Show Decode workers
for i in $(seq 1 $NUM_DECODE); do
    local_port=$((31000 + i - 1))
    echo -e "${BLUE}Decode-$i:${NC}  http://127.0.0.1:$local_port"
done

echo ""
echo -e "${YELLOW}Next step - Start Gateway:${NC}"
echo "  cd /mnt/e/dev/sglang/sgl-model-gateway"
echo "  ./target/debug/sgl-model-gateway \\"
echo "    --pd-disaggregation \\"

# Show Prefill args
for i in $(seq 1 $NUM_PREFILL); do
    local_port=$((30000 + i - 1))
    local_bootstrap=$((90000 + i - 1))
    echo "    --prefill http://127.0.0.1:$local_port $local_bootstrap \\"
done

# Show Decode args
for i in $(seq 1 $NUM_DECODE); do
    local_port=$((31000 + i - 1))
    if [ $i -eq $NUM_DECODE ]; then
        echo "    --decode http://127.0.0.1:$local_port"
    else
        echo "    --decode http://127.0.0.1:$local_port \\"
    fi
done

echo "    --host 127.0.0.1 --port 3000 \\"
echo "    --policy round_robin"
