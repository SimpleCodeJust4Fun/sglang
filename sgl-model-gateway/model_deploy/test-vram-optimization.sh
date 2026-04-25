#!/bin/bash
# VRAM Optimization Tester
# Tests different memory configurations to find maximum workers on 16GB GPU

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct"
TOTAL_VRAM=16384  # 16GB in MB
RESERVED_VRAM=2048  # Reserve 2GB for system/overhead
AVAILABLE_VRAM=$((TOTAL_VRAM - RESERVED_VRAM))

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}VRAM Optimization Tester${NC}"
echo -e "${BLUE}GPU: RTX 4070 Ti Super (16GB)${NC}"
echo -e "${BLUE}Model: Qwen2.5-0.5B-Instruct${NC}"
echo -e "${BLUE}========================================${NC}"

# Function to calculate VRAM for a worker
calculate_vram() {
    local mem_fraction=$1
    local vram_mb=$(echo "$TOTAL_VRAM * $mem_fraction" | bc | cut -d. -f1)
    echo $vram_mb
}

# Function to test a single worker
test_worker() {
    local port=$1
    local mem_fraction=$2
    local name=$3
    local pd_role=$4
    local bootstrap_port=$5
    
    echo -e "${YELLOW}Testing $name (port $port, mem=$mem_fraction)...${NC}"
    
    # Start worker
    setsid python3 -m sglang.launch_server \
        --model-path "$MODEL_PATH" \
        --port $port \
        --mem-fraction-static $mem_fraction \
        --tp 1 \
        --pd $pd_role \
        ${bootstrap_port:+--disaggregation-bootstrap-port $bootstrap_port} \
        --host 127.0.0.1 \
        --context-length 2048 \
        --log-level warning \
        > /tmp/sglang-test-$name.log 2>&1 < /dev/null &
    
    local pid=$!
    
    # Wait for startup
    sleep 5
    
    # Check if still running
    if kill -0 $pid 2>/dev/null; then
        local vram_used=$(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | grep $pid | awk '{print $2}')
        echo -e "${GREEN}✓ $name started successfully (PID: $pid, VRAM: ${vram_used}MB)${NC}"
        return 0
    else
        echo -e "${RED}✗ $name failed to start (OOM or error)${NC}"
        tail -20 /tmp/sglang-test-$name.log
        return 1
    fi
}

# Function to cleanup all workers
cleanup() {
    echo -e "\n${YELLOW}Cleaning up test workers...${NC}"
    killall -9 python3 2>/dev/null || true
    sleep 2
}

# Trap cleanup on exit
trap cleanup EXIT

# Clean existing workers
cleanup

# Test different configurations
echo -e "\n${CYAN}Configuration Tests:${NC}"
echo -e "Available VRAM: ${AVAILABLE_VRAM}MB (after reserving 2GB)\n"

# Test 1: Current config (2P+2D)
echo -e "${BLUE}Test 1: Current Config (2P+2D) - Prefill 10%, Decode 20%${NC}"
PREFILL_MEM=0.10
DECODE_MEM=0.20

test_worker 30000 $PREFILL_MEM "prefill-1" "prefill" 9000 || break
test_worker 30001 $PREFILL_MEM "prefill-2" "prefill" 9001 || break
test_worker 30010 $DECODE_MEM "decode-1" "decode" "" || break
test_worker 30011 $DECODE_MEM "decode-2" "decode" "" || break

echo -e "\n${GREEN}Config 1 Success: 2P+2D${NC}"
echo -e "Total VRAM allocated: $(calculate_vram $PREFILL_MEM)×2 + $(calculate_vram $DECODE_MEM)×2 = $(echo "($(calculate_vram $PREFILL_MEM) * 2) + ($(calculate_vram $DECODE_MEM) * 2)" | bc)MB\n"

sleep 2
cleanup

# Test 2: 3P+3D with reduced memory
echo -e "${BLUE}Test 2: 3P+3D Config - Prefill 7%, Decode 15%${NC}"
PREFILL_MEM=0.07
DECODE_MEM=0.15

success=true
test_worker 30000 $PREFILL_MEM "prefill-1" "prefill" 9000 || success=false
test_worker 30001 $PREFILL_MEM "prefill-2" "prefill" 9001 || success=false
test_worker 30002 $PREFILL_MEM "prefill-3" "prefill" 9002 || success=false
test_worker 30010 $DECODE_MEM "decode-1" "decode" "" || success=false
test_worker 30011 $DECODE_MEM "decode-2" "decode" "" || success=false
test_worker 30012 $DECODE_MEM "decode-3" "decode" "" || success=false

if [ "$success" = true ]; then
    echo -e "\n${GREEN}Config 2 Success: 3P+3D${NC}"
    echo -e "Total VRAM allocated: $(calculate_vram $PREFILL_MEM)×3 + $(calculate_vram $DECODE_MEM)×3 = $(echo "($(calculate_vram $PREFILL_MEM) * 3) + ($(calculate_vram $DECODE_MEM) * 3)" | bc)MB\n"
else
    echo -e "\n${RED}Config 2 Failed: 3P+3D not feasible with these settings${NC}\n"
fi

sleep 2
cleanup

# Test 3: 4P+4D with minimal memory
echo -e "${BLUE}Test 3: 4P+4D Config - Prefill 5%, Decode 10%${NC}"
PREFILL_MEM=0.05
DECODE_MEM=0.10

