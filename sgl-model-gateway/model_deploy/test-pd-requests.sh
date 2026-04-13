#!/bin/bash
# PD 测试脚本 - 发送测试请求到 Gateway
# 在 WSL2 中运行

set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

GATEWAY_URL="http://127.0.0.1:3000"
MODEL_NAME="qwen2.5-7b-awq"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}PD Disaggregation 测试请求${NC}"
echo -e "${BLUE}========================================${NC}"

# 检查 Gateway 是否运行
echo -e "\n${YELLOW}检查 Gateway 状态...${NC}"
if ! curl -s ${GATEWAY_URL}/health > /dev/null 2>&1; then
    echo -e "${RED}✗ Gateway 未运行在 ${GATEWAY_URL}${NC}"
    echo "请先启动 Gateway:"
    echo "  ./start-gateway.sh"
    exit 1
fi
echo -e "${GREEN}✓ Gateway 运行中${NC}"

# 测试 1: 简单的 Chat Completion
echo -e "\n${YELLOW}[测试 1] 简单 Chat Completion${NC}"
echo -e "${BLUE}请求:${NC} Hello, world!"
curl -s -X POST ${GATEWAY_URL}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"Hello, world!\"}],
        \"max_tokens\": 50,
        \"stream\": false
    }" | python3 -m json.tool

# 测试 2: 中文对话
echo -e "\n${YELLOW}[测试 2] 中文对话测试${NC}"
echo -e "${BLUE}请求:${NC} 用一句话解释什么是 PD 分离架构"
curl -s -X POST ${GATEWAY_URL}/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d "{
        \"model\": \"${MODEL_NAME}\",
        \"messages\": [{\"role\": \"user\", \"content\": \"用一句话解释什么是 PD 分离架构\"}],
        \"max_tokens\": 100,
        \"stream\": false
    }" | python3 -m json.tool

# 测试 3: Generate API
echo -e "\n${YELLOW}[测试 3] Generate API 测试${NC}"
echo -e "${BLUE}请求:${NC} The meaning of life is"
curl -s -X POST ${GATEWAY_URL}/generate \
    -H "Content-Type: application/json" \
    -d "{
        \"text\": \"The meaning of life is\",
        \"sampling_params\": {\"max_new_tokens\": 50},
        \"stream\": false
    }" | python3 -m json.tool

# 测试 4: 并发请求（测试负载均衡）
echo -e "\n${YELLOW}[测试 4] 并发请求测试 (5个并发)${NC}"
for i in $(seq 1 5); do
    curl -s -X POST ${GATEWAY_URL}/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{
            \"model\": \"${MODEL_NAME}\",
            \"messages\": [{\"role\": \"user\", \"content\": \"Count to $i\"}],
            \"max_tokens\": 30,
            \"stream\": false
        }" > /tmp/test_response_$i.json 2>&1 &
done

# 等待所有请求完成
wait

# 显示结果
for i in $(seq 1 5); do
    echo -e "\n${BLUE}并发请求 $i 结果:${NC}"
    if [ -f /tmp/test_response_$i.json ]; then
        if python3 -m json.tool /tmp/test_response_$i.json > /dev/null 2>&1; then
            python3 -m json.tool /tmp/test_response_$i.json | grep -A 2 '"content"'
        else
            cat /tmp/test_response_$i.json
        fi
        rm -f /tmp/test_response_$i.json
    fi
done

# 测试 5: 检查 Worker 状态
echo -e "\n${YELLOW}[测试 5] 检查模型信息${NC}"
curl -s ${GATEWAY_URL}/v1/models | python3 -m json.tool

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}所有测试完成!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "\n${BLUE}观察要点:${NC}"
echo "1. 检查 Prefill Server 日志 (/tmp/sglang-prefill.log)"
echo "   - 查看是否收到带 bootstrap 信息的请求"
echo "2. 检查 Decode Server 日志 (/tmp/sglang-decode.log)"
echo "   - 查看是否成功接收 KV Cache 并生成响应"
echo "3. 检查 Gateway 日志"
echo "   - 查看请求分发和路由决策"
echo ""
echo -e "${YELLOW}查看日志命令:${NC}"
echo "  tail -f /tmp/sglang-prefill.log"
echo "  tail -f /tmp/sglang-decode.log"
