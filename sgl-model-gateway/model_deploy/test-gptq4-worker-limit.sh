#!/bin/bash
# Test GPTQ-Int4 worker极限 - 从 9 到 14 workers
set -e

MODEL="/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4"
LOG_FILE="/tmp/sglang-extreme-test.log"

echo "=========================================="
echo "GPTQ-Int4 Worker 极限测试"
echo "=========================================="
echo "模型: GPTQ-Int4 (450MB)"
echo "GPU: RTX 4070 Ti Super (16GB)"
echo ""

# 清理旧进程
cleanup() {
    echo "清理旧进程..."
    killall -9 python3 2>/dev/null || true
    sleep 3
}

cleanup

# 测试函数
run_test() {
    local np=$1
    local nd=$2
    local pmem=$3
    local dmem=$4
    local total=$((np + nd))

    echo ""
    echo "=========================================="
    echo "测试: $total workers (${np}P+${nd}D)"
    echo "Prefill mem: $pmem, Decode mem: $dmem"
    echo "=========================================="

    # 启动 Prefill workers
    for i in $(seq 1 $np); do
        local port=$((30000 + i - 1))
        local bootstrap=$((90000 + i - 1))
        echo "启动 Prefill-$i on port $port..."
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$MODEL\" \
            --port $port \
            --mem-fraction-static $pmem \
            --tp 1 --pd prefill \
            --disaggregation-bootstrap-port $bootstrap \
            --host 127.0.0.1 --context-length 2048 \
            --log-level warning \
            > /tmp/sglang-extreme-prefill-$i.log 2>&1" &
        sleep 2
    done

    # 启动 Decode workers
    for i in $(seq 1 $nd); do
        local port=$((31000 + i - 1))
        echo "启动 Decode-$i on port $port..."
        setsid bash -c "source ~/qwen_env/bin/activate && python3 -m sglang.launch_server \
            --model-path \"$MODEL\" \
            --port $port \
            --mem-fraction-static $dmem \
            --tp 1 --pd decode \
            --host 127.0.0.1 --context-length 2048 \
            --log-level warning \
            > /tmp/sglang-extreme-decode-$i.log 2>&1" &
        sleep 2
    done

    # 等待稳定
    echo "等待 20 秒稳定..."
    sleep 20

    # 检查存活
    local count=$(ps aux | grep sglang | grep -v grep | wc -l)
    echo ""
    echo "结果: $count / $total workers 存活"

    # 显示显存
    echo "显存使用:"
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader

    if [ $count -eq $total ]; then
        echo "✅ SUCCESS - 全部 $total workers 稳定运行!"
        return 0
    else
        echo "❌ FAILED - 只有 $count / $total 存活"
        # 清理失败进程
        cleanup
        return 1
    fi
}

# 逐步测试
echo "开始渐进式测试..."
echo ""

# 9 workers (4P+5D)
if run_test 4 5 0.05 0.07; then
    echo ""
    echo ">>> 9 workers 成功！继续测试 10 workers..."
    sleep 5

    # 10 workers (5P+5D)
    if run_test 5 5 0.04 0.06; then
        echo ""
        echo ">>> 10 workers 成功！继续测试 11 workers..."
        sleep 5

        # 11 workers (5P+6D)
        if run_test 5 6 0.04 0.05; then
            echo ""
            echo ">>> 11 workers 成功！继续测试 12 workers..."
            sleep 5

            # 12 workers (6P+6D)
            if run_test 6 6 0.035 0.05; then
                echo ""
                echo ">>> 12 workers 成功！继续测试 13 workers..."
                sleep 5

                # 13 workers (6P+7D)
                if run_test 6 7 0.03 0.045; then
                    echo ""
                    echo ">>> 13 workers 成功！继续测试 14 workers..."
                    sleep 5

                    # 14 workers (7P+7D)
                    if run_test 7 7 0.03 0.04; then
                        echo ""
                        echo ">>> 🎉 14 workers 成功！已达测试上限"
                    else
                        echo ""
                        echo ">>> 14 workers 失败，极限在 12-13 workers"
                    fi
                else
                    echo ""
                    echo ">>> 13 workers 失败，极限在 11-12 workers"
                fi
            else
                echo ""
                echo ">>> 12 workers 失败，极限在 10-11 workers"
            fi
        else
            echo ""
            echo ">>> 11 workers 失败，极限在 9-10 workers"
        fi
    else
        echo ""
        echo ">>> 10 workers 失败，极限在 9 workers"
    fi
else
    echo ""
    echo ">>> 9 workers 失败，极限仍然是 8 workers"
fi

echo ""
echo "=========================================="
echo "极限测试完成！"
echo "=========================================="

# 最终清理
cleanup

echo ""
echo "查看日志: /tmp/sglang-extreme-*.log"
