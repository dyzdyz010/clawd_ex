# ClawdEx 分发架构设计

> 设计目标：让终端用户无需安装 Elixir 即可使用 ClawdEx

## 背景

当前 ClawdEx 依赖：
- Elixir/Erlang 运行时
- PostgreSQL + pgvector

这对普通用户来说门槛太高。我们需要一个 **零依赖、单文件可执行** 的分发方案。

## 方案选型

| 方案 | 优点 | 缺点 | 结论 |
|------|------|------|------|
| Docker | 跨平台、隔离 | 无法控制宿主系统 (browser/file/exec) | ❌ 不适合 |
| Mix Release | 自包含 | 需按平台编译，仍需 PostgreSQL | ❌ 依赖重 |
| **Burrito** | 单文件、原生执行 | 体积较大 (~50-80MB) | ✅ **首选** |
| Desktop App | GUI 友好 | 开发复杂 | ⏳ 未来考虑 |

## Burrito 方案

### 产出物

```bash
clawd_ex-linux-x64        # Linux x86_64
clawd_ex-linux-arm64      # Linux ARM64 (树莓派等)
clawd_ex-macos-x64        # macOS Intel
clawd_ex-macos-arm64      # macOS Apple Silicon
clawd_ex-windows-x64.exe  # Windows
```

### 用户体验

```bash
# 1. 下载 (一键)
curl -L https://github.com/dyzdyz010/clawd_ex/releases/latest/download/clawd_ex-$(uname -s)-$(uname -m) -o clawd_ex
chmod +x clawd_ex

# 2. 首次配置
./clawd_ex config
# 交互式向导：
# → AI Provider: anthropic (OAuth login / API key)
# → Memory Backend: sqlite (default) / mem0 / postgres
# → Channels: telegram / discord / none
# → Web UI port: 4000

# 3. 启动
./clawd_ex start
# ClawdEx v0.3.0 running
# → Web UI: http://localhost:4000
# → Telegram: @your_bot connected
# → Memory: SQLite (~/.clawd_ex/data/memory.db)

# 4. 其他命令
./clawd_ex status          # 查看状态
./clawd_ex stop            # 停止服务
./clawd_ex channels login  # 配置渠道
./clawd_ex logs            # 查看日志
```

### 目录结构

```
~/.clawd_ex/
├── config.toml              # 主配置文件
├── oauth_credentials.json   # OAuth 凭证
├── data/
│   ├── memory.db            # SQLite 记忆存储
│   ├── sessions.db          # 会话数据
│   └── browser/
│       └── screenshots/     # 浏览器截图
└── logs/
    └── clawd_ex.log         # 运行日志
```

### 配置文件

```toml
# ~/.clawd_ex/config.toml

[general]
port = 4000
log_level = "info"

[ai]
default_provider = "anthropic"
default_model = "claude-sonnet-4-20250514"

[ai.anthropic]
# OAuth token 自动从 oauth_credentials.json 加载
# 或指定 API key:
# api_key = "sk-ant-..."

[ai.openai]
api_key = "sk-..."

[memory]
adapter = "sqlite"  # sqlite | mem0 | postgres

[memory.sqlite]
path = "~/.clawd_ex/data/memory.db"

[memory.mem0]
api_key = "m0-xxx"
user_id = "default"

[memory.postgres]
url = "postgres://user:pass@localhost/clawd_ex_memory"

[channels.telegram]
enabled = true
bot_token = "123456:ABC..."

[channels.discord]
enabled = false
bot_token = ""

[browser]
headless = true
chrome_path = ""  # 自动检测
```

## 记忆适配器架构

### 设计原则

为了让主程序 **零 PostgreSQL 依赖**，我们将记忆系统抽象为适配器模式：

```
┌─────────────────────────────────────────────────────────┐
│                    ClawdEx Core                         │
│              (Burrito-friendly, 无重依赖)               │
├─────────────────────────────────────────────────────────┤
│                                                         │
│   ClawdEx.Memory.Behaviour (统一接口)                   │
│   ├── search/2    - 语义搜索                           │
│   ├── store/2     - 存储内容                           │
│   ├── get/1       - 获取内容                           │
│   ├── delete/1    - 删除内容                           │
│   └── init/1      - 初始化适配器                        │
│                                                         │
├─────────────────────────────────────────────────────────┤
│                      Adapters                           │
├───────────────┬───────────────┬─────────────────────────┤
│    SQLite     │     Mem0      │    PostgreSQL           │
│    (内置)     │    (HTTP)     │    (外部库)             │
├───────────────┼───────────────┼─────────────────────────┤
│  sqlite-vec   │  mem0.ai API  │  pgvector + BM25       │
│  本地嵌入式   │  云端托管     │  clawd_ex_pg_memory    │
│  零配置       │  按需付费     │  自部署高性能           │
└───────────────┴───────────────┴─────────────────────────┘
```

### Behaviour 定义

