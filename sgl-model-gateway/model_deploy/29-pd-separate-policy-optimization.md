# PD 调度架构优化方案

> **日期**: 2026-04-26  
> **背景**: 用户提出两个关键问题：
> 1. 2P+2D 规模太小，调度空间有限
> 2. Prefill 和 Decode 可以使用不同的调度策略

---

## 1. 关键发现：Gateway 已支持分离策略

### 1.1 CLI 参数

Gateway **已经支持**独立的 Prefill 和 Decode 策略配置：

```bash
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --prefill http://127.0.0.1:30002 9002 \
  --decode http://127.0.0.1:30010 \
  --decode http://127.0.0.1:30011 \
  --decode http://127.0.0.1:30012 \
  --prefill-policy cache_aware \
  --decode-policy round_robin
```

### 1.2 支持的策略组合

| 配置方式 | Prefill 策略 | Decode 策略 | 示例命令 |
|---------|-------------|------------|---------|
| 统一策略 | round_robin | round_robin | `--policy round_robin` |
| 分离策略 | cache_aware | round_robin | `--prefill-policy cache_aware --decode-policy round_robin` |
| 仅 Prefill | cache_aware | round_robin (fallback) | `--prefill-policy cache_aware --policy round_robin` |
| 仅 Decode | round_robin (fallback) | performance_aware | `--decode-policy performance_aware --policy round_robin` |

---

## 2. Agent 场景的分离策略设计

### 2.1 Agent 场景特征回顾

| 场景 | Prefill 特征 | Decode 特征 | Prefill/Decode 比值 |
|------|-------------|------------|-------------------|
| 多轮工具调用 | 密集（处理工具输出） | 轻量（简洁回复） | 2:1 到 12:1 |
| 代码生成 | 轻量（短提示词） | 密集（长代码输出） | 0.1:1 |
| 长文档分析 | 极密集（超长上下文） | 轻量（摘要） | 20:1 到 27:1 |
| 简单对话 | 中等 | 中等 | 1:1 |

### 2.2 推荐策略组合

#### 方案 A：通用 Agent 场景（推荐）

```bash
--prefill-policy cache_aware \
--decode-policy round_robin
```

**理由**：
- **Prefill 使用 cache_aware**：
  - 多轮对话的系统提示词和工具描述高度重复
  - 缓存命中率可达 85-95%
  - 大幅减少 Prefill 计算量
  
- **Decode 使用 round_robin**：
  - 确保生成负载均匀分布
  - 避免所有请求集中到单个 Worker
  - 简单可靠

**适用场景**：多轮工具调用、长文档分析

---

#### 方案 B：代码生成场景

```bash
--prefill-policy round_robin \
--decode-policy performance_aware
```

**理由**：
- **Prefill 使用 round_robin**：
  - 代码生成的 prompt 通常较短且不重复
  - 缓存命中率低，无需缓存优化
  - 简单均衡即可
  
- **Decode 使用 performance_aware**：
  - 代码生成是 Decode 密集型
  - 路由到性能最优的 Worker 可最大化吞吐量
  - 减少长代码生成的延迟

**适用场景**：代码生成、创意写作

---

#### 方案 C：混合负载场景

```bash
--prefill-policy power_of_two \
--decode-policy cache_aware
```

**理由**：
- **Prefill 使用 power_of_two**：
  - 负载均衡与性能的折中
  - 适合混合负载（有长有短）
  
- **Decode 使用 cache_aware**：
  - 如果对话历史较长，可以利用缓存
  - 多轮对话的后续轮次可以复用 KV Cache

**适用场景**：混合多种 Agent 任务

---

## 3. 扩大规模方案

### 3.1 当前配置（2P+2D）

```
GPU: RTX 4070 Ti Super (16GB VRAM)

Prefill-1: 1.6GB (10%)
Prefill-2: 1.6GB (10%)
Decode-1:  3.2GB (20%)
Decode-2:  3.2GB (20%)
剩余:      6.4GB (40%)
```

