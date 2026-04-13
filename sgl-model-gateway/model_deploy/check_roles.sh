#!/bin/bash
# 检查 PostgreSQL 角色
echo "20000619" | sudo -S su - postgres -c "psql -c 'SELECT rolname FROM pg_roles;'" 2>/dev/null
