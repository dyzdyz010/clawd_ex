# ClawdEx 🤖

基于 Elixir/Phoenix 的智能 AI 代理框架，实现与 [OpenClaw](https://github.com/openclaw/openclaw) 功能对等。

## ✨ 特性

### 核心能力
- 🧠 **语义记忆** - pgvector 向量搜索 + BM25 混合检索，支持中文
- 🔄 **会话管理** - OTP GenServer 并发处理，自动压缩
- ⚡ **流式响应** - 智能分块、代码块保护、人性化延迟
- 🤖 **多 AI 提供商** - Anthropic Claude, OpenAI GPT, Google Gemini, OpenRouter
- 🔐 **OAuth 支持** - Claude Code OAuth token 自动刷新

### 渠道支持
- 📱 **Telegram** - Telegex 库集成
- 💬 **Discord** - Nostrum 库，支持 slash commands
- 🌐 **WebChat** - Phoenix LiveView 实时聊天界面

### 管理界面 (Phoenix LiveView)
- 📊 **Dashboard** - 系统概览、统计、健康检查
- 💬 **Chat** - 实时聊天界面，流式响应，工具调用显示
- 📋 **Sessions** - 会话列表、筛选、归档、删除
- 🤖 **Agents** - Agent CRUD 管理
- ⏰ **Cron Jobs** - 定时任务管理、运行历史
- 📜 **Logs** - 日志查看器、级别过滤
- ⚙️ **Settings** - 配置管理、系统信息

### CLI 命令
- `status` - 应用状态概览
- `health` - 7 项综合健康检查
- `configure` - 交互式配置向导

### 工具系统 (21+ 个工具)

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
| **语音** | `tts` | 文本转语音 |
| **图像** | `image` | 图像分析 |
| **其他** | `compact` | 会话压缩 |

## 🏗 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Phoenix Gateway                          │
├─────────────────────────────────────────────────────────────┤
│  Channels: Telegram │ Discord │ WebChat (LiveView)          │
├─────────────────────────────────────────────────────────────┤
│  LiveView Pages: Dashboard │ Chat │ Sessions │ Agents       │
├─────────────────────────────────────────────────────────────┤
│  Session Layer                                              │
│  ├── SessionManager (DynamicSupervisor)                    │
│  ├── SessionWorker (GenServer) - 完全异步消息处理           │
│  └── Compaction (AI 摘要压缩)                               │
├─────────────────────────────────────────────────────────────┤
│  Agent Loop (GenStateMachine)                               │
│  └── idle → preparing → inferring → executing_tools         │
│  └── 工具调用上限: 50 次/run                                │
├─────────────────────────────────────────────────────────────┤
│  Tools System (21+ tools)                                   │
│  └── Registry → Execute → Response                          │
├─────────────────────────────────────────────────────────────┤
│  AI Providers: Anthropic │ OpenAI │ Gemini │ OpenRouter     │
│  └── OAuth Token Management (auto-refresh)                  │
│  └── 自动重试机制 (3次，指数退避)                            │
├─────────────────────────────────────────────────────────────┤
│  Memory: pgvector (HNSW) + BM25 Hybrid Search               │
├─────────────────────────────────────────────────────────────┤
│  Browser: Chrome DevTools Protocol                          │
├─────────────────────────────────────────────────────────────┤
│  Nodes: Remote Device Control via Gateway API               │
└─────────────────────────────────────────────────────────────┘
```

## 🖥 WebChat 界面

ClawdEx 内置 Phoenix LiveView 管理界面：

```
http://localhost:4000/          # Dashboard (+ 健康检查)
http://localhost:4000/chat      # 聊天界面
http://localhost:4000/sessions  # 会话管理
http://localhost:4000/agents    # Agent 管理
http://localhost:4000/cron      # Cron 任务管理
http://localhost:4000/logs      # 日志查看器
http://localhost:4000/settings  # 配置管理
```

**特性：**
- 深色主题 UI
- 实时流式响应显示
- 工具调用历史展示
- 会话切换与历史加载
- Agent CRUD 操作
- 健康检查面板 (7 项子系统)
- Cron 任务管理与运行历史
- 日志查看/过滤/搜索

## 🔧 CLI 命令

```bash
# 通过 mix 运行
mix run -e 'ClawdEx.CLI.main(["status"])'
mix run -e 'ClawdEx.CLI.main(["health", "--verbose"])'
mix run -e 'ClawdEx.CLI.main(["configure"])'

# 或编译为独立 escript
mix escript.build
./clawd_ex status
./clawd_ex health -v
```

**健康检查项目：**
- Database (连接/延迟/大小)
- Memory (总量/进程/系统)
- Processes (数量/限制)
- AI Providers (配置状态)
- Browser (Chrome 可用性)
- Filesystem (工作区可写)
- Network (DNS 连通性)

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
iex -S mix phx.server
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
lib/
├── clawd_ex/                 # 核心业务逻辑
│   ├── agent/                # Agent Loop (GenStateMachine)
│   ├── ai/                   # AI 提供商 (chat/stream/embeddings/oauth)
│   ├── browser/              # Browser 控制 (CDP)
│   ├── channels/             # 消息渠道 (Telegram/Discord)
│   ├── cron/                 # 定时任务
│   ├── memory/               # 记忆系统 (BM25/Chunker/Tokenizer)
│   ├── nodes/                # 节点管理
│   ├── sessions/             # 会话管理 (Compaction)
│   ├── streaming/            # 流式响应 (BlockChunker/BlockStreamer)
│   └── tools/                # 21+ 个工具实现
│
└── clawd_ex_web/             # Phoenix Web 层
    ├── components/           # 可复用组件
    │   ├── layouts/          # 布局模板
    │   ├── dashboard_components.ex
    │   ├── session_components.ex
    │   └── ...
    ├── live/                 # LiveView 页面
    │   ├── dashboard_live.ex
    │   ├── chat_live.ex
    │   ├── sessions_live.ex
    │   ├── agents_live.ex
    │   └── ...
    └── helpers/              # 辅助模块
        └── content_renderer.ex
```

## 📊 开发进度

| 阶段 | 状态 | 内容 |
|------|------|------|
| Phase 1 | ✅ | 核心工具 (read/write/edit/exec/process) |
| Phase 2 | ✅ | 会话系统 (sessions_*, agents_list) |
| Phase 3 | ✅ | 自动化 (cron, gateway, message) |
| Phase 4 | ✅ | 浏览器控制 (browser + CDP) |
| Phase 5 | ✅ | 节点系统 (nodes) |
| Phase 6 | ✅ | Canvas/A2UI (canvas) |
| OAuth | ✅ | Anthropic OAuth token 支持 |
| WebChat | ✅ | Phoenix LiveView 管理界面 |

详见 [ROADMAP.md](ROADMAP.md)

## 📈 代码统计

- **工具模块:** 22/24 个 ✅
- **测试用例:** 377 个 ✅
- **AI 提供商:** 5/10 个
- **消息渠道:** 3/11 个
- **LiveView 页面:** 5/17 个
- **CLI 命令:** 0/24 个 (待开发)
- **整体完成度:** ~39%

详细功能对比见 [docs/FEATURES.md](docs/FEATURES.md)

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

- [OpenClaw](https://github.com/openclaw/openclaw) - 原版 Node.js 实现
- [OpenClaw Docs](https://docs.openclaw.ai) - 官方文档
- [Telegex](https://hexdocs.pm/telegex) - Telegram Bot API
- [Nostrum](https://hexdocs.pm/nostrum) - Discord API

## 📄 License

MIT
