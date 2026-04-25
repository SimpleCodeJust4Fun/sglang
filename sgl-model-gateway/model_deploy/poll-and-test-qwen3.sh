#!/bin/bash
# Poll for Qwen3 model download completion and run tests

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MODEL_DIR="/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3-0___6B"
EXPECTED_SIZE_MB=1200  # Qwen3-0.6B FP16 should be ~1.2GB

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Qwen3 Download Monitor & Auto-Test${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Function to check download status
check_download() {
    if [ ! -d "$MODEL_DIR" ]; then
        echo "0"
        return
    fi
    
    # Get current size in MB
    local size_kb=$(du -sk "$MODEL_DIR" 2>/dev/null | cut -f1)
    local size_mb=$((size_kb / 1024))
    echo "$size_mb"
}

# Poll until download completes
echo -e "${YELLOW}Monitoring Qwen3-0.6B download...${NC}"
echo -e "${CYAN}Target: ${EXPECTED_SIZE_MB}MB${NC}"
echo ""

last_size=0
check_count=0

while true; do
    check_count=$((check_count + 1))
    current_size=$(check_download)
    
    # Check if config.json exists (download is functional)
    has_config="no"
    if [ -f "$MODEL_DIR/config.json" ]; then
        has_config="yes"
    fi
    
    # Check if model weights exist
    has_weights="no"
    if ls "$MODEL_DIR"/*.safetensors >/dev/null 2>&1 || ls "$MODEL_DIR"/*.bin >/dev/null 2>&1; then
        has_weights="yes"
    fi
    
    # Calculate progress
    if [ $current_size -gt 0 ]; then
        progress=$((current_size * 100 / EXPECTED_SIZE_MB))
        if [ $progress -gt 100 ]; then
            progress=100
        fi
    else
        progress=0
    fi
    
    # Show progress every 30 seconds
    if [ $((check_count % 6)) -eq 1 ]; then
        echo -e "[$(date '+%H:%M:%S')] Progress: ${current_size}MB / ${EXPECTED_SIZE_MB}MB (${progress}%) - Config: $has_config, Weights: $has_weights"
    fi
    
    # Check if download is complete
    if [ $current_size -ge $EXPECTED_SIZE_MB ] && [ "$has_config" = "yes" ] && [ "$has_weights" = "yes" ]; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}✓ Download Complete!${NC}"
        echo -e "${GREEN}Size: ${current_size}MB${NC}"
        echo -e "${GREEN}========================================${NC}\n"
        break
    fi
    
    # Check if download process is still running
    if ! ps aux | grep -E 'modelscope|snapshot_download' | grep -v grep >/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}Download process not found. Checking if files are complete...${NC}"
        
        # Wait a bit in case process just finished
        sleep 10
        
        current_size=$(check_download)
        if [ $current_size -ge $EXPECTED_SIZE_MB ] && [ "$has_config" = "yes" ] && [ "$has_weights" = "yes" ]; then
            echo -e "${GREEN}Files appear complete, proceeding with tests...${NC}\n"
            break
        else
            echo -e "${RED}Download appears to have failed or stalled${NC}"
            echo -e "${YELLOW}Current size: ${current_size}MB / ${EXPECTED_SIZE_MB}MB${NC}"
            echo -e "${YELLOW}Config: $has_config, Weights: $has_weights${NC}"
            echo ""
            echo -e "${YELLOW}Attempting manual download...${NC}"
            
            source ~/qwen_env/bin/activate
            modelscope download --model "Qwen/Qwen3-0.6B" --local_dir "$MODEL_DIR" 2>&1 | tail -50
            
            # Re-check
            current_size=$(check_download)
            if [ $current_size -ge $EXPECTED_SIZE_MB ]; then
                echo -e "${GREEN}Manual download succeeded!${NC}\n"
                break
            else
                echo -e "${RED}Manual download also failed. Exiting.${NC}"
                exit 1
            fi
        fi
    fi
    
    sleep 5
done

# Download complete, show model info
echo -e "${CYAN}Model files:${NC}"
ls -lhS "$MODEL_DIR" | head -15
echo ""

# Activate environment
echo -e "${YELLOW}Activating Python environment...${NC}"
source ~/qwen_env/bin/activate

# Quick validation
echo -e "${YELLOW}Validating model...${NC}"
if [ ! -f "$MODEL_DIR/config.json" ]; then
    echo -e "${RED}Error: config.json not found${NC}"
    exit 1
fi

model_type=$(python3 -c "import json; print(json.load(open('$MODEL_DIR/config.json'))['model_type'])" 2>/dev/null || echo "unknown")
echo -e "${GREEN}✓ Model type: $model_type${NC}\n"

# Now run the tests
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Starting Qwen3-0.6B Tests${NC}"
echo -e "${BLUE}========================================${NC}\n"

cd /mnt/e/dev/sglang/sgl-model-gateway

# Run the test script
if [ -f "model_deploy/test-qwen3-workers.sh" ]; then
    echo -e "${YELLOW}Executing test-qwen3-workers.sh...${NC}\n"
    bash model_deploy/test-qwen3-workers.sh 2>&1 | tee /tmp/qwen3-auto-test-output.log
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}All Tests Completed!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${CYAN}Results saved to: /tmp/qwen3-auto-test-output.log${NC}"
    echo -e "${CYAN}Logs: /tmp/sglang-qwen3-*.log${NC}"
else
    echo -e "${RED}Error: test-qwen3-workers.sh not found${NC}"
    exit 1
fi
