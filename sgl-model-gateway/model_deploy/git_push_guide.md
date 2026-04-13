# Git Push 到 GitHub 配置指南

## 当前问题

使用 HTTPS URL 推送到 GitHub 需要身份验证。GitHub 已不再支持密码验证，需要使用 **Personal Access Token (PAT)**。

## 解决方案 1: 使用 Personal Access Token (推荐)

### 步骤 1: 创建 GitHub Personal Access Token

1. 访问 GitHub: https://github.com/settings/tokens
2. 点击 "Generate new token" → "Generate new token (classic)"
3. 设置名称: `model-deploy-token`
4. 选择权限: 至少勾选 `repo` (完整仓库权限)
5. 点击 "Generate token"
6. **重要**: 立即复制生成的 token（只显示一次）

### 步骤 2: 配置 Git 凭证存储

```bash
# 在 WSL 中执行
cd /mnt/e/dev/model-deploy

# 配置凭证存储（下次不用重复输入）
git config --global credential.helper store

# 推送时会提示输入用户名和密码
git push -u origin main
# Username: SimpleCodeJust4Fun
# Password: <粘贴你的 Personal Access Token>
```

### 步骤 3: 推送代码

```bash
git push -u origin main
```

首次推送时会提示：
- **Username**: 输入你的 GitHub 用户名 `SimpleCodeJust4Fun`
- **Password**: 粘贴刚才创建的 Personal Access Token（不是 GitHub 密码）

凭证会保存在 `~/.git-credentials`，后续推送无需再输入。

---

## 解决方案 2: 使用 SSH 密钥（更安全）

### 步骤 1: 生成 SSH 密钥

```bash
# 在 WSL 中执行
ssh-keygen -t ed25519 -C "your-email@example.com"
# 按 Enter 使用默认路径
# 可以设置密码或直接 Enter 跳过

# 查看公钥
cat ~/.ssh/id_ed25519.pub
```

### 步骤 2: 添加 SSH 公钥到 GitHub

1. 复制上一步显示的公钥内容（以 `ssh-ed25519` 开头）
2. 访问 https://github.com/settings/keys
3. 点击 "New SSH key"
4. Title: `WSL Ubuntu`
5. Key: 粘贴公钥内容
6. 点击 "Add SSH key"

### 步骤 3: 更改远程仓库 URL 为 SSH

```bash
cd /mnt/e/dev/model-deploy

# 移除现有的 HTTPS URL
git remote remove origin

# 添加 SSH URL
git remote add origin git@github.com:SimpleCodeJust4Fun/model-deploy.git

# 推送
git push -u origin main
```

---

## 解决方案 3: 使用 GitHub CLI（最简单）

### 步骤 1: 安装 GitHub CLI

```bash
# 在 WSL 中执行
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update
sudo apt install gh
```

### 步骤 2: 登录 GitHub

```bash
gh auth login
# 选择: GitHub.com
# 选择: HTTPS
# 选择: Login with a web browser
# 复制显示的代码，在浏览器中授权
```

### 步骤 3: 推送代码

```bash
cd /mnt/e/dev/model-deploy
git push -u origin main
```

---

## 快速命令参考

```bash
# 查看远程仓库配置
git remote -v

# 查看当前分支
git branch

# 查看提交历史
git log --oneline

# 查看仓库状态
git status

# 如果推送失败，先拉取
git pull origin main --rebase
git push -u origin main
```

---

## 常见问题

### 问题 1: 提示 "repository not found"
- 检查仓库名是否正确
- 确保仓库已在 GitHub 上创建
- 访问 https://github.com/SimpleCodeJust4Fun/model-deploy 验证

### 问题 2: 提示 "permission denied"
- HTTPS 方式: 确保使用了有效的 Personal Access Token
- SSH 方式: 确保 SSH 公钥已添加到 GitHub

### 问题 3: 推送被拒绝
```bash
# 如果远程仓库有你本地没有的提交
git pull origin main --rebase
git push -u origin main
```

---

## 推荐方案

对于您的情况，**推荐使用方案 1 (Personal Access Token)**:
1. 设置简单，只需创建 token
2. 可以随时撤销 token
3. 配置 credential.helper 后无需重复输入

**立即执行的命令**:

```bash
cd /mnt/e/dev/model-deploy
git config --global credential.helper store
git push -u origin main
# 输入用户名和 Personal Access Token
```
