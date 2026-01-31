# ClawdEx 记忆适配器设计

> 参考 Mem0 API 设计，实现可插拔的记忆系统

## 设计目标

1. **可插拔** - 支持多种后端 (SQLite, Mem0, PostgreSQL, etc.)
2. **零依赖** - 主程序不强制依赖 PostgreSQL
3. **统一接口** - 所有适配器遵循相同 Behaviour
4. **Mem0 兼容** - API 设计参考 Mem0，便于理解和迁移

## API 设计

### 核心操作

| 操作 | 说明 | Mem0 对应 |
|------|------|-----------|
| `add/2` | 添加记忆 | `POST /memories` |
| `search/2` | 语义搜索 | `POST /memories/search` |
| `get/1` | 获取单条 | `GET /memories/:id` |
| `get_all/1` | 获取全部 | `GET /memories` |
| `update/2` | 更新记忆 | `PUT /memories/:id` |
| `delete/1` | 删除记忆 | `DELETE /memories/:id` |
| `delete_all/1` | 清空记忆 | `DELETE /memories` |

### 数据结构

```elixir
# 记忆条目
@type memory :: %{
  id: String.t(),
  content: String.t(),
  metadata: map(),
  user_id: String.t() | nil,
  agent_id: String.t() | nil,
  created_at: DateTime.t(),
  updated_at: DateTime.t(),
  score: float() | nil  # 仅搜索结果包含
}

# 搜索选项
@type search_opts :: [
  user_id: String.t(),
  agent_id: String.t(),
  limit: pos_integer(),
  threshold: float(),  # 最低相关性阈值
  filters: map()       # 元数据过滤
]

# 添加选项
@type add_opts :: [
  user_id: String.t(),
  agent_id: String.t(),
  metadata: map(),
  infer: boolean()  # 是否让 LLM 推断/增强记忆
]
```

## Behaviour 定义

```elixir
defmodule ClawdEx.Memory.Behaviour do
  @moduledoc """
  记忆系统统一接口。
  
  设计参考 Mem0 API (https://docs.mem0.ai/api-reference)
  所有记忆适配器必须实现此 behaviour。
  """

  @type memory :: %{
    id: String.t(),
    content: String.t(),
    metadata: map(),
    user_id: String.t() | nil,
    agent_id: String.t() | nil,
    created_at: DateTime.t(),
    updated_at: DateTime.t(),
    score: float() | nil
  }

  @type add_opts :: keyword()
  @type search_opts :: keyword()
  @type get_opts :: keyword()

  # ============================================================
  # 生命周期
  # ============================================================

  @doc """
  初始化适配器。
  
  ## 配置示例
  
      # SQLite
      %{adapter: :sqlite, path: "~/.clawd_ex/data/memory.db"}
      
      # Mem0
      %{adapter: :mem0, api_key: "m0-xxx"}
      
      # PostgreSQL
      %{adapter: :postgres, url: "postgres://..."}
  """
  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}

  @doc "关闭适配器，清理资源"
  @callback terminate(state :: term()) :: :ok

  # ============================================================
  # 核心操作
  # ============================================================

  @doc """
  添加记忆。
  
  ## 选项
  
  - `:user_id` - 用户标识 (用于隔离)
  - `:agent_id` - 代理标识
  - `:metadata` - 自定义元数据
  - `:infer` - 是否使用 LLM 推断/增强 (默认 false)
  
  ## 示例
  
      add("用户喜欢喝咖啡", user_id: "alice", metadata: %{type: "preference"})
  """
  @callback add(content :: String.t(), opts :: add_opts()) ::
    {:ok, memory()} | {:error, term()}

  @doc """
  语义搜索记忆。
  
  ## 选项
  
  - `:user_id` - 限定用户
  - `:agent_id` - 限定代理
  - `:limit` - 返回数量 (默认 10)
  - `:threshold` - 最低相关性 (0.0-1.0)
  - `:filters` - 元数据过滤条件
  
  ## 示例
  
      search("用户的饮食偏好", user_id: "alice", limit: 5)
  """
  @callback search(query :: String.t(), opts :: search_opts()) ::
    {:ok, [memory()]} | {:error, term()}

  @doc """
  获取单条记忆。
  """
  @callback get(id :: String.t()) ::
    {:ok, memory()} | {:error, :not_found | term()}

  @doc """
  获取所有记忆。
  
  ## 选项
  
  - `:user_id` - 限定用户
  - `:agent_id` - 限定代理
  - `:limit` - 返回数量
  - `:offset` - 分页偏移
  """
  @callback get_all(opts :: get_opts()) ::
    {:ok, [memory()]} | {:error, term()}

  @doc """
  更新记忆内容。
  """
  @callback update(id :: String.t(), content :: String.t()) ::
    {:ok, memory()} | {:error, :not_found | term()}

  @doc """
  删除单条记忆。
  """
  @callback delete(id :: String.t()) ::
    :ok | {:error, :not_found | term()}

  @doc """
  删除所有记忆 (危险操作)。
  
  ## 选项
  
  - `:user_id` - 仅删除特定用户的记忆
  - `:agent_id` - 仅删除特定代理的记忆
  """
  @callback delete_all(opts :: keyword()) ::
    {:ok, deleted_count :: non_neg_integer()} | {:error, term()}

  # ============================================================
  # 可选操作
  # ============================================================

  @doc "批量添加记忆"
  @callback add_batch(list({String.t(), add_opts()})) ::
    {:ok, [memory()]} | {:error, term()}

  @doc "获取记忆历史版本 (如果支持)"
  @callback history(id :: String.t()) ::
    {:ok, [memory()]} | {:error, :not_supported | term()}

  @optional_callbacks [add_batch: 1, history: 1, terminate: 1]
end
```