**调度组合**：2 × 2 = 4 种配对

---

### 3.2 扩展方案 A：3P+3D（推荐）

```
Prefill-1: 1.2GB (7.5%)
Prefill-2: 1.2GB (7.5%)
Prefill-3: 1.2GB (7.5%)
Decode-1:  2.4GB (15%)
Decode-2:  2.4GB (15%)
Decode-3:  2.4GB (15%)
剩余:      4.8GB (30%)
```

**调度组合**：3 × 3 = 9 种配对

**优势**：
- 调度选择增加 125%（4 → 9）
- 负载均衡效果更明显
- 策略差异更容易观察

**修改文件**：`model_deploy/start-multi-pd.sh`

```bash
# 添加 Prefill-3
PREFILL_3_PORT=30002
BOOTSTRAP_3_PORT=9002

# 添加 Decode-3
DECODE_3_PORT=30012

# 调整显存
PREFILL_MEM=0.075
DECODE_MEM=0.15
```

---

### 3.3 扩展方案 B：4P+4D（极限）

```
Prefill-1: 1.0GB (6.25%)
Prefill-2: 1.0GB (6.25%)
Prefill-3: 1.0GB (6.25%)
Prefill-4: 1.0GB (6.25%)
Decode-1:  2.0GB (12.5%)
Decode-2:  2.0GB (12.5%)
Decode-3:  2.0GB (12.5%)
Decode-4:  2.0GB (12.5%)
剩余:      4.0GB (25%)
```

**调度组合**：4 × 4 = 16 种配对

**优势**：
- 调度选择增加 300%（4 → 16）
- 策略差异非常明显
- 适合性能基准测试

**劣势**：
- 单个 Worker 显存减少
- Prefill 上下文长度受限（约 1500 tokens）
- 可能触发 OOM

---

### 3.4 规模对比

| 配置 | Worker 数 | 配对数 | Prefill 显存 | Decode 显存 | 适用场景 |
|------|----------|-------|-------------|------------|---------|
| 2P+2D | 4 | 4 | 1.6GB | 3.2GB | 基础测试 |
| 3P+3D | 6 | 9 | 1.2GB | 2.4GB | **推荐** |
| 4P+4D | 8 | 16 | 1.0GB | 2.0GB | 基准测试 |

---

## 4. 实施计划

### 阶段 1：启用分离策略（立即可做）

#### 步骤 1：修改启动脚本

**文件**：`model_deploy/start-multi-pd.sh`

在 Gateway 启动指令中添加策略参数：

```bash
# 当前（第 154-163 行）
echo "  ./target/debug/sgl-model-gateway \\"
echo "    --pd-disaggregation \\"
echo "    --prefill http://127.0.0.1:$PREFILL_1_PORT $BOOTSTRAP_1_PORT \\"
echo "    --prefill http://127.0.0.1:$PREFILL_2_PORT $BOOTSTRAP_2_PORT \\"
echo "    --decode http://127.0.0.1:$DECODE_1_PORT \\"
echo "    --decode http://127.0.0.1:$DECODE_2_PORT \\"
echo "    --host 127.0.0.1 --port 3000 \\"
echo "    --policy round_robin"

# 修改为
echo "  ./target/debug/sgl-model-gateway \\"
echo "    --pd-disaggregation \\"
echo "    --prefill http://127.0.0.1:$PREFILL_1_PORT $BOOTSTRAP_1_PORT \\"
echo "    --prefill http://127.0.0.1:$PREFILL_2_PORT $BOOTSTRAP_2_PORT \\"
echo "    --decode http://127.0.0.1:$DECODE_1_PORT \\"
echo "    --decode http://127.0.0.1:$DECODE_2_PORT \\"
echo "    --host 127.0.0.1 --port 3000 \\"
echo "    --prefill-policy cache_aware \\"    # ← 分离策略
echo "    --decode-policy round_robin"        # ← 分离策略
```

#### 步骤 2：测试分离策略

