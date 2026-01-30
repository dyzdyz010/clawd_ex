# ClawdEx 架构设计文档

> 基于 Clawdbot 功能的 Elixir/Phoenix 完整实现方案

## 📋 目录

1. [项目概述](#项目概述)
2. [功能清单](#功能清单)
3. [系统架构](#系统架构)
4. [核心模块](#核心模块)
5. [配置系统](#配置系统)
6. [数据库设计](#数据库设计)
7. [技术选型](#技术选型)
8. [开发路线图](#开发路线图)

---

## 项目概述

ClawdEx 是 Clawdbot 的 Elixir/Phoenix 重新实现，保留原有功能的同时：
- 使用 **OTP** 实现高可用并发
- 使用 **PostgreSQL + pgvector** 改进记忆系统
- 使用 **Elixir 最佳实践** 重构代码架构

---

## 功能清单

### 1. 消息渠道 (Channels)

| 渠道 | 原实现 | ClawdEx 实现 | 优先级 |
|------|--------|--------------|--------|
| Telegram | grammY | Telegex | P0 |
| WhatsApp | Baileys | 待定 (可能用 webhook) | P1 |
| Discord | discord.js | Nostrum | P1 |
| Slack | Socket Mode | Slack Elixir SDK | P2 |
| iMessage | imsg CLI | 不支持 (macOS only) | - |
| Signal | signal-cli | 待定 | P3 |
| WebChat | Phoenix WS | Phoenix Channels + LiveView | P0 |
| Google Chat | Webhook | Req HTTP | P2 |
| Mattermost | Plugin | HTTP/WS | P3 |

### 2. AI 提供商 (Providers)

| 提供商 | API | 功能 |
|--------|-----|------|
| Anthropic | Claude API | Chat + 流式 + 工具调用 |
| OpenAI | Chat Completions | Chat + 流式 + 工具调用 |
| Google | Gemini API | Chat + 流式 |
| OpenRouter | 统一 API | 多模型路由 |
| Ollama | 本地 API | 本地模型 |

### 3. 核心功能

#### 3.1 会话管理 (Sessions)
- [x] 会话创建/销毁
- [ ] 会话状态持久化
- [ ] 会话压缩 (Compaction)
- [ ] 多代理路由 (Multi-agent)
- [ ] 子代理 (Subagents/Spawn)
- [ ] 会话队列模式 (collect/steer/followup)

#### 3.2 记忆系统 (Memory) - **改进版**
- [x] pgvector 向量存储
- [x] HNSW 索引加速
- [ ] 语义搜索 (memory_search)
- [ ] 增量索引
- [ ] 混合搜索 (BM25 + Vector)
- [ ] 会话记忆索引
- [ ] 自动记忆刷新 (compaction 前)

#### 3.3 工具系统 (Tools)
- [ ] exec - Shell 命令执行
- [ ] process - 后台进程管理
- [ ] read/write/edit - 文件操作
- [ ] browser - 浏览器控制
- [ ] web_search - 网页搜索
- [ ] web_fetch - 网页抓取
- [ ] cron - 定时任务
- [ ] message - 跨渠道消息
- [ ] nodes - 节点控制
- [ ] canvas - 画布渲染
- [ ] image - 图像分析
- [ ] tts - 文本转语音

#### 3.4 命令系统 (Commands)
- [ ] /help, /status, /commands
- [ ] /new, /reset, /stop
- [ ] /model - 模型切换
- [ ] /think - 思考级别
- [ ] /verbose - 详细模式
- [ ] /compact - 手动压缩
- [ ] /config - 配置管理
- [ ] /queue - 队列控制

#### 3.5 自动化 (Automation)
- [ ] Cron 定时任务
- [ ] Webhook 接收
- [ ] Heartbeat 心跳
- [ ] 系统事件

#### 3.6 其他功能
- [ ] 流式响应
- [ ] 媒体处理 (图片/音频/文档)
- [ ] 群组 @ 提及
- [ ] DM 配对认证
- [ ] OAuth 认证
- [ ] TTS 语音合成
- [ ] 技能系统 (Skills)

---

## 系统架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ClawdEx Gateway                               │
│                         (Phoenix Application)                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐   │
│  │  Telegram   │  │   Discord   │  │    Slack    │  │   WebChat   │   │
│  │  (Telegex)  │  │  (Nostrum)  │  │   (HTTP)    │  │ (LiveView)  │   │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘   │
│         │                │                │                │           │
│         └────────────────┴────────────────┴────────────────┘           │
│                                   │                                     │
│                    ┌──────────────▼──────────────┐                     │
│                    │      Message Router         │                     │
│                    │   (Phoenix.PubSub based)    │                     │
│                    └──────────────┬──────────────┘                     │
│                                   │                                     │
│         ┌─────────────────────────┼─────────────────────────┐          │
│         │                         │                         │          │
│         ▼                         ▼                         ▼          │
│  ┌─────────────┐          ┌─────────────┐          ┌─────────────┐    │
│  │   Session   │          │    Agent    │          │    Cron     │    │
│  │   Manager   │◄────────►│    Loop     │          │  Scheduler  │    │
│  │(DynSupervisor)         │ (GenStateMachine)      │ (Quantum)   │    │
│  └──────┬──────┘          └──────┬──────┘          └─────────────┘    │
│         │                        │                                     │
│         ▼                        ▼                                     │
│  ┌─────────────┐          ┌─────────────┐                             │
│  │   Session   │          │     AI      │                             │
│  │   Worker    │◄────────►│  Provider   │                             │
│  │ (GenServer) │          │   (Req)     │                             │
│  └──────┬──────┘          └─────────────┘                             │
│         │                                                              │
│         ▼                                                              │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                        Tool Executor                            │  │
│  │                    (Task.Supervisor)                            │  │
│  ├─────────┬─────────┬─────────┬─────────┬─────────┬─────────────┤  │
│  │  exec   │ browser │ web_*   │ memory  │ message │   cron      │  │
│  └─────────┴─────────┴─────────┴────┬────┴─────────┴─────────────┘  │
│                                      │                               │
├──────────────────────────────────────┼───────────────────────────────┤
│                                      ▼                               │
│  ┌─────────────────────────────────────────────────────────────────┐  │
│  │                    PostgreSQL + pgvector                        │  │
│  ├───────────────┬───────────────┬───────────────┬────────────────┤  │
│  │    agents     │   sessions    │   messages    │ memory_chunks  │  │
│  │               │               │               │  (HNSW index)  │  │
│  └───────────────┴───────────────┴───────────────┴────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 核心模块

### 1. Gateway (入口)

```elixir
# lib/clawd_ex/gateway.ex
defmodule ClawdEx.Gateway do
  @moduledoc """
  Gateway 主进程 - 管理所有渠道连接和 WebSocket API
  """
  use Supervisor
  
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(_opts) do
    children = [
      # WebSocket 端点
      {ClawdEx.Gateway.WebSocket, []},
      # 渠道管理器
      {ClawdEx.Channels.Supervisor, []},
      # 会话管理器
      {ClawdEx.Sessions.SessionManager, []},
      # 定时任务
      {ClawdEx.Cron.Scheduler, []},
      # 工具执行器
      {ClawdEx.Tools.Supervisor, []}
    ]
    
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### 2. Agent Loop (代理循环)

```elixir
# lib/clawd_ex/agent/loop.ex
defmodule ClawdEx.Agent.Loop do
  @moduledoc """
  代理循环 - 使用 GenStateMachine 实现状态机
  
  状态: :idle -> :loading -> :inferring -> :executing -> :streaming -> :idle
  """
  use GenStateMachine, callback_mode: :state_functions
  
  defstruct [
    :session_id,
    :agent_id,
    :model,
    :messages,
    :tools,
    :pending_tool_calls,
    :stream_pid
  ]
  
  # 状态转换
  def idle(:cast, {:run, params}, data) do
    # 1. 加载会话上下文
    # 2. 构建系统提示
    # 3. 调用 AI
    {:next_state, :loading, data, [{:next_event, :internal, {:load_context, params}}]}
  end
  
  def loading(:internal, {:load_context, params}, data) do
    # 加载记忆、技能、bootstrap 文件
    {:next_state, :inferring, data, [{:next_event, :internal, :call_ai}]}
  end
  
  def inferring(:internal, :call_ai, data) do
    # 调用 AI API (流式)
    {:next_state, :streaming, data}
  end
  
  def streaming(:info, {:ai_delta, delta}, data) do
    # 处理流式响应
    {:keep_state, data}
  end
  
  def streaming(:info, {:ai_tool_call, tool_call}, data) do
    # 执行工具调用
    {:next_state, :executing, data, [{:next_event, :internal, {:execute_tool, tool_call}}]}
  end
  
  def executing(:internal, {:execute_tool, tool_call}, data) do
    # 执行工具并返回结果
    {:next_state, :inferring, data, [{:next_event, :internal, :call_ai}]}
  end
end
```

### 3. Memory Service (记忆服务)

```elixir
# lib/clawd_ex/memory/service.ex
defmodule ClawdEx.Memory.Service do
  @moduledoc """
  记忆服务 - pgvector 语义搜索
  
  改进点:
  - 使用 PostgreSQL 原生向量索引
  - 支持混合搜索 (BM25 + Vector)
  - 增量索引
  """
  use GenServer
  
  alias ClawdEx.Memory
  alias ClawdEx.AI.Embeddings
  
  # 语义搜索
  def search(agent_id, query, opts \\ []) do
    GenServer.call(__MODULE__, {:search, agent_id, query, opts})
  end
  
  # 索引内容
  def index(agent_id, source, content, opts \\ []) do
    GenServer.cast(__MODULE__, {:index, agent_id, source, content, opts})
  end
  
  # 混合搜索实现
  defp hybrid_search(agent_id, query, opts) do
    vector_weight = Keyword.get(opts, :vector_weight, 0.7)
    text_weight = Keyword.get(opts, :text_weight, 0.3)
    limit = Keyword.get(opts, :limit, 10)
    
    # 1. 向量搜索
    vector_results = Memory.vector_search(agent_id, query, limit: limit * 2)
    
    # 2. 全文搜索 (PostgreSQL ts_rank)
    text_results = Memory.text_search(agent_id, query, limit: limit * 2)
    
    # 3. 合并结果 (RRF 或加权)
    merge_results(vector_results, text_results, vector_weight, text_weight, limit)
  end
end
```

### 4. Tool System (工具系统)

```elixir
# lib/clawd_ex/tools/registry.ex
defmodule ClawdEx.Tools.Registry do
  @moduledoc """
  工具注册表 - 动态工具注册和调用
  """
  
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map(), context :: map()) :: {:ok, any()} | {:error, term()}
  
  # 内置工具
  @builtin_tools [
    ClawdEx.Tools.Exec,
    ClawdEx.Tools.Process,
    ClawdEx.Tools.Read,
    ClawdEx.Tools.Write,
    ClawdEx.Tools.Edit,
    ClawdEx.Tools.WebSearch,
    ClawdEx.Tools.WebFetch,
    ClawdEx.Tools.Browser,
    ClawdEx.Tools.MemorySearch,
    ClawdEx.Tools.MemoryGet,
    ClawdEx.Tools.Message,
    ClawdEx.Tools.Cron,
    ClawdEx.Tools.Image,
    ClawdEx.Tools.TTS,
    ClawdEx.Tools.SessionsList,
    ClawdEx.Tools.SessionsHistory,
    ClawdEx.Tools.SessionsSend,
    ClawdEx.Tools.SessionsSpawn,
    ClawdEx.Tools.SessionStatus
  ]
  
  def list_tools(opts \\ []) do
    allowed = Keyword.get(opts, :allow, ["*"])
    denied = Keyword.get(opts, :deny, [])
    
    @builtin_tools
    |> Enum.filter(&tool_allowed?(&1, allowed, denied))
    |> Enum.map(&tool_schema/1)
  end
  
  def execute(tool_name, params, context) do
    case find_tool(tool_name) do
      nil -> {:error, :tool_not_found}
      tool -> tool.execute(params, context)
    end
  end
end
```

### 5. Channel Behaviour (渠道行为)

```elixir
# lib/clawd_ex/channels/channel.ex
defmodule ClawdEx.Channels.Channel do
  @moduledoc """
  渠道行为定义
  """
  
  @type message :: %{
    id: String.t(),
    content: String.t(),
    author_id: String.t(),
    channel_id: String.t(),
    timestamp: DateTime.t(),
    metadata: map()
  }
  
  @callback name() :: atom()
  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback send_message(target :: String.t(), content :: String.t(), opts :: keyword()) :: {:ok, message()} | {:error, term()}
  @callback handle_inbound(message()) :: :ok | {:error, term()}
  @callback supports_feature?(feature :: atom()) :: boolean()
  
  # 可选回调
  @optional_callbacks [
    send_reaction: 3,
    edit_message: 3,
    delete_message: 2,
    send_media: 4
  ]
end
```

---

## 配置系统

配置文件: `config/clawd_ex.exs` (运行时) 或数据库存储

```elixir
# config/clawd_ex.exs
config :clawd_ex,
  # Gateway 配置
  gateway: [
    port: 18789,
    bind: "127.0.0.1"
  ],
  
  # 渠道配置
  channels: [
    telegram: [
      enabled: true,
      bot_token: {:system, "TELEGRAM_BOT_TOKEN"},
      dm_policy: :pairing,  # :pairing | :allowlist | :open | :disabled
      allow_from: [],
      groups: %{
        "*" => %{require_mention: true}
      }
    ],
    discord: [
      enabled: false,
      token: {:system, "DISCORD_BOT_TOKEN"}
    ],
    webchat: [
      enabled: true
    ]
  ],
  
  # 代理配置
  agents: [
    defaults: [
      workspace: "~/clawd",
      model: "anthropic/claude-sonnet-4",
      timeout_seconds: 600,
      sandbox: [
        mode: :off,  # :off | :non_main | :all
        workspace_access: :rw
      ]
    ],
    list: [
      %{
        id: "main",
        default: true,
        identity: %{
          name: "Clawd",
          emoji: "🦞"
        }
      }
    ]
  ],
  
  # 消息配置
  messages: [
    response_prefix: "",
    ack_reaction: "👀",
    queue: [
      mode: :collect,  # :steer | :followup | :collect
      debounce_ms: 1000,
      cap: 20
    ]
  ],
  
  # AI 提供商
  models: [
    providers: [
      anthropic: [api_key: {:system, "ANTHROPIC_API_KEY"}],
      openai: [api_key: {:system, "OPENAI_API_KEY"}],
      google: [api_key: {:system, "GEMINI_API_KEY"}]
    ]
  ],
  
  # 工具配置
  tools: [
    allow: ["*"],
    deny: [],
    web: [
      search: [enabled: true],
      fetch: [enabled: true]
    ],
    elevated: [
      enabled: false,
      allow_from: []
    ]
  ],
  
  # 记忆配置 (改进版)
  memory: [
    enabled: true,
    provider: :pgvector,
    embedding: [
      provider: :openai,
      model: "text-embedding-3-small",
      dimensions: 1536
    ],
    search: [
      hybrid: [
        enabled: true,
        vector_weight: 0.7,
        text_weight: 0.3
      ]
    ],
    index: [
      chunk_size: 400,
      chunk_overlap: 80
    ]
  ],
  
  # Cron 配置
  cron: [
    enabled: true,
    max_concurrent_runs: 1
  ],
  
  # 日志配置
  logging: [
    level: :info,
    file: "/tmp/clawd_ex/clawd_ex.log"
  ]
```

---

## 数据库设计

### ERD 图

```
┌─────────────────┐       ┌─────────────────┐
│     agents      │       │   config_kv     │
├─────────────────┤       ├─────────────────┤
│ id (PK)         │       │ key (PK)        │
│ name (UNIQUE)   │       │ value (JSONB)   │
│ workspace_path  │       │ updated_at      │
│ default_model   │       └─────────────────┘
│ system_prompt   │
│ identity (JSONB)│       ┌─────────────────┐
│ config (JSONB)  │       │   cron_jobs     │
│ active          │       ├─────────────────┤
│ timestamps      │       │ id (PK)         │
└────────┬────────┘       │ job_id (UNIQUE) │
         │                │ name            │
         │ 1:N            │ schedule (JSONB)│
         │                │ payload (JSONB) │
         ▼                │ agent_id (FK)   │
┌─────────────────┐       │ enabled         │
│    sessions     │       │ last_run_at     │
├─────────────────┤       │ timestamps      │
│ id (PK)         │       └─────────────────┘
│ session_key     │
│ channel         │       ┌─────────────────┐
│ channel_id      │       │   cron_runs     │
│ state           │       ├─────────────────┤
│ model_override  │       │ id (PK)         │
│ token_count     │       │ job_id (FK)     │
│ message_count   │       │ started_at      │
│ metadata (JSONB)│       │ ended_at        │
│ last_activity   │       │ status          │
│ agent_id (FK)   │       │ result (JSONB)  │
│ timestamps      │       └─────────────────┘
└────────┬────────┘
         │ 1:N
         ▼
┌─────────────────┐
│    messages     │
├─────────────────┤
│ id (PK)         │
│ role            │
│ content         │
│ tool_calls      │
│ tool_call_id    │
│ model           │
│ tokens_in       │
│ tokens_out      │
│ metadata (JSONB)│
│ session_id (FK) │
│ timestamps      │
└─────────────────┘

┌─────────────────────────────────────────┐
│           memory_chunks                  │
├─────────────────────────────────────────┤
│ id (PK)                                  │
│ content (TEXT)                           │
│ source_file                              │
│ source_type (memory_file|session|doc)    │
│ start_line                               │
│ end_line                                 │
│ embedding (VECTOR(1536))  ◄── pgvector   │
│ embedding_model                          │
│ metadata (JSONB)                         │
│ agent_id (FK)                            │
│ timestamps                               │
├─────────────────────────────────────────┤
│ INDEX: HNSW on embedding (cosine)        │
│ INDEX: GIN on content (tsvector)         │
└─────────────────────────────────────────┘

┌─────────────────┐       ┌─────────────────┐
│  allow_lists    │       │  pairing_codes  │
├─────────────────┤       ├─────────────────┤
│ id (PK)         │       │ id (PK)         │
│ channel         │       │ channel         │
│ peer_id         │       │ peer_id         │
│ peer_type (dm/group)    │ code            │
│ agent_id (FK)   │       │ expires_at      │
│ metadata (JSONB)│       │ status          │
│ timestamps      │       │ timestamps      │
└─────────────────┘       └─────────────────┘
```

### 索引策略

```sql
-- 向量搜索 HNSW 索引
CREATE INDEX memory_chunks_embedding_idx ON memory_chunks
USING hnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 64);

-- 全文搜索 GIN 索引
CREATE INDEX memory_chunks_content_tsv_idx ON memory_chunks
USING gin (to_tsvector('english', content));

-- 会话查找
CREATE INDEX sessions_session_key_idx ON sessions (session_key);
CREATE INDEX sessions_channel_channel_id_idx ON sessions (channel, channel_id);

-- 消息时间查询
CREATE INDEX messages_session_id_inserted_at_idx ON messages (session_id, inserted_at DESC);
```

---

## 技术选型

| 组件 | 技术 | 说明 |
|------|------|------|
| 语言 | Elixir 1.15+ | 函数式 + OTP |
| Web 框架 | Phoenix 1.7+ | HTTP/WebSocket |
| 数据库 | PostgreSQL 14+ | 主存储 |
| 向量搜索 | pgvector 0.8+ | 语义记忆 |
| HTTP 客户端 | Req | AI API 调用 |
| Telegram | Telegex | Bot API |
| Discord | Nostrum | Gateway API |
| 定时任务 | Quantum | Cron 调度 |
| JSON | Jason | 编解码 |
| 实时 UI | Phoenix LiveView | 管理后台 |

---

## 开发路线图

### Phase 1: 核心基础 (当前)
- [x] Phoenix 项目初始化
- [x] PostgreSQL + pgvector 配置
- [x] 基础 Schema (agents, sessions, messages, memory_chunks)
- [x] AI Chat API (Anthropic, OpenAI, Gemini)
- [x] Embeddings API
- [x] Session Manager (DynamicSupervisor)
- [x] Session Worker (GenServer)
- [x] Telegram 渠道基础

### Phase 2: Agent Loop
- [ ] GenStateMachine Agent Loop
- [ ] 流式响应
- [ ] 工具调用框架
- [ ] 基础工具 (exec, read, write, edit)

### Phase 3: 记忆系统
- [ ] 向量语义搜索完善
- [ ] 混合搜索 (BM25 + Vector)
- [ ] 增量索引
- [ ] 自动记忆刷新

### Phase 4: 完整工具
- [ ] web_search, web_fetch
- [ ] browser (Playwright)
- [ ] message (跨渠道)
- [ ] cron, gateway

### Phase 5: 多渠道
- [ ] Discord 渠道
- [ ] Slack 渠道
- [ ] WebChat (LiveView)

### Phase 6: 高级功能
- [ ] 会话压缩 (Compaction)
- [ ] 多代理路由
- [ ] 技能系统
- [ ] 管理后台

### Phase 7: 生产就绪
- [ ] 日志 + 监控
- [ ] 配置热重载
- [ ] 部署脚本
- [ ] 文档

---

## 目录结构

```
clawd_ex/
├── config/
│   ├── config.exs
│   ├── dev.exs
│   ├── prod.exs
│   └── runtime.exs
├── lib/
│   ├── clawd_ex/
│   │   ├── agents/           # Agent 配置
│   │   │   ├── agent.ex
│   │   │   └── registry.ex
│   │   ├── ai/               # AI 提供商
│   │   │   ├── chat.ex
│   │   │   ├── embeddings.ex
│   │   │   └── providers/
│   │   │       ├── anthropic.ex
│   │   │       ├── openai.ex
│   │   │       └── google.ex
│   │   ├── channels/         # 消息渠道
│   │   │   ├── channel.ex
│   │   │   ├── supervisor.ex
│   │   │   ├── telegram.ex
│   │   │   ├── discord.ex
│   │   │   └── webchat.ex
│   │   ├── gateway/          # Gateway 核心
│   │   │   ├── gateway.ex
│   │   │   ├── websocket.ex
│   │   │   └── router.ex
│   │   ├── memory/           # 记忆系统
│   │   │   ├── memory.ex
│   │   │   ├── chunk.ex
│   │   │   ├── indexer.ex
│   │   │   └── service.ex
│   │   ├── sessions/         # 会话管理
│   │   │   ├── session.ex
│   │   │   ├── message.ex
│   │   │   ├── session_manager.ex
│   │   │   ├── session_worker.ex
│   │   │   └── compaction.ex
│   │   ├── agent/            # Agent Loop
│   │   │   ├── loop.ex
│   │   │   ├── context.ex
│   │   │   └── prompt.ex
│   │   ├── tools/            # 工具系统
│   │   │   ├── registry.ex
│   │   │   ├── supervisor.ex
│   │   │   ├── exec.ex
│   │   │   ├── process.ex
│   │   │   ├── read.ex
│   │   │   ├── write.ex
│   │   │   ├── edit.ex
│   │   │   ├── web_search.ex
│   │   │   ├── web_fetch.ex
│   │   │   ├── browser.ex
│   │   │   ├── memory_search.ex
│   │   │   ├── memory_get.ex
│   │   │   ├── message.ex
│   │   │   ├── cron.ex
│   │   │   ├── image.ex
│   │   │   └── tts.ex
│   │   ├── cron/             # 定时任务
│   │   │   ├── scheduler.ex
│   │   │   ├── job.ex
│   │   │   └── runner.ex
│   │   ├── commands/         # 聊天命令
│   │   │   ├── parser.ex
│   │   │   └── handlers/
│   │   ├── config/           # 配置管理
│   │   │   ├── loader.ex
│   │   │   └── schema.ex
│   │   ├── application.ex
│   │   ├── repo.ex
│   │   └── postgres_types.ex
│   └── clawd_ex_web/         # Phoenix Web
│       ├── channels/
│       │   └── user_socket.ex
│       ├── controllers/
│       ├── live/             # LiveView 管理后台
│       └── router.ex
├── priv/
│   ├── repo/migrations/
│   └── static/
├── test/
├── docs/
│   └── ARCHITECTURE.md       # 本文档
├── mix.exs
└── README.md
```

---

## 参考资料

- [Clawdbot 文档](https://docs.clawd.bot)
- [Clawdbot 源码](https://github.com/clawdbot/clawdbot)
- [Phoenix 文档](https://hexdocs.pm/phoenix)
- [pgvector 文档](https://github.com/pgvector/pgvector)
- [Telegex 文档](https://hexdocs.pm/telegex)