## 适配器实现

### 1. SQLite 适配器 (内置默认)

```elixir
defmodule ClawdEx.Memory.Adapters.SQLite do
  @moduledoc """
  SQLite 记忆适配器。
  
  使用 sqlite-vec 扩展实现向量搜索。
  适合单机部署，零外部依赖。
  """
  
  @behaviour ClawdEx.Memory.Behaviour
  
  use GenServer
  
  defstruct [:conn, :embedding_fn, :config]
  
  # ----------------------------------------------------------
  # 初始化
  # ----------------------------------------------------------
  
  @impl true
  def init(config) do
    db_path = expand_path(config[:path] || "~/.clawd_ex/data/memory.db")
    ensure_dir(db_path)
    
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)
    
    # 加载 sqlite-vec 扩展
    :ok = load_vec_extension(conn)
    
    # 创建表
    :ok = setup_schema(conn)
    
    # 初始化嵌入函数
    embedding_fn = init_embedding(config[:embedding] || :local)
    
    {:ok, %__MODULE__{conn: conn, embedding_fn: embedding_fn, config: config}}
  end
  
  # ----------------------------------------------------------
  # 核心操作
  # ----------------------------------------------------------
  
  @impl true
  def add(content, opts) do
    GenServer.call(__MODULE__, {:add, content, opts})
  end
  
  def handle_call({:add, content, opts}, _from, state) do
    id = generate_id()
    now = DateTime.utc_now()
    
    # 生成嵌入向量
    {:ok, embedding} = state.embedding_fn.(content)
    
    # 插入数据
    :ok = Exqlite.Sqlite3.execute(state.conn, """
      INSERT INTO memories (id, content, embedding, user_id, agent_id, metadata, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, [id, content, serialize_vec(embedding), opts[:user_id], opts[:agent_id], 
          Jason.encode!(opts[:metadata] || %{}), now, now])
    
    memory = %{
      id: id,
      content: content,
      metadata: opts[:metadata] || %{},
      user_id: opts[:user_id],
      agent_id: opts[:agent_id],
      created_at: now,
      updated_at: now
    }
    
    {:reply, {:ok, memory}, state}
  end
  
  @impl true
  def search(query, opts) do
    GenServer.call(__MODULE__, {:search, query, opts})
  end
  
  def handle_call({:search, query, opts}, _from, state) do
    limit = opts[:limit] || 10
    threshold = opts[:threshold] || 0.0
    
    # 生成查询嵌入
    {:ok, query_embedding} = state.embedding_fn.(query)
    
    # 向量相似度搜索
    {:ok, rows} = Exqlite.Sqlite3.execute(state.conn, """
      SELECT 
        id, content, metadata, user_id, agent_id, created_at, updated_at,
        vec_distance_cosine(embedding, ?) as distance
      FROM memories
      WHERE (?1 IS NULL OR user_id = ?1)
        AND (?2 IS NULL OR agent_id = ?2)
      ORDER BY distance ASC
      LIMIT ?
    """, [serialize_vec(query_embedding), opts[:user_id], opts[:agent_id], limit])
    
    memories = Enum.map(rows, fn row ->
      %{
        id: row["id"],
        content: row["content"],
        metadata: Jason.decode!(row["metadata"]),
        user_id: row["user_id"],
        agent_id: row["agent_id"],
        created_at: row["created_at"],
        updated_at: row["updated_at"],
        score: 1.0 - row["distance"]  # 转换为相似度分数
      }
    end)
    |> Enum.filter(fn m -> m.score >= threshold end)
    
    {:reply, {:ok, memories}, state}
  end
  
  # ... 其他方法实现
  
  # ----------------------------------------------------------
  # Schema
  # ----------------------------------------------------------
  
  defp setup_schema(conn) do
    Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS memories (
        id TEXT PRIMARY KEY,
        content TEXT NOT NULL,
        embedding BLOB,
        user_id TEXT,
        agent_id TEXT,
        metadata TEXT DEFAULT '{}',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    """)
    
    # 创建向量索引
    Exqlite.Sqlite3.execute(conn, """
      CREATE INDEX IF NOT EXISTS idx_memories_embedding 
      ON memories(embedding)
    """)
    
    :ok
  end
end
```

