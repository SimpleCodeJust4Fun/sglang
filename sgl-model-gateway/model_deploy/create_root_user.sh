#!/bin/bash
# 创建 root 用户的 PostgreSQL 脚本

# 切换到 postgres 用户并执行 SQL
su - postgres -c "psql -c \"CREATE ROLE root WITH LOGIN SUPERUSER CREATEDB CREATEROLE;\"" 2>/dev/null

# 检查是否成功
if [ $? -eq 0 ]; then
    echo "Root user created successfully"
else
    echo "Failed to create root user or user already exists"
fi

# 列出所有角色
su - postgres -c "psql -c \"\du\"" | grep root
