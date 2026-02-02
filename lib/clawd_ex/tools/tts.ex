defmodule ClawdEx.Tools.Tts do
  @moduledoc """
  文字转语音 (Text-to-Speech) 工具

  支持多个 TTS 提供商:
  - OpenAI TTS (首选)
  - ElevenLabs
  - Edge TTS (免费后备)

  返回 MEDIA: 路径供 agent 直接引用。
  """
  @behaviour ClawdEx.Tools.Tool

  require Logger

  @default_timeout 30_000
  # 5 minutes cleanup delay
  @temp_cleanup_delay 5 * 60 * 1000

  # OpenAI defaults
  @openai_api_url "https://api.openai.com/v1/audio/speech"
  @default_openai_model "tts-1"
  @default_openai_voice "nova"

  # ElevenLabs defaults
  @elevenlabs_api_url "https://api.elevenlabs.io/v1/text-to-speech"
  @default_elevenlabs_voice_id "pMsXgVXv3BLzUgSXRplE"
  @default_elevenlabs_model_id "eleven_multilingual_v2"

  # Output format by channel
  @telegram_format %{openai: "opus", elevenlabs: "opus_48000_64", extension: ".opus"}
  @default_format %{openai: "mp3", elevenlabs: "mp3_44100_128", extension: ".mp3"}

  @impl true
  def name, do: "tts"

  @impl true
  def description do
    "Convert text to speech and return a MEDIA: path. Use when the user requests audio or TTS is enabled. Copy the MEDIA line exactly."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        text: %{
          type: "string",
          description: "Text to convert to speech."
        },
        channel: %{
          type: "string",
          description: "Optional channel id to pick output format (e.g. telegram)."
        }
      },
      required: ["text"]
    }
  end

  @impl true
  def execute(params, _context) do
    text = params["text"] || params[:text]
    channel = params["channel"] || params[:channel]

    if is_nil(text) or String.trim(text) == "" do
      {:error, "Text is required for TTS conversion"}
    else
      do_tts(String.trim(text), channel)
    end
  end

  # ============================================================================
  # Core TTS Logic
  # ============================================================================

  defp do_tts(text, channel) do
    output_format = resolve_output_format(channel)
    providers = resolve_provider_order()

    result =
      Enum.reduce_while(providers, {:error, "No TTS providers available"}, fn provider, _acc ->
        case try_provider(provider, text, output_format) do
          {:ok, audio_path, provider_name} ->
            {:halt, {:ok, audio_path, provider_name, output_format}}

          {:error, reason} ->
            Logger.debug("TTS provider #{provider} failed: #{reason}")
            {:cont, {:error, reason}}
        end
      end)

    case result do
      {:ok, audio_path, provider, format} ->
        lines =
          if format.extension == ".opus" and channel == "telegram" do
            ["[[audio_as_voice]]", "MEDIA:#{audio_path}"]
          else
            ["MEDIA:#{audio_path}"]
          end

        {:ok,
         %{
           content: Enum.join(lines, "\n"),
           audio_path: audio_path,
           provider: provider,
           format: format.extension
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_provider(:openai, text, output_format) do
    case get_openai_api_key() do
      nil ->
        {:error, "OpenAI API key not configured"}

      api_key ->
        openai_tts(text, api_key, output_format)
    end
  end

  defp try_provider(:elevenlabs, text, output_format) do
    case get_elevenlabs_api_key() do
      nil ->
        {:error, "ElevenLabs API key not configured"}

      api_key ->
        elevenlabs_tts(text, api_key, output_format)
    end
  end

  defp try_provider(:edge, text, output_format) do
    edge_tts(text, output_format)
  end

  # ============================================================================
  # OpenAI TTS
  # ============================================================================

  defp openai_tts(text, api_key, output_format) do
    model = get_config([:openai, :model]) || @default_openai_model
    voice = get_config([:openai, :voice]) || @default_openai_voice
    response_format = output_format.openai

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    body =
      Jason.encode!(%{
        model: model,
        input: text,
        voice: voice,
        response_format: response_format
      })

    Logger.debug("OpenAI TTS request: model=#{model}, voice=#{voice}, format=#{response_format}")

    case Req.post(@openai_api_url,
           body: body,
           headers: headers,
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: 200, body: audio_binary}} when is_binary(audio_binary) ->
        save_audio(audio_binary, output_format.extension, :openai)

      {:ok, %{status: status, body: body}} ->
        error_msg = extract_error_message(body)
        {:error, "OpenAI TTS error (#{status}): #{error_msg}"}

      {:error, reason} ->
        {:error, "OpenAI TTS request failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # ElevenLabs TTS
  # ============================================================================

  defp elevenlabs_tts(text, api_key, output_format) do
    voice_id = get_config([:elevenlabs, :voice_id]) || @default_elevenlabs_voice_id
    model_id = get_config([:elevenlabs, :model_id]) || @default_elevenlabs_model_id

    url = "#{@elevenlabs_api_url}/#{voice_id}"

    headers = [
      {"xi-api-key", api_key},
      {"Content-Type", "application/json"},
      {"Accept", "audio/mpeg"}
    ]

    body =
      Jason.encode!(%{
        text: text,
        model_id: model_id,
        voice_settings: %{
          stability: 0.5,
          similarity_boost: 0.75,
          style: 0.0,
          use_speaker_boost: true
        }
      })

    Logger.debug("ElevenLabs TTS request: voice=#{voice_id}, model=#{model_id}")

    case Req.post(url,
           body: body,
           headers: headers,
           params: [output_format: output_format.elevenlabs],
           receive_timeout: @default_timeout
         ) do
      {:ok, %{status: 200, body: audio_binary}} when is_binary(audio_binary) ->
        save_audio(audio_binary, output_format.extension, :elevenlabs)

      {:ok, %{status: status, body: body}} ->
        error_msg = extract_error_message(body)
        {:error, "ElevenLabs TTS error (#{status}): #{error_msg}"}

      {:error, reason} ->
        {:error, "ElevenLabs TTS request failed: #{inspect(reason)}"}
    end
  end

  # ============================================================================
  # Edge TTS (Free fallback using edge-tts CLI)
  # ============================================================================

  defp edge_tts(text, output_format) do
    # Edge TTS requires the edge-tts Python package
    # Install with: pip install edge-tts

    voice = get_config([:edge, :voice]) || "en-US-AriaNeural"
    temp_dir = create_temp_dir()
    output_path = Path.join(temp_dir, "voice-#{System.unique_integer([:positive])}#{output_format.extension}")

    # Use edge-tts CLI
    cmd_args = [
      "--voice", voice,
      "--text", text,
      "--write-media", output_path
    ]

    Logger.debug("Edge TTS request: voice=#{voice}")

    case System.cmd("edge-tts", cmd_args, stderr_to_stdout: true) do
      {_output, 0} ->
        if File.exists?(output_path) do
          schedule_cleanup(temp_dir)
          {:ok, output_path, :edge}
        else
          {:error, "Edge TTS: output file not created"}
        end

      {output, exit_code} ->
        File.rm_rf(temp_dir)
        {:error, "Edge TTS failed (exit #{exit_code}): #{String.slice(output, 0, 200)}"}
    end
  rescue
    e in ErlangError ->
      {:error, "Edge TTS not available: #{inspect(e)}"}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp resolve_output_format("telegram"), do: @telegram_format
  defp resolve_output_format(_), do: @default_format

  defp resolve_provider_order do
    # Try providers in order: OpenAI (if key exists), ElevenLabs, Edge
    providers = []

    providers =
      if get_openai_api_key() do
        providers ++ [:openai]
      else
        providers
      end

    providers =
      if get_elevenlabs_api_key() do
        providers ++ [:elevenlabs]
      else
        providers
      end

    # Edge TTS as fallback (free, no API key needed)
    providers ++ [:edge]
  end

  defp get_openai_api_key do
    System.get_env("OPENAI_API_KEY") ||
      get_config([:openai, :api_key])
  end

  defp get_elevenlabs_api_key do
    System.get_env("ELEVENLABS_API_KEY") ||
      System.get_env("XI_API_KEY") ||
      get_config([:elevenlabs, :api_key])
  end

  defp get_config(keys) do
    config = Application.get_env(:clawd_ex, :tools, [])
    tts_config = Keyword.get(config, :tts, [])
    get_in(tts_config, keys)
  end

  defp save_audio(audio_binary, extension, provider) do
    temp_dir = create_temp_dir()
    filename = "voice-#{System.unique_integer([:positive])}#{extension}"
    audio_path = Path.join(temp_dir, filename)

    case File.write(audio_path, audio_binary) do
      :ok ->
        schedule_cleanup(temp_dir)
        {:ok, audio_path, provider}

      {:error, reason} ->
        File.rm_rf(temp_dir)
        {:error, "Failed to save audio: #{inspect(reason)}"}
    end
  end

  defp create_temp_dir do
    base_dir = System.tmp_dir!()
    dir_name = "tts-#{System.unique_integer([:positive])}"
    temp_dir = Path.join(base_dir, dir_name)
    File.mkdir_p!(temp_dir)
    temp_dir
  end

  defp schedule_cleanup(temp_dir) do
    # Schedule cleanup in background
    Task.start(fn ->
      Process.sleep(@temp_cleanup_delay)

      try do
        File.rm_rf(temp_dir)
      rescue
        _ -> :ok
      end
    end)
  end

  defp extract_error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> msg
      {:ok, %{"detail" => detail}} when is_binary(detail) -> detail
      _ -> String.slice(body, 0, 200)
    end
  end

  defp extract_error_message(body) when is_map(body) do
    body["error"]["message"] || body["detail"] || inspect(body)
  end

  defp extract_error_message(body), do: inspect(body)
end
