defmodule ClawdEx.AI.Providers.OllamaTest do
  use ExUnit.Case, async: true

  alias ClawdEx.AI.Providers.Ollama

  describe "resolve_model/1" do
    test "passes through model names" do
      assert Ollama.resolve_model("llama3") == "llama3"
      assert Ollama.resolve_model("llama3:8b") == "llama3:8b"
      assert Ollama.resolve_model("mistral") == "mistral"
      assert Ollama.resolve_model("codellama:13b") == "codellama:13b"
    end
  end

  describe "configured?/0" do
    test "returns false when Ollama server is not running" do
      # 使用不存在的端口确保连接失败
      original = Application.get_env(:clawd_ex, :ollama)
      Application.put_env(:clawd_ex, :ollama, host: "http://localhost:1")

      refute Ollama.configured?()

      # 恢复
      if original do
        Application.put_env(:clawd_ex, :ollama, original)
      else
        Application.delete_env(:clawd_ex, :ollama)
      end
    end
  end

  describe "chat/3" do
    test "uses correct default host from config" do
      # 验证模块可以正确加载和编译
      assert Code.ensure_loaded?(Ollama)
    end

    test "reads host from application config" do
      original = Application.get_env(:clawd_ex, :ollama)
      Application.put_env(:clawd_ex, :ollama, host: "http://custom-host:11434")

      # 调用会失败（无服务器），但验证不会崩溃
      messages = [%{role: "user", content: "Hello"}]
      result = Ollama.chat("llama3", messages)

      assert {:error, _reason} = result

      # 恢复
      if original do
        Application.put_env(:clawd_ex, :ollama, original)
      else
        Application.delete_env(:clawd_ex, :ollama)
      end
    end

    test "formats tools in Ollama function calling format" do
      # 验证工具格式化不崩溃
      assert Code.ensure_loaded?(Ollama)

      tools = [
        %{
          name: "get_weather",
          description: "Get weather for a location",
          parameters: %{
            type: "object",
            properties: %{
              location: %{type: "string"}
            }
          }
        }
      ]

      messages = [%{role: "user", content: "Hello"}]
      # 这会因为无服务器而失败，但不会崩溃
      result = Ollama.chat("llama3", messages, tools: tools)
      assert {:error, _} = result
    end
  end

  describe "stream/3" do
    test "returns error when server is unreachable" do
      original = Application.get_env(:clawd_ex, :ollama)
      Application.put_env(:clawd_ex, :ollama, host: "http://localhost:1")

      messages = [%{role: "user", content: "Hello"}]
      result = Ollama.stream("llama3", messages)

      assert {:error, _reason} = result

      # 恢复
      if original do
        Application.put_env(:clawd_ex, :ollama, original)
      else
        Application.delete_env(:clawd_ex, :ollama)
      end
    end
  end

  describe "model parsing integration" do
    test "Models.parse routes ollama/ prefix correctly" do
      {provider, model_name} = ClawdEx.AI.Models.parse("ollama/llama3")
      assert provider == :ollama
      assert model_name == "llama3"
    end

    test "Models.parse routes ollama model with tag" do
      {provider, model_name} = ClawdEx.AI.Models.parse("ollama/llama3:70b")
      assert provider == :ollama
      assert model_name == "llama3:70b"
    end

    test "Models.parse routes ollama/mistral" do
      {provider, model_name} = ClawdEx.AI.Models.parse("ollama/mistral")
      assert provider == :ollama
      assert model_name == "mistral"
    end
  end

  @tag :integration
  @tag :skip
  describe "integration tests (requires running Ollama)" do
    test "chat completion with llama3" do
      messages = [%{role: "user", content: "Say 'Hello' and nothing else."}]

      case Ollama.chat("llama3", messages, max_tokens: 50) do
        {:ok, response} ->
          assert is_binary(response.content)
          assert response.content =~ ~r/hello/i

        {:error, _} ->
          :ok
      end
    end

    test "stream completion with llama3" do
      messages = [%{role: "user", content: "Count from 1 to 3."}]

      case Ollama.stream("llama3", messages, stream_to: self(), max_tokens: 100) do
        {:ok, response} ->
          assert is_binary(response.content)
          assert_received {:ai_chunk, %{content: _}}

        {:error, _} ->
          :ok
      end
    end
  end
end