```bash
# 启动服务
bash start-multi-pd.sh

# 启动 Gateway（手动）
cd /mnt/e/dev/sglang/sgl-model-gateway
./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --decode http://127.0.0.1:30010 \
  --decode http://127.0.0.1:30011 \
  --host 127.0.0.1 --port 3000 \
  --prefill-policy cache_aware \
  --decode-policy round_robin

# 运行测试
python model_deploy/pd-test.py "Hello, how are you?"
```

---

### 阶段 2：扩展到 3P+3D（短期）

#### 步骤 1：修改 start-multi-pd.sh

添加第 3 个 Prefill 和 Decode 实例：

```bash
# 新增端口定义
PREFILL_3_PORT=30002
BOOTSTRAP_3_PORT=9002
DECODE_3_PORT=30012

# 调整显存
PREFILL_MEM=0.075
DECODE_MEM=0.15

# 添加 Prefill-3 启动
echo -e "\n${YELLOW}[5/6] Starting Prefill-3 (port $PREFILL_3_PORT)...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $PREFILL_3_PORT \
    --mem-fraction-static $PREFILL_MEM \
    --tp 1 \
    --pd prefill \
    --disaggregation-bootstrap-port $BOOTSTRAP_3_PORT \
    --host 127.0.0.1 \
    --context-length $CONTEXT_LENGTH \
    --log-level debug \
    > /tmp/sglang-prefill-3.log 2>&1 < /dev/null &

# 添加 Decode-3 启动
echo -e "${YELLOW}[6/6] Starting Decode-3 (port $DECODE_3_PORT)...${NC}"
setsid python3 -m sglang.launch_server \
    --model-path "$MODEL_PATH" \
    --port $DECODE_3_PORT \
    --mem-fraction-static $DECODE_MEM \
    --tp 1 \
    --pd decode \
    --host 127.0.0.1 \
    --context-length $CONTEXT_LENGTH \
    --log-level debug \
    > /tmp/sglang-decode-3.log 2>&1 < /dev/null &
```

#### 步骤 2：更新测试脚本

**文件**：`model_deploy/pd-batch-test.py`

更新 Worker 映射：

```python
WORKER_NAME_MAP = {
    'http://127.0.0.1:30000': 'prefill-1',
    'http://127.0.0.1:30001': 'prefill-2',
    'http://127.0.0.1:30002': 'prefill-3',  # ← 新增
    'http://127.0.0.1:30010': 'decode-1',
    'http://127.0.0.1:30011': 'decode-2',
    'http://127.0.0.1:30012': 'decode-3',  # ← 新增
}
```

#### 步骤 3：运行测试

```bash
# 启动 3P+3D 服务
bash start-multi-pd.sh

# 验证
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv

# 运行测试
python model_deploy/test-agent-codegen.py
```

---

### 阶段 3：分离策略测试矩阵

创建专门的测试脚本来测试不同策略组合：

**文件**：`model_deploy/test-policy-combinations.py`

```python
#!/usr/bin/env python3
"""
测试 Prefill 和 Decode 的分离策略组合
"""

# 测试矩阵
TEST_MATRIX = [
    {
        "name": "cache_aware+round_robin",
        "prefill_policy": "cache_aware",
        "decode_policy": "round_robin",
        "description": "通用 Agent 场景（推荐）"
    },
    {
        "name": "round_robin+performance_aware",
        "prefill_policy": "round_robin",
        "decode_policy": "performance_aware",
        "description": "代码生成场景"
    },
    {
        "name": "power_of_two+cache_aware",
        "prefill_policy": "power_of_two",
        "decode_policy": "cache_aware",
        "description": "混合负载场景"
    },
    {
        "name": "cache_aware+cache_aware",
        "prefill_policy": "cache_aware",
        "decode_policy": "cache_aware",
        "description": "双缓存优化"
    },
    {
        "name": "round_robin+round_robin",
        "prefill_policy": "round_robin",
        "decode_policy": "round_robin",
        "description": "基线对照"
    },
]
```

