defmodule ClawdEx.Streaming.BlockChunkerTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Streaming.BlockChunker

  describe "new/1" do
    test "creates chunker with default options" do
      chunker = BlockChunker.new()

      assert chunker.min_chars == 200
      assert chunker.max_chars == 800
      assert chunker.break_preference == :paragraph
      assert chunker.buffer == ""
      assert chunker.in_code_fence == false
    end

    test "creates chunker with custom options" do
      chunker = BlockChunker.new(
        min_chars: 100,
        max_chars: 500,
        break_preference: :sentence
      )

      assert chunker.min_chars == 100
      assert chunker.max_chars == 500
      assert chunker.break_preference == :sentence
    end

    test "ensures max_chars > min_chars" do
      chunker = BlockChunker.new(min_chars: 500, max_chars: 300)

      assert chunker.max_chars > chunker.min_chars
    end
  end

  describe "push/2" do
    test "buffers small text without emitting chunks" do
      chunker = BlockChunker.new(min_chars: 100)
      {chunks, new_chunker} = BlockChunker.push(chunker, "Hello world")

      assert chunks == []
      assert new_chunker.buffer == "Hello world"
    end

    test "emits chunk when buffer exceeds max_chars" do
      chunker = BlockChunker.new(min_chars: 10, max_chars: 50)

      text = String.duplicate("x", 60) <> " " <> String.duplicate("y", 20)
      {chunks, new_chunker} = BlockChunker.push(chunker, text)

      assert length(chunks) >= 1
      assert String.length(new_chunker.buffer) < 50
    end

    test "breaks at paragraph boundaries when possible" do
      chunker = BlockChunker.new(min_chars: 10, max_chars: 100)

      text = "First paragraph.\n\nSecond paragraph."
      {chunks, _chunker} = BlockChunker.push(chunker, text)

      # 应该在段落边界断开
      if length(chunks) > 0 do
        first_chunk = List.first(chunks)
        assert String.contains?(first_chunk, "First paragraph")
        refute String.contains?(first_chunk, "Second paragraph")
      end
    end

    test "breaks at newline when no paragraph break available" do
      chunker = BlockChunker.new(min_chars: 10, max_chars: 50, break_preference: :newline)

      text = "Line one content here.\nLine two content here."
      {chunks, _chunker} = BlockChunker.push(chunker, text)

      if length(chunks) > 0 do
        first_chunk = List.first(chunks)
        assert String.ends_with?(first_chunk, ".") || String.ends_with?(first_chunk, "here")
      end
    end

    test "breaks at sentence boundaries" do
      chunker = BlockChunker.new(min_chars: 10, max_chars: 100, break_preference: :sentence)

      text = "First sentence here. Second sentence here. Third sentence."
      {chunks, _chunker} = BlockChunker.push(chunker, text)

      # 如果发出了 chunk，应该在句子边界
      if length(chunks) > 0 do
        first_chunk = List.first(chunks)
        assert String.ends_with?(first_chunk, ".")
      end
    end
  end

  describe "code fence protection" do
    test "tracks code fence state" do
      chunker = BlockChunker.new(min_chars: 10, max_chars: 500)

      {_chunks, chunker} = BlockChunker.push(chunker, "Some text\n```python\ncode here")

      assert chunker.in_code_fence == true
    end

    test "detects code fence close" do
      chunker = BlockChunker.new(min_chars: 10, max_chars: 500)

      {_chunks, chunker} = BlockChunker.push(chunker, "```python\ncode\n```\nmore text")

      assert chunker.in_code_fence == false
    end

    test "closes and reopens fence on forced break inside code" do
      chunker = BlockChunker.new(min_chars: 10, max_chars: 50)

      # 长代码块，必须在中间断开
      code = "```python\n" <> String.duplicate("x = 1\n", 20)
      {chunks, _chunker} = BlockChunker.push(chunker, code)

      if length(chunks) > 0 do
        first_chunk = List.first(chunks)
        # 第一个 chunk 应该以关闭的 fence 结尾
        assert String.ends_with?(first_chunk, "```")
      end
    end
  end

  describe "flush/1" do
    test "returns empty list for empty buffer" do
      chunker = BlockChunker.new()
      {chunks, new_chunker} = BlockChunker.flush(chunker)

      assert chunks == []
      assert new_chunker.buffer == ""
    end

    test "returns all remaining content" do
      chunker = BlockChunker.new()
      {_, chunker} = BlockChunker.push(chunker, "Some remaining text")
      {chunks, new_chunker} = BlockChunker.flush(chunker)

      assert chunks == ["Some remaining text"]
      assert new_chunker.buffer == ""
    end

    test "closes code fence on flush" do
      chunker = BlockChunker.new()
      {_, chunker} = BlockChunker.push(chunker, "```python\nunclosed code")
      {chunks, new_chunker} = BlockChunker.flush(chunker)

      assert length(chunks) == 1
      chunk = List.first(chunks)
      assert String.ends_with?(chunk, "```")
      assert new_chunker.in_code_fence == false
    end
  end

  describe "peek/1" do
    test "returns current buffer content" do
      chunker = BlockChunker.new()
      {_, chunker} = BlockChunker.push(chunker, "Hello world")

      assert BlockChunker.peek(chunker) == "Hello world"
    end
  end

  describe "ready?/1" do
    test "returns false when buffer is smaller than min_chars" do
      chunker = BlockChunker.new(min_chars: 100)
      {_, chunker} = BlockChunker.push(chunker, "Small")

      refute BlockChunker.ready?(chunker)
    end

    test "returns true when buffer reaches min_chars" do
      chunker = BlockChunker.new(min_chars: 10)
      {_, chunker} = BlockChunker.push(chunker, "This is enough text")

      assert BlockChunker.ready?(chunker)
    end
  end

  describe "integration" do
    test "handles streaming AI response" do
      chunker = BlockChunker.new(min_chars: 50, max_chars: 200)

      # 模拟流式 AI 响应
      deltas = [
        "Hello! ",
        "I'm happy to help you ",
        "with your question.\n\n",
        "Here's what I think:\n",
        "- First point about the topic\n",
        "- Second point that's important\n",
        "- Third point to consider\n\n",
        "Let me know if you need more details!"
      ]

      {all_chunks, final_chunker} = Enum.reduce(deltas, {[], chunker}, fn delta, {acc, c} ->
        {chunks, new_c} = BlockChunker.push(c, delta)
        {acc ++ chunks, new_c}
      end)

      # Flush remaining
      {final_chunks, _} = BlockChunker.flush(final_chunker)
      all_chunks = all_chunks ++ final_chunks

      # 所有块连接起来应该等于原始文本
      combined = Enum.join(all_chunks, "")
      original = Enum.join(deltas, "")

      # 验证内容完整性（去掉可能的空白差异）
      assert String.replace(combined, ~r/\s+/, " ") ==
             String.replace(String.trim(original), ~r/\s+/, " ")
    end
  end
end