```elixir
defmodule ClawdEx.Memory.Behaviour do
  @moduledoc """
  记忆系统统一接口。
  所有记忆适配器必须实现此 behaviour。
  """

  @type content :: String.t()
  @type metadata :: map()
  @type search_result :: %{
    id: String.t(),
    content: content(),
    score: float(),
    metadata: metadata()
  }
  @type config :: map()
  @type state :: term()

  @doc "初始化适配器"
  @callback init(config()) :: {:ok, state()} | {:error, term()}

  @doc "语义搜索"
  @callback search(query :: String.t(), opts :: keyword()) ::
    {:ok, [search_result()]} | {:error, term()}

  @doc "存储内容"
  @callback store(content(), metadata()) ::
    {:ok, id :: String.t()} | {:error, term()}

  @doc "获取内容"
  @callback get(id :: String.t()) ::
    {:ok, %{content: content(), metadata: metadata()}} | {:error, :not_found}

  @doc "删除内容"
  @callback delete(id :: String.t()) :: :ok | {:error, term()}

  @doc "批量存储"
  @callback store_batch(list({content(), metadata()})) ::
    {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks [store_batch: 1]
end
```

### 适配器实现

#### 1. SQLite 适配器 (内置)

```elixir
defmodule ClawdEx.Memory.SQLiteAdapter do
  @behaviour ClawdEx.Memory.Behaviour
  
  # 使用 sqlite-vec 扩展实现向量搜索
  # 嵌入模型：本地 (bumblebee) 或 API (OpenAI)
  
  @impl true
  def init(config) do
    db_path = config[:path] || "~/.clawd_ex/data/memory.db"
    # 初始化 SQLite + sqlite-vec
  end
  
  @impl true
  def search(query, opts) do
    # 1. 生成查询嵌入
    # 2. 向量相似度搜索
    # 3. 可选：BM25 关键词搜索
    # 4. 混合排序返回
  end
  
  # ...
end
```

#### 2. Mem0 适配器 (HTTP)

```elixir
defmodule ClawdEx.Memory.Mem0Adapter do
  @behaviour ClawdEx.Memory.Behaviour
  
  # 调用 mem0.ai REST API
  # https://docs.mem0.ai/api-reference
  
  @base_url "https://api.mem0.ai/v1"
  
  @impl true
  def search(query, opts) do
    Req.post!("#{@base_url}/memories/search", 
      json: %{query: query, user_id: opts[:user_id]},
      headers: [{"Authorization", "Token #{api_key()}"}]
    )
  end
  
  # ...
end
```

#### 3. PostgreSQL 适配器 (独立库)

```elixir
# 在独立库 clawd_ex_pg_memory 中
defmodule ClawdExPgMemory.Adapter do
  @behaviour ClawdEx.Memory.Behaviour
  
  # 使用 pgvector + BM25
  # 保留当前高性能实现
  
  # ...
end
```

### 代码库结构

```
# 主程序 (Burrito 友好)
clawd_ex/
├── lib/clawd_ex/
│   ├── memory/
│   │   ├── behaviour.ex        # 接口定义
│   │   ├── adapter.ex          # 动态加载
│   │   ├── sqlite_adapter.ex   # SQLite 实现
│   │   └── mem0_adapter.ex     # Mem0 实现
│   └── ...
├── mix.exs                      # 无 postgrex 依赖
└── burrito.exs                  # Burrito 配置

# PostgreSQL 独立库 (可选安装)
clawd_ex_pg_memory/
├── lib/
│   ├── adapter.ex              # PostgreSQL 适配器
│   ├── vector_store.ex         # pgvector 封装
│   ├── bm25.ex                 # BM25 搜索
│   └── hybrid_search.ex        # 混合检索
├── priv/repo/migrations/       # 数据库迁移
└── mix.exs                      # postgrex, pgvector 依赖
```

### 使用方式

```elixir
# 主程序自动根据配置加载适配器
config = ClawdEx.Config.get(:memory)
{:ok, adapter} = ClawdEx.Memory.Adapter.start_link(config)

# 统一接口调用
{:ok, results} = ClawdEx.Memory.search("关于 OAuth 的讨论")
{:ok, id} = ClawdEx.Memory.store("今天学习了 Elixir", %{type: "note"})
```

## 实施计划

### Phase 1: 记忆适配器重构
1. [ ] 定义 `ClawdEx.Memory.Behaviour`
2. [ ] 创建 `ClawdEx.Memory.Adapter` 动态加载器
3. [ ] 实现 `SQLiteAdapter` (基础版)
4. [ ] 实现 `Mem0Adapter`
5. [ ] 将现有 PostgreSQL 代码移至 `clawd_ex_pg_memory`

### Phase 2: 配置系统
1. [ ] TOML 配置解析 (toml_elixir)
2. [ ] CLI 配置向导
3. [ ] 运行时配置热更新

### Phase 3: Burrito 集成
1. [ ] 添加 Burrito 依赖
2. [ ] 配置多平台编译
3. [ ] CI/CD 自动构建 Release
4. [ ] GitHub Releases 分发

### Phase 4: 完善
1. [ ] 本地嵌入模型 (Bumblebee)
2. [ ] 安装脚本 (curl | bash)
3. [ ] 自动更新机制
4. [ ] 文档和教程

## 时间线

| 阶段 | 预计时间 | 产出 |
|------|----------|------|
| Phase 1 | 2-3 天 | 记忆适配器系统 |
| Phase 2 | 1-2 天 | TOML 配置 + CLI |
| Phase 3 | 1-2 天 | Burrito 可执行文件 |
| Phase 4 | 持续 | 优化和文档 |

## 参考

- [Burrito](https://github.com/burrito-elixir/burrito) - Elixir 单文件打包
- [sqlite-vec](https://github.com/asg017/sqlite-vec) - SQLite 向量扩展
- [Mem0](https://mem0.ai/) - 记忆即服务
- [Exqlite](https://github.com/elixir-sqlite/exqlite) - Elixir SQLite 驱动
