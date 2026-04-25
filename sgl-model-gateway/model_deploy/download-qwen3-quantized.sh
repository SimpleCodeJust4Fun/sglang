#!/bin/bash
# Download Qwen3 Quantized Models for Higher Worker Density
# AWQ and GPTQ formats require less VRAM per worker

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Download Qwen3 Quantized Models${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Activate environment
source ~/qwen_env/bin/activate

# Model 1: Qwen3-0.6B-AWQ (4-bit)
echo -e "${YELLOW}[1/2] Downloading Qwen3-0.6B-AWQ (4-bit quantized)...${NC}"
AWQ_DIR="/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3-0.6B-AWQ"

if [ -d "$AWQ_DIR" ] && [ $(du -sm "$AWQ_DIR" | cut -f1) -gt 100 ]; then
    echo -e "${GREEN}✓ Qwen3-0.6B-AWQ already exists: $(du -sh $AWQ_DIR | cut -f1)${NC}"
else
    modelscope download --model "Qwen/Qwen3-0.6B-AWQ" --local_dir "$AWQ_DIR" 2>&1 | tail -20
    echo -e "${GREEN}✓ Qwen3-0.6B-AWQ download complete: $(du -sh $AWQ_DIR | cut -f1)${NC}"
fi

echo ""

# Model 2: Qwen3-0.6B-GPTQ-Int4 (4-bit)
echo -e "${YELLOW}[2/2] Downloading Qwen3-0.6B-GPTQ-Int4 (4-bit quantized)...${NC}"
GPTQ_DIR="/home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen3-0.6B-GPTQ-Int4"

if [ -d "$GPTQ_DIR" ] && [ $(du -sm "$GPTQ_DIR" | cut -f1) -gt 100 ]; then
    echo -e "${GREEN}✓ Qwen3-0.6B-GPTQ-Int4 already exists: $(du -sh $GPTQ_DIR | cut -f1)${NC}"
else
    modelscope download --model "Qwen/Qwen3-0.6B-GPTQ-Int4" --local_dir "$GPTQ_DIR" 2>&1 | tail -20
    echo -e "${GREEN}✓ Qwen3-0.6B-GPTQ-Int4 download complete: $(du -sh $GPTQ_DIR | cut -f1)${NC}"
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Download Summary${NC}"
echo -e "${BLUE}========================================${NC}\n"

# Show all Qwen models
echo -e "${CYAN}Available Qwen models:${NC}"
ls -d /home/tyliu/.cache/modelscope/hub/models/Qwen/Qwen* /home/tyliu/.cache/modelscope/hub/models/qwen/Qwen* 2>/dev/null | while read dir; do
    size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    echo "  $dir ($size)"
done

echo ""
echo -e "${GREEN}Next step:${NC}"
echo "  bash test-qwen3-workers.sh"
echo ""
echo -e "${YELLOW}Expected VRAM per worker (4-bit models):${NC}"
echo "  Qwen3-0.6B-AWQ: ~1.2GB (vs 2.0GB for FP16)"
echo "  Qwen3-0.6B-GPTQ: ~1.2GB (vs 2.0GB for FP16)"
echo "  Theoretical max workers: 7-9 (vs 5-6 for FP16)"