### 2. Mem0 适配器 (HTTP)

```elixir
defmodule ClawdEx.Memory.Adapters.Mem0 do
  @moduledoc """
  Mem0.ai 云服务适配器。
  
  通过 REST API 调用 Mem0 服务。
  适合需要托管记忆服务的场景。
  
  配置:
      %{
        adapter: :mem0,
        api_key: "m0-xxx",
        base_url: "https://api.mem0.ai/v1"  # 可选
      }
  """
  
  @behaviour ClawdEx.Memory.Behaviour
  
  @default_base_url "https://api.mem0.ai/v1"
  
  defstruct [:api_key, :base_url]
  
  @impl true
  def init(config) do
    api_key = config[:api_key] || raise "Mem0 API key required"
    base_url = config[:base_url] || @default_base_url
    
    {:ok, %__MODULE__{api_key: api_key, base_url: base_url}}
  end
  
  @impl true
  def add(content, opts) do
    body = %{
      messages: [%{role: "user", content: content}],
      user_id: opts[:user_id],
      agent_id: opts[:agent_id],
      metadata: opts[:metadata]
    }
    
    case request(:post, "/memories", body) do
      {:ok, %{"results" => [result | _]}} ->
        {:ok, parse_memory(result)}
      {:ok, %{"results" => []}} ->
        {:error, :no_memory_created}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  @impl true
  def search(query, opts) do
    body = %{
      query: query,
      user_id: opts[:user_id],
      agent_id: opts[:agent_id],
      limit: opts[:limit] || 10
    }
    
    case request(:post, "/memories/search", body) do
      {:ok, %{"results" => results}} ->
        {:ok, Enum.map(results, &parse_memory/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  @impl true
  def get(id) do
    case request(:get, "/memories/#{id}") do
      {:ok, result} -> {:ok, parse_memory(result)}
      {:error, %{status: 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
  
  @impl true
  def get_all(opts) do
    params = URI.encode_query(%{
      user_id: opts[:user_id],
      agent_id: opts[:agent_id],
      limit: opts[:limit] || 100
    })
    
    case request(:get, "/memories?#{params}") do
      {:ok, %{"results" => results}} ->
        {:ok, Enum.map(results, &parse_memory/1)}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  @impl true
  def update(id, content) do
    case request(:put, "/memories/#{id}", %{content: content}) do
      {:ok, result} -> {:ok, parse_memory(result)}
      {:error, %{status: 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
  
  @impl true
  def delete(id) do
    case request(:delete, "/memories/#{id}") do
      {:ok, _} -> :ok
      {:error, %{status: 404}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
  
  @impl true
  def delete_all(opts) do
    params = URI.encode_query(%{
      user_id: opts[:user_id],
      agent_id: opts[:agent_id]
    })
    
    case request(:delete, "/memories?#{params}") do
      {:ok, %{"deleted" => count}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end
  
  # ----------------------------------------------------------
  # HTTP 请求
  # ----------------------------------------------------------
  
  defp request(method, path, body \\ nil) do
    url = "#{state().base_url}#{path}"
    
    opts = [
      headers: [
        {"Authorization", "Token #{state().api_key}"},
        {"Content-Type", "application/json"}
      ]
    ]
    
    opts = if body, do: Keyword.put(opts, :json, body), else: opts
    
    case Req.request(method, url, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}
      {:ok, %{status: status, body: body}} ->
        {:error, %{status: status, body: body}}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp parse_memory(data) do
    %{
      id: data["id"],
      content: data["memory"] || data["content"],
      metadata: data["metadata"] || %{},
      user_id: data["user_id"],
      agent_id: data["agent_id"],
      created_at: parse_datetime(data["created_at"]),
      updated_at: parse_datetime(data["updated_at"]),
      score: data["score"]
    }
  end
end
```

