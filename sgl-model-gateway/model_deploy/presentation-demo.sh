#!/bin/bash
# Presentation演示脚本 - 快速展示PD分离和调度策略

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

GATEWAY_URL="http://127.0.0.1:3000"
MODEL_NAME="qwen2.5-0.5b-instruct"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   SGLang Model Gateway - Presentation Demo Script       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function 1: Start environment
demo_start_environment() {
    echo -e "${BOLD}${CYAN}[演示1] 启动PD分离环境${NC}"
    echo ""
    echo -e "${YELLOW}正在启动 2 Prefill + 2 Decode...${NC}"
    
    bash /mnt/e/dev/sglang/sgl-model-gateway/model_deploy/start-multi-pd.sh
    
    echo ""
    echo -e "${GREEN}✓ PD环境启动完成${NC}"
    echo ""
    echo -e "${YELLOW}架构:${NC}"
    echo "  Prefill-1:  http://127.0.0.1:30000 (Bootstrap: 9000)"
    echo "  Prefill-2:  http://127.0.0.1:30001 (Bootstrap: 9001)"
    echo "  Decode-1:   http://127.0.0.1:30010"
    echo "  Decode-2:   http://127.0.0.1:30011"
    echo ""
}

# Function 2: Start Gateway with specific policy
demo_start_gateway() {
    local policy=${1:-"round_robin"}
    
    echo -e "${BOLD}${CYAN}[演示2] 启动Gateway (策略: $policy)${NC}"
    echo ""
    
    bash /mnt/e/dev/sglang/sgl-model-gateway/model_deploy/start-gateway-multi.sh $policy
    
    echo ""
    echo -e "${GREEN}✓ Gateway启动完成 (Port 3000)${NC}"
    echo ""
}

# Function 3: Send simple request
demo_simple_request() {
    echo -e "${BOLD}${CYAN}[演示3] 发送简单请求${NC}"
    echo ""
    echo -e "${YELLOW}请求内容: ${NC}"
    echo '  {"messages": [{"role": "user", "content": "Hello"}], "max_tokens": 30}'
    echo ""
    
    echo -e "${YELLOW}执行命令: ${NC}"
    echo "  curl -X POST $GATEWAY_URL/v1/chat/completions \\"
    echo "      -H \"Content-Type: application/json\" \\"
    echo "      -d '{\"model\": \"$MODEL_NAME\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 30}'"
    echo ""
    
    echo -e "${YELLOW}响应: ${NC}"
    local response=$(curl -s -X POST $GATEWAY_URL/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"$MODEL_NAME\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 30}")
    
    local content=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "ERROR")
    echo "  $content"
    echo ""
    
    local tokens=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"prompt={d['usage']['prompt_tokens']}, completion={d['usage']['completion_tokens']}\")" 2>/dev/null || echo "N/A")
    echo -e "${YELLOW}Token使用: ${NC}$tokens"
    echo ""
}

# Function 4: Show routing decision
demo_routing_decision() {
    echo -e "${BOLD}${CYAN}[演示4] 查看路由决策${NC}"
    echo ""
    echo -e "${YELLOW}查看Gateway日志中的路由决策...${NC}"
    echo ""
    
    if [ -f /tmp/gateway.log ]; then
        echo -e "${GREEN}最近的路由决策:${NC}"
        grep -E "(route|select|dispatch|policy)" /tmp/gateway.log 2>/dev/null | tail -5 || echo "暂无路由日志"
    else
        echo "Gateway日志不存在: /tmp/gateway.log"
    fi
    echo ""
}

