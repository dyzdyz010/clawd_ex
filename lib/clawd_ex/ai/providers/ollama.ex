defmodule ClawdEx.AI.Providers.Ollama do
  @moduledoc """
  Ollama AI 提供商

  Ollama 是本地运行的 LLM 推理引擎，支持多种开源模型。

  API 文档: https://github.com/ollama/ollama/blob/main/docs/api.md

  特性:
  - 本地推理，无需 API key
  - 支持流式和非流式响应
  - NDJSON 流式格式（每行一个 JSON 对象）
  - 模型格式: ollama/llama3 → 提取 llama3

  配置:
  - Application.get_env(:clawd_ex, :ollama)[:host] (默认 http://localhost:11434)
  """

  require Logger

  @default_host "http://localhost:11434"

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: [
          system: String.t() | nil,
          tools: [map()],
          max_tokens: integer(),
          stream_to: pid() | nil
        ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  非流式聊天补全
  """
  @spec chat(String.t(), [message()], opts()) :: {:ok, map()} | {:error, term()}
  def chat(model, messages, opts \\ []) do
    do_chat(model, messages, opts)
  end

  @doc """
  流式聊天补全

  发送流式块到 stream_to 进程，格式: {:ai_chunk, %{content: text}}
  """
  @spec stream(String.t(), [message()], opts()) :: {:ok, map()} | {:error, term()}
  def stream(model, messages, opts \\ []) do
    do_stream(model, messages, opts)
  end

  @doc """
  检查 Ollama 是否可用（本地服务是否运行）
  """
  @spec configured?() :: boolean()
  def configured? do
    host = get_host()

    case Req.get("#{host}/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  解析模型名称

  从 ollama/ 前缀格式中提取模型名:
  - "llama3" -> "llama3"
  - "llama3:8b" -> "llama3:8b"
  """
  @spec resolve_model(String.t()) :: String.t()
  def resolve_model(model), do: model

  # ============================================================================
  # Non-Streaming Implementation
  # ============================================================================

  defp do_chat(model, messages, opts) do
    host = get_host()
    system_prompt = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])

    messages = prepend_system_message(messages, system_prompt)

    body = %{
      model: model,
      messages: format_messages(messages),
      stream: false
    }

    body =
      if tools != [] do
        Map.put(body, :tools, format_tools(tools))
      else
        body
      end

    # Ollama supports num_predict for max tokens
    body =
      case Keyword.get(opts, :max_tokens) do
        nil -> body
        max -> Map.put(body, :options, %{num_predict: max})
      end

    case Req.post("#{host}/api/chat",
           json: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 300_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Ollama API error: status=#{status}, body=#{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("Ollama request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Streaming Implementation
  # ============================================================================

  defp do_stream(model, messages, opts) do
    host = get_host()
    system_prompt = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    stream_to = Keyword.get(opts, :stream_to)

    messages = prepend_system_message(messages, system_prompt)

    body = %{
      model: model,
      messages: format_messages(messages),
      stream: true
    }

    body =
      if tools != [] do
        Map.put(body, :tools, format_tools(tools))
      else
        body
      end

    body =
      case Keyword.get(opts, :max_tokens) do
        nil -> body
        max -> Map.put(body, :options, %{num_predict: max})
      end

    request =
      Req.new(
        url: "#{host}/api/chat",
        method: :post,
        json: body,
        headers: [{"content-type", "application/json"}],
        receive_timeout: 300_000,
        into: :self
      )

    case Req.request(request) do
      {:ok, response} ->
        if response.status >= 200 and response.status < 300 do
          process_stream(response, stream_to)
        else
          Logger.error("Ollama stream error: HTTP #{response.status}")
          {:error, {:api_error, response.status, inspect(response.body)}}
        end

      {:error, reason} ->
        Logger.error("Ollama stream request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_stream(response, stream_to) do
    acc = %{
      content: "",
      tool_calls: [],
      tokens_in: nil,
      tokens_out: nil,
      stop_reason: nil
    }

    receive_loop(response, acc, stream_to, "")
  end

  defp receive_loop(response, acc, stream_to, buffer) do
    async_ref = get_async_ref(response)

    receive do
      {ref, {:data, data}} when ref == async_ref ->
        full_data = buffer <> data

        # Ollama uses NDJSON: each line is a complete JSON object
        {json_objects, new_buffer} = parse_ndjson(full_data)

        new_acc =
          Enum.reduce(json_objects, acc, fn json_str, current_acc ->
            process_ndjson_event(json_str, current_acc, stream_to)
          end)

        receive_loop(response, new_acc, stream_to, new_buffer)

      {ref, :done} when ref == async_ref ->
        {:ok, acc}

      {ref, {:error, reason}} when ref == async_ref ->
        {:error, reason}
    after
      300_000 ->
        {:error, :timeout}
    end
  end

  defp parse_ndjson(data) do
    lines = String.split(data, "\n")

    {complete_lines, incomplete} =
      if String.ends_with?(data, "\n") do
        {lines, ""}
      else
        case List.pop_at(lines, -1) do
          {nil, []} -> {[], ""}
          {last, rest} -> {rest, last}
        end
      end

    objects =
      complete_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {objects, incomplete}
  end

  defp process_ndjson_event(json_str, acc, stream_to) do
    case Jason.decode(json_str) do
      {:ok, event} ->
        process_event(event, acc, stream_to)

      {:error, _} ->
        acc
    end
  end

  # Process streaming event from Ollama
  # Ollama streaming format: {"model":"llama3","message":{"role":"assistant","content":"Hi"},"done":false}
  defp process_event(%{"message" => %{"content" => content}, "done" => false}, acc, stream_to) do
    if stream_to && content != "" do
      send(stream_to, {:ai_chunk, %{content: content}})
    end

    %{acc | content: acc.content <> content}
  end

  # Final event with done: true includes token counts
  defp process_event(
         %{"done" => true} = event,
         acc,
         _stream_to
       ) do
    %{
      acc
      | tokens_in: event["prompt_eval_count"],
        tokens_out: event["eval_count"],
        stop_reason: "stop"
    }
  end

  # Tool call response from Ollama
  defp process_event(
         %{"message" => %{"tool_calls" => tool_calls}, "done" => false},
         acc,
         _stream_to
       )
       when is_list(tool_calls) and tool_calls != [] do
    formatted =
      Enum.map(tool_calls, fn tc ->
        func = tc["function"] || %{}

        %{
          "id" => "ollama_#{:erlang.unique_integer([:positive])}",
          "name" => func["name"],
          "input" => func["arguments"] || %{}
        }
      end)

    %{acc | tool_calls: acc.tool_calls ++ formatted}
  end

  defp process_event(_event, acc, _stream_to), do: acc

  # Get async ref - handles different Req versions
  defp get_async_ref(%{body: %{ref: ref}}), do: ref
  defp get_async_ref(%{async: %{ref: ref}}), do: ref
  defp get_async_ref(response), do: response.body.ref

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_host do
    case Application.get_env(:clawd_ex, :ollama) do
      nil -> @default_host
      config -> Keyword.get(config, :host, @default_host)
    end
  end

  defp prepend_system_message(messages, nil), do: messages

  defp prepend_system_message(messages, system_prompt) do
    [%{role: "system", content: system_prompt} | messages]
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]
      tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]

      cond do
        role == "tool" && tool_call_id ->
          %{role: "tool", content: content}

        true ->
          %{role: role, content: content}
      end
    end)
  end

  defp format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool[:name] || tool["name"],
          description: tool[:description] || tool["description"],
          parameters: tool[:input_schema] || tool[:parameters] || tool["parameters"] || %{}
        }
      }
    end)
  end

  defp parse_response(%{"message" => message} = resp) do
    tool_calls =
      case message["tool_calls"] do
        nil ->
          []

        calls when is_list(calls) ->
          Enum.map(calls, fn tc ->
            func = tc["function"] || %{}

            %{
              "id" => "ollama_#{:erlang.unique_integer([:positive])}",
              "name" => func["name"],
              "input" => func["arguments"] || %{}
            }
          end)
      end

    %{
      content: message["content"],
      tool_calls: tool_calls,
      tokens_in: resp["prompt_eval_count"],
      tokens_out: resp["eval_count"],
      stop_reason: if(resp["done"], do: "stop", else: nil)
    }
  end

  defp parse_response(resp) do
    Logger.warning("Unexpected Ollama response format: #{inspect(resp)}")
    %{content: nil, tool_calls: [], tokens_in: nil, tokens_out: nil, stop_reason: nil}
  end
end
