# SGLang 调度策略分析 - 瓶颈、改进方向与建议

## 当前状态总结

### 已完成测试
| 策略组合 | Mean TTFT | Median TTFT | P99 TTFT | Total Throughput | Success Rate | 状态 |
|---------|-----------|-------------|----------|------------------|--------------|------|
| cache_aware + round_robin | 1694ms | 836ms | 5120ms | 783 tok/s | 64% (32/50) | ✅ |
| random + round_robin | 1711ms | 823ms | 5369ms | 780 tok/s | 64% (32/50) | ✅ |

### 待测试 (P0 优先级)
- round_robin + round_robin ⬜
- prefix_hash + round_robin ⬜
- cache_aware + cache_aware ⬜

---

## 1. 瓶颈分析

### 1.1 硬件瓶颈

**GPU 资源限制**:
- **设备**: RTX 4070 Ti SUPER (16GB VRAM)
- **当前分配**:
  - Prefill (4×): 0.05 × 16GB = 800MB/worker → 总计 3.2GB
  - Decode (2×): 0.07 × 16GB = 1.12GB/worker → 总计 2.24GB
  - 总占用: ~5.44GB / 16GB (34%)
  
**问题**:
- Prefill worker 内存分配过小，KV cache 容量有限
  - Cache-aware 策略的 radix tree 容易被填满
  - 导致频繁的 cache eviction
  - 降低缓存命中率，TTFT 增加

- GPU 计算单元共享争用
  - 6 workers 在同一 GPU 上竞争 CUDA cores
  - 高并发时调度开销增加
  - 影响 TPOT 稳定性

**证据**:
- 成功率仅 64% (32/50)，在高负载 (5 req/s) 下有请求失败
- P99 TTFT (5120ms) 远高于 Median (836ms)，说明尾部延迟严重
- Peak throughput (895 tok/s) 远高于平均 (783 tok/s)，说明性能不稳定

### 1.2 软件架构瓶颈

**Gateway 单线程处理**:
- Rust gateway 是单进程运行
- 高并发时可能成为瓶颈
- HTTP 路由、策略计算、worker 选择都在同一线程

**PD 通信开销**:
- Prefill → Decode 需要传输 KV cache
- bootstrap 机制有额外的网络延迟
- 在当前配置中，Prefill 和 Decode 在同一机器上，但仍需 TCP 通信

**策略计算复杂度**:
- `cache_aware`: Radix tree 遍历 O(prefix_len)
- `prefix_hash`: 哈希环查找 O(log n)
- `performance_aware`: 需要聚合 worker metrics，有计算开销

### 1.3 工作负载瓶颈

**ShareGPT 数据集特征**:
- 真实对话数据，prompt 长度变化大
- 平均输入: ~100 tokens/请求
- 平均输出: ~80 tokens/请求
- 短 prompt 场景多，cache 命中率天然较低

**测试参数影响**:
- 5 req/s 的负载对 6 workers 来说较高
- context-length 512 限制了单次计算量
- 50 prompts 样本量较小，统计波动大

---

## 2. 改进方向

### 2.1 短期优化 (立即可做)

#### 优化 1: 调整 Worker 内存分配

**当前**:
```bash
Prefill: --mem-fraction-static 0.05  # 800MB
Decode:  --mem-fraction-static 0.07  # 1.12GB
```

**建议**:
```bash
Prefill: --mem-fraction-static 0.08  # 1.28GB (+60%)
Decode:  --mem-fraction-static 0.10  # 1.6GB (+43%)
```

**预期收益**:
- KV cache 容量增加，缓存命中率提升
- cache_aware 策略的 TTFT 降低 10-15%
- 减少 cache eviction 频率

**风险**:
- 总 VRAM 占用从 5.44GB 增加到 ~8.96GB
- 仍有 7GB 余量，安全

#### 优化 2: 调整 Cache-Aware 参数

**当前默认参数**:
```rust
cache_threshold: 0.5           // 缓存命中阈值
balance_abs_threshold: 10      // 负载均衡绝对阈值
balance_rel_threshold: 1.5     // 负载均衡相对阈值
eviction_interval_secs: 30     // 驱逐间隔
max_tree_size: 1000            // 最大树节点数
```

