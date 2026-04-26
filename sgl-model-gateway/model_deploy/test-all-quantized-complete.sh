#!/bin/bash
# Complete test of all quantized models with multiple configurations

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Complete Quantized Models Test${NC}"
echo -e "${BLUE}========================================${NC}\n"

source ~/qwen_env/bin/activate

BASE_DIR="/home/tyliu/.cache/modelscope/hub/models/qwen"

cleanup() {
    killall -9 python3 2>/dev/null || true
    sleep 3
}

# Test function
run_test() {
    local model_name=$1
    local model_path=$2
    local np=$3
    local nd=$4
    local pmem=$5
    local dmem=$6
    local expected=$((np + nd))
    
    local total=$((np + nd))
    local pairs=$((np * nd))
    
    echo -e "${BLUE}Testing: $model_name - ${np}P+${nd}D ($total workers, $pairs pairs)${NC}"
    echo -e "  Memory: P=$pmem D=$dmem${NC}"
    
    cleanup
    
    local pids=()
    local failed=false
    
    # Start Prefill
    for i in $(seq 1 $np); do
        local port=$((30000 + i - 1))
        local bootstrap=$((90000 + i - 1))
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$model_path\" \
            --port $port \
            --mem-fraction-static $pmem \
            --tp 1 --pd prefill \
            --disaggregation-bootstrap-port $bootstrap \
            --host 127.0.0.1 --context-length 2048 \
            --log-level warning \
            > /tmp/test-${model_name}-p-$i.log 2>&1" &
        pids+=($!)
        sleep 3
        
        sleep 2
        if ! kill -0 ${pids[-1]} 2>/dev/null; then
            echo -e "  ${RED}✗ Prefill-$i failed${NC}"
            failed=true
            break
        fi
    done
    
    if [ "$failed" = true ]; then
        echo -e "  ${RED}Result: FAIL (prefill startup)${NC}\n"
        cleanup
        return 1
    fi
    
    # Start Decode
    for i in $(seq 1 $nd); do
        local port=$((31000 + i - 1))
        
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$model_path\" \
            --port $port \
            --mem-fraction-static $dmem \
            --tp 1 --pd decode \
            --host 127.0.0.1 --context-length 2048 \
            --log-level warning \
            > /tmp/test-${model_name}-d-$i.log 2>&1" &
        pids+=($!)
        sleep 3
        
        sleep 2
        if ! kill -0 ${pids[-1]} 2>/dev/null; then
            echo -e "  ${RED}✗ Decode-$i failed${NC}"
            failed=true
            break
        fi
    done
    
    if [ "$failed" = true ]; then
        echo -e "  ${RED}Result: FAIL (decode startup)${NC}\n"
        cleanup
        return 1
    fi
    
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
    
    if [ $running -eq $expected ]; then
        echo -e "  ${GREEN}✓ SUCCESS: $running/$expected workers stable${NC}"
        echo -e "  ${CYAN}VRAM: $vram${NC}"
        echo -e "  ${GREEN}Result: PASS${NC}\n"
        cleanup
        return 0
    else
        echo -e "  ${RED}✗ FAILED: Only $running/$expected survived${NC}"
        echo -e "  ${CYAN}VRAM: $vram${NC}"
        echo -e "  ${RED}Result: FAIL${NC}\n"
        cleanup
        return 1
    fi
}

# Models
GPTQ4="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int4"
GPTQ8="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int8"
AWQ="$BASE_DIR/Qwen2___5-0___5B-Instruct-AWQ"

echo -e "${CYAN}Test Plan:${NC}"
echo " 1. GPTQ-Int4: Test 4, 5, 6, 7, 8 workers"
echo " 2. GPTQ-Int8: Test 4, 5, 6 workers"
echo " 3. AWQ: Test 4, 5, 6 workers"
echo ""

# Results tracking
results=""

# ===== GPTQ-Int4 Tests =====
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}GPTQ-Int4 Tests${NC}"
echo -e "${BLUE}========================================${NC}\n"

