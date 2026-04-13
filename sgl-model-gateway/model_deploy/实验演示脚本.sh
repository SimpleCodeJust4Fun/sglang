#!/bin/bash
# 基于实验的Presentation演示脚本
# 按步骤展示实验结果

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   SGLang Model Gateway - 基于实验的技术分享              ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Step 1: 展示实验环境
step_1_environment() {
    echo -e "${BOLD}${CYAN}[步骤1] 实验环境介绍${NC}"
    echo ""
    echo -e "${YELLOW}架构配置: 2 Prefill + 2 Decode${NC}"
    echo ""
    echo "  Prefill-1:  Port 30000, Bootstrap 9000"
    echo "  Prefill-2:  Port 30001, Bootstrap 9001"
    echo "  Decode-1:   Port 30010"
    echo "  Decode-2:   Port 30011"
    echo "  Gateway:    Port 3000"
    echo ""
    echo -e "${YELLOW}GPU状态:${NC}"
    nvidia-smi --query-gpu=memory.used,memory.total,memory.free --format=csv,noheader 2>/dev/null || echo "无法获取GPU信息"
    echo ""
    echo -e "${YELLOW}运行中的服务:${NC}"
    ps aux | grep -E "(sglang|python3)" | grep -v grep | grep -E "(port 300|pd )" | awk '{print "  PID: "$2", CMD: "$11" "$12}' | head -10
    echo ""
}

# Step 2: 展示启动日志
step_2_logs() {
    echo -e "${BOLD}${CYAN}[步骤2] 启动日志分析${NC}"
    echo ""
    
    if [ -f /tmp/sglang-prefill-1.log ]; then
        echo -e "${YELLOW}Prefill-1 关键日志:${NC}"
        echo ""
        grep -E "(KV Cache|max_total_num_tokens|Uvicorn running|fired up)" /tmp/sglang-prefill-1.log | tail -5 | while read line; do
            echo "  $line"
        done
        echo ""
        
        echo -e "${YELLOW}关键发现:${NC}"
        echo "  ✓ KV Cache分配: 107,319 tokens (1.22 GB)"
        echo "  ✓ 可用GPU显存: 11.69 GB"
        echo "  ✓ 最大并发请求: 4096"
    else
        echo "  Prefill日志不存在"
    fi
    echo ""
}

# Step 3: 演示PD流程
step_3_pd_flow() {
    echo -e "${BOLD}${CYAN}[步骤3] PD分离架构流程${NC}"
    echo ""
    echo -e "${YELLOW}请求流程示意图:${NC}"
    echo ""
    echo "  Client"
    echo "    │ 1. 发送请求"
    echo "    ▼"
    echo "  Gateway (Port 3000)"
    echo "    │ 2a. 同时发送           2b. 同时发送"
    echo "    ├──────────────────────►├──────┐"
    echo "    ▼                        ▼      │"
    echo "  Prefill Server          Decode Server│"
    echo "  (计算KV cache)          (生成token)  │"
    echo "    │                        │        │"
    echo "    │ 3. Bootstrap ─────────►│        │"
    echo "    │    传输KV cache        │        │"
    echo "    │                        │        │"
    echo "    │                        │ 4. 直接返回┤"
    echo "    │                        │        │"
    echo "    ◄────────────────────────┴────────┘"
    echo "    │ 5. 返回响应"
    echo "    ▼"
    echo "  Client"
    echo ""
    echo -e "${GREEN}关键: Decode直接返回响应给Gateway，不经过Prefill${NC}"
    echo ""
    
    echo -e "${YELLOW}源码证据 (pd_router.rs):${NC}"
    echo '  // Decode响应是主输出'
    echo '  if !decode_resp.status.is_success() {'
    echo '      return self.handle_decode_error_response(...);'
    echo '  }'
    echo '  // 最终返回Decode响应'
    echo '  return (status, decode_body).into_response();'
    echo ""
}

# Step 4: 策略对比
step_4_policies() {
    echo -e "${BOLD}${CYAN}[步骤4] 调度策略对比实验${NC}"
    echo ""
    
    echo -e "${YELLOW}性能对比表:${NC}"
    echo ""
    printf "  %-15s | %-12s | %-12s | %-10s\n" "策略" "首次延迟" "并发延迟" "缓存利用"
    echo "  ----------------|--------------|--------------|----------"
    printf "  %-15s | %-12s | %-12s | %-10s\n" "Round Robin" "961ms" "~300ms" "无"
    printf "  %-15s | %-12s | %-12s | %-10s\n" "Cache Aware" "-" "302ms" "高"
    printf "  %-15s | %-12s | %-12s | %-10s\n" "Random" "-" "301ms" "无"
    echo ""
    
    echo -e "${YELLOW}关键发现:${NC}"
    echo "  1. Cache Aware和Random性能相当 (~300ms)"
    echo "  2. Round Robin首次延迟高（冷启动）"
    echo "  3. Cache Aware在相似请求多时效果最好"
    echo ""
}

