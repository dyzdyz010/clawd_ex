defmodule ClawdEx.AI.Providers.OpenAI do
  @moduledoc """
  OpenAI GPT Provider — native OpenAI API.

  Config: OPENAI_API_KEY env or Application config
  """

  @behaviour ClawdEx.AI.Provider

  alias ClawdEx.AI.Providers.OpenAICompat
  alias ClawdEx.AI.OAuth

  @base_url "https://api.openai.com/v1"

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def name, do: :openai

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
    case OAuth.get_api_key(:openai) do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end
end
