# ClawdEx 🤖

基于 Elixir/Phoenix 的智能聊天机器人框架，使用 PostgreSQL + pgvector 提供语义记忆能力。

灵感来源于 [Clawdbot](https://github.com/clawdbot/clawdbot)，用 Elixir 重新实现。

## 特性

- 🧠 **语义记忆**: 使用 pgvector 实现向量相似度搜索
- 🔄 **多会话管理**: 基于 OTP 的并发会话处理
- 🤖 **多 AI 提供商**: 支持 Anthropic, OpenAI, Google Gemini
- 📱 **多渠道支持**: Telegram (已实现), Discord, WebSocket 等
- ⚡ **实时处理**: Phoenix Channels 实现实时通信
- 🛠 **工具系统**: 可扩展的工具/函数调用支持

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Phoenix Gateway                          │
├─────────────────────────────────────────────────────────────┤
│  Channels                                                   │
│  ├── Telegram (Telegex)                                    │
│  ├── Discord (待实现)                                       │
│  └── WebSocket                                             │
├─────────────────────────────────────────────────────────────┤
│  Core (OTP)                                                │
│  ├── SessionManager (DynamicSupervisor)                    │
│  ├── SessionWorker (GenServer per session)                 │
│  └── MemoryService (Ecto + pgvector)                       │
├─────────────────────────────────────────────────────────────┤
│  AI Providers (Req HTTP)                                   │
│  ├── Anthropic Claude                                      │
│  ├── OpenAI GPT                                            │
│  └── Google Gemini                                         │
├─────────────────────────────────────────────────────────────┤
│  Storage                                                   │
│  └── PostgreSQL + pgvector                                 │
└─────────────────────────────────────────────────────────────┘
```

## 项目结构

```
lib/
├── clawd_ex/
│   ├── agents/           # Agent 配置和管理
│   │   └── agent.ex
│   ├── ai/               # AI 提供商接口
│   │   ├── chat.ex       # 聊天补全
│   │   └── embeddings.ex # 嵌入向量
│   ├── channels/         # 消息渠道
│   │   ├── channel.ex    # Behaviour 定义
│   │   └── telegram.ex   # Telegram 实现
│   ├── memory/           # 记忆系统
│   │   ├── chunk.ex      # 记忆块 Schema
│   │   └── memory.ex     # 记忆服务
│   ├── sessions/         # 会话管理
│   │   ├── message.ex    # 消息 Schema
│   │   ├── session.ex    # 会话 Schema
│   │   ├── session_manager.ex
│   │   └── session_worker.ex
│   ├── application.ex
│   ├── postgres_types.ex # pgvector 类型
│   └── repo.ex
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

- [x] 基础架构 (Phoenix + Ecto)
- [x] pgvector 记忆系统
- [x] 会话管理 (OTP)
- [x] AI 提供商集成
- [x] Telegram 渠道
- [ ] Discord 渠道
- [ ] WebSocket 渠道
- [ ] 工具/函数调用
- [ ] 流式响应
- [ ] 记忆压缩
- [ ] 管理后台

## License

MIT
