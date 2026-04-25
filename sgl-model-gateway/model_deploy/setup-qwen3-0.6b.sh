#!/bin/bash
# Download and Setup Qwen3-0.6B Model
# Downloads from ModelScope and integrates with existing PD setup

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

MODELSCOPE_URL="https://modelscope.cn/models/Qwen/Qwen3-0.6B-MLX-4bit"
MODEL_NAME="Qwen3-0.6B-MLX-4bit"
MODEL_DIR="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen3-0___6B-MLX-4bit"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Qwen3-0.6B Model Setup${NC}"
echo -e "${BLUE}========================================${NC}"

# Check if modelscope CLI is installed
if ! command -v modelscope &> /dev/null; then
    echo -e "${YELLOW}Activating Python environment...${NC}"
    source ~/qwen_env/bin/activate 2>/dev/null || {
        echo -e "${RED}Error: qwen_env not found${NC}"
        exit 1
    }
    
    echo -e "${YELLOW}Installing ModelScope CLI...${NC}"
    pip install modelscope
fi

# Download model
echo -e "\n${YELLOW}[1/3] Downloading Qwen3-0.6B from ModelScope...${NC}"
echo -e "${CYAN}URL: $MODELSCOPE_URL${NC}"

if [ -d "$MODEL_DIR" ]; then
    echo -e "${GREEN}Model already exists at: $MODEL_DIR${NC}"
    echo -e "${YELLOW}Re-download? (y/n)${NC}"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Using existing model${NC}"
    else
        echo -e "${YELLOW}Re-downloading...${NC}"
        rm -rf "$MODEL_DIR"
        modelscope download --model "$MODELSCOPE_URL" --local_dir "$MODEL_DIR"
    fi
else
    echo -e "${YELLOW}Downloading model...${NC}"
    modelscope download --model "Qwen/Qwen3-0.6B-MLX-4bit" --local_dir "$MODEL_DIR"
fi

# Verify model
echo -e "\n${YELLOW}[2/3] Verifying model files...${NC}"
if [ -d "$MODEL_DIR" ]; then
    model_size=$(du -sh "$MODEL_DIR" | cut -f1)
    file_count=$(find "$MODEL_DIR" -type f | wc -l)
    echo -e "${GREEN}✓ Model downloaded successfully${NC}"
    echo -e "  Location: $MODEL_DIR"
    echo -e "  Size: $model_size"
    echo -e "  Files: $file_count"
    
    # List key files
    echo -e "\n${CYAN}Key files:${NC}"
    ls -lh "$MODEL_DIR" | head -20
else
    echo -e "${RED}✗ Model download failed${NC}"
    exit 1
fi

# Test model with SGLang
echo -e "\n${YELLOW}[3/3] Testing model with SGLang...${NC}"

# Activate env
source ~/qwen_env/bin/activate

# Quick test
echo -e "${CYAN}Starting quick test...${NC}"
python3 -m sglang.launch_server \
    --model-path "$MODEL_DIR" \
    --port 30999 \
    --mem-fraction-static 0.15 \
    --host 127.0.0.1 \
    --log-level warning \
    > /tmp/sglang-qwen3-test.log 2>&1 &

TEST_PID=$!
echo -e "  Waiting for server to start..."

# Wait for server
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:30999/health >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Qwen3-0.6B server ready on port 30999${NC}"
        
        # Test inference
        echo -e "\n${CYAN}Testing inference...${NC}"
        response=$(curl -s -X POST http://127.0.0.1:30999/generate \
            -H "Content-Type: application/json" \
            -d '{
                "text": "Hello, how are you?",
                "sampling_params": {
                    "temperature": 0,
                    "max_new_tokens": 20
                }
            }')
        
        echo -e "${GREEN}Response: $response${NC}"
        
        # Cleanup
        kill $TEST_PID 2>/dev/null || true
        wait $TEST_PID 2>/dev/null || true
        
        echo -e "\n${GREEN}========================================${NC}"
        echo -e "${GREEN}Qwen3-0.6B Setup Complete!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo -e "\n${CYAN}Model path for SGLang:${NC}"
        echo "  $MODEL_DIR"
        echo -e "\n${CYAN}Usage with PD:${NC}"
        echo "  bash start-multi-pd.sh 3p3d qwen3"
        exit 0
    fi
    
    if [ $((i % 5)) -eq 0 ]; then
        echo -n "."
    fi
    sleep 2
done

echo -e "\n${RED}✗ Server failed to start${NC}"
echo -e "${YELLOW}Check logs: tail -100 /tmp/sglang-qwen3-test.log${NC}"
exit 1
