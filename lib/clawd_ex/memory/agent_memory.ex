defmodule ClawdEx.Memory.AgentMemory do
  @moduledoc """
  Agent 专用记忆接口

  为 Agent Loop 提供简化的记忆操作，封装了：
  - 自动记忆检索（每次行动前）
  - 自动记忆存储（每轮对话后）
  - 上下文构建（将记忆融入 prompt）

  ## 记忆流程
  ```
  用户消息 → recall() → 获取相关记忆
      ↓
  构建上下文 → build_context() → 包含记忆的 system prompt
      ↓
  AI 响应 → memorize() → 存储对话和行动
      ↓
  下一轮
  ```

  ## 使用示例
  ```elixir
  # 在 Agent Loop 中
  def handle_message(message, state) do
    # 1. 回忆相关记忆
    {:ok, memories} = AgentMemory.recall(state.agent_id, message)

    # 2. 构建包含记忆的上下文
    context = AgentMemory.build_context(memories)

    # 3. 调用 AI
    response = call_ai(message, context)

    # 4. 存储本轮对话
    AgentMemory.memorize(state.agent_id, message, response, state.tool_calls)

    response
  end
  ```
  """

  require Logger

  alias ClawdEx.Memory.Manager

  @type memory :: map()
  @type recall_opts :: [
          limit: pos_integer(),
          min_score: float(),
          include_recent: boolean()
        ]
  @type memorize_opts :: [
          conversation_id: String.t(),
          tool_calls: [map()],
          files_modified: [String.t()]
        ]

  @doc """
  回忆相关记忆

  在处理用户消息前调用，获取与当前上下文相关的记忆。

  ## Options
  - `:limit` - 返回记忆数量（默认 5）
  - `:min_score` - 最小相关性（默认 0.3）
  - `:include_recent` - 是否包含最近的对话记忆（默认 true）
  """
  @spec recall(String.t(), keyword()) :: {:ok, [memory()]} | {:error, term()}
  def recall(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    min_score = Keyword.get(opts, :min_score, 0.3)

    # 提取查询关键词
    search_query = extract_keywords(query)

    if String.trim(search_query) == "" do
      {:ok, []}
    else
      Manager.search(search_query, limit: limit, min_score: min_score)
    end
  end

  @doc """
  存储本轮对话记忆

  在完成一轮对话后调用，记录：
  - 用户输入
  - AI 响应
  - 工具调用摘要
  - 文件操作

  ## Options
  - `:conversation_id` - 对话 ID（默认自动生成）
  - `:tool_calls` - 本轮工具调用列表
  - `:files_modified` - 修改的文件列表
  """
  @spec memorize(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def memorize(user_input, assistant_response, opts \\ []) do
    tool_calls = Keyword.get(opts, :tool_calls, [])
    files_modified = Keyword.get(opts, :files_modified, [])
    conversation_id = Keyword.get(opts, :conversation_id, generate_conversation_id())

    # 构建消息
    messages = [
      %{role: "user", content: user_input},
      %{role: "assistant", content: build_assistant_content(assistant_response, tool_calls, files_modified)}
    ]

    Manager.store_conversation(messages, conversation_id: conversation_id)
  end

  @doc """
  构建记忆上下文

  将检索到的记忆格式化为可插入 system prompt 的文本。
  """
  @spec build_context([memory()]) :: String.t()
  def build_context([]), do: ""

  def build_context(memories) do
    memory_text =
      memories
      |> Enum.map(&format_memory/1)
      |> Enum.join("\n\n")

    """
    ## Recalled Memories

    The following memories may be relevant to the current context:

    #{memory_text}

    Use these memories to inform your response, but don't explicitly mention "I remember" unless natural.
    """
  end

  @doc """
  提取重要信息并存储为长期记忆

  用于将重要的事实、偏好、决策存储为语义记忆。
  """
  @spec store_insight(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def store_insight(content, opts \\ []) do
    Manager.store(content, Keyword.put(opts, :type, :semantic))
  end

  @doc """
  存储程序性记忆（技能、流程）
  """
  @spec store_procedure(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def store_procedure(content, opts \\ []) do
    Manager.store(content, Keyword.put(opts, :type, :procedural))
  end

  @doc """
  获取记忆系统状态
  """
  @spec status() :: map()
  def status do
    Manager.status()
  end

  # Private helpers

  defp extract_keywords(text) do
    # 简单的关键词提取：移除停用词，保留有意义的词
    stop_words = ~w(的 是 在 了 和 与 或 但 如果 那么 这个 那个 什么 怎么 a an the is are was were be been being have has had do does did will would could should may might must)

    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in stop_words))
    |> Enum.take(10)
    |> Enum.join(" ")
  end

  defp build_assistant_content(response, [], []) do
    response
  end

  defp build_assistant_content(response, tool_calls, files_modified) do
    tool_part =
      if tool_calls != [] do
        tool_summary =
          tool_calls
          |> Enum.map(fn tc ->
            name = tc[:name] || tc["name"] || "unknown"
            "- #{name}"
          end)
          |> Enum.join("\n")

        "\n\n[Tool calls:\n#{tool_summary}]"
      else
        ""
      end

    files_part =
      if files_modified != [] do
        files_summary = Enum.join(files_modified, ", ")
        "\n\n[Files modified: #{files_summary}]"
      else
        ""
      end

    response <> tool_part <> files_part
  end

  defp format_memory(memory) do
    score = memory[:score] || memory.score || 0
    source = memory[:source] || memory.source || "unknown"
    content = memory[:content] || memory.content || ""
    backend = memory[:backend] || "unknown"

    score_str = Float.round(score * 100, 1)

    """
    **[#{source}]** (relevance: #{score_str}%, via #{backend})
    #{String.slice(content, 0, 500)}#{if String.length(content) > 500, do: "...", else: ""}
    """
  end

  defp generate_conversation_id do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    random = :rand.uniform(10000)
    "conv_#{timestamp}_#{random}"
  end
end
