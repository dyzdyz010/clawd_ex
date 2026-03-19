defmodule ClawdEx.AI.Chat do
  @moduledoc """
  AI Chat Completion Service — thin routing layer.

  Routes chat/stream requests to the appropriate provider via ProviderRegistry.
  All provider-specific logic lives in `ClawdEx.AI.Providers.*` modules.
  """

  alias ClawdEx.AI.ProviderRegistry

  @type message :: %{role: String.t(), content: String.t()}
  @type tool :: %{name: String.t(), description: String.t(), parameters: map()}

  @doc """
  Send a chat request and get a response.
  """
  @spec complete(String.t(), [message()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(model, messages, opts \\ []) do
    {provider_atom, model_name} = parse_model(model)

    case ProviderRegistry.get(provider_atom) do
      nil -> {:error, :unsupported_provider}
      provider_mod -> provider_mod.chat(model_name, messages, opts)
    end
  end

  @doc """
  Stream a chat response.
  """
  @spec stream(String.t(), [message()], keyword()) ::
          {:ok, map()} | {:error, term()} | Enumerable.t()
  def stream(model, messages, opts \\ []) do
    {provider_atom, model_name} = parse_model(model)

    case ProviderRegistry.get(provider_atom) do
      nil -> {:error, :unsupported_provider}
      provider_mod -> provider_mod.stream(model_name, messages, opts)
    end
  end

  @doc """
  Parse a model string into {provider_atom, model_name}.

  ## Examples

      iex> ClawdEx.AI.Chat.parse_model("anthropic/claude-3-opus")
      {:anthropic, "claude-3-opus"}

      iex> ClawdEx.AI.Chat.parse_model("openrouter/anthropic/claude-3-opus")
      {:openrouter, "openrouter/anthropic/claude-3-opus"}

      iex> ClawdEx.AI.Chat.parse_model("claude-3-opus")
      {:anthropic, "claude-3-opus"}
  """
  @spec parse_model(String.t()) :: {atom(), String.t()}
  def parse_model(model) do
    case String.split(model, "/", parts: 2) do
      ["anthropic", name] -> {:anthropic, name}
      ["openai", name] -> {:openai, name}
      ["google", name] -> {:google, name}
      ["openrouter", name] -> {:openrouter, "openrouter/" <> name}
      ["ollama", name] -> {:ollama, name}
      ["groq", name] -> {:groq, name}
      ["qwen", name] -> {:qwen, name}
      # Default to Anthropic
      [name] -> {:anthropic, name}
      _ -> {:unknown, model}
    end
  end
end
