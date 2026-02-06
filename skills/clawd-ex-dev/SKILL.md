---
name: clawd-ex-dev
description: ClawdEx 自我开发和维护技能。用于修改 ClawdEx 代码、添加功能、调试问题、管理服务。
---

# ClawdEx 自我开发技能

## 概述

此技能允许 AI 助手修改和维护 ClawdEx 项目本身，包括：
- 修改 Elixir 源代码
- 添加新功能
- 修复 bug
- 管理 systemd 服务
- 查看日志和调试

## 项目结构

```
/root/clawdbot-workspace/clawd_ex/
├── lib/
│   ├── clawd_ex/              # 核心逻辑
│   │   ├── channels/          # 消息渠道 (telegram.ex, discord.ex)
│   │   ├── sessions/          # 会话管理
│   │   ├── agent/             # AI Agent 循环
│   │   ├── tools/             # 工具实现
│   │   └── ...
│   └── clawd_ex_web/          # Phoenix Web 界面
├── config/                    # 配置文件
├── test/                      # 测试
├── mix.exs                    # 项目依赖
└── skills/                    # 技能文档
```

## 关键文件

### Telegram 渠道
- **位置**: `lib/clawd_ex/channels/telegram.ex`
- **功能**: 消息收发、typing 状态、图片发送
- **API**: Telegram Bot API (visciang/telegram 库)

### 会话管理
- **SessionManager**: `lib/clawd_ex/sessions/session_manager.ex`
- **SessionWorker**: `lib/clawd_ex/sessions/session_worker.ex`

### Agent 循环
- **Loop**: `lib/clawd_ex/agent/loop.ex` - 消息处理状态机
- **Prompt**: `lib/clawd_ex/agent/prompt.ex` - System prompt 构建

## 服务管理

### Systemd 服务
```bash
# 状态
systemctl status clawd-ex

# 重启 (代码修改后)
systemctl restart clawd-ex

# 查看日志
tail -f /var/log/clawd-ex.log
journalctl -u clawd-ex -f
```

### 服务配置
- **服务文件**: `/etc/systemd/system/clawd-ex.service`
- **启动脚本**: `/opt/clawd-ex-start.sh`
- **环境变量**: `TELEGRAM_BOT_TOKEN` 在服务文件中配置

## 开发流程

### 1. 修改代码
```bash
cd /root/clawdbot-workspace/clawd_ex
# 编辑文件...
```

### 2. 编译检查
```bash
mix compile
# 或检查警告
mix compile --warnings-as-errors
```

### 3. 运行测试
```bash
mix test
# 或单个测试文件
mix test test/clawd_ex/channels/telegram_test.exs
```

### 4. 提交并重启
```bash
git add -A
git commit -m "feat: description"
git push
systemctl restart clawd-ex
```

## 常见任务

### 添加新工具
1. 在 `lib/clawd_ex/tools/` 创建新模块
2. 实现 `execute/2` 函数
3. 在 `lib/clawd_ex/tools.ex` 注册工具

### 修改 Telegram 功能
1. 编辑 `lib/clawd_ex/channels/telegram.ex`
2. 编译: `mix compile`
3. 重启: `systemctl restart clawd-ex`
4. 查看日志: `tail -f /var/log/clawd-ex.log`

### 调试问题
1. 查看日志: `tail -100 /var/log/clawd-ex.log`
2. 添加 `Logger.debug/info/error` 语句
3. 重启服务查看输出

## 数据库

- **类型**: PostgreSQL (Docker 容器)
- **端口**: 127.0.0.1:15432
- **数据库**: clawd_ex_dev

### 迁移
```bash
mix ecto.migrate
mix ecto.rollback
```

## 依赖

- Elixir 1.19.5 (OTP 28)
- Phoenix 1.8
- PostgreSQL 17 (pgvector)
- visciang/telegram (Telegram API)

## 注意事项

1. **修改后必须重启服务** - Elixir 是编译型语言
2. **保持向后兼容** - 不要破坏现有功能
3. **添加日志** - 方便调试
4. **写测试** - 确保功能正确
5. **提交代码** - 保持版本控制
