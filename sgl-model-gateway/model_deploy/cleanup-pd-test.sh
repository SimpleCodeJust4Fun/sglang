#!/bin/bash
# 清理脚本 - 停止所有 PD 测试相关进程

set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}正在清理 PD 测试环境...${NC}"

# 停止 SGLang Servers
echo -e "\n${YELLOW}停止 SGLang Servers...${NC}"
pkill -f "sglang.launch_server" 2>/dev/null && echo -e "${GREEN}✓ SGLang Servers 已停止${NC}" || echo -e "${YELLOW}未找到运行中的 SGLang Servers${NC}"

# 停止 Gateway
echo -e "\n${YELLOW}停止 Gateway...${NC}"
pkill -f "sgl-model-gateway" 2>/dev/null && echo -e "${GREEN}✓ Gateway 已停止${NC}" || echo -e "${YELLOW}未找到运行中的 Gateway${NC}"

# 等待进程完全退出
sleep 2

# 检查是否还有残留进程
if pgrep -f "sglang.launch_server" > /dev/null 2>&1; then
    echo -e "${RED}强制停止残留的 SGLang 进程...${NC}"
    pkill -9 -f "sglang.launch_server" 2>/dev/null || true
fi

if pgrep -f "sgl-model-gateway" > /dev/null 2>&1; then
    echo -e "${RED}强制停止残留的 Gateway 进程...${NC}"
    pkill -9 -f "sgl-model-gateway" 2>/dev/null || true
fi

# 清理临时文件
rm -f /tmp/sglang-prefill.log /tmp/sglang-decode.log /tmp/test_response_*.json

# 显示 GPU 状态
echo -e "\n${YELLOW}当前 GPU 状态:${NC}"
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}清理完成!${NC}"
echo -e "${GREEN}========================================${NC}"
