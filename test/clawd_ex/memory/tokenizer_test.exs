defmodule ClawdEx.Memory.TokenizerTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Memory.Tokenizer

  describe "estimate_tokens/1" do
    test "estimates tokens for English text" do
      text = "Hello world this is a test"
      tokens = Tokenizer.estimate_tokens(text)

      # ~26 chars / 4 = ~6-7 tokens
      assert tokens >= 5 and tokens <= 10
    end

    test "estimates tokens for Chinese text" do
      text = "你好世界这是一个测试"
      tokens = Tokenizer.estimate_tokens(text)

      # 10 chars / 1.8 = ~5-6 tokens
      assert tokens >= 4 and tokens <= 8
    end

    test "handles mixed content" do
      text = "Hello 你好 World 世界"
      tokens = Tokenizer.estimate_tokens(text)

      assert tokens > 0
    end

    test "returns 0 for empty string" do
      assert Tokenizer.estimate_tokens("") == 0
    end

    test "returns 0 for nil" do
      assert Tokenizer.estimate_tokens(nil) == 0
    end
  end

  describe "truncate_to_tokens/2" do
    test "returns full text if under limit" do
      text = "Short text"
      assert Tokenizer.truncate_to_tokens(text, 100) == text
    end

    test "truncates text that exceeds limit" do
      text = String.duplicate("word ", 100)
      truncated = Tokenizer.truncate_to_tokens(text, 10)

      assert String.length(truncated) < String.length(text)
      # 允许一点误差
      assert Tokenizer.estimate_tokens(truncated) <= 15
    end
  end

  describe "exceeds_limit?/2" do
    test "returns false for text under limit" do
      refute Tokenizer.exceeds_limit?("hello", 10)
    end

    test "returns true for text over limit" do
      text = String.duplicate("word ", 100)
      assert Tokenizer.exceeds_limit?(text, 10)
    end
  end
end
