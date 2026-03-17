# ClawdEx 部署指南

ClawdEx 是一个基于 Elixir Phoenix 的 AI 助手框架，本指南将帮助您快速部署和配置 ClawdEx。

## 系统要求

### 必需依赖
- **Elixir**: >=1.19
- **Erlang/OTP**: >=26
- **PostgreSQL**: >=14
- **pgvector 扩展**: >=0.5.0（用于向量存储）

### 建议配置
- **内存**: 最少 2GB，建议 4GB+
- **存储**: 最少 10GB 可用空间
- **CPU**: 2 核心以上

### 可选依赖
- **Chrome/Chromium**: 浏览器自动化功能
- **FFmpeg**: 音频/视频处理工具

## 快速开始

### 1. 获取源码

```bash
git clone <repository-url> clawd_ex
cd clawd_ex
```

### 2. 安装依赖

```bash
# 安装 Elixir 依赖
mix deps.get

# 编译依赖（生产环境）
MIX_ENV=prod mix deps.compile
```

### 3. 配置数据库

确保 PostgreSQL 正在运行，并创建数据库：

```bash
# 创建数据库并运行迁移
mix ecto.setup

# 或者手动步骤
mix ecto.create
mix ecto.migrate
mix run priv/repo/seeds.exs
```

### 4. 配置环境变量

创建 `.env` 文件或设置环境变量：

```bash
# 数据库配置
export DATABASE_URL="ecto://user:pass@localhost/clawd_ex_dev"

# Web 服务器
export PORT=4000
export PHX_HOST="localhost"
export SECRET_KEY_BASE="$(mix phx.gen.secret)"

# AI 提供商（至少配置一个）
export OPENROUTER_API_KEY="sk-or-v1-..."
export GROQ_API_KEY="gsk_..."
export OLLAMA_URL="http://localhost:11434"

# 消息渠道（可选）
export DISCORD_BOT_TOKEN="your-discord-bot-token"
export TELEGRAM_BOT_TOKEN="your-telegram-bot-token"
```

### 5. 启动服务

```bash
# 开发模式
mix phx.server

# 或使用 CLI 启动
mix escript.build
./clawd_ex start

# 访问 http://localhost:4000
```

## 环境变量配置

### 数据库配置

```bash
# 必需 - 数据库连接 URL
DATABASE_URL="ecto://username:password@hostname:port/database"

# 可选 - 连接池大小（默认 10）
POOL_SIZE=10

# 可选 - IPv6 支持
ECTO_IPV6=true
```

### Web 服务器配置

```bash
# 必需 - 密钥（用于签名 cookies 和 session）
SECRET_KEY_BASE="64-char-hex-string"

# Web 服务器端口（默认 4000）
PORT=4000

# 外部访问主机名（生产环境必需）
PHX_HOST="yourdomain.com"

# 启用服务器（生产部署必需）
PHX_SERVER=true
```

### AI 提供商配置

```bash
# OpenRouter（推荐）
OPENROUTER_API_KEY="sk-or-v1-xxxxxxxx"

# Groq（高速推理）
GROQ_API_KEY="gsk_xxxxxxxx"

# Ollama（本地部署）
OLLAMA_URL="http://localhost:11434"
```

### 消息渠道配置

```bash
# Discord Bot
DISCORD_BOT_TOKEN="your-discord-bot-token"

# Telegram Bot
TELEGRAM_BOT_TOKEN="your-telegram-bot-token"
```

### 系统配置

```bash
# DNS 集群查询（多实例部署）
DNS_CLUSTER_QUERY="clawd-ex.service.consul"

# 日志级别
LOG_LEVEL="info"
```

## 数据库设置

### PostgreSQL 安装

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install postgresql postgresql-contrib
```

**macOS (Homebrew):**
```bash
brew install postgresql
brew services start postgresql
```

**CentOS/RHEL:**
```bash
sudo yum install postgresql-server postgresql-contrib
sudo postgresql-setup initdb
sudo systemctl start postgresql
```

### pgvector 扩展安装

**Ubuntu/Debian:**
```bash
sudo apt install postgresql-14-pgvector
```

**macOS (Homebrew):**
```bash
brew install pgvector
```

**从源码编译:**
```bash
git clone https://github.com/pgvector/pgvector.git
cd pgvector
make
sudo make install
```

### 数据库用户和权限

```sql
-- 创建用户
CREATE USER clawd_ex WITH PASSWORD 'your-secure-password';

