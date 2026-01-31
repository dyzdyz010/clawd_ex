# ClawdEx 🤖

基于 Elixir/Phoenix 的智能 AI 代理框架，实现与 [Clawdbot](https://github.com/clawdbot/clawdbot) 功能对等。

## ✨ 特性

### 核心能力
- 🧠 **语义记忆** - pgvector 向量搜索 + BM25 混合检索，支持中文
- 🔄 **会话管理** - OTP GenServer 并发处理，自动压缩
- ⚡ **流式响应** - 智能分块、代码块保护、人性化延迟
- 🤖 **多 AI 提供商** - Anthropic Claude, OpenAI GPT, Google Gemini
- 🔐 **OAuth 支持** - Claude Code OAuth token 自动刷新

### 渠道支持
- 📱 **Telegram** - Telegex 库集成
- 💬 **Discord** - Nostrum 库，支持 slash commands
- 🌐 **WebSocket** - Phoenix Channels 实时通信

### 工具系统 (21 个工具)

| 分类 | 工具 | 功能 |
|------|------|------|
| **文件** | `read`, `write`, `edit` | 文件读写编辑 |
| **执行** | `exec`, `process` | 命令执行与进程管理 |
| **记忆** | `memory_search`, `memory_get` | 语义搜索与检索 |
| **网页** | `web_search`, `web_fetch` | 搜索与抓取 |
| **会话** | `sessions_list`, `sessions_history`, `sessions_send`, `sessions_spawn` | 会话管理与子代理 |
| **代理** | `agents_list`, `session_status` | 代理列表与状态 |
| **自动化** | `cron`, `gateway`, `message` | 定时任务、自管理、多渠道消息 |
| **浏览器** | `browser` | CDP 控制 (navigate/snapshot/screenshot/act/evaluate) |
| **节点** | `nodes` | 远程设备控制 (notify/run/camera/screen/location) |
| **画布** | `canvas` | A2UI 显示控制 |
| **其他** | `compact` | 会话压缩 |

## 🏗 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Phoenix Gateway                          │
├─────────────────────────────────────────────────────────────┤
│  Channels: Telegram │ Discord │ WebSocket                   │
├─────────────────────────────────────────────────────────────┤
│  Session Layer                                              │
│  ├── SessionManager (DynamicSupervisor)                    │
│  ├── SessionWorker (GenServer)                             │
│  └── Compaction (AI 摘要压缩)                               │
├─────────────────────────────────────────────────────────────┤
│  Agent Loop (GenStateMachine)                               │
│  └── idle → preparing → inferring → executing_tools         │
├─────────────────────────────────────────────────────────────┤
│  Tools System (21 tools)                                    │
│  └── Registry → Execute → Response                          │
├─────────────────────────────────────────────────────────────┤
│  AI Providers: Anthropic │ OpenAI │ Gemini                  │
│  └── OAuth Token Management (auto-refresh)                  │
├─────────────────────────────────────────────────────────────┤
│  Memory: pgvector (HNSW) + BM25 Hybrid Search               │
├─────────────────────────────────────────────────────────────┤
│  Browser: Chrome DevTools Protocol                          │
├─────────────────────────────────────────────────────────────┤
│  Nodes: Remote Device Control via Gateway API               │
└─────────────────────────────────────────────────────────────┘
```

## 🔐 OAuth 认证

ClawdEx 支持 Anthropic Claude OAuth token (与 Claude Code CLI 兼容)：

```elixir
# 自动从 Claude CLI 加载凭证
ClawdEx.AI.OAuth.load_from_claude_cli()

# 或手动存储
ClawdEx.AI.OAuth.store_credentials(:anthropic, %{
  type: "oauth",
  access: "sk-ant-oat-...",
  refresh: "...",
  expires: 1234567890
})

# API 调用时自动处理 token 刷新
{:ok, api_key} = ClawdEx.AI.OAuth.get_api_key(:anthropic)
```

**OAuth 特性：**
- 自动检测 OAuth token (`sk-ant-oat*`)
- Token 过期前 5 分钟自动刷新
- Claude Code 兼容的 headers 和 system prompt
- 凭证持久化到 `~/.clawd_ex/oauth_credentials.json`

## 🚀 快速开始

### 环境要求

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 14+ with pgvector
- Chrome/Chromium (可选，用于 browser 工具)

### 安装

```bash
git clone https://github.com/dyzdyz010/clawd_ex.git
cd clawd_ex

# 安装依赖
mix deps.get

# 数据库设置
mix ecto.create
mix ecto.migrate

# 启动
mix phx.server
```

### 配置

```bash
# AI 提供商 (至少一个)
export ANTHROPIC_API_KEY="sk-..."  # 或使用 OAuth token
export OPENAI_API_KEY="sk-..."
export GEMINI_API_KEY="..."

# 渠道 (可选)
export TELEGRAM_BOT_TOKEN="..."
export DISCORD_BOT_TOKEN="..."
```

## 📁 项目结构

```
lib/clawd_ex/
├── agent/           # Agent Loop (GenStateMachine)
├── ai/              # AI 提供商 (chat/stream/embeddings/oauth)
│   ├── chat.ex      # 非流式 API
│   ├── stream.ex    # 流式 API
│   ├── oauth.ex     # OAuth 凭证管理
│   └── oauth/       # 提供商特定 OAuth
├── browser/         # Browser 控制 (CDP)
│   ├── server.ex    # Browser GenServer
│   └── cdp.ex       # Chrome DevTools Protocol
├── channels/        # 消息渠道 (Telegram/Discord)
├── cron/            # 定时任务
├── memory/          # 记忆系统 (BM25/Chunker/Tokenizer)
├── nodes/           # 节点管理
├── sessions/        # 会话管理 (Compaction)
├── streaming/       # 流式响应 (BlockChunker/BlockStreamer)
└── tools/           # 21 个工具实现
```

## 📊 开发进度

| 阶段 | 状态 | 内容 |
|------|------|------|
| Phase 1 | ✅ | 核心工具 (web_search, web_fetch, compact) |
| Phase 2 | ✅ | 会话系统 (sessions_*, agents_list) |
| Phase 3 | ✅ | 自动化 (cron, gateway, message) |
| Phase 4 | ✅ | 浏览器控制 (browser + CDP) |
| Phase 5 | ✅ | 节点系统 (nodes) |
| Phase 6 | ✅ | Canvas/A2UI (canvas) |
| OAuth | ✅ | Anthropic OAuth token 支持 |

**剩余:** `apply_patch`, `image` 工具 (低优先级)

详见 [ROADMAP.md](ROADMAP.md)

## 📈 代码统计

- **工具模块:** 21 个
- **测试用例:** 318 个 ✅
- **AI 提供商:** 3 个
- **消息渠道:** 3 个
- **总代码量:** ~18,000 行

## 🧪 测试

```bash
# 运行所有测试
mix test

# 运行特定测试
mix test test/clawd_ex/ai/oauth_test.exs
mix test test/clawd_ex/browser/server_test.exs

# 带详情
mix test --trace
```

## 🔗 相关链接

- [Clawdbot](https://github.com/clawdbot/clawdbot) - 原版 Node.js 实现
- [Clawdbot Docs](https://docs.clawd.bot) - 官方文档
- [Telegex](https://hexdocs.pm/telegex) - Telegram Bot API
- [Nostrum](https://hexdocs.pm/nostrum) - Discord API

## 📄 License

MIT
