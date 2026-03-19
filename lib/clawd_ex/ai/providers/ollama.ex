defmodule ClawdEx.AI.Providers.Ollama do
  @moduledoc """
  Ollama AI Provider — local LLM inference engine.

  API docs: https://github.com/ollama/ollama/blob/main/docs/api.md

  Features:
  - Local inference, no API key required
  - Streaming via NDJSON (not SSE like other OpenAI-compat providers)
  - Non-streaming uses OpenAI-compatible format

  Config: Application.get_env(:clawd_ex, :ollama)[:host] (default http://localhost:11434)
  """

  @behaviour ClawdEx.AI.Provider

  alias ClawdEx.AI.Providers.OpenAICompat

  require Logger

  @default_host "http://localhost:11434"

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def name, do: :ollama

  @impl true
  def configured? do
    host = get_host()

    case Req.get("#{host}/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def chat(model, messages, opts \\ []) do
    # Ollama supports OpenAI-compatible endpoint
    base_url = "#{get_host()}/v1"
    OpenAICompat.chat(base_url, "ollama", model, messages, opts)
  end

  @impl true
  def stream(model, messages, opts \\ []) do
    # Ollama uses NDJSON streaming, not SSE — use native /api/chat endpoint
    do_stream_ndjson(model, messages, opts)
  end

  @impl true
  def resolve_model(model), do: model

  # ============================================================================
  # NDJSON Streaming (Ollama-specific)
  # ============================================================================

  defp do_stream_ndjson(model, messages, opts) do
    system_prompt = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    stream_to = Keyword.get(opts, :stream_to)

    messages = OpenAICompat.prepend_system_message(messages, system_prompt)

    body = %{
      model: model,
      messages: OpenAICompat.format_messages(messages),
      stream: true
    }

    body =
      if tools != [] do
        Map.put(body, :tools, OpenAICompat.format_tools(tools))
      else
        body
      end

    host = get_host()

    request =
      Req.new(
        url: "#{host}/api/chat",
        method: :post,
        json: body,
        headers: [{"content-type", "application/json"}],
        receive_timeout: 120_000,
        into: :self
      )

    case Req.request(request) do
      {:ok, response} ->
        if response.status >= 200 and response.status < 300 do
          ndjson_receive_loop(response, stream_to)
        else
          {:error, {:api_error, response.status, inspect(response.body)}}
        end

      {:error, reason} ->
        Logger.error("Ollama stream request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ndjson_receive_loop(response, stream_to) do
    acc = %{
      content: "",
      tool_calls: [],
      tokens_in: nil,
      tokens_out: nil,
      stop_reason: nil
    }

    do_ndjson_loop(response, acc, stream_to, "")
  end

  defp do_ndjson_loop(response, acc, stream_to, buffer) do
    async_ref = get_async_ref(response)

    receive do
      {ref, {:data, data}} when ref == async_ref ->
        full_data = buffer <> data
        {lines, new_buffer} = split_ndjson(full_data)

        new_acc =
          Enum.reduce(lines, acc, fn line, current_acc ->
            process_ndjson_line(line, current_acc, stream_to)
          end)

        do_ndjson_loop(response, new_acc, stream_to, new_buffer)

      {ref, :done} when ref == async_ref ->
        {:ok, OpenAICompat.finalize_response(acc)}

      {ref, {:error, reason}} when ref == async_ref ->
        {:error, reason}
    after
      120_000 ->
        {:error, :timeout}
    end
  end

  defp split_ndjson(data) do
    lines = String.split(data, "\n")

    {complete, incomplete} =
      if String.ends_with?(data, "\n") do
        {lines, ""}
      else
        case List.pop_at(lines, -1) do
          {nil, []} -> {[], ""}
          {last, rest} -> {rest, last}
        end
      end

    {Enum.reject(complete, &(&1 == "")), incomplete}
  end

  defp process_ndjson_line(line, acc, stream_to) do
    case Jason.decode(line) do
      {:ok, %{"message" => msg} = event} ->
        content = msg["content"] || ""

        if stream_to && content != "" do
          send(stream_to, {:ai_chunk, %{content: content}})
        end

        # Tool calls from Ollama
        new_tool_calls =
          if msg["tool_calls"] do
            acc.tool_calls ++
              Enum.map(msg["tool_calls"], fn tc ->
                %{
                  "id" => tc["id"] || "ollama_#{:erlang.unique_integer([:positive])}",
                  "name" => get_in(tc, ["function", "name"]),
                  "arguments_raw" => Jason.encode!(get_in(tc, ["function", "arguments"]) || %{})
                }
              end)
          else
            acc.tool_calls
          end

        stop_reason =
          if event["done"] do
            "stop"
          else
            acc.stop_reason
          end

        # Ollama provides eval_count / prompt_eval_count
        tokens_in = event["prompt_eval_count"] || acc.tokens_in
        tokens_out = event["eval_count"] || acc.tokens_out

        %{
          acc
          | content: acc.content <> content,
            tool_calls: new_tool_calls,
            tokens_in: tokens_in,
            tokens_out: tokens_out,
            stop_reason: stop_reason
        }

      {:error, _} ->
        acc
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_host do
    case Application.get_env(:clawd_ex, :ollama) do
      nil -> @default_host
      config -> Keyword.get(config, :host, @default_host)
    end
  end

  defp get_async_ref(%{body: %{ref: ref}}), do: ref
  defp get_async_ref(%{async: %{ref: ref}}), do: ref
  defp get_async_ref(response), do: response.body.ref
end