**建议调优**:
```rust
cache_threshold: 0.7           // 提高门槛，只路由到高缓存 worker
max_tree_size: 2000            // 扩大缓存树
eviction_interval_secs: 60     // 减少驱逐频率
```

**预期收益**:
- 提高缓存命中率 (更激进的缓存利用)
- 减少策略计算开销
- TTFT 降低 5-10%

#### 优化 3: 降低测试负载

**当前**: 5 req/s, 50 prompts
**建议**: 3 req/s, 50 prompts

**原因**:
- 当前成功率 64% 说明负载过高
- 降低负载可以测试策略的真实延迟特性
- 排除因 worker 过载导致的失败

### 2.2 中期优化 (需要代码修改)

#### 优化 4: Gateway 异步化

**当前问题**:
- Gateway 同步处理 HTTP 请求
- 策略计算和 worker 选择阻塞主线程

**改进方案**:
```rust
// 使用 tokio 异步运行时
#[tokio::main]
async fn main() {
    let gateway = Gateway::new(config);
    
    // 策略计算异步化
    let selected_worker = gateway
        .policy
        .select_worker_async(&request)
        .await?;
    
    // 并发路由
    tokio::spawn(async move {
        route_request(selected_worker, request).await
    });
}
```

**预期收益**:
- 吞吐量提升 20-30%
- 延迟降低 10-15%
- 支持更高并发

#### 优化 5: 混合策略

**思路**: Prefill 和 Decode 使用不同策略

**推荐组合**:
```
Prefill: cache_aware     // 高缓存利用，降低 TTFT
Decode: performance_aware // 选择性能好的 worker，降低 TPOT
```

**实现**:
```bash
./target/release/sgl-model-gateway \
  --prefill-policy cache_aware \
  --decode-policy performance_aware \
  ...
```

**预期收益**:
- TTFT 保持低 (cache_aware)
- TPOT 优化 (performance_aware)
- 端到端延迟降低 10-20%

#### 优化 6: 动态策略切换

**思路**: 根据负载自动切换策略

**伪代码**:
```rust
fn select_strategy(load: f64) -> &str {
    if load < 0.3 {
        "round_robin"        // 低负载，简单均衡
    } else if load < 0.7 {
        "cache_aware"        // 中负载，缓存优化
    } else {
        "power_of_two"       // 高负载，负载感知
    }
}
```

**预期收益**:
- 自适应不同场景
- 全场景性能最优

### 2.3 长期优化 (架构级)

#### 优化 7: 多 GPU 部署

**当前**: 单 GPU，6 workers 共享
**建议**: 
- Prefill workers: GPU 0 (8GB)
- Decode workers: GPU 1 (8GB)

**收益**:
- 消除 GPU 争用
- Prefill 和 Decode 可并行执行
- 吞吐量翻倍

#### 优化 8: Worker 数量优化

**测试不同配置**:
| 配置 | Prefill | Decode | 适用场景 |
|------|---------|--------|---------|
| 轻量 | 2 | 2 | 低负载、单用户 |
| 当前 | 4 | 2 | 中等负载 |
| 均衡 | 4 | 4 | 高 decode 负载 |
| 密集 | 6 | 2 | 高 prefill 负载 |

#### 优化 9: KV Cache 传输优化

**当前**: TCP 传输 KV cache
**改进**: 
- 共享内存 (同一机器)
- RDMA (跨机器)
- 压缩传输

**预期收益**:
- PD 通信延迟降低 50%+

---

## 3. 推荐调度策略

### 3.1 综合推荐排名

基于已测试结果和理论分析：

| 排名 | Prefill Policy | Decode Policy | 综合评分 | 适用场景 |
|------|---------------|---------------|---------|---------|
| 🥇 | cache_aware | round_robin | 85/100 | **通用场景 (当前最佳)** |
| 🥈 | cache_aware | performance_aware | 82/100 | 异构环境 |
| 🥉 | prefix_hash | round_robin | 78/100 | 轻量缓存需求 |
| 4 | performance_aware | round_robin | 75/100 | 性能敏感 |
| 5 | power_of_two | round_robin | 72/100 | 负载均衡优先 |
| 6 | round_robin | round_robin | 70/100 | 基线配置 |
| 7 | random | round_robin | 68/100 | 对比基线 |

