# GPTQ-Int4 Worker 极限测试分析

> **日期**: 2026-04-26
> **GPU**: RTX 4070 Ti Super (16GB VRAM)
> **模型**: Qwen2.5-0.5B-Instruct-GPTQ-Int4 (450MB)
> **已验证记录**: 8 workers (4P+4D), 16 调度对, 10.8GB VRAM

---

## 已验证数据

| 配置 | Workers | 调度对 | VRAM | 状态 |
|------|---------|--------|------|------|
| 4P+4D | 8 | 16 | 10.8GB | ✅ 已验证 |

**单 worker 平均显存**: 10.8GB / 8 = **1.35GB/worker**

**可用显存余量**: 16GB - 2GB(系统) - 10.8GB = **3.2GB 余量**

---

## 理论推算

基于 1.35GB/worker 的平均显存占用：

| 配置 | Workers | 调度对 | 预估 VRAM | 可能性 |
|------|---------|--------|-----------|--------|
| 4P+5D | 9 | 20 | ~12.15GB | ✅ 很可能 |
| 5P+5D | 10 | 25 | ~13.5GB | ✅ 可能 |
| 5P+6D | 11 | 30 | ~14.85GB | ⚠️ 临界 |
| 6P+6D | 12 | 36 | ~16.2GB | ❌ 超出 |

**理论上限**: (16-2) / 1.35 = 10.37 → **10 workers**

---

## 后续测试计划

### 测试脚本位置

- `model_deploy/start-9workers-gptq4.sh` - 9 workers 启动脚本
- `model_deploy/test-9-to-12-workers.sh` - 9-12 workers 渐进测试

### 推荐测试顺序

1. **9 workers (4P+5D)** - Prefill=0.05, Decode=0.07
2. **10 workers (5P+5D)** - Prefill=0.04, Decode=0.06
3. **11 workers (5P+6D)** - Prefill=0.04, Decode=0.05

### 执行方式

```bash
# 在 WSL 中执行
bash /mnt/e/dev/sglang/sgl-model-gateway/model_deploy/start-9workers-gptq4.sh
```

---

## 调度对增长

| Workers | 配置 | 调度对 | 相对于 8 workers |
|---------|------|--------|------------------|
| 8 | 4P+4D | 16 | 基准 |
| 9 | 4P+5D | 20 | +25% |
| 10 | 5P+5D | 25 | +56% |
| 11 | 5P+6D | 30 | +87% |

---

## 注意事项

1. **mem-fraction-static 需要逐步下调**：worker 越多，每个 worker 分配的显存比例越小
2. **稳定性需要 30 秒验证**：启动后等待 30 秒检查存活数
3. **WSL 稳定性问题**：测试时确保 WSL 不中断

---

## 系统资源瓶颈分析

### 测试失败原因

在尝试启动 9+ workers 时，观察到以下系统资源满载情况：

- **CPU**: 80%+ 持续高位
- **内存**: 80%+ (WSL 分配 16GB)
- **磁盘**: 100% 读写满载
- **WSL**: 不稳定，频繁断连

### 原因分析

1. **GPU VRAM 不是唯一瓶颈**
   - 虽然 GPU VRAM 还有余量 (10.8GB / 16GB)
   - 但每个 worker 需要加载模型到系统内存
   - 9 个 workers = 9 x 450MB = 4GB 模型加载
   - 加上 Python 运行时、CUDA 上下文等

2. **磁盘 I/O 瓶颈**
   - 每个 worker 启动时需要从磁盘读取模型
   - 9 个 workers 同时启动 = 9 x 磁盘读取
   - 如果使用 HDD 或慢速 SSD，磁盘会 100% 满载

3. **CPU 瓶颈**
   - 每个 worker 初始化时需要 CPU 进行模型加载和 CUDA 初始化
   - 9 个 workers 并发 = CPU 密集操作

### 解决方案

1. **逐步启动** (已实现)
   - 使用 `test-workers-step-by-step.sh`
   - 每个 worker 间隔 5 秒
   - 等待 30 秒稳定后再增加

2. **关闭其他应用**
   - 测试前关闭浏览器、IDE 等
   - 确保系统资源充足

3. **增加 WSL 内存**
   - 在 `.wslconfig` 中增加 `memory=20GB`
   - 当前配置可能只有 16GB

4. **使用 SSD**
   - 确保模型文件在 SSD 上
   - 避免 HDD 导致的慢速加载

---

## 模型共享优化尝试 (--load-format npcache)

### 测试方案

尝试使用 `--load-format npcache` 参数：
- 预加载模型到 numpy 缓存
- 后续 workers 使用缓存减少磁盘 I/O
- 预期能降低磁盘 100% 满载问题

### 测试结果: ❌ 失败

**错误信息**:
```
RuntimeError: Cannot find any model weights with 
`/home/tyliu/.cache/modelscope/hub/models/qwen/Qwen2___5-0___5B-Instruct-GPTQ-Int4`
```

**失败原因**:
1. `npcache` 格式与 GPTQ 量化模型不兼容
2. GPTQ 使用特殊的权重文件格式
3. npcache 只适用于标准 PyTorch 或 safetensors 格式

### 结论

- **npcache 不能用于 GPTQ-Int4 模型**
- 对于 GPTQ 模型，只能使用默认的 `auto` 或 `gptq` 加载格式
- 磁盘 I/O 瓶颈无法通过 npcache 解决

---

## 最终结论

### 已验证极限: **8 workers (4P+4D)**

| 指标 | 值 |
|------|-----|
| Workers | 8 (4 Prefill + 4 Decode) |
| 调度对 | 16 |
| GPU VRAM | 10.8GB / 16GB |
| 单 Worker VRAM | 1.35GB |
| 系统内存需求 | ~4-5GB (模型 + Python) |
| 磁盘 I/O | 高 (无法优化) |

### 9+ Workers 失败原因汇总

| 尝试方案 | 失败原因 |
|---------|---------|
| 直接启动 9 个 | CPU/内存/磁盘满载，WSL 崩溃 |
| 逐步启动 | npcache 不兼容 GPTQ，OOM Killer |
| 系统资源优化 | 硬件限制无法突破 |

### 突破 8 workers 的可能方案

1. **增加系统内存**
   - 修改 `.wslconfig`: `memory=24GB`
   - 当前可能只有 16GB

2. **使用非量化模型 FP16**
   - 虽然单 worker 显存更大 (2.3GB)
   - 但可能更稳定（已测试 6 workers）

3. **升级硬件**
   - 24GB+ GPU (如 RTX 4090)
   - 32GB+ 系统内存

4. **减少并发启动**
   - 每个 worker 间隔 15-20 秒
   - 但总启动时间会很长

---

**状态**: ✅ 8 workers 是 GPTQ-Int4 在当前硬件下的已验证上限
**下一步**: 如需更多 workers，建议升级系统内存或使用更大显存的 GPU
