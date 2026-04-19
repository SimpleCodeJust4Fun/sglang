#!/bin/bash
# 异构GPU调度策略演示脚本
# 本脚本演示如何使用新实现的三种调度策略

echo "=========================================="
echo "异构GPU调度策略演示"
echo "=========================================="
echo ""

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}本演示展示三种新的调度策略:${NC}"
echo "1. RequestSizeBucket - 基于请求长度的分桶策略"
echo "2. PerformanceAware - 性能感知策略"
echo "3. RequestClassification - 请求分类策略"
echo ""

# 示例 1: RequestSizeBucket 策略
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}示例 1: RequestSizeBucket 策略${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "策略说明:"
echo "- 短请求 (<100字符): 路由到低延迟GPU"
echo "- 中等请求 (100-500字符): 路由到均衡型GPU"
echo "- 长请求 (>=500字符): 路由到大显存GPU"
echo ""
echo "配置文件示例 (config.json):"
cat << 'EOF'
{
  "policy": {
    "type": "request_size_bucket",
    "short_threshold": 100,
    "medium_threshold": 500,
    "track_load_per_bucket": true
  },
  "mode": {
    "type": "regular",
    "worker_urls": [
      "http://gpu-fast:8000",
      "http://gpu-balanced:8000",
      "http://gpu-memory:8000"
    ]
  }
}
EOF
echo ""
echo "工作原理:"
echo "1. 自动根据 priority/cost 比例将worker分类"
echo "2. 高priority+低cost → 短请求桶"
echo "3. 低priority+高cost → 长请求桶"
echo "4. 每个桶独立跟踪负载"
echo ""

# 示例 2: PerformanceAware 策略
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}示例 2: PerformanceAware 策略${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "策略说明:"
echo "- 综合考虑 TTFT、TPOT、吞吐量指标"
echo "- 自动计算性能分数并定期刷新"
echo "- 适用于异构GPU环境"
echo ""
echo "配置文件示例 (config.json):"
cat << 'EOF'
{
  "policy": {
    "type": "performance_aware",
    "weight_ttft": 0.3,
    "weight_tpot": 0.3,
    "weight_throughput": 0.4,
    "score_refresh_interval_secs": 60,
    "consider_load": true
  },
  "mode": {
    "type": "regular",
    "worker_urls": [
      "http://gpu-a100:8000",
      "http://gpu-v100:8000",
      "http://gpu-t4:8000"
    ]
  }
}
EOF
echo ""
echo "工作原理:"
echo "1. 收集每个worker的性能指标(TTFT/TPOT/吞吐量)"
echo "2. 归一化指标到0-1范围"
echo "3. 按权重计算综合分数"
echo "4. 选择分数最高的worker"
echo "5. 定期刷新分数以适适应性能变化"
echo ""

# 示例 3: RequestClassification 策略
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}示例 3: RequestClassification 策略${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "策略说明:"
echo "- 计算密集型(短输入+长输出): 路由到高端GPU"
echo "- 内存密集型(长输入+短输出): 路由到大显存GPU"
echo "- 均衡型(中等输入+中等输出): 路由到均衡GPU"
echo ""
echo "配置文件示例 (config.json):"
cat << 'EOF'
{
  "policy": {
    "type": "request_classification",
    "short_input_threshold": 100,
    "medium_input_threshold": 500,
    "small_output_threshold": 100,
    "medium_output_threshold": 500,
    "auto_assign_workers": true
  },
  "mode": {
    "type": "regular",
    "worker_urls": [
      "http://gpu-a100:8000",
      "http://gpu-a100-2:8000",
      "http://gpu-4090:8000",
      "http://gpu-3090:8000"
    ]
  }
}
EOF
echo ""
echo "工作原理:"
echo "1. 分析请求的输入长度和预期输出长度"
echo "2. 分类为计算密集型/内存密集型/均衡型"
echo "3. 根据worker的priority/cost自动分类"
echo "4. 将请求路由到匹配的worker类型"
echo ""

# PD模式示例
echo -e "${YELLOW}=========================================${NC}"
echo -e "${YELLOW}PD模式下的策略配置示例${NC}"
echo -e "${YELLOW}=========================================${NC}"
echo ""
echo "在PD分离架构中，可以为Prefill和Decode分别配置不同策略:"
cat << 'EOF'
{
  "mode": {
    "type": "prefill_decode",
    "prefill_urls": [
      ["http://prefill-1:8000", 8001],
      ["http://prefill-2:8000", 8002]
    ],
    "decode_urls": [
      "http://decode-1:8000",
      "http://decode-2:8000",
      "http://decode-3:8000"
    ],
    "prefill_policy": {
      "type": "request_size_bucket",
      "short_threshold": 100,
      "medium_threshold": 500
    },
    "decode_policy": {
      "type": "performance_aware",
      "weight_ttft": 0.2,
      "weight_tpot": 0.5,
      "weight_throughput": 0.3
    }
  }
}
EOF
echo ""
echo "说明:"
echo "- Prefill阶段使用 RequestSizeBucket: 根据prompt长度分配到不同prefill实例"
echo "- Decode阶段使用 PerformanceAware: 根据生成性能选择最优decode实例"
echo ""

# 测试建议
echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}测试建议${NC}"
echo -e "${BLUE}=========================================${NC}"
echo ""
echo "1. 启动Gateway时使用新策略:"
echo "   cargo run -- --config config.json"
echo ""
echo "2. 发送不同长度的请求观察路由:"
echo "   # 短请求"
echo '   curl -X POST http://localhost:3001/v1/chat/completions \'
echo '     -H "Content-Type: application/json" \'
echo '     -d '\''{"model": "test", "messages": [{"role": "user", "content": "Hi"}]}'\'''
echo ""
echo "   # 长请求"
echo '   curl -X POST http://localhost:3001/v1/chat/completions \'
echo '     -H "Content-Type: application/json" \'
echo '     -d '\''{"model": "test", "messages": [{"role": "user", "content": "'
echo '这是一个非常长的输入..."'}]}'\'''
echo ""
echo "3. 查看日志中的路由决策:"
echo "   tail -f /tmp/sglang-gateway.log | grep RequestSizeBucket"
echo "   tail -f /tmp/sglang-gateway.log | grep PerformanceAware"
echo "   tail -f /tmp/sglang-gateway.log | grep RequestClassification"
echo ""

echo -e "${GREEN}=========================================="
echo "演示完成!"
echo -e "==========================================${NC}"