### 3. PostgreSQL 适配器 (独立库)

```elixir
# 在独立库 clawd_ex_pg_memory 中实现
defmodule ClawdExPgMemory.Adapter do
  @moduledoc """
  PostgreSQL 记忆适配器。
  
  使用 pgvector 实现向量搜索，结合 BM25 实现混合检索。
  适合需要高性能和可扩展性的生产环境。
  
  需要单独安装: {:clawd_ex_pg_memory, "~> 0.1"}
  
  配置:
      %{
        adapter: :postgres,
        url: "postgres://user:pass@localhost/clawd_ex_memory",
        pool_size: 10
      }
  """
  
  @behaviour ClawdEx.Memory.Behaviour
  
  # 保留当前 ClawdEx 的 pgvector + BM25 实现
  # 迁移现有代码到此适配器
  
  # ...
end
```

## 适配器管理器

```elixir
defmodule ClawdEx.Memory do
  @moduledoc """
  记忆系统入口模块。
  
  根据配置动态加载适配器，提供统一的 API。
  
  ## 使用
  
      # 配置在 config.toml 中指定
      ClawdEx.Memory.add("用户喜欢咖啡", user_id: "alice")
      ClawdEx.Memory.search("饮食偏好", user_id: "alice")
  """
  
  use GenServer
  
  @adapters %{
    sqlite: ClawdEx.Memory.Adapters.SQLite,
    mem0: ClawdEx.Memory.Adapters.Mem0,
    # postgres 需要安装 clawd_ex_pg_memory
    postgres: {ClawdExPgMemory.Adapter, optional: true}
  }
  
  # ----------------------------------------------------------
  # 公共 API (代理到适配器)
  # ----------------------------------------------------------
  
  def add(content, opts \\ []), do: call({:add, content, opts})
  def search(query, opts \\ []), do: call({:search, query, opts})
  def get(id), do: call({:get, id})
  def get_all(opts \\ []), do: call({:get_all, opts})
  def update(id, content), do: call({:update, id, content})
  def delete(id), do: call({:delete, id})
  def delete_all(opts \\ []), do: call({:delete_all, opts})
  
  # ----------------------------------------------------------
  # GenServer
  # ----------------------------------------------------------
  
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end
  
  @impl true
  def init(config) do
    adapter_name = config[:adapter] || :sqlite
    adapter_module = resolve_adapter(adapter_name)
    
    case adapter_module.init(config) do
      {:ok, adapter_state} ->
        {:ok, %{adapter: adapter_module, adapter_state: adapter_state}}
      {:error, reason} ->
        {:stop, reason}
    end
  end
  
  @impl true
  def handle_call({op, args}, _from, state) when is_list(args) do
    result = apply(state.adapter, op, args ++ [state.adapter_state])
    {:reply, result, state}
  end
  
  def handle_call({op, arg}, _from, state) do
    result = apply(state.adapter, op, [arg, state.adapter_state])
    {:reply, result, state}
  end
  
  defp call(request) do
    GenServer.call(__MODULE__, request)
  end
  
  defp resolve_adapter(name) do
    case Map.get(@adapters, name) do
      nil -> 
        raise "Unknown memory adapter: #{name}"
      {module, optional: true} ->
        if Code.ensure_loaded?(module) do
          module
        else
          raise "Memory adapter #{name} requires clawd_ex_pg_memory package"
        end
      module ->
        module
    end
  end
end
```

## 配置示例

