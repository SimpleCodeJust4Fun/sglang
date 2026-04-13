#!/bin/bash
# Quick Test Commands for Multi-PD Environment
# 快速测试命令集合

echo "=========================================="
echo " Multi-PD Quick Test Commands"
echo "=========================================="
echo ""

GATEWAY="http://127.0.0.1:3000"

echo "1. 检查所有服务健康状态:"
echo "   curl -s http://127.0.0.1:30000/health && echo ' P1 OK' || echo ' P1 FAIL'"
echo "   curl -s http://127.0.0.1:30001/health && echo ' P2 OK' || echo ' P2 FAIL'"
echo "   curl -s http://127.0.0.1:30010/health && echo ' D1 OK' || echo ' D1 FAIL'"
echo "   curl -s http://127.0.0.1:30011/health && echo ' D2 OK' || echo ' D2 FAIL'"
echo "   curl -s $GATEWAY/health && echo ' GW OK' || echo ' GW FAIL'"
echo ""

echo "2. 简单对话测试:"
echo "   curl -s -X POST $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"qwen2.5-0.5b-instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 50}' | python3 -m json.tool"
echo ""

echo "3. 中文对话测试:"
echo "   curl -s -X POST $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"qwen2.5-0.5b-instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"你好，介绍一下自己\"}], \"max_tokens\": 100}' | python3 -m json.tool"
echo ""

echo "4. Generate API测试:"
echo "   curl -s -X POST $GATEWAY/generate -H 'Content-Type: application/json' -d '{\"text\": \"Python is\", \"sampling_params\": {\"max_new_tokens\": 50}}' | python3 -m json.tool"
echo ""

echo "5. 并发请求测试 (5个):"
echo "   for i in 1 2 3 4 5; do curl -s -X POST $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\": \"qwen2.5-0.5b-instruct\", \"messages\": [{\"role\": \"user\", \"content\": \"Count to \$i\"}], \"max_tokens\": 20}' > /tmp/req_\$i.json & done; wait; echo 'All done'; for i in 1 2 3 4 5; do python3 -c \"import json; print(f'Req \$i:', json.load(open('/tmp/req_\$i.json'))['choices'][0]['message']['content'][:50])\"; done"
echo ""

echo "6. 查看Gateway日志 (最近20行):"
echo "   tail -20 /tmp/sgl-gateway-*.log"
echo ""

echo "7. 查看GPU使用情况:"
echo "   nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader"
echo "   nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv"
echo ""

echo "8. 停止所有服务:"
echo "   killall -9 python3 sgl-model-gateway"
echo ""

echo "=========================================="
echo " 启动流程 (三步):"
echo "=========================================="
echo "1. 启动多PD环境: bash start-multi-pd.sh"
echo "2. 启动Gateway:    bash start-gateway-multi.sh round_robin"
echo "3. 执行测试:       使用上面的命令"
echo "=========================================="
