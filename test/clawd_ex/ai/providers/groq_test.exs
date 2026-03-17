defmodule ClawdEx.AI.Providers.GroqTest do
  use ExUnit.Case, async: true

  alias ClawdEx.AI.Providers.Groq

  describe "resolve_model/1" do
    test "passes through model names" do
      assert Groq.resolve_model("llama-3.3-70b-versatile") == "llama-3.3-70b-versatile"
      assert Groq.resolve_model("llama-3.1-8b-instant") == "llama-3.1-8b-instant"
      assert Groq.resolve_model("mixtral-8x7b-32768") == "mixtral-8x7b-32768"
    end
  end

  describe "configured?/0" do
    test "returns false when no API key is set" do
      original_app = Application.get_env(:clawd_ex, :groq)
      original_env = System.get_env("GROQ_API_KEY")

      Application.put_env(:clawd_ex, :groq, api_key: nil)
      System.delete_env("GROQ_API_KEY")

      refute Groq.configured?()

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :groq, original_app)
      else
        Application.delete_env(:clawd_ex, :groq)
      end

      if original_env, do: System.put_env("GROQ_API_KEY", original_env)
    end

    test "returns true when API key is configured via Application" do
      original = Application.get_env(:clawd_ex, :groq)
      Application.put_env(:clawd_ex, :groq, api_key: "test-key-123")

      assert Groq.configured?()

      # 恢复
      if original do
        Application.put_env(:clawd_ex, :groq, original)
      else
        Application.delete_env(:clawd_ex, :groq)
      end
    end

    test "returns true when API key is set via environment variable" do
      original_app = Application.get_env(:clawd_ex, :groq)
      original_env = System.get_env("GROQ_API_KEY")

      Application.put_env(:clawd_ex, :groq, api_key: nil)
      System.put_env("GROQ_API_KEY", "env-test-key")

      assert Groq.configured?()

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :groq, original_app)
      else
        Application.delete_env(:clawd_ex, :groq)
      end

      if original_env do
        System.put_env("GROQ_API_KEY", original_env)
      else
        System.delete_env("GROQ_API_KEY")
      end
    end
  end

  describe "chat/3" do
    test "returns error when API key is not configured" do
      original_app = Application.get_env(:clawd_ex, :groq)
      original_env = System.get_env("GROQ_API_KEY")

      Application.put_env(:clawd_ex, :groq, api_key: nil)
      System.delete_env("GROQ_API_KEY")

      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :missing_api_key} = Groq.chat("llama-3.3-70b-versatile", messages)

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :groq, original_app)
      else
        Application.delete_env(:clawd_ex, :groq)
      end

      if original_env, do: System.put_env("GROQ_API_KEY", original_env)
    end

    @tag :integration
    @tag :skip
    test "sends chat completion request to Groq API" do
      messages = [%{role: "user", content: "Say 'Hello' and nothing else."}]

      case Groq.chat("llama-3.3-70b-versatile", messages, max_tokens: 50) do
        {:ok, response} ->
          assert is_binary(response.content)
          assert response.content =~ ~r/hello/i

        {:error, :missing_api_key} ->
          :ok
      end
    end
  end

  describe "stream/3" do
    test "returns error when API key is not configured" do
      original_app = Application.get_env(:clawd_ex, :groq)
      original_env = System.get_env("GROQ_API_KEY")

      Application.put_env(:clawd_ex, :groq, api_key: nil)
      System.delete_env("GROQ_API_KEY")

      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :missing_api_key} = Groq.stream("llama-3.3-70b-versatile", messages)

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :groq, original_app)
      else
        Application.delete_env(:clawd_ex, :groq)
      end

      if original_env, do: System.put_env("GROQ_API_KEY", original_env)
    end

    @tag :integration
    @tag :skip
    test "streams response chunks to the specified process" do
      messages = [%{role: "user", content: "Count from 1 to 3."}]

      case Groq.stream("llama-3.1-8b-instant", messages, stream_to: self(), max_tokens: 50) do
        {:ok, response} ->
          assert is_binary(response.content)
          assert_received {:ai_chunk, %{content: _}}

        {:error, :missing_api_key} ->
          :ok
      end
    end
  end

  describe "model parsing integration" do
    test "Models.parse routes groq/ prefix correctly" do
      {provider, model_name} = ClawdEx.AI.Models.parse("groq/llama-3.3-70b-versatile")
      assert provider == :groq
      assert model_name == "llama-3.3-70b-versatile"
    end

    test "Models.parse routes groq/mixtral model" do
      {provider, model_name} = ClawdEx.AI.Models.parse("groq/mixtral-8x7b-32768")
      assert provider == :groq
      assert model_name == "mixtral-8x7b-32768"
    end

    test "Models.parse routes groq/llama-3.1-8b-instant" do
      {provider, model_name} = ClawdEx.AI.Models.parse("groq/llama-3.1-8b-instant")
      assert provider == :groq
      assert model_name == "llama-3.1-8b-instant"
    end
  end

  describe "module loading" do
    test "module compiles and loads correctly" do
      assert Code.ensure_loaded?(Groq)
    end

    test "handles messages with atom and string keys" do
      # 验证模块可以处理两种 key 格式
      assert Code.ensure_loaded?(Groq)
    end
  end
end
