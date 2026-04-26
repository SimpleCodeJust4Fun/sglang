#!/bin/bash
# Test all quantized models for maximum worker density
# GPTQ-Int4, GPTQ-Int8, AWQ

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Quantized Models Worker Density Test${NC}"
echo -e "${BLUE}GPU: RTX 4070 Ti Super (16GB)${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Activate Python environment
source ~/qwen_env/bin/activate 2>/dev/null || {
    echo -e "${RED}Error: qwen_env not found${NC}"
    exit 1
}

BASE_DIR="/home/tyliu/.cache/modelscope/hub/models/qwen"

# Models to test
declare -A MODELS
MODELS=(
    ["GPTQ-Int4"]="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int4"
    ["GPTQ-Int8"]="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int8"
    ["AWQ"]="$BASE_DIR/Qwen2___5-0___5B-Instruct-AWQ"
)

# Function to cleanup
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    killall -9 python3 2>/dev/null || true
    sleep 3
}

# Test a single configuration
test_config() {
    local model_name=$1
    local model_path=$2
    local config_name=$3
    local num_prefill=$4
    local num_decode=$5
    local prefill_mem=$6
    local decode_mem=$7
    
    local total_workers=$((num_prefill + num_decode))
    local pairs=$((num_prefill * num_decode))
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Testing: $model_name - $config_name${NC}"
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
            --model-path \"$model_path\" \
            --port $port \
            --mem-fraction-static $prefill_mem \
            --tp 1 \
            --pd prefill \
            --disaggregation-bootstrap-port $bootstrap \
            --host 127.0.0.1 \
            --context-length 2048 \
            --log-level warning \
            > /tmp/sglang-quant-$model_name-prefill-$i.log 2>&1 < /dev/null" &
        
        local pid=$!
        started_pids+=($pid)
        sleep 4
        
        # Quick check
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Prefill-$i failed immediately${NC}"
            tail -30 /tmp/sglang-quant-$model_name-prefill-$i.log 2>/dev/null | grep -i "error\|oom\|kill\|fail" || true
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
            --model-path \"$model_path\" \
            --port $port \
            --mem-fraction-static $decode_mem \
            --tp 1 \
            --pd decode \
            --host 127.0.0.1 \
            --context-length 2048 \
            --log-level warning \
            > /tmp/sglang-quant-$model_name-decode-$i.log 2>&1 < /dev/null" &
        
        local pid=$!
        started_pids+=($pid)
        sleep 4
        
        # Quick check
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo -e "${RED}✗ Decode-$i failed immediately${NC}"
            tail -30 /tmp/sglang-quant-$model_name-decode-$i.log 2>/dev/null | grep -i "error\|oom\|kill\|fail" || true
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
        echo -e "${GREEN}SUCCESS: $model_name - $config_name${NC}"
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

# Test each quantized model
for model_name in "GPTQ-Int4" "GPTQ-Int8" "AWQ"; do
    model_path="${MODELS[$model_name]}"
    
    # Check if model exists
    if [ ! -d "$model_path" ] || [ ! -f "$model_path/config.json" ]; then
        echo -e "${YELLOW}Skipping $model_name - not found at: $model_path${NC}\n"
        continue
    fi
    
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Testing Model: $model_name${NC}"
    echo -e "${BLUE}Path: $model_path${NC}"
    echo -e "${BLUE}Size: $(du -sh $model_path | cut -f1)${NC}"
    echo -e "${BLUE}========================================${NC}\n"
    
    # Clean existing
    cleanup
    
    # Test 1: 2P+2D (Baseline)
    test_config "$model_name" "$model_path" "2P+2D-Baseline" 2 2 0.08 0.15 || true
    
    # Test 2: 2P+4D (Target 6 workers - match FP16)
    test_config "$model_name" "$model_path" "2P+4D-6workers" 2 4 0.07 0.12 || true
    
    # Test 3: 3P+4D (Target 7 workers - BEAT FP16!)
    test_config "$model_name" "$model_path" "3P+4D-7workers" 3 4 0.06 0.10 || true
    
    # Test 4: 4P+4D (Target 8 workers - MAXIMUM)
    test_config "$model_name" "$model_path" "4P+4D-8workers" 4 4 0.05 0.08 || true
    
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}$model_name Tests Complete${NC}"
    echo -e "${GREEN}========================================${NC}\n"
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}All Quantized Model Tests Completed${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${YELLOW}Comparison Summary:${NC}"
echo "  Qwen2.5-0.5B-FP16:  6 workers max (2P+4D)"
echo "  GPTQ-Int4:          Check results above"
echo "  GPTQ-Int8:          Check results above"
echo "  AWQ:                Check results above"
echo ""
echo "Check logs: tail -100 /tmp/sglang-quant-*.log"
