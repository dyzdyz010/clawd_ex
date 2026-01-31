defmodule ClawdEx.Memory.Tokenizer do
  @moduledoc """
  简易 Token 估算器
  
  使用字符/单词比例估算 token 数量，适用于大多数 LLM tokenizer。
  规则：~4 字符 ≈ 1 token（英文），中文约 1.5-2 字符 ≈ 1 token
  """

  @chars_per_token_en 4.0
  @chars_per_token_cjk 1.8

  @doc """
  估算文本的 token 数量
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text) when is_binary(text) do
    # 分离 CJK 字符和其他字符
    {cjk_count, other_count} = count_char_types(text)
    
    cjk_tokens = cjk_count / @chars_per_token_cjk
    other_tokens = other_count / @chars_per_token_en
    
    round(cjk_tokens + other_tokens)
  end

  def estimate_tokens(_), do: 0

  @doc """
  将文本截断到指定的 token 数量
  """
  @spec truncate_to_tokens(String.t(), non_neg_integer()) :: String.t()
  def truncate_to_tokens(text, max_tokens) do
    current_tokens = estimate_tokens(text)
    
    if current_tokens <= max_tokens do
      text
    else
      # 估算需要保留的字符数
      ratio = max_tokens / max(current_tokens, 1)
      chars_to_keep = round(String.length(text) * ratio * 0.95)  # 保守一点
      String.slice(text, 0, chars_to_keep)
    end
  end

  @doc """
  检查文本是否超过 token 限制
  """
  @spec exceeds_limit?(String.t(), non_neg_integer()) :: boolean()
  def exceeds_limit?(text, limit) do
    estimate_tokens(text) > limit
  end

  # 统计 CJK 字符和其他字符数量
  defp count_char_types(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({0, 0}, fn char, {cjk, other} ->
      if cjk_char?(char) do
        {cjk + 1, other}
      else
        {cjk, other + 1}
      end
    end)
  end

  # 检测是否为 CJK 字符
  defp cjk_char?(char) do
    case char |> String.to_charlist() |> List.first() do
      nil -> false
      codepoint ->
        # CJK 统一汉字范围
        (codepoint >= 0x4E00 and codepoint <= 0x9FFF) or
        # CJK 扩展 A
        (codepoint >= 0x3400 and codepoint <= 0x4DBF) or
        # 日文平假名
        (codepoint >= 0x3040 and codepoint <= 0x309F) or
        # 日文片假名
        (codepoint >= 0x30A0 and codepoint <= 0x30FF) or
        # 韩文音节
        (codepoint >= 0xAC00 and codepoint <= 0xD7AF)
    end
  end
end
