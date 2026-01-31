defmodule ClawdEx.Streaming.BlockChunker do
  @moduledoc """
  Block Streaming 分块器

  实现智能文本分块：
  - Low bound: 不发送直到 buffer >= minChars（除非强制刷新）
  - High bound: 在 maxChars 之前寻找断点；如果没有，在 maxChars 处强制断开
  - Break preference: paragraph > newline > sentence > whitespace > hard break
  - Code fence protection: 不在代码块中间断开；强制断开时关闭并重新打开 fence

  ## 使用示例

      chunker = BlockChunker.new(min_chars: 200, max_chars: 800)
      {chunks, chunker} = BlockChunker.push(chunker, "Hello world...")
      {final_chunks, _} = BlockChunker.flush(chunker)

  """

  @enforce_keys [:min_chars, :max_chars]
  defstruct [
    :min_chars,
    :max_chars,
    :break_preference,
    buffer: "",
    in_code_fence: false,
    fence_marker: nil
  ]

  @type break_preference :: :paragraph | :newline | :sentence | :whitespace
  @type t :: %__MODULE__{
          min_chars: non_neg_integer(),
          max_chars: pos_integer(),
          break_preference: break_preference(),
          buffer: String.t(),
          in_code_fence: boolean(),
          fence_marker: String.t() | nil
        }

  @default_min_chars 200
  @default_max_chars 800
  @default_break_preference :paragraph

  # Break patterns in order of preference
  @paragraph_break ~r/\n\n+/
  @newline_break ~r/\n/
  @sentence_break ~r/[.!?]\s+/
  @whitespace_break ~r/\s+/

  # Code fence pattern
  @code_fence_pattern ~r/^(`{3,}|~{3,})(\w*)?$/m

  @doc """
  创建新的分块器

  ## Options

    * `:min_chars` - 最小块大小（默认 #{@default_min_chars}）
    * `:max_chars` - 最大块大小（默认 #{@default_max_chars}）
    * `:break_preference` - 断点偏好，`:paragraph` | `:newline` | `:sentence` | `:whitespace`
      （默认 `:paragraph`）

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    min_chars = Keyword.get(opts, :min_chars, @default_min_chars)
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    break_preference = Keyword.get(opts, :break_preference, @default_break_preference)

    # max_chars 必须大于 min_chars
    max_chars = max(max_chars, min_chars + 1)

    %__MODULE__{
      min_chars: min_chars,
      max_chars: max_chars,
      break_preference: break_preference
    }
  end

  @doc """
  推送文本到分块器，返回可发送的块列表

  返回 `{chunks, updated_chunker}`，其中 chunks 是可以发送的完整块列表。
  """
  @spec push(t(), String.t()) :: {[String.t()], t()}
  def push(%__MODULE__{} = chunker, text) when is_binary(text) do
    # 更新 buffer 和代码块状态
    new_buffer = chunker.buffer <> text
    {in_fence, fence_marker} = track_code_fences(new_buffer)

    chunker = %{chunker | buffer: new_buffer, in_code_fence: in_fence, fence_marker: fence_marker}

    # 尝试提取块
    extract_chunks(chunker, [])
  end

  @doc """
  强制刷新所有剩余内容

  返回 `{chunks, empty_chunker}`
  """
  @spec flush(t()) :: {[String.t()], t()}
  def flush(%__MODULE__{buffer: ""} = chunker) do
    {[], chunker}
  end

  def flush(%__MODULE__{} = chunker) do
    # 刷新时，即使在代码块中也要关闭它
    final_chunk =
      if chunker.in_code_fence && chunker.fence_marker do
        chunker.buffer <> "\n" <> chunker.fence_marker
      else
        chunker.buffer
      end

    final_chunk = String.trim(final_chunk)

    chunks = if final_chunk == "", do: [], else: [final_chunk]

    new_chunker = %{chunker | buffer: "", in_code_fence: false, fence_marker: nil}

    {chunks, new_chunker}
  end

  @doc """
  获取当前 buffer 内容（用于流式预览）
  """
  @spec peek(t()) :: String.t()
  def peek(%__MODULE__{buffer: buffer}), do: buffer

  @doc """
  检查是否有足够内容可以发送
  """
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{buffer: buffer, min_chars: min_chars}) do
    String.length(buffer) >= min_chars
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # 递归提取块
  defp extract_chunks(%__MODULE__{buffer: buffer} = chunker, acc) do
    buffer_len = String.length(buffer)

    cond do
      # Buffer 太小，等待更多内容
      buffer_len < chunker.min_chars ->
        {Enum.reverse(acc), chunker}

      # Buffer 超过 max_chars，必须断开
      buffer_len >= chunker.max_chars ->
        {chunk, remaining, new_fence_state} = force_break(chunker)

        new_chunker = %{
          chunker
          | buffer: remaining,
            in_code_fence: new_fence_state.in_fence,
            fence_marker: new_fence_state.marker
        }

        extract_chunks(new_chunker, [chunk | acc])

      # 在 min_chars 和 max_chars 之间，寻找合适断点
      true ->
        case find_break_point(chunker) do
          nil ->
            # 没有找到合适断点，等待更多内容
            {Enum.reverse(acc), chunker}

          break_pos ->
            {chunk, remaining} = split_at(buffer, break_pos)
            {in_fence, fence_marker} = track_code_fences(remaining)

            new_chunker = %{
              chunker
              | buffer: remaining,
                in_code_fence: in_fence,
                fence_marker: fence_marker
            }

            extract_chunks(new_chunker, [String.trim(chunk) | acc])
        end
    end
  end

  # 寻找断点（在 min_chars 之后，max_chars 之前）
  defp find_break_point(%__MODULE__{} = chunker) do
    %{buffer: buffer, min_chars: min_chars, max_chars: max_chars} = chunker

    # 只在 min_chars 到 max_chars 范围内搜索
    search_range = String.slice(buffer, min_chars, max_chars - min_chars)

    # 按优先级顺序尝试不同的断点类型
    break_patterns = get_break_patterns(chunker.break_preference)

    Enum.find_value(break_patterns, fn pattern ->
      find_last_match(search_range, pattern, min_chars)
    end)
  end

  # 根据偏好获取断点模式列表
  defp get_break_patterns(:paragraph),
    do: [@paragraph_break, @newline_break, @sentence_break, @whitespace_break]

  defp get_break_patterns(:newline), do: [@newline_break, @sentence_break, @whitespace_break]
  defp get_break_patterns(:sentence), do: [@sentence_break, @whitespace_break]
  defp get_break_patterns(:whitespace), do: [@whitespace_break]

  # 在搜索范围内找到最后一个匹配的位置
  defp find_last_match(search_range, pattern, offset) do
    case Regex.scan(pattern, search_range, return: :index) do
      [] ->
        nil

      matches ->
        # 获取最后一个匹配的结束位置
        {start, len} = List.last(matches) |> List.first()
        offset + start + len
    end
  end

  # 强制断开（在 max_chars 处或代码块安全位置）
  defp force_break(%__MODULE__{} = chunker) do
    %{buffer: buffer, max_chars: max_chars, in_code_fence: in_fence, fence_marker: marker} =
      chunker

    if in_fence do
      # 在代码块中，需要关闭并重新打开
      force_break_in_code_fence(buffer, max_chars, marker)
    else
      # 不在代码块中，尝试在空白处断开
      break_pos = find_whitespace_break(buffer, max_chars) || max_chars
      {chunk, remaining} = split_at(buffer, break_pos)
      {String.trim(chunk), remaining, %{in_fence: false, marker: nil}}
    end
  end

  # 在代码块中强制断开
  defp force_break_in_code_fence(buffer, max_chars, fence_marker) do
    # 在代码块内尝试在换行处断开
    search_area = String.slice(buffer, 0, max_chars)

    break_pos =
      case Regex.scan(~r/\n/, search_area, return: :index) do
        [] ->
          max_chars

        matches ->
          {start, _len} = List.last(matches) |> List.first()
          start + 1
      end

    {chunk_content, remaining} = split_at(buffer, break_pos)

    # 关闭代码块
    chunk = chunk_content <> "\n" <> fence_marker

    # 重新打开代码块
    new_remaining = fence_marker <> "\n" <> remaining

    {chunk, new_remaining, %{in_fence: true, marker: fence_marker}}
  end

  # 在 max_chars 之前寻找空白断点
  defp find_whitespace_break(buffer, max_chars) do
    search_area = String.slice(buffer, 0, max_chars)

    case Regex.scan(@whitespace_break, search_area, return: :index) do
      [] ->
        nil

      matches ->
        {start, len} = List.last(matches) |> List.first()
        start + len
    end
  end

  # 分割字符串
  defp split_at(string, pos) do
    {String.slice(string, 0, pos), String.slice(string, pos..-1//1)}
  end

  # 跟踪代码块状态
  defp track_code_fences(text) do
    # 找到所有代码块标记
    fences =
      Regex.scan(@code_fence_pattern, text, return: :index)
      |> Enum.map(fn [{start, len} | _] ->
        String.slice(text, start, len)
      end)

    # 计算当前是否在代码块中
    {in_fence, marker} =
      Enum.reduce(fences, {false, nil}, fn fence, {in_fence, _marker} ->
        fence_chars = String.trim(fence)
        # 提取 fence marker (``` 或 ~~~)
        marker = Regex.run(~r/^(`{3,}|~{3,})/, fence_chars) |> List.first()

        if in_fence do
          # 检查是否是关闭标记（与打开标记相同或更长）
          {false, nil}
        else
          {true, marker}
        end
      end)

    {in_fence, marker}
  end
end
