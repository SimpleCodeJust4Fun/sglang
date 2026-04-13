#!/bin/bash
# PD Disaggregation 测试脚本 - 使用 Qwen2.5-7B-Instruct-AWQ 模型
# 适用于 WSL2 + RTX 4070 Ti SUPER (16GB VRAM)

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
MODEL_PATH="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-7B-Instruct-AWQ"
PREFILL_PORT=30000
DECODE_PORT=30001
BOOTSTRAP_PORT=9000
GATEWAY_PORT=3000
MEM_FRACTION=0.4

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}PD Disaggregation 测试 - 7B-AWQ 模型${NC}"
echo -e "${BLUE}========================================${NC}"

# 激活虚拟环境
echo -e "\n${YELLOW}[1/7] 激活 Python 虚拟环境...${NC}"
source ~/qwen_env/bin/activate
echo -e "${GREEN}✓ Python 虚拟环境已激活${NC}"

# 检查 GPU
echo -e "\n${YELLOW}[2/7] 检查 GPU 环境...${NC}"
nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader
echo -e "${GREEN}✓ GPU 环境正常${NC}"

# 检查模型
echo -e "\n${YELLOW}[3/7] 检查模型文件...${NC}"
if [ ! -d "$MODEL_PATH" ]; then
    echo -e "${RED}✗ 模型路径不存在: $MODEL_PATH${NC}"
    exit 1
fi
echo -e "${GREEN}✓ 模型路径存在: $MODEL_PATH${NC}"
ls -lh "$MODEL_PATH" | head -5

# 停止旧进程
echo -e "\n${YELLOW}[4/7] 清理旧进程...${NC}"
pkill -f "sglang.launch_server" 2>/dev/null || true
pkill -f "sgl-model-gateway" 2>/dev/null || true
sleep 2
echo -e "${GREEN}✓ 旧进程已清理${NC}"

# 启动 Prefill Server
echo -e "\n${YELLOW}[5/7] 启动 Prefill Server (端口: $PREFILL_PORT)...${NC}"
python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $PREFILL_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd prefill \
    --disaggregation-bootstrap-port $BOOTSTRAP_PORT \
    --host 127.0.0.1 \
    > /tmp/sglang-prefill.log 2>&1 &
PREFILL_PID=$!
echo "Prefill Server PID: $PREFILL_PID"

# 等待 Prefill Server 启动
echo -e "${BLUE}等待 Prefill Server 启动 (30秒)...${NC}"
sleep 30

# 检查 Prefill Server 健康状态
if curl -s http://127.0.0.1:$PREFILL_PORT/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Prefill Server 启动成功${NC}"
else
    echo -e "${RED}✗ Prefill Server 启动失败，查看日志:${NC}"
    tail -50 /tmp/sglang-prefill.log
    exit 1
fi

# 启动 Decode Server
echo -e "\n${YELLOW}[6/7] 启动 Decode Server (端口: $DECODE_PORT)...${NC}"
python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $DECODE_PORT \
    --mem-fraction-static $MEM_FRACTION \
    --tp 1 \
    --pd decode \
    --host 127.0.0.1 \
    > /tmp/sglang-decode.log 2>&1 &
DECODE_PID=$!
echo "Decode Server PID: $DECODE_PID"

# 等待 Decode Server 启动
echo -e "${BLUE}等待 Decode Server 启动 (30秒)...${NC}"
sleep 30

# 检查 Decode Server 健康状态
if curl -s http://127.0.0.1:$DECODE_PORT/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Decode Server 启动成功${NC}"
else
    echo -e "${RED}✗ Decode Server 启动失败，查看日志:${NC}"
    tail -50 /tmp/sglang-decode.log
    exit 1
fi

# 检查显存使用
echo -e "\n${YELLOW}当前显存使用情况:${NC}"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Prefill 和 Decode Servers 已就绪!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "${BLUE}Prefill Server:${NC} http://127.0.0.1:$PREFILL_PORT (PID: $PREFILL_PID)"
echo -e "${BLUE}Decode Server:${NC} http://127.0.0.1:$DECODE_PORT (PID: $DECODE_PID)"
echo -e "${BLUE}Bootstrap Port:${NC} $BOOTSTRAP_PORT"
echo ""
echo -e "${YELLOW}下一步:${NC}"
echo "1. 编译并启动 Gateway:"
echo "   cd /mnt/e/dev/sglang/sgl-model-gateway"
echo "   cargo build"
echo "   ./target/debug/sgl-model-gateway \\"
echo "     --pd-disaggregation \\"
echo "     --prefill http://127.0.0.1:$PREFILL_PORT $BOOTSTRAP_PORT \\"
echo "     --decode http://127.0.0.1:$DECODE_PORT \\"
echo "     --host 127.0.0.1 \\"
echo "     --port $GATEWAY_PORT \\"
echo "     --policy round_robin"
echo ""
echo "2. 测试请求:"
echo "   curl -X POST http://127.0.0.1:$GATEWAY_PORT/v1/chat/completions \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"model\": \"qwen2.5-7b-awq\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
echo ""
echo "3. 停止服务:"
echo "   kill $PREFILL_PID $DECODE_PID"
echo ""
echo -e "${YELLOW}日志文件:${NC}"
echo "Prefill: /tmp/sglang-prefill.log"
echo "Decode:  /tmp/sglang-decode.log"
