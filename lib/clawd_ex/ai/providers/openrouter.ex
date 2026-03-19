defmodule ClawdEx.AI.Providers.OpenRouter do
  @moduledoc """
  OpenRouter AI Provider — multi-model routing via OpenAI-compatible API.

  API docs: https://openrouter.ai/docs

  Features:
  - OpenAI-compatible chat/completions endpoint
  - Multi-model routing (anthropic/claude-3-opus, openai/gpt-4, etc.)
  - Model aliases (openrouter/auto)
  - Optional HTTP-Referer and X-Title headers

  Config: OPENROUTER_API_KEY env or Application config
  """

  @behaviour ClawdEx.AI.Provider

  alias ClawdEx.AI.Providers.OpenAICompat

  @base_url "https://openrouter.ai/api/v1"

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def name, do: :openrouter

  @impl true
  def configured? do
    match?({:ok, _}, get_api_key())
  end

  @impl true
  def chat(model, messages, opts \\ []) do
    case get_api_key() do
      {:ok, api_key} ->
        model_name = resolve_model(model)
        extra_headers = site_headers(opts)
        opts = Keyword.put(opts, :headers, extra_headers)
        OpenAICompat.chat(@base_url, api_key, model_name, messages, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(model, messages, opts \\ []) do
    case get_api_key() do
      {:ok, api_key} ->
        model_name = resolve_model(model)
        extra_headers = site_headers(opts)
        opts = Keyword.put(opts, :headers, extra_headers)
        OpenAICompat.stream(@base_url, api_key, model_name, messages, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def resolve_model("auto"), do: "openrouter/auto"
  def resolve_model("openrouter/auto"), do: "openrouter/auto"
  def resolve_model(model), do: model

  # ============================================================================
  # Private
  # ============================================================================

  defp get_api_key do
    case Application.get_env(:clawd_ex, :openrouter_api_key) ||
           System.get_env("OPENROUTER_API_KEY") do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  # OpenRouter-specific headers for analytics
  defp site_headers(opts) do
    headers = []

    headers =
      case Keyword.get(opts, :site_url) do
        nil -> headers
        url -> headers ++ [{"http-referer", url}]
      end

    case Keyword.get(opts, :site_name) do
      nil -> headers
      name -> headers ++ [{"x-title", name}]
    end
  end
end
