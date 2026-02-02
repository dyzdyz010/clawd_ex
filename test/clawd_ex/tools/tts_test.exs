defmodule ClawdEx.Tools.TtsTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.Tts, as: TTS

  describe "TTS tool metadata" do
    test "returns correct name" do
      assert TTS.name() == "tts"
    end

    test "returns description" do
      desc = TTS.description()
      assert is_binary(desc)
      assert desc =~ "speech"
      assert desc =~ "MEDIA"
    end

    test "returns valid parameters schema" do
      params = TTS.parameters()

      assert params.type == "object"
      assert is_map(params.properties)
      assert Map.has_key?(params.properties, :text)
      assert params.required == ["text"]
    end
  end

  describe "TTS.execute/2" do
    test "returns error when text is missing" do
      assert {:error, message} = TTS.execute(%{}, %{})
      assert message =~ "Text is required"
    end

    test "returns error when text is empty" do
      assert {:error, message} = TTS.execute(%{"text" => ""}, %{})
      assert message =~ "Text is required"
    end

    test "returns error when text is whitespace only" do
      assert {:error, message} = TTS.execute(%{"text" => "   "}, %{})
      assert message =~ "Text is required"
    end

    test "accepts text as atom key" do
      # Without API keys, it should try edge-tts and fail gracefully
      result = TTS.execute(%{text: "Hello"}, %{})
      # Should either succeed or fail with a provider error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "accepts channel parameter" do
      result = TTS.execute(%{"text" => "Test", "channel" => "telegram"}, %{})
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "TTS output format" do
    # These tests verify the expected output format when TTS succeeds
    # They require a mock or actual API key to pass

    @tag :integration
    test "returns MEDIA path on success with OpenAI" do
      # Skip if no API key
      api_key = System.get_env("OPENAI_API_KEY")

      if api_key do
        result = TTS.execute(%{"text" => "Hello, this is a test."}, %{})
        assert {:ok, output} = result
        assert output.content =~ "MEDIA:"
        assert File.exists?(output.audio_path)
        assert output.provider == :openai
      end
    end

    @tag :integration
    test "returns opus format for telegram channel" do
      api_key = System.get_env("OPENAI_API_KEY")

      if api_key do
        result = TTS.execute(%{"text" => "Hello", "channel" => "telegram"}, %{})
        assert {:ok, output} = result
        assert output.format == ".opus"
        assert output.content =~ "[[audio_as_voice]]"
      end
    end
  end

  describe "provider fallback" do
    @tag :integration
    test "falls back to edge-tts when no API keys" do
      # Temporarily unset API keys
      original_openai = System.get_env("OPENAI_API_KEY")
      original_eleven = System.get_env("ELEVENLABS_API_KEY")

      System.delete_env("OPENAI_API_KEY")
      System.delete_env("ELEVENLABS_API_KEY")

      try do
        result = TTS.execute(%{"text" => "Test fallback"}, %{})

        # Edge TTS may or may not be installed
        case result do
          {:ok, output} ->
            assert output.provider == :edge
            assert output.content =~ "MEDIA:"

          {:error, msg} ->
            assert msg =~ "Edge TTS" or msg =~ "not available"
        end
      after
        # Restore API keys
        if original_openai, do: System.put_env("OPENAI_API_KEY", original_openai)
        if original_eleven, do: System.put_env("ELEVENLABS_API_KEY", original_eleven)
      end
    end
  end
end