success=true
for i in {1..4}; do
    port=$((30000 + i - 1))
    bootstrap=$((9000 + i - 1))
    test_worker $port $PREFILL_MEM "prefill-$i" "prefill" $bootstrap || success=false
done

for i in {1..4}; do
    port=$((30010 + i - 1))
    test_worker $port $DECODE_MEM "decode-$i" "decode" "" || success=false
done

if [ "$success" = true ]; then
    echo -e "\n${GREEN}Config 3 Success: 4P+4D${NC}"
    echo -e "Total VRAM allocated: $(calculate_vram $PREFILL_MEM)×4 + $(calculate_vram $DECODE_MEM)×4 = $(echo "($(calculate_vram $PREFILL_MEM) * 4) + ($(calculate_vram $DECODE_MEM) * 4)" | bc)MB\n"
else
    echo -e "\n${RED}Config 3 Failed: 4P+4D not feasible with these settings${NC}\n"
fi

sleep 2
cleanup

# Test 4: Asymmetric config (more decode workers)
echo -e "${BLUE}Test 4: 2P+4D Config - Prefill 10%, Decode 12%${NC}"
PREFILL_MEM=0.10
DECODE_MEM=0.12

success=true
test_worker 30000 $PREFILL_MEM "prefill-1" "prefill" 9000 || success=false
test_worker 30001 $PREFILL_MEM "prefill-2" "prefill" 9001 || success=false

for i in {1..4}; do
    port=$((30010 + i - 1))
    test_worker $port $DECODE_MEM "decode-$i" "decode" "" || success=false
done

if [ "$success" = true ]; then
    echo -e "\n${GREEN}Config 4 Success: 2P+4D${NC}"
    echo -e "Total VRAM allocated: $(calculate_vram $PREFILL_MEM)×2 + $(calculate_vram $DECODE_MEM)×4 = $(echo "($(calculate_vram $PREFILL_MEM) * 2) + ($(calculate_vram $DECODE_MEM) * 4)" | bc)MB\n"
else
    echo -e "\n${RED}Config 4 Failed: 2P+4D not feasible with these settings${NC}\n"
fi

sleep 2
cleanup

# Test 5: 3P+2D (more prefill for agent scenarios)
echo -e "${BLUE}Test 5: 3P+2D Config - Prefill 8%, Decode 18%${NC}"
PREFILL_MEM=0.08
DECODE_MEM=0.18

success=true
for i in {1..3}; do
    port=$((30000 + i - 1))
    bootstrap=$((9000 + i - 1))
    test_worker $port $PREFILL_MEM "prefill-$i" "prefill" $bootstrap || success=false
done

for i in {1..2}; do
    port=$((30010 + i - 1))
    test_worker $port $DECODE_MEM "decode-$i" "decode" "" || success=false
done

if [ "$success" = true ]; then
    echo -e "\n${GREEN}Config 5 Success: 3P+2D${NC}"
    echo -e "Total VRAM allocated: $(calculate_vram $PREFILL_MEM)×3 + $(calculate_vram $DECODE_MEM)×2 = $(echo "($(calculate_vram $PREFILL_MEM) * 3) + ($(calculate_vram $DECODE_MEM) * 2)" | bc)MB\n"
else
    echo -e "\n${RED}Config 5 Failed: 3P+2D not feasible with these settings${NC}\n"
fi

sleep 2
cleanup

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}VRAM Optimization Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "${CYAN}Test Results:${NC}"
echo -e "Config 1 (2P+2D, P:10% D:20%):    $(calculate_vram 0.10)MB×2 + $(calculate_vram 0.20)MB×2 = $(echo "($(calculate_vram 0.10) * 2) + ($(calculate_vram 0.20) * 2)" | bc)MB"
echo -e "Config 2 (3P+3D, P:7%  D:15%):    $(calculate_vram 0.07)MB×3 + $(calculate_vram 0.15)MB×3 = $(echo "($(calculate_vram 0.07) * 3) + ($(calculate_vram 0.15) * 3)" | bc)MB"
echo -e "Config 3 (4P+4D, P:5%  D:10%):    $(calculate_vram 0.05)MB×4 + $(calculate_vram 0.10)MB×4 = $(echo "($(calculate_vram 0.05) * 4) + ($(calculate_vram 0.10) * 4)" | bc)MB"
echo -e "Config 4 (2P+4D, P:10% D:12%):    $(calculate_vram 0.10)MB×2 + $(calculate_vram 0.12)MB×4 = $(echo "($(calculate_vram 0.10) * 2) + ($(calculate_vram 0.12) * 4)" | bc)MB"
echo -e "Config 5 (3P+2D, P:8%  D:18%):    $(calculate_vram 0.08)MB×3 + $(calculate_vram 0.18)MB×2 = $(echo "($(calculate_vram 0.08) * 3) + ($(calculate_vram 0.18) * 2)" | bc)MB"
echo -e "\n${YELLOW}Available VRAM: ${AVAILABLE_VRAM}MB (Total: ${TOTAL_VRAM}MB - Reserved: ${RESERVED_VRAM}MB)${NC}"

echo -e "\n${GREEN}Recommendation:${NC}"
echo -e "For Agent scenarios (Prefill-heavy): Use Config 5 (3P+2D)"
echo -e "For Code generation (Decode-heavy): Use Config 4 (2P+4D)"
echo -e "For balanced workloads: Use Config 2 (3P+3D)"