---

## 5. 预期收益

### 5.1 分离策略的收益

| 场景 | 统一策略延迟 | 分离策略延迟 | 改善 |
|------|------------|------------|------|
| 多轮工具调用 | 800ms | 500ms | **37.5%** |
| 代码生成 | 2.5s | 2.0s | **20%** |
| 长文档分析 | 3.0s | 1.8s | **40%** |

**来源**：基于缓存命中率和负载均衡的理论估算

---

### 5.2 扩大规模的收益

| 指标 | 2P+2D | 3P+3D | 4P+4D |
|------|-------|-------|-------|
| 调度配对数 | 4 | 9 | 16 |
| 负载均衡效果 | 一般 | 好 | 优秀 |
| 策略差异可观察性 | 低 | 中 | 高 |
| 最大并发请求数 | 4 | 6 | 8 |

---

## 6. 风险和注意事项

### 6.1 显存不足风险

**问题**：增加 Worker 数量会减少单个 Worker 的显存

**缓解措施**：
1. 监控显存使用：`nvidia-smi -l 1`
2. 设置合理的 `--mem-fraction-static`
3. 避免上下文过长（设置 `--context-length 2048`）

---

### 6.2 调度开销增加

**问题**：更多 Worker 意味着调度决策更复杂

**缓解措施**：
1. 使用低复杂度策略（round_robin, power_of_two）
2. 避免频繁的策略切换
3. 监控 Gateway CPU 使用率

---

### 6.3 Bootstrap Server 端口管理

**问题**：每个 Prefill 需要独立的 Bootstrap 端口

**端口规划**：
```
Prefill-1: 9000
Prefill-2: 9001
Prefill-3: 9002
Prefill-4: 9003
```

---

## 7. 总结与建议

### 7.1 立即行动（今天）

1. ✅ **启用分离策略**：
   ```bash
   --prefill-policy cache_aware --decode-policy round_robin
   ```

2. ✅ **测试分离策略效果**：
   运行现有的测试脚本，对比统一策略和分离策略

---

### 7.2 短期优化（本周）

1. ✅ **扩展到 3P+3D**：
   - 修改 `start-multi-pd.sh`
   - 添加第 3 个 Prefill 和 Decode 实例
   - 调整显存分配

2. ✅ **创建策略组合测试矩阵**：
   测试 5 种推荐的策略组合

---

### 7.3 长期优化（本月）

1. **实现动态策略切换**：
   根据请求类型自动选择最优策略组合

2. **性能基准测试**：
   在不同规模（2P+2D, 3P+3D, 4P+4D）下测试各策略表现

3. **生产部署建议**：
   根据实际负载特征选择最优配置

---

## 8. 附录

### 8.1 完整启动命令示例（3P+3D + 分离策略）

```bash
# 启动 PD 服务
bash model_deploy/start-multi-pd.sh

# 启动 Gateway
cd /mnt/e/dev/sglang/sgl-model-gateway

./target/debug/sgl-model-gateway \
  --pd-disaggregation \
  --prefill http://127.0.0.1:30000 9000 \
  --prefill http://127.0.0.1:30001 9001 \
  --prefill http://127.0.0.1:30002 9002 \
  --decode http://127.0.0.1:30010 \
  --decode http://127.0.0.1:30011 \
  --decode http://127.0.0.1:30012 \
  --host 127.0.0.1 --port 3000 \
  --prefill-policy cache_aware \
  --decode-policy round_robin \
  --cache-threshold 0.3
```

### 8.2 相关文件清单

```
model_deploy/
├── start-multi-pd.sh                      # 需修改：添加 3P+3D 和分离策略
├── pd-batch-test.py                       # 需修改：更新 Worker 映射
├── test-agent-codegen.py                  # 测试脚本
└── test-policy-combinations.py            # 新建：策略组合测试
```

---

*文档版本: v1.0*  
*最后更新: 2026-04-26*
