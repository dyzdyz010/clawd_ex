defmodule ClawdEx.Sessions.Compaction do
  @moduledoc """
  会话上下文压缩 (Compaction)

  当会话消息历史接近模型的上下文窗口限制时，自动压缩旧消息为摘要。

  ## 工作原理

  1. 监控 token 使用量
  2. 当超过阈值时，将旧消息发送给 AI 生成摘要
  3. 用摘要消息替换旧消息
  4. 保留最近的消息不被压缩

  ## 配置

  - `:context_window` - 模型的上下文窗口大小（默认 200_000）
  - `:compaction_threshold` - 触发压缩的阈值比例（默认 0.8，即 80%）
  - `:keep_recent_messages` - 压缩时保留的最近消息数（默认 10）
  - `:compaction_model` - 用于生成摘要的模型（默认使用会话模型）
  """

  require Logger

  alias ClawdEx.Sessions.{Session, Message}
  alias ClawdEx.AI.Chat
  alias ClawdEx.Repo

  import Ecto.Query

  @type compaction_result :: {:ok, summary :: String.t()} | {:error, term()}
  @type check_result :: :ok | {:needs_compaction, estimated_tokens :: integer()}

  # 默认配置
  @default_context_window 200_000
  @default_threshold 0.8
  @default_keep_recent 10
  @default_compaction_model "anthropic/claude-sonnet-4"

  # 模型上下文窗口大小（可扩展）
  @model_context_windows %{
    "anthropic/claude-sonnet-4" => 200_000,
    "anthropic/claude-opus-4" => 200_000,
    "anthropic/claude-3-5-sonnet-20241022" => 200_000,
    "anthropic/claude-3-opus-20240229" => 200_000,
    "openai/gpt-4o" => 128_000,
    "openai/gpt-4-turbo" => 128_000,
    "openai/gpt-4" => 8_192,
    "google/gemini-pro" => 32_000,
    "google/gemini-1.5-pro" => 1_000_000
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  检查会话是否需要压缩

  返回 `:ok` 如果不需要压缩，或 `{:needs_compaction, token_count}` 如果需要。
  """
  @spec check_needed(Session.t() | integer(), keyword()) :: check_result()
  def check_needed(%Session{id: session_id} = session, opts \\ []) do
    model = session.model_override || opts[:model] || @default_compaction_model
    context_window = get_context_window(model, opts)
    threshold = Keyword.get(opts, :compaction_threshold, @default_threshold)

    # 估算当前 token 使用量
    estimated_tokens = estimate_session_tokens(session_id)
    max_tokens = trunc(context_window * threshold)

    if estimated_tokens >= max_tokens do
      Logger.info("Session #{session_id} needs compaction: #{estimated_tokens}/#{max_tokens} tokens")
      {:needs_compaction, estimated_tokens}
    else
      :ok
    end
  end

  def check_needed(session_id, opts) when is_integer(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :session_not_found}
      session -> check_needed(session, opts)
    end
  end

  @doc """
  执行会话压缩

  将旧消息压缩为摘要，保留最近的消息。

  ## Options

  - `:keep_recent` - 保留的最近消息数（默认 10）
  - `:custom_instructions` - 自定义压缩指令
  - `:model` - 用于生成摘要的模型
  """
  @spec compact(Session.t() | integer(), keyword()) :: compaction_result()
  def compact(%Session{id: session_id} = session, opts \\ []) do
    keep_recent = Keyword.get(opts, :keep_recent, @default_keep_recent)
    model = Keyword.get(opts, :model, session.model_override || @default_compaction_model)
    custom_instructions = Keyword.get(opts, :custom_instructions)

    Logger.info("Starting compaction for session #{session_id}")

    # 1. 获取所有消息
    messages = get_session_messages(session_id)
    message_count = length(messages)

    if message_count <= keep_recent do
      Logger.debug("Session #{session_id} has too few messages (#{message_count}) to compact")
      {:ok, "No compaction needed - too few messages"}
    else
      # 2. 分离要压缩的消息和要保留的消息
      {to_compact, _to_keep} = Enum.split(messages, message_count - keep_recent)

      # 3. 生成摘要
      case generate_summary(to_compact, model, custom_instructions) do
        {:ok, summary} ->
          # 4. 执行压缩：删除旧消息，插入摘要
          execute_compaction(session, to_compact, summary)

          # 5. 更新会话元数据
          update_session_compaction_stats(session)

          Logger.info("Compaction complete for session #{session_id}: #{length(to_compact)} messages -> 1 summary")
          {:ok, summary}

        {:error, reason} = error ->
          Logger.error("Compaction failed for session #{session_id}: #{inspect(reason)}")
          error
      end
    end
  end

  def compact(session_id, opts) when is_integer(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :session_not_found}
      session -> compact(session, opts)
    end
  end

  @doc """
  手动触发压缩（带自定义指令）
  """
  @spec manual_compact(Session.t() | integer(), String.t() | nil) :: compaction_result()
  def manual_compact(session, instructions \\ nil) do
    compact(session, custom_instructions: instructions)
  end

  @doc """
  获取模型的上下文窗口大小
  """
  @spec get_context_window(String.t(), keyword()) :: integer()
  def get_context_window(model, opts \\ []) do
    Keyword.get(opts, :context_window) ||
      Map.get(@model_context_windows, model) ||
      @default_context_window
  end

  @doc """
  估算消息列表的 token 数量

  使用简单的字符计数估算（约 4 字符 = 1 token）
  """
  @spec estimate_tokens([map()] | String.t()) :: integer()
  def estimate_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      content = msg[:content] || msg["content"] || ""
      tool_calls = msg[:tool_calls] || msg["tool_calls"] || []

      content_tokens = estimate_string_tokens(content)
      tool_tokens = tool_calls |> Jason.encode!() |> estimate_string_tokens()

      acc + content_tokens + tool_tokens
    end)
  end

  def estimate_tokens(text) when is_binary(text) do
    estimate_string_tokens(text)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp estimate_session_tokens(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> Repo.all()
    |> Enum.reduce(0, fn msg, acc ->
      # 优先使用实际 token 数（如果有）
      actual_tokens = (msg.tokens_in || 0) + (msg.tokens_out || 0)

      if actual_tokens > 0 do
        acc + actual_tokens
      else
        # 否则估算
        content_tokens = estimate_string_tokens(msg.content || "")
        tool_tokens = msg.tool_calls |> Jason.encode!() |> estimate_string_tokens()
        acc + content_tokens + tool_tokens
      end
    end)
  end

  defp estimate_string_tokens(text) when is_binary(text) do
    # 简单估算：约 4 字符 = 1 token（英文）
    # 中文可能更高，约 2 字符 = 1 token
    char_count = String.length(text)
    chinese_chars = count_chinese_chars(text)
    english_chars = char_count - chinese_chars

    trunc(english_chars / 4 + chinese_chars / 2)
  end

  defp estimate_string_tokens(_), do: 0

  defp count_chinese_chars(text) do
    text
    |> String.graphemes()
    |> Enum.count(fn char ->
      # 简单检测：CJK 统一汉字范围
      char_code = String.to_charlist(char) |> List.first()
      char_code != nil and char_code >= 0x4E00 and char_code <= 0x9FFF
    end)
  end

  defp get_session_messages(session_id) do
    Message
    |> where([m], m.session_id == ^session_id)
    |> order_by([m], asc: m.inserted_at)
    |> Repo.all()
    |> Enum.map(&message_to_map/1)
  end

  defp message_to_map(%Message{} = msg) do
    base = %{
      id: msg.id,
      role: to_string(msg.role),
      content: msg.content,
      inserted_at: msg.inserted_at
    }

    base =
      if msg.tool_calls && msg.tool_calls != [] do
        Map.put(base, :tool_calls, msg.tool_calls)
      else
        base
      end

    if msg.tool_call_id do
      Map.put(base, :tool_call_id, msg.tool_call_id)
    else
      base
    end
  end

  defp generate_summary(messages, model, custom_instructions) do
    # 构建摘要请求
    system_prompt = build_summary_system_prompt(custom_instructions)
    conversation_text = format_conversation_for_summary(messages)

    summary_request = [
      %{
        role: "user",
        content: """
        Please summarize the following conversation history. Focus on:
        - Key decisions and conclusions
        - Important context and background
        - Ongoing tasks and their status
        - Any critical information that should be preserved

        === CONVERSATION HISTORY ===
        #{conversation_text}
        === END OF HISTORY ===

        Provide a concise but comprehensive summary.
        """
      }
    ]

    case Chat.complete(model, summary_request, system: system_prompt, max_tokens: 2048) do
      {:ok, %{content: summary}} when is_binary(summary) and summary != "" ->
        {:ok, summary}

      {:ok, response} ->
        Logger.warning("Unexpected summary response: #{inspect(response)}")
        {:error, :invalid_summary_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_summary_system_prompt(nil) do
    """
    You are a conversation summarizer. Your task is to create concise but comprehensive
    summaries of conversation history. Preserve:

    1. Key decisions and their rationale
    2. Important context (names, dates, technical details)
    3. Ongoing tasks and their current status
    4. Questions that were asked and answered
    5. Any commitments or action items

    Be concise but don't lose important information. Write in a neutral, factual tone.
    """
  end

  defp build_summary_system_prompt(custom) do
    """
    You are a conversation summarizer.

    Additional instructions: #{custom}

    Create a concise but comprehensive summary preserving key decisions, context, and status.
    """
  end

  defp format_conversation_for_summary(messages) do
    messages
    |> Enum.map(fn msg ->
      role = String.upcase(msg[:role])
      content = msg[:content] || "(no content)"

      tool_info =
        if msg[:tool_calls] && msg[:tool_calls] != [] do
          tools = msg[:tool_calls] |> Enum.map(& &1["name"]) |> Enum.join(", ")
          " [Called tools: #{tools}]"
        else
          ""
        end

      "[#{role}]#{tool_info}: #{content}"
    end)
    |> Enum.join("\n\n")
  end

  defp execute_compaction(session, messages_to_delete, summary) do
    Repo.transaction(fn ->
      # 1. 删除旧消息
      message_ids = Enum.map(messages_to_delete, & &1[:id])

      Message
      |> where([m], m.id in ^message_ids)
      |> Repo.delete_all()

      # 2. 插入摘要消息（作为 system 角色）
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %Message{}
      |> Message.changeset(%{
        session_id: session.id,
        role: :system,
        content: "[Compaction Summary]\n\n#{summary}",
        metadata: %{
          type: "compaction_summary",
          compacted_at: now,
          original_message_count: length(messages_to_delete),
          original_first_message_at: messages_to_delete |> List.first() |> Map.get(:inserted_at),
          original_last_message_at: messages_to_delete |> List.last() |> Map.get(:inserted_at)
        }
      })
      |> Repo.insert!()
    end)
  end

  defp update_session_compaction_stats(session) do
    current_metadata = session.metadata || %{}
    compaction_count = Map.get(current_metadata, "compaction_count", 0) + 1

    new_metadata =
      Map.merge(current_metadata, %{
        "compaction_count" => compaction_count,
        "last_compaction_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    # 重新计算 token 数
    new_token_count = estimate_session_tokens(session.id)
    new_message_count = Repo.aggregate(
      from(m in Message, where: m.session_id == ^session.id),
      :count
    )

    session
    |> Session.changeset(%{
      metadata: new_metadata,
      token_count: new_token_count,
      message_count: new_message_count
    })
    |> Repo.update!()
  end
end
