defmodule ClawdEx.Memory.ChunkerTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Memory.Chunker
  alias ClawdEx.Memory.Tokenizer

  describe "chunk_text/2" do
    test "chunks text based on token count" do
      # 创建一个足够长的文本
      lines = Enum.map(1..100, fn i -> "This is line number #{i} with some content." end)
      content = Enum.join(lines, "\n")

      chunks = Chunker.chunk_text(content, chunk_size: 100, overlap: 20)

      # 应该产生多个 chunks
      assert length(chunks) > 1

      # 每个 chunk 应该有正确的结构
      for {text, start_line, end_line} <- chunks do
        assert is_binary(text)
        assert is_integer(start_line)
        assert is_integer(end_line)
        assert start_line <= end_line
        # 允许一定超出
        assert Tokenizer.estimate_tokens(text) <= 600
      end
    end

    test "respects semantic boundaries" do
      content = """
      # Section 1
      This is the first section.
      It has multiple lines.

      # Section 2
      This is the second section.
      With more content here.

      # Section 3
      Final section content.
      """

      chunks = Chunker.chunk_text(content, chunk_size: 50, overlap: 10)

      # 检查是否在标题处断开
      chunk_texts = Enum.map(chunks, fn {text, _, _} -> text end)

      # 至少应该有一个 chunk 以标题开头
      assert Enum.any?(chunk_texts, &String.starts_with?(String.trim(&1), "#"))
    end

    test "handles empty content" do
      assert Chunker.chunk_text("") == []
    end

    test "handles single line" do
      chunks = Chunker.chunk_text("Hello world")
      assert length(chunks) == 1
      [{text, start, end_line}] = chunks
      assert text == "Hello world"
      assert start == 1
      assert end_line == 1
    end

    test "handles Chinese content" do
      content = """
      # 中文标题

      这是第一段内容，包含一些中文字符。

      ## 子标题

      这是第二段内容，同样使用中文。
      """

      chunks = Chunker.chunk_text(content, chunk_size: 50, overlap: 10)

      # 应该能正常分块
      assert length(chunks) >= 1
    end
  end
end