-- 创建数据库
CREATE DATABASE clawd_ex_prod OWNER clawd_ex;

-- 连接到数据库并启用扩展
\c clawd_ex_prod
CREATE EXTENSION IF NOT EXISTS pgvector;

-- 授权
GRANT ALL PRIVILEGES ON DATABASE clawd_ex_prod TO clawd_ex;
```

## 生产部署

### 构建 Release

```bash
# 设置环境
export MIX_ENV=prod

# 获取并编译依赖
mix deps.get --only prod
mix deps.compile

# 编译应用
mix compile

# 构建前端资源
mix assets.deploy

# 构建 release
mix release

# Release 位于 _build/prod/rel/clawd_ex/
```

### Systemd 服务

创建 `/etc/systemd/system/clawd-ex.service`：

```ini
[Unit]
Description=ClawdEx AI Assistant
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=exec
User=clawd-ex
Group=clawd-ex
WorkingDirectory=/opt/clawd-ex
ExecStart=/opt/clawd-ex/bin/clawd_ex start
ExecStop=/opt/clawd-ex/bin/clawd_ex stop
Restart=on-failure
RestartSec=5
Environment="MIX_ENV=prod"
Environment="PHX_SERVER=true"
EnvironmentFile=/opt/clawd-ex/.env

# 安全设置
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/opt/clawd-ex
ProtectHome=yes

[Install]
WantedBy=multi-user.target
```

**启用和启动服务:**
```bash
sudo systemctl enable clawd-ex
sudo systemctl start clawd-ex
sudo systemctl status clawd-ex
```

### 部署脚本示例

```bash
#!/bin/bash
# deploy.sh

set -e

APP_NAME="clawd_ex"
APP_USER="clawd-ex"
APP_DIR="/opt/clawd-ex"
BACKUP_DIR="/opt/backups"

echo "=== ClawdEx 部署脚本 ==="

# 创建备份
echo "创建数据库备份..."
sudo -u postgres pg_dump clawd_ex_prod > "$BACKUP_DIR/clawd_ex_$(date +%Y%m%d_%H%M%S).sql"

# 停止服务
echo "停止服务..."
sudo systemctl stop clawd-ex

# 备份当前版本
if [ -d "$APP_DIR/current" ]; then
    echo "备份当前版本..."
    sudo mv "$APP_DIR/current" "$APP_DIR/previous"
fi

# 部署新版本
echo "部署新版本..."
sudo mkdir -p "$APP_DIR/current"
sudo tar -xzf clawd_ex_release.tar.gz -C "$APP_DIR/current"
sudo chown -R $APP_USER:$APP_USER "$APP_DIR/current"

# 运行数据库迁移
echo "运行数据库迁移..."
sudo -u $APP_USER "$APP_DIR/current/bin/clawd_ex" eval "ClawdEx.Release.migrate"

# 启动服务
echo "启动服务..."
sudo systemctl start clawd-ex

# 验证部署
sleep 5
if sudo systemctl is-active --quiet clawd-ex; then
    echo "✅ 部署成功！"
else
    echo "❌ 部署失败，回滚中..."
    sudo systemctl stop clawd-ex
    sudo rm -rf "$APP_DIR/current"
    sudo mv "$APP_DIR/previous" "$APP_DIR/current"
    sudo systemctl start clawd-ex
    exit 1
fi
```

### Nginx 反向代理

创建 `/etc/nginx/sites-available/clawd-ex`：

```nginx
upstream clawd_ex {
    server 127.0.0.1:4000;
}

