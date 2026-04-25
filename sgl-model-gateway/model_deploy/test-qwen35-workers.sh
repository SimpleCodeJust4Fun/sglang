#!/bin/bash
# Qwen3.5-0.8B Worker Density Test
# Tests the newer Qwen3.5 model with larger parameters

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3___5-0___8B"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Qwen3.5-0.8B Worker Density Test${NC}"
echo -e "${BLUE}GPU: RTX 4070 Ti Super (16GB)${NC}"
echo -e "${BLUE}Model: Qwen3.5-0.8B (newer than Qwen3-0.6B)${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Check if model exists
if [ ! -d "$MODEL_PATH" ] || [ ! -f "$MODEL_PATH/config.json" ]; then
    echo -e "${RED}Error: Qwen3.5-0.8B model not found or incomplete${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Model found: $(du -sh $MODEL_PATH | cut -f1)${NC}\n"

# Activate Python environment
source ~/qwen_env/bin/activate 2>/dev/null || {
    echo -e "${RED}Error: qwen_env not found${NC}"
    exit 1
}

# Function to cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    killall -9 python3 2>/dev/null || true
    sleep 3
}

# Clean existing
cleanup

# Test a single configuration
test_config() {
    local config_name=$1
    local num_prefill=$2
    local num_decode=$3
    local prefill_mem=$4
    local decode_mem=$5
    
    local total_workers=$((num_prefill + num_decode))
    local pairs=$((num_prefill * num_decode))
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Testing: $config_name${NC}"
    echo -e "${BLUE}Configuration: ${num_prefill}P + ${num_decode}D = ${total_workers} workers${NC}"
    echo -e "${BLUE}Memory: Prefill=${prefill_mem} Decode=${decode_mem}${NC}"
    echo -e "${BLUE}Scheduling Pairs: ${pairs}${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    # Check VRAM before
    echo -e "${CYAN}VRAM before start:${NC}"
    nvidia-smi --query-gpu=memory.used --format=csv,noheader
    
    local success=true
    local started_pids=()
    
    # Start Prefill workers
    for i in $(seq 1 $num_prefill); do
        local port=$((30000 + i - 1))
        local bootstrap=$((90000 + i - 1))
        
        echo -e "${YELLOW}[$i/$num_prefill] Starting Prefill-$i (port $port)...${NC}"
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$MODEL_PATH\" \
            --port $port \
            --mem-fraction-static $prefill_mem \
            --tp 1 \
            --pd prefill \
            --disaggregation-bootstrap-port $bootstrap \
            --host 127.0.0.1 \
            --context-length 2048 \
            --log-level warning \
            > /tmp/sglang-qwen35-prefill-$i.log 2>&1 < /dev/null" &
        
        local pid=$!
        started_pids+=($pid)
        sleep 5  # Qwen3.5 is larger, give more time
        
        # Quick check
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Prefill-$i failed immediately${NC}"
            tail -30 /tmp/sglang-qwen35-prefill-$i.log 2>/dev/null | grep -i "error\|oom\|kill\|fail\|cuda" || true
            success=false
            break
        else
            echo -e "${GREEN}✓ Prefill-$i PID=$pid${NC}"
        fi
    done
    
    if [ "$success" = false ]; then
        echo -e "\n${RED}FAILED during Prefill startup${NC}\n"
        cleanup
        return 1
    fi
    
    # Start Decode workers
    for i in $(seq 1 $num_decode); do
        local port=$((31000 + i - 1))
        
        echo -e "${YELLOW}[$i/$num_decode] Starting Decode-$i (port $port)...${NC}"
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$MODEL_PATH\" \
            --port $port \
            --mem-fraction-static $decode_mem \
            --tp 1 \
            --pd decode \
            --host 127.0.0.1 \
            --context-length 2048 \
            --log-level warning \
            > /tmp/sglang-qwen35-decode-$i.log 2>&1 < /dev/null" &
        
        local pid=$!
        started_pids+=($pid)
        sleep 5
        
        # Quick check
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Decode-$i failed immediately${NC}"
            tail -30 /tmp/sglang-qwen35-decode-$i.log 2>/dev/null | grep -i "error\|oom\|kill\|fail\|cuda" || true
            success=false
            break
        else
            echo -e "${GREEN}✓ Decode-$i PID=$pid${NC}"
        fi
    done
    
    if [ "$success" = false ]; then
        echo -e "\n${RED}FAILED during Decode startup${NC}\n"
        cleanup
        return 1
    fi
    
    # Wait for stability
    echo -e "\n${CYAN}Waiting 15s for stability check...${NC}"
    sleep 15
    
    # Count surviving workers
    local running=0
    for pid in "${started_pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            running=$((running + 1))
        fi
    done
    
    # Show VRAM
    echo -e "\n${CYAN}VRAM after stability:${NC}"
    nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
    
    nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | \
        awk '{sum+=$2; count++} END {printf "Total VRAM: %dMB across %d processes\n", sum, count}' 2>/dev/null || true
    
    if [ $running -eq $total_workers ]; then
        echo -e "\n${GREEN}========================================${NC}"
        echo -e "${GREEN}SUCCESS: $config_name${NC}"
        echo -e "${GREEN}All $total_workers workers stable (${num_prefill}P + ${num_decode}D)${NC}"
        echo -e "${GREEN}Scheduling Pairs: $pairs${NC}"
        echo -e "${GREEN}========================================${NC}\n"
        cleanup
        return 0
    else
        echo -e "\n${RED}========================================${NC}"
        echo -e "${RED}FAILED: Only $running/$total_workers survived${NC}"
        echo -e "${RED}========================================${NC}\n"
        cleanup
        return 1
    fi
}

# Test Qwen3.5 configurations
echo -e "${CYAN}Starting Qwen3.5-0.8B worker density tests...${NC}\n"

# Test 1: 2P+2D (Baseline - Qwen2.5 used 13.9GB)
echo -e "${CYAN}Test 1: 2P+2D Baseline${NC}\n"
test_config "Qwen35-2P+2D" 2 2 0.12 0.22 || true

# Test 2: 2P+3D (Try for 5 workers)
echo -e "\n${CYAN}Test 2: 2P+3D (5 workers, 6 pairs)${NC}\n"
test_config "Qwen35-2P+3D" 2 3 0.10 0.18 || true

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Qwen3.5 Tests Completed${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. Compare VRAM usage with Qwen2.5 results"
echo "2. Check logs: tail -100 /tmp/sglang-qwen35-*.log"
echo "3. If tests succeeded, try more aggressive configs"
