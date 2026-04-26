#!/bin/bash
# Download all Qwen2.5-0.5B quantized models for worker density testing

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Download Qwen2.5-0.5B Quantized Models${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Activate environment
source ~/qwen_env/bin/activate

BASE_DIR="/home/tyliu/.cache/modelscope/hub/models/qwen"

# Download 3 quantized models in parallel
echo -e "${YELLOW}[1/3] Downloading Qwen2.5-0.5B-GPTQ-Int4...${NC}"
GPTQ4_DIR="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int4"
if [ -d "$GPTQ4_DIR" ] && [ $(du -sm "$GPTQ4_DIR" 2>/dev/null | cut -f1) -gt 50 ]; then
    echo -e "${GREEN}✓ Already exists: $(du -sh $GPTQ4_DIR | cut -f1)${NC}"
else
    modelscope download --model "Qwen/Qwen2.5-0.5B-Instruct-GPTQ-Int4" --local_dir "$GPTQ4_DIR" 2>&1 | tail -10 &
    PID1=$!
fi

echo -e "\n${YELLOW}[2/3] Downloading Qwen2.5-0.5B-GPTQ-Int8...${NC}"
GPTQ8_DIR="$BASE_DIR/Qwen2___5-0___5B-Instruct-GPTQ-Int8"
if [ -d "$GPTQ8_DIR" ] && [ $(du -sm "$GPTQ8_DIR" 2>/dev/null | cut -f1) -gt 50 ]; then
    echo -e "${GREEN}✓ Already exists: $(du -sh $GPTQ8_DIR | cut -f1)${NC}"
else
    modelscope download --model "Qwen/Qwen2.5-0.5B-Instruct-GPTQ-Int8" --local_dir "$GPTQ8_DIR" 2>&1 | tail -10 &
    PID2=$!
fi

echo -e "\n${YELLOW}[3/3] Downloading Qwen2.5-0.5B-AWQ...${NC}"
AWQ_DIR="$BASE_DIR/Qwen2___5-0___5B-Instruct-AWQ"
if [ -d "$AWQ_DIR" ] && [ $(du -sm "$AWQ_DIR" 2>/dev/null | cut -f1) -gt 50 ]; then
    echo -e "${GREEN}✓ Already exists: $(du -sh $AWQ_DIR | cut -f1)${NC}"
else
    modelscope download --model "Qwen/Qwen2.5-0.5B-Instruct-AWQ" --local_dir "$AWQ_DIR" 2>&1 | tail -10 &
    PID3=$!
fi

# Wait for all downloads
echo -e "\n${CYAN}Waiting for downloads to complete...${NC}"
wait $PID1 2>/dev/null || true
wait $PID2 2>/dev/null || true
wait $PID3 2>/dev/null || true

echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Download Summary${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Show all models
for dir in "$GPTQ4_DIR" "$GPTQ8_DIR" "$AWQ_DIR"; do
    if [ -d "$dir" ]; then
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        files=$(ls "$dir" 2>/dev/null | wc -l)
        echo -e "${GREEN}✓ $dir${NC}"
        echo "  Size: $size, Files: $files"
        ls -lh "$dir" | head -5
        echo ""
    else
        echo -e "${RED}✗ $dir - NOT FOUND${NC}\n"
    fi
done

echo -e "${GREEN}Next step:${NC}"
echo "  bash model_deploy/test-quantized-models.sh"
echo ""
echo -e "${YELLOW}Expected VRAM per worker (4-bit/8-bit models):${NC}"
echo "  GPTQ-Int4: ~1.2GB (vs 1.8GB for FP16)"
echo "  GPTQ-Int8: ~1.5GB (vs 1.8GB for FP16)"
echo "  AWQ:       ~1.3GB (vs 1.8GB for FP16)"
echo "  Theoretical max workers: 7-9 (vs 6 for FP16)"
