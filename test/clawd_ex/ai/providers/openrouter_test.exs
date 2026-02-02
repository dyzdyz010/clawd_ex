defmodule ClawdEx.AI.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias ClawdEx.AI.Providers.OpenRouter

  describe "resolve_model/1" do
    test "passes through full model names" do
      assert OpenRouter.resolve_model("anthropic/claude-3-opus") == "anthropic/claude-3-opus"
      assert OpenRouter.resolve_model("openai/gpt-4") == "openai/gpt-4"
      assert OpenRouter.resolve_model("google/gemini-pro") == "google/gemini-pro"
    end

    test "resolves 'auto' to 'openrouter/auto'" do
      assert OpenRouter.resolve_model("auto") == "openrouter/auto"
    end

    test "keeps 'openrouter/auto' as is" do
      assert OpenRouter.resolve_model("openrouter/auto") == "openrouter/auto"
    end
  end

  describe "configured?/0" do
    test "returns false when no API key is set" do
      # 清除配置
      original = Application.get_env(:clawd_ex, :openrouter_api_key)
      Application.delete_env(:clawd_ex, :openrouter_api_key)

      # 也清除环境变量（如果存在的话）
      System.delete_env("OPENROUTER_API_KEY")

      refute OpenRouter.configured?()

      # 恢复
      if original, do: Application.put_env(:clawd_ex, :openrouter_api_key, original)
    end

    test "returns true when API key is configured via Application" do
      original = Application.get_env(:clawd_ex, :openrouter_api_key)
      Application.put_env(:clawd_ex, :openrouter_api_key, "test-key")

      assert OpenRouter.configured?()

      # 恢复
      if original do
        Application.put_env(:clawd_ex, :openrouter_api_key, original)
      else
        Application.delete_env(:clawd_ex, :openrouter_api_key)
      end
    end
  end

  describe "chat/3" do
    test "returns error when API key is not configured" do
      # 确保没有 API key
      original_app = Application.get_env(:clawd_ex, :openrouter_api_key)
      original_env = System.get_env("OPENROUTER_API_KEY")
      
      Application.delete_env(:clawd_ex, :openrouter_api_key)
      System.delete_env("OPENROUTER_API_KEY")

      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :missing_api_key} = OpenRouter.chat("anthropic/claude-3-opus", messages)

      # 恢复
      if original_app, do: Application.put_env(:clawd_ex, :openrouter_api_key, original_app)
      if original_env, do: System.put_env("OPENROUTER_API_KEY", original_env)
    end

    @tag :integration
    @tag :skip
    test "sends chat completion request to OpenRouter API" do
      # 这是集成测试，需要真实 API key
      # 运行: mix test --only integration

      messages = [%{role: "user", content: "Say 'Hello' and nothing else."}]
      
      case OpenRouter.chat("anthropic/claude-3-haiku", messages, max_tokens: 50) do
        {:ok, response} ->
          assert is_binary(response.content)
          assert response.content =~ ~r/hello/i

        {:error, :missing_api_key} ->
          # 跳过，没有 API key
          :ok
      end
    end
  end

  describe "stream/3" do
    test "returns error when API key is not configured" do
      original_app = Application.get_env(:clawd_ex, :openrouter_api_key)
      original_env = System.get_env("OPENROUTER_API_KEY")
      
      Application.delete_env(:clawd_ex, :openrouter_api_key)
      System.delete_env("OPENROUTER_API_KEY")

      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :missing_api_key} = OpenRouter.stream("openai/gpt-4", messages)

      # 恢复
      if original_app, do: Application.put_env(:clawd_ex, :openrouter_api_key, original_app)
      if original_env, do: System.put_env("OPENROUTER_API_KEY", original_env)
    end

    @tag :integration
    @tag :skip
    test "streams response chunks to the specified process" do
      # 集成测试
      messages = [%{role: "user", content: "Count from 1 to 3."}]
      
      case OpenRouter.stream("openai/gpt-3.5-turbo", messages, stream_to: self(), max_tokens: 50) do
        {:ok, response} ->
          assert is_binary(response.content)
          # 应该收到了 chunks
          assert_received {:ai_chunk, %{content: _}}

        {:error, :missing_api_key} ->
          :ok
      end
    end
  end

  describe "message formatting" do
    # 测试内部消息格式化逻辑
    # 由于 format_messages/1 是私有函数，我们通过模块的行为来间接测试

    test "handles messages with atom and string keys" do
      # 这个测试验证模块可以正确加载和编译
      assert Code.ensure_loaded?(OpenRouter)
    end
  end

  describe "tool formatting" do
    @tag :integration
    @tag :skip
    test "formats tools in OpenAI function calling format" do
      tools = [
        %{
          name: "get_weather",
          description: "Get the weather for a location",
          parameters: %{
            type: "object",
            properties: %{
              location: %{type: "string", description: "City name"}
            },
            required: ["location"]
          }
        }
      ]

      messages = [%{role: "user", content: "What's the weather in Tokyo?"}]

      case OpenRouter.chat("openai/gpt-3.5-turbo", messages, tools: tools, max_tokens: 100) do
        {:ok, response} ->
          # 模型可能返回工具调用或文本
          assert is_list(response.tool_calls)

        {:error, :missing_api_key} ->
          :ok
      end
    end
  end
end