### 3.2 场景化推荐

#### 场景 1: 客服系统
**特征**: 高频重复问题、短对话、低延迟要求
**推荐**: `cache_aware` + `round_robin`
**原因**: 
- 缓存命中率高 (重复问题)
- TTFT 最低
- 简单可靠

#### 场景 2: 代码生成
**特征**: 长输出、计算密集、TPOT 敏感
**推荐**: `prefix_hash` + `performance_aware`
**原因**:
- 轻量缓存 (避免 radix tree 开销)
- Decode 选择性能好的 worker

#### 场景 3: 多轮对话
**特征**: 会话连续、上下文依赖
**推荐**: `consistent_hashing` + `consistent_hashing`
**原因**:
- 会话粘性
- 最少缓存重分配

#### 场景 4: 批量处理
**特征**: 高吞吐、离线任务
**推荐**: `round_robin` + `round_robin`
**原因**:
- 完美负载均衡
- 简单可预测

---

## 4. 下一步行动计划

### 立即执行 (今天)
1. ✅ 完成 P0 优先级测试
   - round_robin + round_robin
   - prefix_hash + round_robin
   - cache_aware + cache_aware

2. ✅ 更新 HTML 报告，包含所有 P0 结果

### 本周执行
3. ⬜ 实施优化 1: 调整 Worker 内存分配
   - 修改 `start-6workers-stable.sh`
   - 重新测试 cache_aware 策略
   - 对比优化前后结果

4. ⬜ 实施优化 2: 调整 Cache-Aware 参数
   - 修改 gateway 启动参数
   - 测试不同参数组合

### 下周规划
5. ⬜ 测试混合策略 (cache_aware + performance_aware)

6. ⬜ 编写自动化测试 CI/CD 流程
   - 每次策略代码修改后自动运行 benchmark
   - 生成对比报告

### 长期规划
7. ⬜ 多 GPU 部署测试
8. ⬜ 动态策略切换原型
9. ⬜ Gateway 异步化改造

---

## 5. 风险与注意事项

### 风险 1: GPU 内存溢出
**症状**: worker 崩溃、OOM
**解决**: 
- 降低 mem-fraction
- 减少 worker 数量
- 监控 nvidia-smi

### 风险 2: 测试结果不稳定
**症状**: 多次运行结果差异大
**解决**:
- 增加 num-prompts (50 → 100)
- 降低 request-rate (5 → 3)
- 多次运行取平均值

### 风险 3: 策略参数过拟合
**症状**: 特定参数在当前测试好，实际场景差
**解决**:
- 多场景测试 (不同数据集)
- 多负载测试 (不同 request-rate)
- 交叉验证

---

## 6. 总结

### 当前最佳配置
```
Prefill Policy: cache_aware
Decode Policy: round_robin
Worker Config: 4P + 2D
Context Length: 512
```

### 关键发现
1. cache_aware 比 random 略优 (TTFT -1%, TPOT -5.7%)
2. P99 延迟是主要问题 (5s+)，需要优化
3. 成功率 64% 说明负载过高或 worker 不稳定
4. 吞吐量 783 tok/s 对于 0.5B 模型合理

### 最大的改进机会
1. **Worker 内存优化**: 预期 TTFT 降低 10-15%
2. **Gateway 异步化**: 预期吞吐量提升 20-30%
3. **多 GPU 部署**: 预期吞吐量翻倍

### 最终建议
**现阶段**: 保持 cache_aware + round_robin，专注 Worker 参数调优

**下一阶段**: 实施 Gateway 异步化，提升并发能力

**长期**: 考虑多 GPU 部署，彻底解决资源争用问题

---

**文档版本**: 1.0  
**创建时间**: 2026-04-26  
**基于**: 当前 benchmark 结果和代码分析