# Step 5: 发送测试请求
step_5_test_request() {
    echo -e "${BOLD}${CYAN}[步骤5] 实时测试请求${NC}"
    echo ""
    
    echo -e "${YELLOW}发送测试请求...${NC}"
    echo ""
    
    local start_time=$(date +%s%N)
    local response=$(curl -s -X POST http://127.0.0.1:3000/v1/chat/completions \
        -H "Content-Type: application/json" \
        -d '{"model": "qwen2.5-0.5b-instruct", "messages": [{"role": "user", "content": "Hello, please respond briefly."}], "max_tokens": 30}' \
        2>/dev/null || echo '{"error": "Gateway not ready"}')
    local end_time=$(date +%s%N)
    local duration=$(( (end_time - start_time) / 1000000 ))
    
    echo -e "${GREEN}响应 (耗时: ${duration}ms):${NC}"
    echo ""
    
    if echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('choices', [{}])[0].get('message', {}).get('content', 'ERROR'))" 2>/dev/null; then
        echo ""
        local tokens=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"Token使用: prompt={d['usage']['prompt_tokens']}, completion={d['usage']['completion_tokens']}\")" 2>/dev/null || echo "")
        [ -n "$tokens" ] && echo -e "${YELLOW}${tokens}${NC}"
    else
        echo "  $response"
    fi
    echo ""
}

# Step 6: Bootstrap机制
step_6_bootstrap() {
    echo -e "${BOLD}${CYAN}[步骤6] Bootstrap机制${NC}"
    echo ""
    
    echo -e "${YELLOW}Bootstrap参数:${NC}"
    echo ""
    echo "  Prefill启动参数:"
    echo "    --pd prefill"
    echo "    --disaggregation-bootstrap-port 9000"
    echo ""
    echo "  Gateway注册:"
    echo "    --prefill http://127.0.0.1:30000 9000"
    echo "                            ↑ HTTP端口  ↑ Bootstrap端口"
    echo ""
    
    echo -e "${YELLOW}传输流程:${NC}"
    echo "  1. Prefill计算KV cache"
    echo "  2. 通过bootstrap端口建立TCP连接"
    echo "  3. 使用mooncake传输引擎传输KV cache"
    echo "  4. Decode接收并应用KV cache"
    echo ""
    
    echo -e "${YELLOW}KV Cache容量 (从日志):${NC}"
    echo "  #tokens: 107,319"
    echo "  K size: 0.61 GB"
    echo "  V size: 0.61 GB"
    echo "  总计: 1.22 GB per Prefill instance"
    echo ""
}

# Step 7: 源码分析
step_7_source_code() {
    echo -e "${BOLD}${CYAN}[步骤7] 关键源码组件${NC}"
    echo ""
    
    echo -e "${YELLOW}核心文件:${NC}"
    echo ""
    echo "  src/main.rs                          - 入口，CLI解析"
    echo "  src/routers/http/pd_router.rs        - PD路由核心 (1,483 lines)"
    echo "  src/policies/cache_aware.rs          - 缓存感知策略 (31.1 KB)"
    echo "  src/core/worker_registry.rs          - Worker管理 (29.4 KB)"
    echo "  src/observability/logging.rs         - 日志系统 (4.9 KB)"
    echo "  src/observability/metrics.rs         - Prometheus指标 (48.0 KB)"
    echo ""
    
    echo -e "${YELLOW}PD Router核心逻辑:${NC}"
    echo ""
    echo "  async fn execute_dual_dispatch(...) {"
    echo "      // 同时发送到Prefill和Decode"
    echo "      let (prefill_resp, decode_resp) = tokio::join!("
    echo "          send_to_prefill(...),"
    echo "          send_to_decode(...)"
    echo "      );"
    echo ""
    echo "      // Decode响应为主输出"
    echo "      // 合并logprobs"
    echo "      // 返回最终响应"
    echo "  }"
    echo ""
}

# Step 8: 总结
step_8_summary() {
    echo -e "${BOLD}${CYAN}[步骤8] 实验总结${NC}"
    echo ""
    
    echo -e "${YELLOW}核心发现:${NC}"
    echo ""
    echo "  ✓ PD流程: Decode直接返回响应，不经过Prefill"
    echo "  ✓ Bootstrap: KV cache通过专用端口传输"
    echo "  ✓ 调度策略: Cache Aware和Random性能相当"
    echo "  ✓ 显存限制: 16GB可运行4个0.5B，无法运行2个7B"
    echo "  ✓ KV cache: 每个实例107K tokens容量"
    echo ""
    
    echo -e "${YELLOW}生产建议:${NC}"
    echo ""
    echo "  1. 使用Cache Aware策略（相似请求多时）"
    echo "  2. 合理设置mem-fraction-static"
    echo "  3. 开启Prometheus metrics监控"
    echo "  4. 使用release build提升性能"
    echo ""
}

# Interactive menu
interactive_menu() {
    while true; do
        echo -e "${BOLD}选择演示步骤:${NC}"
        echo "  1. 实验环境介绍"
        echo "  2. 启动日志分析"
        echo "  3. PD分离架构流程"
        echo "  4. 调度策略对比"
        echo "  5. 实时测试请求"
        echo "  6. Bootstrap机制"
        echo "  7. 关键源码组件"
        echo "  8. 实验总结"
        echo "  9. 执行全部步骤"
        echo "  0. 退出"
        echo ""
        echo -n "请输入选项 (0-9): "
        read choice
        
        echo ""
        case $choice in
            1) step_1_environment ;;
            2) step_2_logs ;;
            3) step_3_pd_flow ;;
            4) step_4_policies ;;
            5) step_5_test_request ;;
            6) step_6_bootstrap ;;
            7) step_7_source_code ;;
            8) step_8_summary ;;
            9) 
                step_1_environment
                step_2_logs
                step_3_pd_flow
                step_4_policies
                step_5_test_request
                step_6_bootstrap
                step_7_source_code
                step_8_summary
                ;;
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
