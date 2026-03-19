defmodule ClawdEx.AI.Providers.Google do
  @moduledoc """
  Google Gemini AI Provider — native Gemini API.

  Uses Google's generateContent endpoint (NOT OpenAI-compatible).

  Config: GEMINI_API_KEY env or Application config
  """

  @behaviour ClawdEx.AI.Provider

  require Logger

  alias ClawdEx.AI.OAuth

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def name, do: :google

  @impl true
  def configured? do
    match?({:ok, _}, get_api_key())
  end

  @impl true
  def chat(model, messages, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    case get_api_key() do
      {:ok, api_key} ->
        url =
          "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

        body = %{
          contents: format_messages(messages),
          generationConfig: %{maxOutputTokens: max_tokens}
        }

        case Req.post(url, json: body) do
          {:ok, %{status: 200, body: resp_body}} ->
            {:ok, parse_response(resp_body)}

          {:ok, %{status: status, body: resp_body}} ->
            {:error, {:api_error, status, resp_body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stream(_model, _messages, _opts \\ []) do
    # Placeholder — Gemini streaming uses different format
    {:error, :not_implemented}
  end

  @impl true
  def resolve_model(model), do: model

  # ============================================================================
  # Formatting
  # ============================================================================

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      role =
        case msg[:role] || msg["role"] do
          "user" -> "user"
          "assistant" -> "model"
          _ -> "user"
        end

      %{role: role, parts: [%{text: msg[:content] || msg["content"]}]}
    end)
  end

  # ============================================================================
  # Response Parsing
  # ============================================================================

  defp parse_response(%{"candidates" => [candidate | _]}) do
    content = candidate["content"]["parts"] |> Enum.map(& &1["text"]) |> Enum.join("")

    %{
      content: content,
      tool_calls: [],
      tokens_in: nil,
      tokens_out: nil,
      stop_reason: candidate["finishReason"]
    }
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp get_api_key do
    case OAuth.get_api_key(:gemini) do
      {:ok, key} -> {:ok, key}
      _ -> {:error, :missing_api_key}
    end
  end
end
