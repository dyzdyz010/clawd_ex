# ClawdEx 🤖

基于 Elixir/Phoenix 的智能聊天机器人框架，使用 PostgreSQL + pgvector 提供语义记忆能力。

灵感来源于 [Clawdbot](https://github.com/clawdbot/clawdbot)，用 Elixir 重新实现。

## 特性

- 🧠 **语义记忆**: 使用 pgvector 实现向量相似度搜索
- 🔄 **多会话管理**: 基于 OTP 的并发会话处理
- 🤖 **多 AI 提供商**: 支持 Anthropic, OpenAI, Google Gemini
- 📱 **多渠道支持**: Telegram (已实现), Discord (已实现), WebSocket 等
- ⚡ **实时处理**: Phoenix Channels 实现实时通信
- 🛠 **工具系统**: 可扩展的工具/函数调用支持

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Phoenix Gateway                          │
├─────────────────────────────────────────────────────────────┤
│  Channels                                                   │
│  ├── Telegram (HTTP Long Polling)                          │
│  ├── Discord (Nostrum - WebSocket Gateway)                 │
│  └── WebSocket                                             │
├─────────────────────────────────────────────────────────────┤
│  Session Layer                                             │
│  ├── SessionManager (DynamicSupervisor)                    │
│  └── SessionWorker (GenServer - 管理会话生命周期)           │
├─────────────────────────────────────────────────────────────┤
│  Agent Loop (GenStateMachine)                              │
│  ├── :idle → :preparing → :inferring → :executing_tools    │
│  ├── 工具并行执行                                           │
│  ├── 流式响应 (PubSub)                                      │
│  └── 消息持久化                                             │
├─────────────────────────────────────────────────────────────┤
│  AI Providers (Req HTTP + SSE)                             │
│  ├── Anthropic Claude (流式)                               │
│  ├── OpenAI GPT (流式)                                     │
│  └── Google Gemini (流式)                                  │
├─────────────────────────────────────────────────────────────┤
│  Tools System                                              │
│  ├── Registry (工具注册/查找)                               │
│  └── Tools: read, write, edit, exec, memory_*              │
├─────────────────────────────────────────────────────────────┤
│  Memory (pgvector)                                         │
│  ├── Semantic Search (HNSW 索引)                           │
│  └── Chunk Management                                       │
├─────────────────────────────────────────────────────────────┤
│  Storage: PostgreSQL + pgvector                            │
└─────────────────────────────────────────────────────────────┘
```

## 项目结构

```
lib/
├── clawd_ex/
│   ├── agent/            # Agent 核心
│   │   ├── loop.ex       # Agent Loop (GenStateMachine)
│   │   └── prompt.ex     # 系统提示构建器
│   ├── agents/           # Agent 配置
│   │   └── agent.ex      # Agent Schema
│   ├── ai/               # AI 提供商
│   │   ├── chat.ex       # 同步聊天补全
│   │   ├── stream.ex     # 流式聊天 (SSE)
│   │   └── embeddings.ex # 嵌入向量生成
│   ├── channels/         # 消息渠道
│   │   ├── channel.ex    # Behaviour 定义
│   │   ├── telegram.ex   # Telegram 实现
│   │   ├── discord.ex    # Discord 实现 (Nostrum)
│   │   └── discord_supervisor.ex  # Discord Supervisor
│   ├── memory/           # 记忆系统
│   │   ├── chunk.ex      # 记忆块 Schema
│   │   └── memory.ex     # 向量搜索服务
│   ├── sessions/         # 会话管理
│   │   ├── message.ex    # 消息 Schema
│   │   ├── session.ex    # 会话 Schema
│   │   ├── session_manager.ex  # DynamicSupervisor
│   │   └── session_worker.ex   # 会话工作进程
│   ├── tools/            # 工具系统
│   │   ├── registry.ex   # 工具注册表
│   │   ├── read.ex       # 读取文件
│   │   ├── write.ex      # 写入文件
│   │   ├── edit.ex       # 编辑文件
│   │   ├── exec.ex       # 执行命令
│   │   ├── memory_search.ex
│   │   ├── memory_get.ex
│   │   └── session_status.ex
│   ├── application.ex    # OTP Application
│   ├── postgres_types.ex # pgvector 类型
│   └── repo.ex           # Ecto Repo
└── clawd_ex_web/         # Phoenix Web 层
```

## 快速开始

### 环境要求

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 14+ with pgvector extension

### 安装

```bash
# 克隆项目
cd clawd_ex

# 安装依赖
mix deps.get

# 创建数据库
mix ecto.create
mix ecto.migrate

# 启动服务
mix phx.server
```

### 配置

设置环境变量:

```bash
# AI 提供商 API Key (至少配置一个)
export ANTHROPIC_API_KEY="your-key"
export OPENAI_API_KEY="your-key"
export GEMINI_API_KEY="your-key"

# Telegram Bot Token (可选)
export TELEGRAM_BOT_TOKEN="your-bot-token"

# Discord Bot Token (可选)
export DISCORD_BOT_TOKEN="your-discord-bot-token"
```

## 数据库 Schema

### memory_chunks (记忆块)

| 字段 | 类型 | 说明 |
|------|------|------|
| content | text | 文本内容 |
| embedding | vector(1536) | 嵌入向量 |
| source_file | string | 来源文件 |
| source_type | enum | memory_file/session/document |
| agent_id | integer | 关联 Agent |

使用 HNSW 索引加速向量搜索。

## 使用示例

### 语义记忆搜索

```elixir
# 索引记忆内容
ClawdEx.Memory.index_content(agent_id, "MEMORY.md", content)

# 语义搜索
results = ClawdEx.Memory.search(agent_id, "用户偏好设置", limit: 5)
```

### 会话管理

```elixir
# 启动会话
{:ok, pid} = ClawdEx.Sessions.SessionManager.start_session("telegram:123456")

# 发送消息
{:ok, response} = ClawdEx.Sessions.SessionWorker.send_message("telegram:123456", "你好!")
```

### Discord 渠道

Discord 渠道使用 [Nostrum](https://hexdocs.pm/nostrum) 库连接 Discord Gateway。

**配置步骤:**

1. 在 [Discord Developer Portal](https://discord.com/developers/applications) 创建应用和 Bot
2. 获取 Bot Token
3. 设置环境变量 `DISCORD_BOT_TOKEN`
4. 在 Bot 设置中启用 **MESSAGE CONTENT INTENT**
5. 邀请 Bot 到服务器 (需要 `Send Messages`, `Read Message History` 权限)

```elixir
# 检查 Discord 连接状态
ClawdEx.Channels.Discord.ready?()

# 注册 slash commands (可选)
ClawdEx.Channels.DiscordSupervisor.register_commands()

# 发送消息到频道
ClawdEx.Channels.Discord.send_message("channel_id", "Hello from ClawdEx!")
```

### AI 调用

```elixir
# 聊天补全
{:ok, response} = ClawdEx.AI.Chat.complete(
  "anthropic/claude-sonnet-4",
  [%{role: "user", content: "Hello!"}],
  system: "You are a helpful assistant."
)
```

## 开发计划

### ✅ 已完成

- [x] 基础架构 (Phoenix 1.8 + Ecto + PostgreSQL)
- [x] pgvector 记忆系统 (HNSW 向量索引)
- [x] 会话管理 (OTP DynamicSupervisor)
- [x] AI 提供商集成 (Anthropic/OpenAI/Gemini)
- [x] Agent Loop (GenStateMachine 状态机)
- [x] 工具系统 (read/write/edit/exec/memory)
- [x] 流式响应 (SSE + PubSub)
- [x] **WebChat 界面** (Phoenix LiveView)
- [x] Telegram 渠道 (基础实现)

### 🚧 进行中

- [x] Discord 渠道 (Nostrum)
- [ ] WebSocket 实时渠道

### 📋 计划中

- [ ] 管理后台 (LiveView Dashboard)
- [ ] 记忆压缩/清理
- [ ] 多模态支持 (图片/文件)
- [ ] API 接口
- [ ] 插件系统

详细状态见 [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md)

## License

MIT
