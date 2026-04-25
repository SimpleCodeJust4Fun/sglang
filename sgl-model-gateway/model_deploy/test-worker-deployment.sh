#!/bin/bash
# Simplified Worker Deployment Test
# Tests key configurations to find optimal worker count

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct"
TOTAL_VRAM_MB=16384

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Simplified Worker Deployment Test${NC}"
echo -e "${BLUE}GPU: RTX 4070 Ti Super (16GB)${NC}"
echo -e "${BLUE}Model: Qwen2.5-0.5B-Instruct${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Activate Python environment
echo -e "${YELLOW}Activating Python environment...${NC}"
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
test_single_config() {
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
            > /tmp/sglang-test-prefill-$i.log 2>&1 < /dev/null" &
        
        local pid=$!
        started_pids+=($pid)
        sleep 3  # Stagger startup
        
        # Quick check
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Prefill-$i failed immediately${NC}"
            tail -20 /tmp/sglang-test-prefill-$i.log 2>/dev/null | grep -i "error\|oom\|kill\|fail" || true
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
            > /tmp/sglang-test-decode-$i.log 2>&1 < /dev/null" &
        
        local pid=$!
        started_pids+=($pid)
        sleep 3
        
        # Quick check
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Decode-$i failed immediately${NC}"
            tail -20 /tmp/sglang-test-decode-$i.log 2>/dev/null | grep -i "error\|oom\|kill\|fail" || true
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

# Test key configurations
echo -e "${CYAN}Test 1: Conservative 2P+2D (should work)${NC}\n"
test_single_config "2P+2D-Conservative" 2 2 0.10 0.20 || true

echo -e "\n${CYAN}Test 2: Balanced 3P+3D (recommended)${NC}\n"
test_single_config "3P+3D-Balanced" 3 3 0.07 0.12 || true

echo -e "\n${CYAN}Test 3: Decode-Heavy 2P+4D (for code generation)${NC}\n"
test_single_config "2P+4D-DecodeHeavy" 2 4 0.07 0.10 || true

echo -e "\n${CYAN}Test 4: Maximum Workers 4P+4D${NC}\n"
test_single_config "4P+4D-MaxWorkers" 4 4 0.05 0.08 || true

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}All Tests Completed${NC}"
echo -e "${BLUE}========================================${NC}"
