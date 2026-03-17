# ClawdEx CLI

ClawdEx 命令行界面提供了完整的应用管理和监控功能。支持 escript 独立可执行文件形式。

## 安装

```bash
# 通过 Mix escript 安装
mix escript.build
./clawd_ex --help

# 或直接使用 Mix
mix run -e "ClawdEx.CLI.main(~w[--help])"
```

## 全局选项

```
-h, --help     显示帮助信息
-v, --verbose  启用详细输出
-f, --format   输出格式 (text, json)
-l, --limit N  限制结果数量
```

---

## 命令列表

### clawd_ex status

显示应用状态概览

**用法:**
```bash
clawd_ex status [--verbose] [--format json]
```

**选项:**
- `--verbose` - 显示详细统计信息（Agents、Sessions、Messages、Cron Jobs）
- `--format` - 输出格式，支持 `text`（默认）或 `json`

**输出:**
- 应用名称、版本、环境
- 运行时间、内存使用、进程数
- Elixir/OTP 版本信息
- 数据库连接状态
- 健康检查摘要

**示例:**
```bash
# 基础状态信息
clawd_ex status

# 详细统计信息
clawd_ex status --verbose

# JSON 格式输出
clawd_ex status --format json
```

---

### clawd_ex health

运行综合健康检查

**用法:**
```bash
clawd_ex health [--verbose] [--format json]
```

**检查项目:**
1. **数据库** - 连接、延迟、大小
2. **内存** - 总量、进程、系统
3. **进程** - 数量、限制
4. **AI 提供商** - 配置状态
5. **浏览器** - Chrome 可用性
6. **文件系统** - 工作区可写
7. **网络** - DNS 连通性

**选项:**
- `--verbose` - 显示详细诊断信息
- `--format` - 输出格式，支持 `text`（默认）或 `json`

**退出码:**
- `0` - 所有检查通过
- `1` - 有错误或警告

**示例:**
```bash
# 运行健康检查
clawd_ex health

# 详细诊断信息
clawd_ex health --verbose
```

---

### clawd_ex configure

交互式配置向导

**用法:**
```bash
clawd_ex configure
```

**配置项目:**
- 数据库 URL
- AI 提供商 API 密钥（Anthropic、OpenAI、Google）
- 服务器端口和主机
- 环境变量管理

**功能:**
- 自动检测现有配置
- 安全的密钥输入（掩码显示）
- 配置验证和保存
- `.env` 文件管理

---

### clawd_ex sessions

会话管理

**用法:**
```bash
clawd_ex sessions <子命令> [选项]
```

#### sessions list

列出所有会话

**用法:**
```bash
clawd_ex sessions list [--limit N]
```

**选项:**
- `--limit N` - 限制显示数量（默认：50）

**输出:**
- 会话密钥、Agent、渠道
- 消息数、活跃状态
- 最后活动时间

#### sessions history

查看会话消息历史

**用法:**
```bash
clawd_ex sessions history <session_key> [--limit N]
```

**参数:**
- `<session_key>` - 会话标识符（必需）

**选项:**
- `--limit N` - 限制消息数量（默认：20）

**输出:**
- 会话信息（Agent、渠道、状态）
- 消息历史（角色、时间戳、内容）

---

### clawd_ex agents

Agent 管理

**用法:**
```bash
clawd_ex agents <子命令> [选项]
```

#### agents list

列出所有 Agents

**用法:**
```bash
clawd_ex agents list
```

**输出:**
- Agent ID、名称、模型
- 活跃状态、会话数量

#### agents add

创建新 Agent

**用法:**
```bash
clawd_ex agents add <name> [--model MODEL] [--system-prompt PROMPT]
```

**参数:**
- `<name>` - Agent 名称（必需）

**选项:**
- `--model MODEL` - 设置默认模型
- `--system-prompt PROMPT` - 设置系统提示词

