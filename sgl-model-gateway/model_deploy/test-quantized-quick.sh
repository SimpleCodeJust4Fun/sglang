#!/bin/bash
# Quick test of all 3 quantized models - find which supports most workers

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Quick Quantized Models Test${NC}"
echo -e "${BLUE}========================================${NC}\n"

source ~/qwen_env/bin/activate

BASE_DIR="/home/tyliu/.cache/modelscope/hub/models/qwen"

# Models
declare -A MODELS
MODELS=(
    ["FP16"]="$BASE_DIR/Qwen2___5-0___5B-Instruct"
    ["GPTQ-Int4"]="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int4"
    ["GPTQ-Int8"]="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int8"
    ["AWQ"]="$BASE_DIR/Qwen2___5-0___5B-Instruct-AWQ"
)

cleanup() {
    killall -9 python3 2>/dev/null || true
    sleep 3
}

# Test single config for a model
test_model() {
    local name=$1
    local path=$2
    local prefill_mem=$3
    local decode_mem=$4
    local target_workers=$5
    
    if [ ! -d "$path" ] || [ ! -f "$path/config.json" ]; then
        echo -e "${YELLOW}SKIP: $name (not found)${NC}"
        return
    fi
    
    local size=$(du -sh "$path" | cut -f1)
    echo -e "${BLUE}Testing: $name ($size)${NC}"
    echo -e "  Config: ${target_workers} workers with mem P=$prefill_mem D=$decode_mem${NC}"
    echo -e "  VRAM before: $(nvidia-smi --query-gpu=memory.used --format=csv,noheader)${NC}"
    
    cleanup
    
    local success=true
    local pids=()
    
    # Parse target workers into P and D
    case $target_workers in
        "6") local np=2; local nd=4 ;;
        "7") local np=3; local nd=4 ;;
        "8") local np=4; local nd=4 ;;
        *) local np=2; local nd=2 ;;
    esac
    
    # Start Prefill
    for i in $(seq 1 $np); do
        local port=$((30000 + i - 1))
        local bootstrap=$((90000 + i - 1))
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$path\" \
            --port $port \
            --mem-fraction-static $prefill_mem \
            --tp 1 --pd prefill \
            --disaggregation-bootstrap-port $bootstrap \
            --host 127.0.0.1 --context-length 2048 \
            --log-level warning \
            > /tmp/quant-$name-prefill-$i.log 2>&1 < /dev/null" &
        pids+=($!)
        sleep 3
    done
    
    # Start Decode
    for i in $(seq 1 $nd); do
        local port=$((31000 + i - 1))
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$path\" \
            --port $port \
            --mem-fraction-static $decode_mem \
            --tp 1 --pd decode \
            --host 127.0.0.1 --context-length 2048 \
            --log-level warning \
            > /tmp/quant-$name-decode-$i.log 2>&1 < /dev/null" &
        pids+=($!)
        sleep 3
    done
    
    # Wait for stability
    sleep 15
    
    # Count survivors
    local running=0
    for pid in "${pids[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            running=$((running + 1))
        fi
    done
    
    local vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader)
    
    if [ $running -eq $target_workers ]; then
        echo -e "  ${GREEN}✓ SUCCESS: $running/$target_workers workers stable${NC}"
        echo -e "  ${CYAN}VRAM: $vram${NC}"
        echo -e "  Result: PASS\n"
    else
        echo -e "  ${RED}✗ FAILED: Only $running/$target_workers survived${NC}"
        echo -e "  ${CYAN}VRAM: $vram${NC}"
        echo -e "  Result: FAIL\n"
    fi
    
    cleanup
}

echo -e "${CYAN}Testing strategy:${NC}"
echo " 1. FP16 baseline (already know: 6 workers)"
echo " 2. GPTQ-Int4 (smallest: should support more?)"
echo " 3. GPTQ-Int8 (medium)"
echo " 4. AWQ (lightest)"
echo ""

# Test 6 workers first (baseline)
echo -e "${BLUE}=== Test 1: 6 Workers (2P+4D) ===${NC}\n"

for model in "FP16" "GPTQ-Int4" "GPTQ-Int8" "AWQ"; do
    case $model in
        "FP16") test_model "$model" "${MODELS[$model]}" 0.10 0.20 6 ;;
        "GPTQ-Int4") test_model "$model" "${MODELS[$model]}" 0.07 0.12 6 ;;
        "GPTQ-Int8") test_model "$model" "${MODELS[$model]}" 0.08 0.14 6 ;;
        "AWQ") test_model "$model" "${MODELS[$model]}" 0.07 0.12 6 ;;
    esac
done

# Test 7 workers (the target!)
echo -e "\n${BLUE}=== Test 2: 7 Workers (3P+4D) ===${NC}\n"

for model in "GPTQ-Int4" "GPTQ-Int8" "AWQ"; do
    case $model in
        "GPTQ-Int4") test_model "$model" "${MODELS[$model]}" 0.06 0.10 7 ;;
        "GPTQ-Int8") test_model "$model" "${MODELS[$model]}" 0.06 0.10 7 ;;
        "AWQ") test_model "$model" "${MODELS[$model]}" 0.06 0.10 7 ;;
    esac
done

# Test 8 workers (maximum target)
echo -e "\n${BLUE}=== Test 3: 8 Workers (4P+4D) ===${NC}\n"

for model in "GPTQ-Int4" "AWQ"; do
    case $model in
        "GPTQ-Int4") test_model "$model" "${MODELS[$model]}" 0.05 0.08 8 ;;
        "AWQ") test_model "$model" "${MODELS[$model]}" 0.05 0.08 8 ;;
    esac
done

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Summary${NC}"
echo -e "${BLUE}========================================${NC}\n"

echo "Model           | 6 workers | 7 workers | 8 workers"
echo "----------------|-----------|-----------|----------"
echo "FP16 (954MB)    | ✓ PASS    | ✗ N/A     | ✗ N/A"
echo "GPTQ-Int4(450MB)| See above | See above | See above"
echo "GPTQ-Int8(471MB)| See above | See above | ✗ N/A"
echo "AWQ (437MB)     | See above | See above | See above"

echo -e "\n${GREEN}Logs: /tmp/quant-*.log${NC}"
