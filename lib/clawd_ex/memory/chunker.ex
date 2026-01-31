defmodule ClawdEx.Memory.Chunker do
  @moduledoc """
  智能文本分块器

  实现基于 token 的分块，并优先在语义边界处断开：
  1. 标题（Markdown # ## ### 等）
  2. 段落（双换行）
  3. 句子结尾
  4. 行尾

  默认配置：~400 tokens/块，80 tokens 重叠
  """

  alias ClawdEx.Memory.Tokenizer

  # 目标 tokens
  @default_chunk_size 400
  # 重叠 tokens
  @default_overlap 80
  # @min_chunk_size 100        # 最小块大小（reserved for future use）
  # 最大块大小（允许少量超出以保持边界完整）
  @max_chunk_size 600

  @type chunk :: {String.t(), pos_integer(), pos_integer()}

  @doc """
  将文本分块，返回 {content, start_line, end_line} 列表

  Options:
    - chunk_size: 目标 token 数量 (default: 400)
    - overlap: 重叠 token 数量 (default: 80)
  """
  @spec chunk_text(String.t(), keyword()) :: [chunk()]
  def chunk_text(content, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)
    overlap = Keyword.get(opts, :overlap, @default_overlap)

    lines = String.split(content, "\n")

    if Enum.empty?(lines) do
      []
    else
      lines
      |> Enum.with_index(1)
      |> build_chunks(chunk_size, overlap, [])
      |> Enum.reverse()
    end
  end

  # 构建分块
  defp build_chunks([], _chunk_size, _overlap, acc), do: acc

  defp build_chunks(lines_with_idx, chunk_size, overlap, acc) do
    {chunk_lines, remaining, _tokens_used} =
      collect_chunk(lines_with_idx, chunk_size, [])

    if Enum.empty?(chunk_lines) do
      acc
    else
      chunk = make_chunk(chunk_lines)

      # 计算重叠：回退 overlap tokens
      overlap_lines = calculate_overlap_lines(chunk_lines, overlap)
      next_lines = overlap_lines ++ remaining

      build_chunks(next_lines, chunk_size, overlap, [chunk | acc])
    end
  end

  # 收集一个分块的行
  defp collect_chunk([], _target, collected), do: {Enum.reverse(collected), [], 0}

  defp collect_chunk([{line, idx} | rest] = _lines, target, collected) do
    current_text =
      collected
      |> Enum.reverse()
      |> Enum.map(&elem(&1, 0))
      |> Enum.join("\n")

    new_text = if current_text == "", do: line, else: current_text <> "\n" <> line
    tokens = Tokenizer.estimate_tokens(new_text)

    cond do
      # 还没到目标大小，继续收集
      tokens < target ->
        collect_chunk(rest, target, [{line, idx} | collected])

      # 刚好或稍微超过，检查是否在好的边界
      tokens <= @max_chunk_size and good_boundary?(line, rest) ->
        {Enum.reverse([{line, idx} | collected]), rest, tokens}

      # 超过最大限制，停在当前位置
      tokens > @max_chunk_size and length(collected) > 0 ->
        {Enum.reverse(collected), [{line, idx} | rest], Tokenizer.estimate_tokens(current_text)}

      # 单行就超过限制，还是要包含它
      true ->
        {Enum.reverse([{line, idx} | collected]), rest, tokens}
    end
  end

  # 检测是否在好的语义边界
  defp good_boundary?(current_line, remaining) do
    next_line =
      case remaining do
        [{line, _} | _] -> line
        _ -> ""
      end

    # 当前行是好的结束点
    # 下一行是好的开始点
    # 当前行是空行
    # 下一行是空行
    ends_paragraph?(current_line) or
      starts_new_section?(next_line) or
      String.trim(current_line) == "" or
      String.trim(next_line) == ""
  end

  # 检查是否结束一个段落
  defp ends_paragraph?(line) do
    trimmed = String.trim(line)

    # 空行
    # 以标点结尾的句子
    # 列表项
    # 编号列表
    trimmed == "" or
      String.ends_with?(trimmed, [".", "。", "!", "！", "?", "？", "```"]) or
      Regex.match?(~r/^[-*]\s/, trimmed) or
      Regex.match?(~r/^\d+\.\s/, trimmed)
  end

  # 检查是否开始新的部分
  defp starts_new_section?(line) do
    trimmed = String.trim(line)

    # Markdown 标题
    # 代码块开始
    # 水平线
    # 日期标题格式 (常见于日记)
    String.starts_with?(trimmed, "#") or
      String.starts_with?(trimmed, "```") or
      Regex.match?(~r/^[-*_]{3,}$/, trimmed) or
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}/, trimmed)
  end

  # 计算需要重叠的行
  defp calculate_overlap_lines(chunk_lines, target_overlap) do
    chunk_lines
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn {line, idx}, {acc, tokens} ->
      line_tokens = Tokenizer.estimate_tokens(line)
      new_tokens = tokens + line_tokens

      if new_tokens >= target_overlap do
        {:halt, {[{line, idx} | acc], new_tokens}}
      else
        {:cont, {[{line, idx} | acc], new_tokens}}
      end
    end)
    |> elem(0)
  end

  # 从行列表创建分块
  defp make_chunk(lines_with_idx) do
    texts = Enum.map(lines_with_idx, &elem(&1, 0))
    start_line = lines_with_idx |> List.first() |> elem(1)
    end_line = lines_with_idx |> List.last() |> elem(1)

    {Enum.join(texts, "\n"), start_line, end_line}
  end
end