```toml
# ~/.clawd_ex/config.toml

# 方案 1: SQLite (默认，零配置)
[memory]
adapter = "sqlite"
path = "~/.clawd_ex/data/memory.db"

[memory.embedding]
provider = "local"  # 使用本地模型 (Bumblebee)
# provider = "openai"  # 或使用 OpenAI API
# api_key = "sk-..."

# 方案 2: Mem0 云服务
[memory]
adapter = "mem0"
api_key = "m0-xxx"

# 方案 3: PostgreSQL (需要 clawd_ex_pg_memory)
[memory]
adapter = "postgres"
url = "postgres://user:pass@localhost/clawd_ex_memory"
pool_size = 10
```

## 嵌入模型

### 本地嵌入 (Bumblebee)

```elixir
defmodule ClawdEx.Memory.Embedding.Local do
  @moduledoc """
  本地嵌入模型，使用 Bumblebee + ONNX。
  
  默认模型: sentence-transformers/all-MiniLM-L6-v2 (384 维)
  """
  
  def init(config) do
    model = config[:model] || "sentence-transformers/all-MiniLM-L6-v2"
    {:ok, model} = Bumblebee.load_model({:hf, model})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, model})
    {:ok, %{model: model, tokenizer: tokenizer}}
  end
  
  def embed(text, state) do
    inputs = Bumblebee.apply_tokenizer(state.tokenizer, text)
    outputs = Axon.predict(state.model, inputs)
    embedding = outputs["last_hidden_state"] |> Nx.mean(axes: [1]) |> Nx.to_flat_list()
    {:ok, embedding}
  end
end
```

### OpenAI 嵌入

```elixir
defmodule ClawdEx.Memory.Embedding.OpenAI do
  @moduledoc """
  OpenAI text-embedding-3-small (1536 维)
  """
  
  def embed(text, config) do
    case Req.post!("https://api.openai.com/v1/embeddings",
      json: %{input: text, model: "text-embedding-3-small"},
      headers: [{"Authorization", "Bearer #{config[:api_key]}"}]
    ) do
      %{status: 200, body: %{"data" => [%{"embedding" => embedding}]}} ->
        {:ok, embedding}
      response ->
        {:error, response}
    end
  end
end
```

## 迁移计划

### 从现有代码迁移

```
当前结构:
lib/clawd_ex/memory/
├── bm25.ex           → clawd_ex_pg_memory
├── chunker.ex        → 保留 (通用)
├── tokenizer.ex      → 保留 (通用)
└── vector_store.ex   → clawd_ex_pg_memory

新结构:
lib/clawd_ex/memory/
├── behaviour.ex      # 接口定义
├── memory.ex         # 入口模块
├── adapters/
│   ├── sqlite.ex     # SQLite 适配器
│   └── mem0.ex       # Mem0 适配器
├── embedding/
│   ├── local.ex      # Bumblebee
│   └── openai.ex     # OpenAI API
├── chunker.ex        # 文档分块 (通用)
└── tokenizer.ex      # 中文分词 (通用)
```

## 测试策略

```elixir
# 适配器行为测试 (所有适配器共用)
defmodule ClawdEx.Memory.AdapterTest do
  use ExUnit.Case
  
  # 测试每个适配器实现
  @adapters [
    {ClawdEx.Memory.Adapters.SQLite, %{path: ":memory:"}},
    {ClawdEx.Memory.Adapters.Mem0, %{api_key: "test"}, skip: :no_api}
  ]
  
  for {adapter, config, opts} <- @adapters do
    describe "#{adapter}" do
      setup do
        {:ok, state} = adapter.init(config)
        {:ok, adapter: adapter, state: state}
      end
      
      test "add and search", %{adapter: adapter, state: state} do
        {:ok, memory} = adapter.add("测试内容", [user_id: "test"], state)
        assert memory.id
        assert memory.content == "测试内容"
        
        {:ok, results} = adapter.search("测试", [user_id: "test"], state)
        assert length(results) > 0
      end
      
      test "get and delete", %{adapter: adapter, state: state} do
        {:ok, memory} = adapter.add("临时内容", [], state)
        
        {:ok, fetched} = adapter.get(memory.id, state)
        assert fetched.content == "临时内容"
        
        :ok = adapter.delete(memory.id, state)
        assert {:error, :not_found} = adapter.get(memory.id, state)
      end
    end
  end
end
```

## 参考资料

- [Mem0 API Reference](https://docs.mem0.ai/api-reference)
- [sqlite-vec](https://github.com/asg017/sqlite-vec)
- [Bumblebee](https://github.com/elixir-nx/bumblebee)
- [Exqlite](https://github.com/elixir-sqlite/exqlite)
