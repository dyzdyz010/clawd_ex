defmodule ClawdEx.TTS.Config do
  @moduledoc """
  TTS 配置管理

  支持多个 TTS 提供商:
  - OpenAI TTS (tts-1, tts-1-hd)
  - ElevenLabs
  - Edge TTS (免费)
  """

  @type provider :: :openai | :elevenlabs | :edge
  @type voice :: String.t()
  @type output_format :: :mp3 | :opus | :aac | :flac | :pcm

  @default_config %{
    provider: :openai,
    openai: %{
      model: "tts-1",
      voice: "alloy",
      speed: 1.0
    },
    elevenlabs: %{
      voice_id: "pMsXgVXv3BLzUgSXRplE",
      model_id: "eleven_multilingual_v2",
      stability: 0.5,
      similarity_boost: 0.75
    },
    edge: %{
      voice: "en-US-MichelleNeural",
      rate: "+0%",
      pitch: "+0Hz"
    },
    output: %{
      format: :mp3,
      sample_rate: 24000
    },
    max_text_length: 4096,
    timeout_ms: 30_000
  }

  @openai_voices ~w(alloy echo fable onyx nova shimmer)
  @openai_formats ~w(mp3 opus aac flac pcm wav)a

  @doc """
  获取 TTS 配置
  """
  @spec get_config(keyword()) :: map()
  def get_config(opts \\ []) do
    base = @default_config

    # 从环境变量读取 API keys
    openai_config =
      Map.merge(base.openai, %{
        api_key: System.get_env("OPENAI_API_KEY")
      })

    elevenlabs_config =
      Map.merge(base.elevenlabs, %{
        api_key: System.get_env("ELEVENLABS_API_KEY")
      })

    config = %{base | openai: openai_config, elevenlabs: elevenlabs_config}

    # 应用用户选项
    Enum.reduce(opts, config, fn
      {:provider, p}, acc -> %{acc | provider: p}
      {:voice, v}, acc -> put_in(acc, [:openai, :voice], v)
      {:model, m}, acc -> put_in(acc, [:openai, :model], m)
      {:speed, s}, acc -> put_in(acc, [:openai, :speed], s)
      {:format, f}, acc -> put_in(acc, [:output, :format], f)
      _, acc -> acc
    end)
  end

  @doc """
  获取渠道最优输出格式
  """
  @spec format_for_channel(String.t() | nil) :: {output_format(), String.t(), boolean()}
  def format_for_channel(channel) do
    case channel do
      "telegram" -> {:opus, ".opus", true}
      "discord" -> {:opus, ".opus", false}
      "whatsapp" -> {:opus, ".opus", true}
      _ -> {:mp3, ".mp3", false}
    end
  end

  @doc """
  验证配置
  """
  @spec validate_config(map()) :: :ok | {:error, String.t()}
  def validate_config(config) do
    cond do
      config.provider == :openai and is_nil(config.openai.api_key) ->
        {:error, "OpenAI API key required for TTS"}

      config.provider == :elevenlabs and is_nil(config.elevenlabs.api_key) ->
        {:error, "ElevenLabs API key required for TTS"}

      config.provider == :openai and config.openai.voice not in @openai_voices ->
        {:error, "Invalid OpenAI voice. Available: #{Enum.join(@openai_voices, ", ")}"}

      true ->
        :ok
    end
  end

  @doc """
  可用的 OpenAI 声音列表
  """
  @spec available_voices(:openai) :: [String.t()]
  def available_voices(:openai), do: @openai_voices

  @doc """
  可用的输出格式
  """
  @spec available_formats(:openai) :: [atom()]
  def available_formats(:openai), do: @openai_formats
end
