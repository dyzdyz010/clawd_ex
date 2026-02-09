defmodule ClawdEx.Memory.Backend do
  @moduledoc """
  统一记忆后端 Behaviour

  所有记忆存储后端（PgVector, MemOS, LocalFile 等）必须实现此接口。

  ## 记忆类型
  - `:episodic` - 情景记忆：对话、事件、经历
  - `:semantic` - 语义记忆：事实、知识、概念
  - `:procedural` - 程序记忆：技能、流程、方法

  ## 记忆条目结构
  ```
  %{
    id: string,
    content: string,
    type: :episodic | :semantic | :procedural,
    source: string,           # 来源标识
    metadata: map,            # 额外元数据
    embedding: [float] | nil, # 向量嵌入（可选）
    score: float,             # 相关性分数（搜索结果）
    created_at: DateTime,
    updated_at: DateTime
  }
  ```
  """

  @type memory_type :: :episodic | :semantic | :procedural
  @type memory_entry :: %{
          id: String.t(),
          content: String.t(),
          type: memory_type(),
          source: String.t(),
          metadata: map(),
          embedding: [float()] | nil,
          score: float() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t()
        }
  @type search_opts :: [
          limit: pos_integer(),
          min_score: float(),
          types: [memory_type()],
          sources: [String.t()],
          after: DateTime.t(),
          before: DateTime.t()
        ]
  @type store_opts :: [
          type: memory_type(),
          source: String.t(),
          metadata: map(),
          conversation_id: String.t()
        ]

  @doc """
  初始化后端连接/状态
  """
  @callback init(config :: map()) :: {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  语义搜索记忆
  """
  @callback search(state :: term(), query :: String.t(), opts :: search_opts()) ::
              {:ok, [memory_entry()]} | {:error, reason :: term()}

  @doc """
  存储记忆条目
  """
  @callback store(state :: term(), content :: String.t(), opts :: store_opts()) ::
              {:ok, memory_entry()} | {:error, reason :: term()}

  @doc """
  批量存储消息（对话形式）
  """
  @callback store_messages(
              state :: term(),
              messages :: [%{role: String.t(), content: String.t()}],
              opts :: store_opts()
            ) ::
              {:ok, [memory_entry()]} | {:error, reason :: term()}

  @doc """
  删除记忆条目
  """
  @callback delete(state :: term(), id :: String.t()) :: :ok | {:error, reason :: term()}

  @doc """
  按来源删除所有记忆
  """
  @callback delete_by_source(state :: term(), source :: String.t()) ::
              {:ok, count :: non_neg_integer()} | {:error, reason :: term()}

  @doc """
  获取后端健康状态
  """
  @callback health(state :: term()) :: :ok | {:error, reason :: term()}

  @doc """
  获取后端名称标识
  """
  @callback name() :: atom()

  @optional_callbacks [health: 1]
end
