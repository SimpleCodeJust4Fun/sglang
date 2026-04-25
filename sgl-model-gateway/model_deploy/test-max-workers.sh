#!/bin/bash
# Maximum Worker Deployment Tester
# Tests the maximum number of workers that can fit on 16GB GPU

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
RESERVED_VRAM_MB=2048  # Reserve 2GB for system
AVAILABLE_VRAM_MB=$((TOTAL_VRAM_MB - RESERVED_VRAM_MB))

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Maximum Worker Deployment Tester${NC}"
echo -e "${BLUE}GPU: RTX 4070 Ti Super (16GB)${NC}"
echo -e "${BLUE}Model: Qwen2.5-0.5B-Instruct${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${CYAN}Available VRAM: ${AVAILABLE_VRAM_MB}MB (Total: ${TOTAL_VRAM_MB}MB - Reserved: ${RESERVED_VRAM_MB}MB)${NC}\n"

# Activate Python environment
echo -e "${YELLOW}Activating Python environment...${NC}"
source ~/qwen_env/bin/activate 2>/dev/null || {
    echo -e "${RED}Error: qwen_env not found. Please create it first.${NC}"
    exit 1
}

# Function to cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up all workers...${NC}"
    killall -9 python3 2>/dev/null || true
    sleep 2
}

# Clean existing
cleanup

# Test function
test_config() {
    local config_name=$1
    local num_prefill=$2
    local num_decode=$3
    local prefill_mem=$4
    local decode_mem=$5
    local context_len=${6:-2048}
    
    local total_workers=$((num_prefill + num_decode))
    local total_mem_mb=$(echo "($num_prefill * $prefill_mem + $num_decode * $decode_mem) * $TOTAL_VRAM_MB / 100" | bc | cut -d. -f1)
    local pairs=$((num_prefill * num_decode))
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Testing: $config_name${NC}"
    echo -e "${BLUE}Workers: ${num_prefill}P + ${num_decode}D = ${total_workers}${NC}"
    echo -e "${BLUE}Memory: Prefill=${prefill_mem}% Decode=${decode_mem}%${NC}"
    echo -e "${BLUE}Total VRAM: ~${total_mem_mb}MB${NC}"
    echo -e "${BLUE}Scheduling Pairs: ${pairs}${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    local success=true
    local started_workers=0
    
    # Start Prefill workers
    for i in $(seq 1 $num_prefill); do
        local port=$((30000 + i - 1))
        local bootstrap=$((9000 + i - 1))
        
        echo -e "${YELLOW}[$((started_workers + 1))/$total_workers] Starting Prefill-$i (port $port)...${NC}"
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$MODEL_PATH\" \
            --port $port \
            --mem-fraction-static $prefill_mem \
            --tp 1 \
            --pd prefill \
            --disaggregation-bootstrap-port $bootstrap \
            --host 127.0.0.1 \
            --context-length $context_len \
            --log-level warning \
            > /tmp/sglang-test-prefill-$i.log 2>&1 < /dev/null" &
        
        started_workers=$((started_workers + 1))
        sleep 2  # Stagger startup
        
        # Check if still running
        local pid=$!
        sleep 3
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Prefill-$i failed to start${NC}"
            success=false
            break
        else
            echo -e "${GREEN}✓ Prefill-$i started${NC}"
        fi
    done
    
    if [ "$success" = false ]; then
        echo -e "\n${RED}Config $config_name FAILED${NC}\n"
        cleanup
        return 1
    fi
    
    # Start Decode workers
    for i in $(seq 1 $num_decode); do
        local port=$((30010 + i - 1))
        
        echo -e "${YELLOW}[$((started_workers + 1))/$total_workers] Starting Decode-$i (port $port)...${NC}"
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$MODEL_PATH\" \
            --port $port \
            --mem-fraction-static $decode_mem \
            --tp 1 \
            --pd decode \
            --host 127.0.0.1 \
            --context-length $context_len \
            --log-level warning \
            > /tmp/sglang-test-decode-$i.log 2>&1 < /dev/null" &
        
        started_workers=$((started_workers + 1))
        sleep 2
        
        # Check if still running
        local pid=$!
        sleep 3
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Decode-$i failed to start${NC}"
            success=false
            break
        else
            echo -e "${GREEN}✓ Decode-$i started${NC}"
        fi
    done
    
    if [ "$success" = true ]; then
        # Wait for stability
        echo -e "\n${CYAN}Waiting for stability check (10s)...${NC}"
        sleep 10
        
        # Final check
        local running=0
        for pid in $(pgrep -f "sglang.launch_server"); do
            running=$((running + 1))
        done
        
        if [ $running -eq $total_workers ]; then
            echo -e "\n${GREEN}========================================${NC}"
            echo -e "${GREEN}✓ SUCCESS: $config_name${NC}"
            echo -e "${GREEN}Workers: $total_workers ($num_prefill P + $num_decode D)${NC}"
            echo -e "${GREEN}Scheduling Pairs: $pairs${NC}"
            echo -e "${GREEN}========================================${NC}\n"
            
            # Show VRAM usage
            echo -e "${CYAN}Current VRAM Usage:${NC}"
            nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | \
                awk '{sum+=$2; count++} END {printf "Total: %dMB across %d processes\n", sum, count}'
            
            cleanup
            return 0
        else
            echo -e "\n${RED}✗ FAILED: Only $running/$total_workers workers survived${NC}\n"
            cleanup
            return 1
        fi
    else
        echo -e "\n${RED}✗ FAILED: $config_name${NC}\n"
        cleanup
        return 1
    fi
}

# Test configurations from conservative to aggressive
echo -e "${CYAN}Starting VRAM optimization tests...${NC}\n"

# Config 1: 2P+2D (Baseline - should work)
test_config "2P+2D-Baseline" 2 2 0.10 0.20

# Config 2: 3P+3D (Balanced)
test_config "3P+3D-Balanced" 3 3 0.07 0.12

# Config 3: 2P+4D (Decode-heavy)
test_config "2P+4D-DecodeHeavy" 2 4 0.08 0.15

# Config 4: 4P+2D (Prefill-heavy)
test_config "4P+2D-PrefillHeavy" 4 2 0.08 0.15

# Config 5: 3P+4D (More workers)
test_config "3P+4D-MoreWorkers" 3 4 0.06 0.10

# Config 6: 4P+4D (Maximum balanced)
test_config "4P+4D-MaxBalanced" 4 4 0.06 0.10

# Config 7: 2P+6D (Extreme decode)
test_config "2P+6D-ExtremeDecode" 2 6 0.08 0.08

# Config 8: 6P+2D (Extreme prefill)
test_config "6P+2D-ExtremePrefill" 6 2 0.08 0.08

# Config 9: 5P+5D (Maximum total)
test_config "5P+5D-Maximum" 5 5 0.05 0.05

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}All Tests Completed${NC}"
echo -e "${BLUE}========================================${NC}"
