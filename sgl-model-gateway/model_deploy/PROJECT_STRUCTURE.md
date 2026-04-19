# 项目文件结构

```
model-deploy/
│
├── 📘 核心文档
│   ├── README.md                          # 项目总览和快速开始
│   ├── deployment-comparison.md           # 两种部署方案对比指南 ★NEW★
│   └── git_push_guide.md                  # Git 推送指南
│
├── 🏗️ 基础部署方案 (单机版)
│   ├── 01-部署总结.md                     # WSL2 + SGLang 单机部署详解
│   ├── 02-服务启停手册.md                 # 服务管理和故障排查
│   ├── 03-SGLang学习指南.md               # SGLang 框架学习路径
│   ├── 04-调试技巧.md                     # 性能调优和问题诊断
│   │
│   ├── 🔧 脚本和工具
│   │   ├── start_sglang.sh                # SGLang 服务启动脚本
│   │   ├── test_sglang_api.py             # API 测试脚本
│   │   ├── download_awq.py                # 模型下载脚本
│   │   └── test_qwen.py                   # Transformers 测试 (历史)
│   │
│   └── 📦 环境配置
│       ├── miniconda.sh                   # Miniconda 安装脚本
│       ├── get-pip.py                     # pip 安装工具
│       └── cuda-keyring_1.1-1_all.deb     # CUDA 密钥环
│
└── 🚀 高级部署方案 (Kubernetes + Hami vGPU) ★NEW★
    └── hami-sglang-deployment/
        │
        ├── 📖 文档
        │   ├── README.md                  # 方案概述和架构设计
        │   ├── ARCHITECTURE.md            # 详细架构设计文档
        │   ├── DEPLOYMENT_GUIDE.md        # 完整部署流程指南
        │   └── QUICK_REFERENCE.md         # 快速参考手册
        │
        ├── ☸️ Kubernetes Manifests
        │   ├── hami-configmap.yaml        # Hami 配置 ConfigMap
        │   ├── hami-scheduler.yaml        # Hami Scheduler 部署
        │   ├── hami-device-plugin.yaml    # Hami Device Plugin 部署
        │   ├── model-storage.yaml         # 模型持久化存储
        │   ├── qwen-prefill-deployment.yaml   # Prefill Pod 部署
        │   ├── qwen-decode-deployment.yaml    # Decode Pod 部署
        │   └── sglang-router-deployment.yaml  # Router 部署
        │
        ├── 🔧 脚本和工具
        │   ├── deploy.sh                  # 一键部署脚本
        │   └── test_sglang_pd.py          # PD 分离服务测试工具
        │
        └── 📝 使用说明
            └── (参见上方文档中的详细说明)
```

## 📂 文件说明

### 基础部署方案文件

| 文件 | 用途 | 适用人群 |
|------|------|---------|
| `start_sglang.sh` | 启动 SGLang 服务 | 所有用户 |
| `test_sglang_api.py` | 测试 API 端点 | 开发者 |
| `01-部署总结.md` | 完整部署教程 | 新手 |
| `03-SGLang学习指南.md` | 进阶学习路径 | 进阶用户 |

### 高级部署方案文件

| 文件 | 用途 | 重要程度 |
|------|------|---------|
| `README.md` | 方案介绍 | ⭐⭐⭐⭐⭐ |
| `ARCHITECTURE.md` | 架构原理 | ⭐⭐⭐⭐ |
| `DEPLOYMENT_GUIDE.md` | 部署步骤 | ⭐⭐⭐⭐⭐ |
| `QUICK_REFERENCE.md` | 速查手册 | ⭐⭐⭐⭐ |
| `deploy.sh` | 自动化部署 | ⭐⭐⭐⭐⭐ |
| `test_sglang_pd.py` | 测试工具 | ⭐⭐⭐⭐ |

## 🎯 使用建议

### 新手入门路线

```
1. 阅读 README.md
   ↓
2. 选择部署方案 (单机 or K8s)
   ↓
3. 按照对应指南操作
   ├─ 单机：01-部署总结.md
   └─ K8s: hami-sglang-deployment/DEPLOYMENT_GUIDE.md
   ↓
4. 使用测试工具验证
   ├─ 单机：test_sglang_api.py
   └─ K8s: test_sglang_pd.py
   ↓
5. 遇到问题查看调试技巧
   └─ 04-调试技巧.md / QUICK_REFERENCE.md
```

### 开发者路线

```
1. 阅读 ARCHITECTURE.md 理解架构
   ↓
2. 研究 Kubernetes YAML 配置
   ↓
3. 自定义配置参数
   ↓
4. 开发定制功能
   ↓
5. 贡献代码和改进
```

## 📊 文件大小统计

| 类别 | 文件数 | 总大小估算 |
|------|--------|-----------|
| 文档 (.md) | 9 | ~150 KB |
| Kubernetes YAML | 7 | ~20 KB |
| Shell 脚本 | 2 | ~10 KB |
| Python 脚本 | 4 | ~30 KB |
| 其他 | 3 | ~5 MB (包含安装包) |

## 🔄 版本控制

### Git 分支策略

```
main (主分支)
├─ feature/single-node (单机部署优化)
├─ feature/k8s-hami (K8s 方案开发)
├─ docs/improvement (文档改进)
└─ bugfix/* (问题修复)
```

### 提交规范

```bash
# 功能新增
git commit -m "feat: add Hami vGPU scheduler configuration"

# 文档更新
git commit -m "docs: update architecture diagram"

# Bug 修复
git commit -m "fix: correct vGPU memory allocation"

# 配置修改
git commit -m "config: adjust default GPU memory to 6GB"
```

## 🤝 贡献指南

### 添加新文档

1. 在对应目录创建 `.md` 文件
2. 在上级 README 中添加索引链接
3. 提交时写清楚变更说明

### 修改配置文件

1. 备份原文件
2. 在 PR 中说明修改原因
3. 测试通过后合并

### 报告问题

创建 Issue 时提供以下信息:
- 部署方案 (单机/K8s)
- 错误日志
- 环境信息
- 复现步骤

## 📅 更新日志

### v2.0.0 (2026-04-02) - ★NEW★
- ✅ 新增 Kubernetes + Hami vGPU 部署方案
- ✅ 新增 PD 分离架构支持
- ✅ 新增一键部署脚本
- ✅ 完善架构文档和快速参考

### v1.0.0 (2026-01-25)
- ✅ 初始版本发布
- ✅ WSL2 + SGLang 单机部署
- ✅ Qwen2.5-7B-Instruct-AWQ 支持
- ✅ 基础文档和脚本

## 🔮 未来计划

### 待添加文件

- [ ] Helm Chart 包
- [ ] Prometheus 监控配置
- [ ] Grafana 仪表板模板
- [ ] CI/CD 工作流配置
- [ ] 多模型切换脚本
- [ ] 性能基准测试报告

### 改进方向

- [ ] 简化 K8s 部署流程
- [ ] 增加更多示例代码
- [ ] 完善故障排查手册
- [ ] 录制视频教程
- [ ] 建立社区论坛

---

**维护者**: Model Deploy Team  
**最后更新**: 2026-04-02  
**当前版本**: v2.0.0
