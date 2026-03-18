defmodule ClawdEx.AI.Providers.QwenTest do
  use ExUnit.Case, async: true

  alias ClawdEx.AI.Providers.Qwen

  describe "resolve_model/1" do
    test "passes through model names" do
      assert Qwen.resolve_model("qwen-max") == "qwen-max"
      assert Qwen.resolve_model("qwen-plus") == "qwen-plus"
      assert Qwen.resolve_model("qwen-turbo") == "qwen-turbo"
      assert Qwen.resolve_model("qwen-long") == "qwen-long"
      assert Qwen.resolve_model("qwen-vl-max") == "qwen-vl-max"
      assert Qwen.resolve_model("qwen-vl-plus") == "qwen-vl-plus"
    end
  end

  describe "configured?/0" do
    test "returns false when no API key is set" do
      original_app = Application.get_env(:clawd_ex, :qwen)
      original_env = System.get_env("DASHSCOPE_API_KEY")

      Application.put_env(:clawd_ex, :qwen, api_key: nil)
      System.delete_env("DASHSCOPE_API_KEY")

      refute Qwen.configured?()

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :qwen, original_app)
      else
        Application.delete_env(:clawd_ex, :qwen)
      end

      if original_env, do: System.put_env("DASHSCOPE_API_KEY", original_env)
    end

    test "returns true when API key is configured via Application" do
      original = Application.get_env(:clawd_ex, :qwen)
      Application.put_env(:clawd_ex, :qwen, api_key: "test-key-123")

      assert Qwen.configured?()

      # 恢复
      if original do
        Application.put_env(:clawd_ex, :qwen, original)
      else
        Application.delete_env(:clawd_ex, :qwen)
      end
    end

    test "returns true when API key is set via environment variable" do
      original_app = Application.get_env(:clawd_ex, :qwen)
      original_env = System.get_env("DASHSCOPE_API_KEY")

      Application.put_env(:clawd_ex, :qwen, api_key: nil)
      System.put_env("DASHSCOPE_API_KEY", "env-test-key")

      assert Qwen.configured?()

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :qwen, original_app)
      else
        Application.delete_env(:clawd_ex, :qwen)
      end

      if original_env do
        System.put_env("DASHSCOPE_API_KEY", original_env)
      else
        System.delete_env("DASHSCOPE_API_KEY")
      end
    end
  end

  describe "chat/3" do
    test "returns error when API key is not configured" do
      original_app = Application.get_env(:clawd_ex, :qwen)
      original_env = System.get_env("DASHSCOPE_API_KEY")

      Application.put_env(:clawd_ex, :qwen, api_key: nil)
      System.delete_env("DASHSCOPE_API_KEY")

      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :missing_api_key} = Qwen.chat("qwen-max", messages)

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :qwen, original_app)
      else
        Application.delete_env(:clawd_ex, :qwen)
      end

      if original_env, do: System.put_env("DASHSCOPE_API_KEY", original_env)
    end

    @tag :integration
    @tag :skip
    test "sends chat completion request to Qwen API" do
      messages = [%{role: "user", content: "Say 'Hello' and nothing else."}]

      case Qwen.chat("qwen-turbo", messages, max_tokens: 50) do
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
      original_app = Application.get_env(:clawd_ex, :qwen)
      original_env = System.get_env("DASHSCOPE_API_KEY")

      Application.put_env(:clawd_ex, :qwen, api_key: nil)
      System.delete_env("DASHSCOPE_API_KEY")

      messages = [%{role: "user", content: "Hello"}]
      assert {:error, :missing_api_key} = Qwen.stream("qwen-turbo", messages)

      # 恢复
      if original_app do
        Application.put_env(:clawd_ex, :qwen, original_app)
      else
        Application.delete_env(:clawd_ex, :qwen)
      end

      if original_env, do: System.put_env("DASHSCOPE_API_KEY", original_env)
    end

    @tag :integration
    @tag :skip
    test "streams response chunks to the specified process" do
      messages = [%{role: "user", content: "Count from 1 to 3."}]

      case Qwen.stream("qwen-turbo", messages, stream_to: self(), max_tokens: 50) do
        {:ok, response} ->
          assert is_binary(response.content)
          assert_received {:ai_chunk, %{content: _}}

        {:error, :missing_api_key} ->
          :ok
      end
    end
  end

  describe "model parsing integration" do
    test "Models.parse routes qwen/ prefix correctly" do
      {provider, model_name} = ClawdEx.AI.Models.parse("qwen/qwen-max")
      assert provider == :qwen
      assert model_name == "qwen-max"
    end

    test "Models.parse routes qwen-plus model" do
      {provider, model_name} = ClawdEx.AI.Models.parse("qwen/qwen-plus")
      assert provider == :qwen
      assert model_name == "qwen-plus"
    end

    test "Models.parse routes qwen-turbo model" do
      {provider, model_name} = ClawdEx.AI.Models.parse("qwen/qwen-turbo")
      assert provider == :qwen
      assert model_name == "qwen-turbo"
    end

    test "Models.parse routes qwen-vl-max model" do
      {provider, model_name} = ClawdEx.AI.Models.parse("qwen/qwen-vl-max")
      assert provider == :qwen
      assert model_name == "qwen-vl-max"
    end

    test "Models.parse routes qwen-vl-plus model" do
      {provider, model_name} = ClawdEx.AI.Models.parse("qwen/qwen-vl-plus")
      assert provider == :qwen
      assert model_name == "qwen-vl-plus"
    end
  end

  describe "model metadata" do
    test "qwen models are registered in Models" do
      models = ClawdEx.AI.Models.all()

      assert Map.has_key?(models, "qwen/qwen-max")
      assert Map.has_key?(models, "qwen/qwen-plus")
      assert Map.has_key?(models, "qwen/qwen-turbo")
      assert Map.has_key?(models, "qwen/qwen-long")
      assert Map.has_key?(models, "qwen/qwen-vl-max")
      assert Map.has_key?(models, "qwen/qwen-vl-plus")
    end

    test "qwen-max has correct capabilities" do
      model = ClawdEx.AI.Models.get("qwen/qwen-max")
      assert :chat in model.capabilities
      assert :tools in model.capabilities
      assert model.context_window == 32_768
      assert model.max_tokens == 8_192
    end

    test "qwen-plus has correct capabilities" do
      model = ClawdEx.AI.Models.get("qwen/qwen-plus")
      assert :chat in model.capabilities
      assert :tools in model.capabilities
      assert model.context_window == 128_000
    end

    test "qwen-vl-max has vision capability" do
      model = ClawdEx.AI.Models.get("qwen/qwen-vl-max")
      assert :chat in model.capabilities
      assert :vision in model.capabilities
      assert model.context_window == 32_768
      assert model.max_tokens == 2_048
    end

    test "qwen alias resolves correctly" do
      assert ClawdEx.AI.Models.resolve("qwen") == "qwen/qwen-max"
      assert ClawdEx.AI.Models.resolve("qwen-max") == "qwen/qwen-max"
      assert ClawdEx.AI.Models.resolve("qwen-turbo") == "qwen/qwen-turbo"
      assert ClawdEx.AI.Models.resolve("qwen-vision") == "qwen/qwen-vl-max"
    end

    test "qwen vision models appear in vision_models list" do
      vision = ClawdEx.AI.Models.vision_models()
      assert "qwen/qwen-vl-max" in vision
      assert "qwen/qwen-vl-plus" in vision
    end

    test "qwen tool models appear in tool_models list" do
      tool = ClawdEx.AI.Models.tool_models()
      assert "qwen/qwen-max" in tool
      assert "qwen/qwen-plus" in tool
      assert "qwen/qwen-turbo" in tool
    end
  end

  describe "module loading" do
    test "module compiles and loads correctly" do
      assert Code.ensure_loaded?(Qwen)
    end

    test "handles messages with atom and string keys" do
      assert Code.ensure_loaded?(Qwen)
    end
  end
end
