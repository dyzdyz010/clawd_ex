defmodule ClawdEx.Memory.AgentMemory do
  @moduledoc """
  Agent 专用记忆模块

  为每个 Agent 管理独立的记忆实例。每个 Agent 启动时根据配置
  选择一个记忆后端，整个生命周期内使用同一个后端。

  ## 使用

  ```elixir
  # Agent 初始化时
  {:ok, memory} = AgentMemory.init(agent_id)

  # 处理消息前：回忆
  context = AgentMemory.recall(memory, user_message)

  # 处理消息后：记忆
  AgentMemory.memorize(memory, user_input, response, tool_calls: [...])
  ```
  """

  alias ClawdEx.Memory

  @doc """
  为 Agent 初始化记忆实例

  根据 Agent 配置选择后端。如果配置中没有指定，使用全局默认。
  """
  @spec init(term()) :: {:ok, Memory.t()} | {:error, term()}
  def init(agent_id) do
    Memory.for_agent(agent_id)
  end

  @doc """
  使用指定后端初始化（测试或手动配置用）
  """
  @spec init_with_backend(atom(), map()) :: {:ok, Memory.t()} | {:error, term()}
  def init_with_backend(backend, config \\ %{}) do
    Memory.new(backend, config)
  end

  @doc """
  回忆相关记忆

  根据用户消息搜索相关记忆，返回可插入 system prompt 的上下文文本。
  如果搜索失败或无结果，返回空字符串。

  ## Options
  - `:limit` - 返回数量，默认 5
  - `:min_score` - 最小相关性，默认 0.3
  """
  @spec recall(Memory.t(), String.t(), keyword()) :: String.t()
  def recall(memory, query, opts \\ []) do
    Memory.recall_context(memory, query, opts)
  end

  @doc """
  存储本轮对话

  将用户输入和 AI 响应存入记忆。工具调用会作为摘要附加到响应中。

  ## Options
  - `:tool_calls` - 本轮工具调用列表
  - `:conversation_id` - 对话 ID
  """
  @spec memorize(Memory.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def memorize(memory, user_input, assistant_response, opts \\ []) do
    Memory.memorize_turn(memory, user_input, assistant_response, opts)
  end

  @doc """
  存储重要信息为语义记忆

  用于保存事实、知识、用户偏好等长期有效的信息。
  """
  @spec store_insight(Memory.t(), String.t(), keyword()) ::
          {:ok, Memory.Backend.memory_entry()} | {:error, term()}
  def store_insight(memory, content, opts \\ []) do
    Memory.store(memory, content, Keyword.put(opts, :type, :semantic))
  end

  @doc """
  存储技能/流程为程序记忆
  """
  @spec store_procedure(Memory.t(), String.t(), keyword()) ::
          {:ok, Memory.Backend.memory_entry()} | {:error, term()}
  def store_procedure(memory, content, opts \\ []) do
    Memory.store(memory, content, Keyword.put(opts, :type, :procedural))
  end

  @doc """
  获取记忆后端信息
  """
  @spec info(Memory.t()) :: map()
  def info(memory) do
    %{
      backend: Memory.backend_name(memory),
      health: Memory.health(memory)
    }
  end
end