server {
    listen 80;
    server_name yourdomain.com;

    # 重定向到 HTTPS
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name yourdomain.com;

    # SSL 配置
    ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;

    # 通用设置
    client_max_body_size 50M;
    
    location / {
        proxy_pass http://clawd_ex;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket 支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # 静态资源缓存
    location ~* \.(css|js|png|jpg|jpeg|gif|svg|ico)$ {
        proxy_pass http://clawd_ex;
        proxy_cache_valid 200 1d;
        add_header Cache-Control "public, immutable";
    }
}
```

## Docker 部署

### Dockerfile

```dockerfile
FROM elixir:1.19-otp-26-alpine as builder

# 安装构建依赖
RUN apk add --no-cache \
    gcc \
    git \
    make \
    musl-dev \
    nodejs \
    npm

WORKDIR /app

# 复制依赖文件
COPY mix.exs mix.lock ./
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only prod && \
    mix deps.compile

# 复制源码和资源
COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

# 构建前端资源
RUN mix assets.deploy

# 构建 release
RUN MIX_ENV=prod mix compile && \
    MIX_ENV=prod mix release

# ===== Runtime Image =====
FROM alpine:3.18

# 安装运行时依赖
RUN apk add --no-cache \
    bash \
    openssl \
    postgresql-client \
    ncurses-libs

# 创建应用用户
RUN addgroup -g 1000 clawd_ex && \
    adduser -u 1000 -G clawd_ex -s /bin/sh -D clawd_ex

USER clawd_ex
WORKDIR /app

# 复制 release
COPY --from=builder --chown=clawd_ex:clawd_ex /app/_build/prod/rel/clawd_ex ./

# 暴露端口
EXPOSE 4000

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD /app/bin/clawd_ex eval "ClawdEx.Health.check()" || exit 1

# 启动命令
ENTRYPOINT ["/app/bin/clawd_ex"]
CMD ["start"]
```

### Docker Compose

```yaml
# docker-compose.yml
version: '3.8'

services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: clawd_ex_prod
      POSTGRES_USER: clawd_ex
      POSTGRES_PASSWORD: secure_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U clawd_ex"]
      interval: 30s
      timeout: 10s
      retries: 5

  clawd_ex:
    build: .
    ports:
      - "4000:4000"
    environment:
      MIX_ENV: prod
      PHX_SERVER: "true"
      DATABASE_URL: "ecto://clawd_ex:secure_password@postgres:5432/clawd_ex_prod"
      SECRET_KEY_BASE: "your-64-char-secret-key"
      OPENROUTER_API_KEY: "your-openrouter-key"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - app_data:/app/data
    restart: unless-stopped

volumes:
  postgres_data:
  app_data:
```

### 部署命令

```bash
# 构建和启动
docker-compose up -d

# 查看日志
docker-compose logs -f clawd_ex

# 运行迁移
docker-compose exec clawd_ex /app/bin/clawd_ex eval "ClawdEx.Release.migrate"

# 停止服务
docker-compose down

# 更新部署
docker-compose pull && docker-compose up -d
```

## 故障排查

### 常见问题

**1. 数据库连接失败**
```bash
# 检查 PostgreSQL 状态
sudo systemctl status postgresql

# 检查连接
psql -h localhost -U clawd_ex -d clawd_ex_prod

# 查看日志
sudo journalctl -u postgresql
```

**2. pgvector 扩展缺失**
```sql
-- 检查扩展
\dx

-- 安装扩展
CREATE EXTENSION IF NOT EXISTS pgvector;
```

**3. 权限问题**
```bash
# 检查文件权限
ls -la /opt/clawd-ex
sudo chown -R clawd-ex:clawd-ex /opt/clawd-ex
```

**4. 内存不足**
```bash
# 检查内存使用
free -m
htop

# 优化 Erlang VM
export ERL_MAX_ETS_TABLES=10000
export ERL_CRASH_DUMP_SECONDS=0
```

### 日志查看

```bash
# 应用日志
sudo journalctl -u clawd-ex -f

# 数据库日志
sudo journalctl -u postgresql -f

# Nginx 日志
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log
```

### 性能监控

```bash
# 使用 CLI 检查状态
./clawd_ex status --verbose

# 检查健康度
./clawd_ex health

# 数据库查询
psql -c "SELECT count(*) FROM sessions;"
psql -c "SELECT count(*) FROM messages;"
```

---

## 维护任务

### 备份

```bash
#!/bin/bash
# backup.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/opt/backups"

# 数据库备份
sudo -u postgres pg_dump clawd_ex_prod > "$BACKUP_DIR/db_$DATE.sql"

# 应用数据备份
tar -czf "$BACKUP_DIR/app_data_$DATE.tar.gz" /opt/clawd-ex/data

# 清理旧备份（保留 30 天）
find "$BACKUP_DIR" -name "*.sql" -mtime +30 -delete
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +30 -delete
```

### 更新部署

```bash
# 1. 备份数据
./backup.sh

# 2. 下载新版本
wget https://github.com/your-org/clawd_ex/releases/latest/download/clawd_ex.tar.gz

# 3. 运行部署脚本
./deploy.sh
```

---

*此部署指南对应 ClawdEx v0.4.0。如有问题请查阅项目文档或提交 Issue。*