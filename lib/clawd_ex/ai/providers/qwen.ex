defmodule ClawdEx.AI.Providers.Qwen do
  @moduledoc """
  阿里通义千问 (Qwen) AI Provider — OpenAI-compatible via DashScope.

  API docs: https://help.aliyun.com/zh/model-studio/getting-started/

  Features:
  - OpenAI-compatible chat/completions endpoint
  - Vision models (qwen-vl-max, qwen-vl-plus)
  - Tool calling support

  Config: DASHSCOPE_API_KEY env or Application config
  """

  @behaviour ClawdEx.AI.Provider

  alias ClawdEx.AI.Providers.OpenAICompat

  @base_url "https://dashscope.aliyuncs.com/compatible-mode/v1"

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def name, do: :qwen

  @impl true
  def configured? do
    match?({:ok, _}, get_api_key())
  end

  @impl true
  def chat(model, messages, opts \\ []) do
    case get_api_key() do
      {:ok, api_key} ->
        OpenAICompat.chat(@base_url, api_key, model, messages, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(model, messages, opts \\ []) do
    case get_api_key() do
      {:ok, api_key} ->
        OpenAICompat.stream(@base_url, api_key, model, messages, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def resolve_model(model), do: model

  # ============================================================================
  # Private
  # ============================================================================

  defp get_api_key do
    key =
      case Application.get_env(:clawd_ex, :qwen) do
        nil -> nil
        config -> Keyword.get(config, :api_key)
      end

    key = key || System.get_env("DASHSCOPE_API_KEY")

    case key do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      k -> {:ok, k}
    end
  end
end