**示例:**
```bash
# 基础 Agent
clawd_ex agents add my-agent

# 指定模型和提示词
clawd_ex agents add my-agent --model gpt-4 --system-prompt "你是一个有用的助手"
```

---

### clawd_ex cron

定时任务管理

**用法:**
```bash
clawd_ex cron <子命令> [选项]
```

#### cron list

列出所有定时任务

**用法:**
```bash
clawd_ex cron list
```

**输出:**
- 任务 ID、名称、调度表达式
- 启用状态、最后运行、下次运行时间

#### cron run

手动触发定时任务

**用法:**
```bash
clawd_ex cron run <id>
```

**参数:**
- `<id>` - 任务 ID（必需）

**输出:**
- 执行状态、输出/错误信息

---

### clawd_ex models

AI 模型管理

**用法:**
```bash
clawd_ex models <子命令> [选项]
```

#### models list

列出可用的 AI 模型

**用法:**
```bash
clawd_ex models list
```

**输出:**
- 按提供商分组的模型列表
- 模型别名和能力
- 配置状态（已配置/未配置）

**示例输出:**
```
ANTHROPIC [✓ configured]
  claude-opus-4-5                     opus, claude-opus          chat, vision, tools, reasoning
  claude-sonnet-4-5                   sonnet, claude-sonnet      chat, vision, tools

OPENAI [✗ not configured]  
  gpt-5.2                            gpt-5, gpt5                 chat, tools, reasoning
  ...
```

---

### clawd_ex logs

查看应用日志

**用法:**
```bash
clawd_ex logs [--level LEVEL] [--tail N]
```

**选项:**
- `--level LEVEL` - 按级别过滤（error、warn、info、debug）
- `--tail N` - 显示最后 N 行（默认：50）

**示例:**
```bash
# 查看最新日志
clawd_ex logs

# 只显示错误
clawd_ex logs --level error

# 显示最后 100 行警告
clawd_ex logs --level warn --tail 100
```

---

### clawd_ex gateway

网关管理

**用法:**
```bash
clawd_ex gateway <子命令> [选项]
```

#### gateway status

显示网关状态

**用法:**
```bash
clawd_ex gateway status
```

**输出:**
- 运行状态、端口、URL
- 服务器配置、认证状态

#### gateway restart

优雅重启网关

**用法:**
```bash
clawd_ex gateway restart
```

**注意:** 测试环境下不可用

---

### clawd_ex start

启动应用（服务器模式）

**用法:**
```bash
clawd_ex start
```

**功能:**
- 启动所有应用依赖
- 进入无限等待模式
- 通过 Ctrl+C 停止

---

### clawd_ex stop

停止运行中的应用

**用法:**
```bash
clawd_ex stop
```

---

### clawd_ex version

显示版本信息

**用法:**
```bash
clawd_ex version
```

---

## 使用示例

```bash
# 检查应用状态
clawd_ex status --verbose

# 运行健康检查
clawd_ex health

# 配置 API 密钥
clawd_ex configure

# 查看会话列表
clawd_ex sessions list --limit 10

# 查看特定会话历史
clawd_ex sessions history "agent:ceo:telegram:123456"

# 创建新 Agent
clawd_ex agents add assistant --model claude-sonnet-4-5

# 列出可用模型
clawd_ex models list

# 手动运行定时任务
clawd_ex cron run abc123

# 查看错误日志
clawd_ex logs --level error

# 重启网关
clawd_ex gateway restart
```

## 故障排查

### 常见问题

**数据库连接失败:**
```bash
clawd_ex health --verbose
# 检查 DATABASE_URL 配置
```

**AI API 密钥未配置:**
```bash
clawd_ex configure
# 交互式配置 API 密钥
```

**网关无法启动:**
```bash
clawd_ex gateway status
# 检查端口占用
```

### 日志诊断

```bash
# 查看启动错误
clawd_ex logs --level error --tail 100

# 查看所有最近活动
clawd_ex logs --tail 200
```