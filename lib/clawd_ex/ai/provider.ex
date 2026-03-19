defmodule ClawdEx.AI.Provider do
  @moduledoc """
  AI Provider behaviour.

  All AI providers (Anthropic, OpenAI, Google, OpenRouter, Ollama, Groq, Qwen)
  must implement this interface.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: keyword()

  @doc "Provider identifier atom (e.g. :anthropic, :openai)"
  @callback name() :: atom()

  @doc "Whether the provider is configured and ready"
  @callback configured?() :: boolean()

  @doc "Non-streaming chat completion"
  @callback chat(model :: String.t(), messages :: [message()], opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc "Streaming chat completion"
  @callback stream(model :: String.t(), messages :: [message()], opts :: opts()) ::
              {:ok, map()} | {:error, term()}

  @doc "Resolve model name (handle aliases, prefixes, etc.)"
  @callback resolve_model(String.t()) :: String.t()

  @optional_callbacks [resolve_model: 1]
end
