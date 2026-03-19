defmodule ClawdEx.AI.ProviderRegistry do
  @moduledoc """
  Registry of available AI providers.

  Provides dynamic dispatch — Chat.ex routes to providers via this registry
  instead of hardcoded case statements.
  """

  @providers %{
    anthropic: ClawdEx.AI.Providers.Anthropic,
    openai: ClawdEx.AI.Providers.OpenAI,
    google: ClawdEx.AI.Providers.Google,
    openrouter: ClawdEx.AI.Providers.OpenRouter,
    ollama: ClawdEx.AI.Providers.Ollama,
    groq: ClawdEx.AI.Providers.Groq,
    qwen: ClawdEx.AI.Providers.Qwen
  }

  @doc "Get provider module by atom key"
  @spec get(atom()) :: module() | nil
  def get(provider_atom) do
    Map.get(@providers, provider_atom)
  end

  @doc "List all registered providers"
  @spec list() :: %{atom() => module()}
  def list, do: @providers

  @doc "List only configured (ready) providers"
  @spec configured() :: [atom()]
  def configured do
    @providers
    |> Enum.filter(fn {_name, mod} ->
      try do
        mod.configured?()
      rescue
        _ -> false
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end
end
