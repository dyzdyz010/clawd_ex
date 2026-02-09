defmodule ClawdEx.Memory.Manager do
  @moduledoc """
  统一记忆管理器

  协调多个记忆后端，提供：
  - 智能路由：根据记忆类型选择合适的后端
  - 聚合搜索：并行查询多个后端并合并结果
  - 自动同步：在后端间同步重要记忆
  - 生命周期管理：记忆的创建、检索、整合、遗忘

  ## 记忆层次
  ```
  ┌─────────────────────────────────────────────────────┐
  │  短期记忆 (Short-term)                               │
  │  - 当前对话上下文                                     │
  │  - 存储：进程状态                                     │
  │  - 生命周期：会话结束即消失                            │
  └─────────────────────────────────────────────────────┘
                          ↓ 整合
  ┌─────────────────────────────────────────────────────┐
  │  工作记忆 (Working)                                  │
  │  - 当前任务相关上下文                                 │
  │  - 存储：LocalFile (daily notes)                    │
  │  - 生命周期：数天                                     │
  └─────────────────────────────────────────────────────┘
                          ↓ 整合
  ┌─────────────────────────────────────────────────────┐
  │  长期记忆 (Long-term)                                │
  │  - 重要经验、知识、偏好                               │
  │  - 存储：PgVector / MemOS / MEMORY.md               │
  │  - 生命周期：永久（定期回顾）                          │
  └─────────────────────────────────────────────────────┘
  ```

  ## 使用
  ```elixir
  # 启动管理器
  {:ok, manager} = Manager.start_link(config)

  # 搜索记忆
  {:ok, memories} = Manager.search(manager, "用户偏好", limit: 5)

  # 存储记忆
  {:ok, _} = Manager.store(manager, "用户喜欢简洁的回复", type: :semantic)

  # 存储对话
  {:ok, _} = Manager.store_conversation(manager, messages)
  ```
  """

  use GenServer
  require Logger

  alias ClawdEx.Memory.Backends.{MemOS, PgVector, LocalFile}

  @type backend_config :: %{
          module: module(),
          config: map(),
          enabled: boolean(),
          priority: integer(),
          # 该后端适合存储的记忆类型
          types: [:episodic | :semantic | :procedural]
        }

  @type state :: %{
          backends: %{atom() => {module(), term()}},
          config: map(),
          # 路由规则：类型 -> 后端列表
          routing: %{atom() => [atom()]}
        }

  # Client API

  def start_link(config \\ %{}) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  语义搜索记忆

  Options:
  - `:limit` - 返回结果数量（默认 10）
  - `:min_score` - 最小相关性分数（默认 0.3）
  - `:types` - 过滤记忆类型
  - `:backends` - 指定查询的后端（默认全部）
  - `:merge` - 合并策略 `:score` | `:round_robin`（默认 :score）
  """
  @spec search(GenServer.server(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def search(server \\ __MODULE__, query, opts \\ []) do
    GenServer.call(server, {:search, query, opts}, 30_000)
  end

  @doc """
  存储单条记忆

  Options:
  - `:type` - 记忆类型（默认 :episodic）
  - `:source` - 来源标识
  - `:backends` - 指定存储的后端（默认根据类型路由）
  - `:metadata` - 额外元数据
  """
  @spec store(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def store(server \\ __MODULE__, content, opts \\ []) do
    GenServer.call(server, {:store, content, opts}, 30_000)
  end

  @doc """
  存储对话消息

  自动路由到支持对话存储的后端（MemOS, LocalFile）
  """
  @spec store_conversation(GenServer.server(), [map()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def store_conversation(server \\ __MODULE__, messages, opts \\ []) do
    GenServer.call(server, {:store_conversation, messages, opts}, 30_000)
  end

  @doc """
  获取所有后端状态
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc """
  健康检查
  """
  @spec health(GenServer.server()) :: %{atom() => :ok | {:error, term()}}
  def health(server \\ __MODULE__) do
    GenServer.call(server, :health, 10_000)
  end

  # Server callbacks

  @impl true
  def init(config) do
    Logger.info("Memory Manager initializing...")

    backends = init_backends(config)
    routing = build_routing(config, backends)

    state = %{
      backends: backends,
      config: config,
      routing: routing
    }

    Logger.info("Memory Manager started with backends: #{inspect(Map.keys(backends))}")
    {:ok, state}
  end

  @impl true
  def handle_call({:search, query, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    merge = Keyword.get(opts, :merge, :score)
    backend_filter = Keyword.get(opts, :backends, nil)

    # 选择要查询的后端
    backends_to_query =
      if backend_filter do
        state.backends
        |> Enum.filter(fn {name, _} -> name in backend_filter end)
        |> Map.new()
      else
        state.backends
      end

    # 并行查询所有后端
    tasks =
      backends_to_query
      |> Enum.map(fn {name, {_module, backend_state}} ->
        Task.async(fn ->
          {name, search_backend(name, backend_state, query, opts)}
        end)
      end)

    # 收集结果（最多等待 25 秒）
    results =
      tasks
      |> Task.yield_many(25_000)
      |> Enum.map(fn {task, result} ->
        case result do
          {:ok, {name, {:ok, entries}}} ->
            {name, entries}

          {:ok, {name, {:error, reason}}} ->
            Logger.warning("Backend #{name} search failed: #{inspect(reason)}")
            {name, []}

          nil ->
            Task.shutdown(task, :brutal_kill)
            {:timeout, []}
        end
      end)
      |> Enum.flat_map(fn {name, entries} ->
        Enum.map(entries, &Map.put(&1, :backend, name))
      end)

    # 合并结果
    merged =
      case merge do
        :score ->
          results
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(limit)

        :round_robin ->
          results
          |> Enum.group_by(& &1.backend)
          |> Map.values()
          |> round_robin_merge(limit)
      end

    {:reply, {:ok, merged}, state}
  end

  @impl true
  def handle_call({:store, content, opts}, _from, state) do
    type = Keyword.get(opts, :type, :episodic)
    backend_filter = Keyword.get(opts, :backends, nil)

    # 确定目标后端
    target_backends =
      if backend_filter do
        backend_filter
      else
        Map.get(state.routing, type, Map.keys(state.backends))
      end

    # 存储到第一个可用后端
    result =
      target_backends
      |> Enum.find_value(fn backend_name ->
        case Map.get(state.backends, backend_name) do
          nil ->
            nil

          {_module, backend_state} ->
            case store_backend(backend_name, backend_state, content, opts) do
              {:ok, entry} -> {:ok, Map.put(entry, :backend, backend_name)}
              {:error, _} -> nil
            end
        end
      end)

    case result do
      {:ok, _} = success -> {:reply, success, state}
      nil -> {:reply, {:error, :no_available_backend}, state}
    end
  end

  @impl true
  def handle_call({:store_conversation, messages, opts}, _from, state) do
    # 对话优先存储到 MemOS，其次 LocalFile
    preferred_backends = [:memos, :local_file]

    result =
      preferred_backends
      |> Enum.find_value(fn backend_name ->
        case Map.get(state.backends, backend_name) do
          nil ->
            nil

          {_module, backend_state} ->
            case store_messages_backend(backend_name, backend_state, messages, opts) do
              {:ok, entries} ->
                {:ok, Enum.map(entries, &Map.put(&1, :backend, backend_name))}

              {:error, _} ->
                nil
            end
        end
      end)

    case result do
      {:ok, _} = success -> {:reply, success, state}
      nil -> {:reply, {:error, :no_available_backend}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      state.backends
      |> Enum.map(fn {name, {module, _state}} ->
        {name, %{module: module, enabled: true}}
      end)
      |> Map.new()

    {:reply, %{backends: status, routing: state.routing}, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health_status =
      state.backends
      |> Enum.map(fn {name, {module, backend_state}} ->
        result =
          if function_exported?(module, :health, 1) do
            module.health(backend_state)
          else
            :ok
          end

        {name, result}
      end)
      |> Map.new()

    {:reply, health_status, state}
  end

  # Private helpers

  defp init_backends(config) do
    backends_config = Map.get(config, :backends, default_backends_config())

    backends_config
    |> Enum.reduce(%{}, fn {name, backend_config}, acc ->
      if Map.get(backend_config, :enabled, true) do
        module = Map.fetch!(backend_config, :module)
        init_config = Map.get(backend_config, :config, %{})

        case module.init(init_config) do
          {:ok, state} ->
            Logger.info("Backend #{name} initialized")
            Map.put(acc, name, {module, state})

          {:error, reason} ->
            Logger.warning("Backend #{name} failed to init: #{inspect(reason)}")
            acc
        end
      else
        acc
      end
    end)
  end

  defp default_backends_config do
    %{
      local_file: %{
        module: LocalFile,
        enabled: true,
        priority: 1,
        types: [:episodic, :semantic, :procedural],
        config: %{
          workspace: System.get_env("CLAWD_WORKSPACE", "~/.clawd/workspace")
        }
      },
      memos: %{
        module: MemOS,
        enabled: memos_configured?(),
        priority: 2,
        types: [:episodic],
        config: %{
          api_key: get_memos_api_key(),
          user_id: System.get_env("MEMOS_USER_ID", "default")
        }
      },
      pgvector: %{
        module: PgVector,
        enabled: pgvector_available?(),
        priority: 3,
        types: [:semantic, :procedural],
        config: %{}
      }
    }
  end

  defp build_routing(config, backends) do
    backends_config = Map.get(config, :backends, default_backends_config())

    # 为每种类型建立后端优先级列表
    [:episodic, :semantic, :procedural]
    |> Enum.map(fn type ->
      backends_for_type =
        backends_config
        |> Enum.filter(fn {name, cfg} ->
          Map.has_key?(backends, name) and type in Map.get(cfg, :types, [])
        end)
        |> Enum.sort_by(fn {_name, cfg} -> Map.get(cfg, :priority, 99) end)
        |> Enum.map(fn {name, _} -> name end)

      {type, backends_for_type}
    end)
    |> Map.new()
  end

  defp search_backend(:memos, state, query, opts),
    do: MemOS.search(state, query, opts)

  defp search_backend(:pgvector, state, query, opts),
    do: PgVector.search(state, query, opts)

  defp search_backend(:local_file, state, query, opts),
    do: LocalFile.search(state, query, opts)

  defp search_backend(name, _state, _query, _opts) do
    Logger.warning("Unknown backend: #{name}")
    {:error, :unknown_backend}
  end

  defp store_backend(:memos, state, content, opts),
    do: MemOS.store(state, content, opts)

  defp store_backend(:pgvector, state, content, opts),
    do: PgVector.store(state, content, opts)

  defp store_backend(:local_file, state, content, opts),
    do: LocalFile.store(state, content, opts)

  defp store_backend(name, _state, _content, _opts) do
    Logger.warning("Unknown backend: #{name}")
    {:error, :unknown_backend}
  end

  defp store_messages_backend(:memos, state, messages, opts),
    do: MemOS.store_messages(state, messages, opts)

  defp store_messages_backend(:pgvector, state, messages, opts),
    do: PgVector.store_messages(state, messages, opts)

  defp store_messages_backend(:local_file, state, messages, opts),
    do: LocalFile.store_messages(state, messages, opts)

  defp store_messages_backend(name, _state, _messages, _opts) do
    Logger.warning("Unknown backend: #{name}")
    {:error, :unknown_backend}
  end

  defp round_robin_merge(grouped_results, limit) do
    grouped_results
    |> Enum.map(&Enum.with_index/1)
    |> List.flatten()
    |> Enum.sort_by(fn {_item, idx} -> idx end)
    |> Enum.map(fn {item, _} -> item end)
    |> Enum.take(limit)
  end

  defp memos_configured? do
    api_key = get_memos_api_key()
    api_key != nil and api_key != ""
  end

  defp get_memos_api_key do
    # 从环境变量或配置文件读取
    System.get_env("MEMOS_API_KEY") ||
      read_config_memos_key()
  end

  defp read_config_memos_key do
    config_path = Path.expand("~/.clawd/config.json")

    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"skills" => %{"memos" => %{"apiKey" => key}}}} -> key
          {:ok, %{"memos" => %{"api_key" => key}}} -> key
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp pgvector_available? do
    # 检查数据库连接和 pgvector 扩展
    case ClawdEx.Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'vector'") do
      {:ok, %{num_rows: 1}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