# Function 5: Concurrent requests
demo_concurrent_requests() {
    echo -e "${BOLD}${CYAN}[演示5] 并发请求测试${NC}"
    echo ""
    echo -e "${YELLOW}发送5个并发请求...${NC}"
    echo ""
    
    local start_time=$(date +%s%N)
    
    for i in 1 2 3 4 5; do
        curl -s -X POST $GATEWAY_URL/v1/chat/completions \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"$MODEL_NAME\", \"messages\": [{\"role\": \"user\", \"content\": \"Concurrent request $i\"}], \"max_tokens\": 15}" \
            > /tmp/demo_concurrent_$i.json &
    done
    wait
    
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    echo -e "${GREEN}结果:${NC}"
    for i in 1 2 3 4 5; do
        if [ -f /tmp/demo_concurrent_$i.json ]; then
            local content=$(python3 -c "import json; print(json.load(open('/tmp/demo_concurrent_$i.json'))['choices'][0]['message']['content'][:50])" 2>/dev/null || echo "ERROR")
            echo "  请求$i: ${content}..."
            rm -f /tmp/demo_concurrent_$i.json
        fi
    done
    echo ""
    echo -e "${YELLOW}总耗时: ${NC}${duration}ms"
    echo ""
}

# Function 6: Show GPU status
demo_gpu_status() {
    echo -e "${BOLD}${CYAN}[演示6] GPU状态${NC}"
    echo ""
    
    echo -e "${YELLOW}显存使用:${NC}"
    nvidia-smi --query-gpu=memory.used,memory.total,memory.free --format=csv,noheader
    echo ""
    
    echo -e "${YELLOW}GPU进程:${NC}"
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
    echo ""
}

# Function 7: Stop all services
demo_stop_services() {
    echo -e "${BOLD}${CYAN}[演示7] 停止所有服务${NC}"
    echo ""
    echo -e "${YELLOW}正在停止...${NC}"
    
    killall -9 python3 sgl-model-gateway 2>/dev/null || true
    sleep 2
    
    echo -e "${GREEN}✓ 所有服务已停止${NC}"
    echo ""
}

# Function 8: Show architecture diagram
show_architecture() {
    echo -e "${BOLD}${CYAN}[演示8] PD分离架构示意图${NC}"
    echo ""
    echo -e "${YELLOW}请求流程:${NC}"
    echo ""
    echo "  Client"
    echo "    │"
    echo "    │ 1. 发送请求"
    echo "    ▼"
    echo "  Gateway (Port 3000)"
    echo "    │"
    echo "    │ 2a. 同时发送                    2b. 同时发送"
    echo "    ├────────────────────────────────►├──────┐"
    echo "    ▼                                 ▼      │"
    echo "  Prefill Server                  Decode Server│"
    echo "  (计算KV cache)                  (生成token)  │"
    echo "    │                                 │        │"
    echo "    │ 3. Bootstrap传输KV cache ──────►│        │"
    echo "    │                                 │        │"
    echo "    │                                 │ 4. 直接返回┤"
    echo "    │                                 │        │"
    echo "    ◄─────────────────────────────────┴────────┘"
    echo "    │"
    echo "    │ 5. 返回响应"
    echo "    ▼"
    echo "  Client"
    echo ""
    echo -e "${GREEN}关键点: Decode直接返回响应给Gateway，不经过Prefill${NC}"
    echo ""
}

# Interactive menu
interactive_menu() {
    while true; do
        echo -e "${BOLD}选择演示项目:${NC}"
        echo "  1. 启动PD环境 (2P+2D)"
        echo "  2. 启动Gateway (选择策略)"
        echo "  3. 发送简单请求"
        echo "  4. 查看路由决策"
        echo "  5. 并发请求测试"
        echo "  6. 查看GPU状态"
        echo "  7. 显示PD架构示意图"
        echo "  8. 停止所有服务"
        echo "  0. 退出"
        echo ""
        echo -n "请输入选项 (0-8): "
        read choice
        
        echo ""
        case $choice in
            1) demo_start_environment ;;
            2) 
                echo -n "选择策略 (round_robin/cache_aware/random): "
                read policy
                demo_start_gateway $policy
                ;;
            3) demo_simple_request ;;
            4) demo_routing_decision ;;
            5) demo_concurrent_requests ;;
            6) demo_gpu_status ;;
            7) show_architecture ;;
            8) demo_stop_services ;;
            0) 
                echo -e "${GREEN}退出演示${NC}"
                exit 0
                ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
        
        echo ""
        echo -e "${BLUE}────────────────────────────────────────────────────${NC}"
        echo ""
    done
}

# Run interactive menu
interactive_menu