if [ -d "$GPTQ4" ] && [ -f "$GPTQ4/config.json" ]; then
    echo "Model size: $(du -sh $GPTQ4 | cut -f1)"
    echo ""
    
    # Test 4 workers
    if run_test "GPTQ4" "$GPTQ4" 2 2 0.08 0.15; then
        results="${results}GPTQ-Int4 | 4 (2P+2D) | PASS\n"
        
        # Test 5 workers
        if run_test "GPTQ4" "$GPTQ4" 2 3 0.07 0.13; then
            results="${results}GPTQ-Int4 | 5 (2P+3D) | PASS\n"
            
            # Test 6 workers
            if run_test "GPTQ4" "$GPTQ4" 2 4 0.07 0.12; then
                results="${results}GPTQ-Int4 | 6 (2P+4D) | PASS\n"
                
                # Test 7 workers
                if run_test "GPTQ4" "$GPTQ4" 3 4 0.06 0.10; then
                    results="${results}GPTQ-Int4 | 7 (3P+4D) | PASS\n"
                    
                    # Test 8 workers
                    if run_test "GPTQ4" "$GPTQ4" 4 4 0.05 0.08; then
                        results="${results}GPTQ-Int4 | 8 (4P+4D) | PASS\n"
                    else
                        results="${results}GPTQ-Int4 | 8 (4P+4D) | FAIL\n"
                    fi
                else
                    results="${results}GPTQ-Int4 | 7 (3P+4D) | FAIL\n"
                fi
            else
                results="${results}GPTQ-Int4 | 6 (2P+4D) | FAIL\n"
            fi
        else
            results="${results}GPTQ-Int4 | 5 (2P+3D) | FAIL\n"
        fi
    else
        results="${results}GPTQ-Int4 | 4 (2P+2D) | FAIL\n"
    fi
else
    echo "Model not found, skipping..."
    results="${results}GPTQ-Int4 | - | SKIP\n"
fi

# ===== GPTQ-Int8 Tests =====
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}GPTQ-Int8 Tests${NC}"
echo -e "${BLUE}========================================${NC}\n"

if [ -d "$GPTQ8" ] && [ -f "$GPTQ8/config.json" ]; then
    echo "Model size: $(du -sh $GPTQ8 | cut -f1)"
    echo ""
    
    # Test 4 workers
    if run_test "GPTQ8" "$GPTQ8" 2 2 0.10 0.18; then
        results="${results}GPTQ-Int8 | 4 (2P+2D) | PASS\n"
        
        # Test 5 workers
        if run_test "GPTQ8" "$GPTQ8" 2 3 0.09 0.16; then
            results="${results}GPTQ-Int8 | 5 (2P+3D) | PASS\n"
            
            # Test 6 workers
            if run_test "GPTQ8" "$GPTQ8" 2 4 0.08 0.14; then
                results="${results}GPTQ-Int8 | 6 (2P+4D) | PASS\n"
            else
                results="${results}GPTQ-Int8 | 6 (2P+4D) | FAIL\n"
            fi
        else
            results="${results}GPTQ-Int8 | 5 (2P+3D) | FAIL\n"
        fi
    else
        results="${results}GPTQ-Int8 | 4 (2P+2D) | FAIL\n"
    fi
else
    echo "Model not found, skipping..."
    results="${results}GPTQ-Int8 | - | SKIP\n"
fi

# ===== AWQ Tests =====
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}AWQ Tests${NC}"
echo -e "${BLUE}========================================${NC}\n"

if [ -d "$AWQ" ] && [ -f "$AWQ/config.json" ]; then
    echo "Model size: $(du -sh $AWQ | cut -f1)"
    echo ""
    
    # Test 4 workers
    if run_test "AWQ" "$AWQ" 2 2 0.08 0.15; then
        results="${results}AWQ | 4 (2P+2D) | PASS\n"
        
        # Test 5 workers
        if run_test "AWQ" "$AWQ" 2 3 0.07 0.13; then
            results="${results}AWQ | 5 (2P+3D) | PASS\n"
            
            # Test 6 workers
            if run_test "AWQ" "$AWQ" 2 4 0.07 0.12; then
                results="${results}AWQ | 6 (2P+4D) | PASS\n"
            else
                results="${results}AWQ | 6 (2P+4D) | FAIL\n"
            fi
        else
            results="${results}AWQ | 5 (2P+3D) | FAIL\n"
        fi
    else
        results="${results}AWQ | 4 (2P+2D) | FAIL\n"
    fi
else
    echo "Model not found, skipping..."
    results="${results}AWQ | - | SKIP\n"
fi

# ===== Final Summary =====
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Final Results Summary${NC}"
echo -e "${BLUE}========================================${NC}\n"

echo "Model         | Workers    | Result"
echo "--------------|------------|-------"
echo -e "$results"

echo -e "\n${GREEN}Reference: FP16 achieved 6 workers (2P+4D)${NC}"
echo -e "${GREEN}Logs: /tmp/test-*.log${NC}"
