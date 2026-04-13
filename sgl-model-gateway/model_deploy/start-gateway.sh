#!/bin/bash
# Gateway 启动脚本 - PD 模式
# 在 WSL2 中运行

set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 配置
PREFILL_URL="http://127.0.0.1:30000"
DECODE_URL="http://127.0.0.1:30001"
BOOTSTRAP_PORT=9000
GATEWAY_HOST="127.0.0.1"
GATEWAY_PORT=3000
POLICY="round_robin"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}启动 Gateway - PD 模式${NC}"
echo -e "${BLUE}========================================${NC}"

# 检查 Prefill Server
echo -e "\n${YELLOW}检查 Prefill Server...${NC}"
if curl -s ${PREFILL_URL}/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Prefill Server 可访问${NC}"
else
    echo -e "${RED}✗ Prefill Server 不可访问: ${PREFILL_URL}${NC}"
    echo "请先运行 start-pd-test.sh 启动 SGLang Servers"
    exit 1
fi

# 检查 Decode Server
echo -e "\n${YELLOW}检查 Decode Server...${NC}"
if curl -s ${DECODE_URL}/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Decode Server 可访问${NC}"
else
    echo -e "${RED}✗ Decode Server 不可访问: ${DECODE_URL}${NC}"
    echo "请先运行 start-pd-test.sh 启动 SGLang Servers"
    exit 1
fi

# 编译 Gateway（如果需要）
echo -e "\n${YELLOW}检查 Gateway 二进制...${NC}"
if [ ! -f "./target/debug/sgl-model-gateway" ]; then
    echo -e "${BLUE}Gateway 未编译，开始编译...${NC}"
    cargo build
    echo -e "${GREEN}✓ 编译完成${NC}"
else
    echo -e "${GREEN}✓ Gateway 二进制已存在${NC}"
fi

# 停止旧的 Gateway 进程
pkill -f "sgl-model-gateway" 2>/dev/null || true
sleep 1

# 启动 Gateway
echo -e "\n${YELLOW}启动 Gateway...${NC}"
echo -e "${BLUE}配置:${NC}"
echo "  Prefill: ${PREFILL_URL} (bootstrap: ${BOOTSTRAP_PORT})"
echo "  Decode:  ${DECODE_URL}"
echo "  Gateway: http://${GATEWAY_HOST}:${GATEWAY_PORT}"
echo "  Policy:  ${POLICY}"
echo ""

./target/debug/sgl-model-gateway \
    --pd-disaggregation \
    --prefill ${PREFILL_URL} ${BOOTSTRAP_PORT} \
    --decode ${DECODE_URL} \
    --host ${GATEWAY_HOST} \
    --port ${GATEWAY_PORT} \
    --policy ${POLICY} \
    --log-level debug
