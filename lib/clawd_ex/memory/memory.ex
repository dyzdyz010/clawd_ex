defmodule ClawdEx.Memory do
  @moduledoc """
  统一记忆接口

  每个 Agent 选择一个记忆后端，通过此模块统一调用。
  后端作为可插拔的接入端，遵循 Memory.Backend 规范。

  ## 设计理念

  - **单选模式**：每个 Agent 只使用一个记忆后端，不聚合
  - **可插拔**：开发者可以自定义后端，只需实现 Backend behaviour
  - **配置驱动**：通过配置指定使用哪个后端

  ## 内置后端

  - `:local_file` - 本地 Markdown 文件 + BM25 搜索
  - `:memos` - MemOS 云端记忆服务
  - `:pgvector` - PostgreSQL 向量数据库

  ## 使用

  ```elixir
  # 获取 Agent 的记忆实例
  {:ok, memory} = Memory.for_agent(agent_id)

  # 或者直接创建指定后端的实例
  {:ok, memory} = Memory.new(:memos, %{api_key: "...", user_id: "..."})

  # 搜索
  {:ok, results} = Memory.search(memory, "关键词", limit: 5)

  # 存储
  :ok = Memory.store(memory, "内容", type: :episodic)

  # 存储对话
  :ok = Memory.store_conversation(memory, messages)
  ```

  ## Agent 配置

  ```elixir
  # config/config.exs 或 Agent 配置
  config :clawd_ex, :agents,
    default: %{
      memory: %{
        backend: :memos,  # 选择后端
        config: %{
          api_key: "...",
          user_id: "dyzdyz010"
        }
      }
    }
  ```
  """

  alias ClawdEx.Memory.Backend
  alias ClawdEx.Memory.Backends.{LocalFile, MemOS, PgVector}

  @type t :: %__MODULE__{
          backend: module(),
          state: term(),
          name: atom()
        }

  defstruct [:backend, :state, :name]

  @backends %{
    local_file: LocalFile,
    memos: MemOS,
    pgvector: PgVector
  }

  # ===========================================================================
  # 创建实例
  # ===========================================================================

  @doc """
  为指定 Agent 获取记忆实例

  根据 Agent 配置自动选择后端并初始化。
  """
  @spec for_agent(term()) :: {:ok, t()} | {:error, term()}
  def for_agent(agent_id) do
    config = get_agent_memory_config(agent_id)
    backend_name = config[:backend] || :local_file
    backend_config = config[:config] || %{}

    new(backend_name, backend_config)
  end

  @doc """
  创建指定后端的记忆实例
  """
  @spec new(atom(), map()) :: {:ok, t()} | {:error, term()}
  def new(backend_name, config \\ %{}) do
    case Map.get(@backends, backend_name) do
      nil ->
        {:error, {:unknown_backend, backend_name}}

      module ->
        case module.init(config) do
          {:ok, state} ->
            memory = %__MODULE__{
              backend: module,
              state: state,
              name: backend_name
            }

            {:ok, memory}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  注册自定义后端
  """
  @spec register_backend(atom(), module()) :: :ok
  def register_backend(name, module) do
    # 运行时注册，存入 persistent_term
    backends = :persistent_term.get({__MODULE__, :backends}, @backends)
    :persistent_term.put({__MODULE__, :backends}, Map.put(backends, name, module))
    :ok
  end

  @doc """
  列出可用后端
  """
  @spec list_backends() :: [atom()]
  def list_backends do
    backends = :persistent_term.get({__MODULE__, :backends}, @backends)
    Map.keys(backends)
  end

  # ===========================================================================
  # 记忆操作
  # ===========================================================================

  @doc """
  语义搜索记忆

  ## Options
  - `:limit` - 返回数量，默认 5
  - `:min_score` - 最小相关性，默认 0.3
  - `:types` - 过滤记忆类型
  """
  @spec search(t(), String.t(), keyword()) :: {:ok, [Backend.memory_entry()]} | {:error, term()}
  def search(%__MODULE__{backend: backend, state: state}, query, opts \\ []) do
    backend.search(state, query, opts)
  end

  @doc """
  存储单条记忆

  ## Options
  - `:type` - 记忆类型 (:episodic | :semantic | :procedural)，默认 :episodic
  - `:source` - 来源标识
  - `:metadata` - 额外元数据
  """
  @spec store(t(), String.t(), keyword()) :: {:ok, Backend.memory_entry()} | {:error, term()}
  def store(%__MODULE__{backend: backend, state: state}, content, opts \\ []) do
    backend.store(state, content, opts)
  end

  @doc """
  存储对话消息

  ## Options
  - `:conversation_id` - 对话 ID
  """
  @spec store_conversation(t(), [map()], keyword()) ::
          {:ok, [Backend.memory_entry()]} | {:error, term()}
  def store_conversation(%__MODULE__{backend: backend, state: state}, messages, opts \\ []) do
    backend.store_messages(state, messages, opts)
  end

  @doc """
  删除记忆
  """
  @spec delete(t(), String.t()) :: :ok | {:error, term()}
  def delete(%__MODULE__{backend: backend, state: state}, id) do
    backend.delete(state, id)
  end

  @doc """
  按来源删除所有记忆
  """
  @spec delete_by_source(t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_by_source(%__MODULE__{backend: backend, state: state}, source) do
    backend.delete_by_source(state, source)
  end

  @doc """
  健康检查
  """
  @spec health(t()) :: :ok | {:error, term()}
  def health(%__MODULE__{backend: backend, state: state}) do
    if function_exported?(backend, :health, 1) do
      backend.health(state)
    else
      :ok
    end
  end

  @doc """
  获取后端名称
  """
  @spec backend_name(t()) :: atom()
  def backend_name(%__MODULE__{name: name}), do: name

  # ===========================================================================
  # 便捷方法（给 Agent Loop 用）
  # ===========================================================================

  @doc """
  回忆相关记忆并构建上下文

  返回可直接插入 system prompt 的文本。
  """
  @spec recall_context(t(), String.t(), keyword()) :: String.t()
  def recall_context(memory, query, opts \\ []) do
    case search(memory, query, opts) do
      {:ok, []} ->
        ""

      {:ok, memories} ->
        format_context(memories)

      {:error, _} ->
        ""
    end
  end

  @doc """
  存储本轮对话（简化接口）
  """
  @spec memorize_turn(t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def memorize_turn(memory, user_input, assistant_response, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls, [])

    # 构建 assistant 内容，包含工具调用摘要
    assistant_content =
      if tool_calls == [] do
        assistant_response
      else
        tool_summary =
          tool_calls
          |> Enum.map(fn tc -> "- #{tc[:name] || tc["name"]}" end)
          |> Enum.join("\n")

        "#{assistant_response}\n\n[Tools: #{tool_summary}]"
      end

    messages = [
      %{role: "user", content: user_input},
      %{role: "assistant", content: assistant_content}
    ]

    case store_conversation(memory, messages, opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp get_agent_memory_config(agent_id) do
    ClawdEx.Memory.Config.for_agent(agent_id)
  end

  defp format_context(memories) do
    memory_text =
      memories
      |> Enum.take(5)
      |> Enum.map(fn mem ->
        score = Float.round((mem.score || 0) * 100, 1)
        source = mem.source || "unknown"
        content = String.slice(mem.content || "", 0, 400)

        "**[#{source}]** (#{score}%)\n#{content}"
      end)
      |> Enum.join("\n\n---\n\n")

    """

    ## Recalled Memories

    #{memory_text}

    """
  end
end
