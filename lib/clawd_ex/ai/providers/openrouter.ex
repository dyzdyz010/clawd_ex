defmodule ClawdEx.AI.Providers.OpenRouter do
  @moduledoc """
  OpenRouter AI 提供商
  
  OpenRouter 使用 OpenAI 兼容 API，支持多模型路由。
  
  API 文档: https://openrouter.ai/docs
  
  特性:
  - OpenAI 兼容的 chat/completions 端点
  - 支持流式和非流式响应
  - 多模型路由 (如 anthropic/claude-3-opus, openai/gpt-4 等)
  - 支持模型别名 (如 openrouter/auto)
  
  配置:
  - OPENROUTER_API_KEY 环境变量
  - 或 Application.get_env(:clawd_ex, :openrouter_api_key)
  """

  require Logger

  @base_url "https://openrouter.ai/api/v1"

  @type message :: %{role: String.t(), content: String.t()}
  @type opts :: [
          system: String.t() | nil,
          tools: [map()],
          max_tokens: integer(),
          stream_to: pid() | nil,
          site_url: String.t() | nil,
          site_name: String.t() | nil
        ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  非流式聊天补全
  
  ## 参数
  - model: 模型名称 (如 "anthropic/claude-3-opus" 或 "openrouter/auto")
  - messages: 消息列表
  - opts: 可选参数
    - :system - 系统提示
    - :tools - 工具列表
    - :max_tokens - 最大 token 数
    - :site_url - HTTP-Referer header
    - :site_name - X-Title header
  """
  @spec chat(String.t(), [message()], opts()) :: {:ok, map()} | {:error, term()}
  def chat(model, messages, opts \\ []) do
    case get_api_key() do
      {:ok, api_key} ->
        do_chat(model, messages, api_key, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  流式聊天补全
  
  发送流式块到 stream_to 进程，格式: {:ai_chunk, %{content: text}}
  """
  @spec stream(String.t(), [message()], opts()) :: {:ok, map()} | {:error, term()}
  def stream(model, messages, opts \\ []) do
    case get_api_key() do
      {:ok, api_key} ->
        do_stream(model, messages, api_key, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  检查 API key 是否已配置
  """
  @spec configured?() :: boolean()
  def configured? do
    case get_api_key() do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ============================================================================
  # Non-Streaming Implementation
  # ============================================================================

  defp do_chat(model, messages, api_key, opts) do
    system_prompt = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    # 解析模型名称
    model_name = resolve_model(model)

    # 构建消息，添加系统提示
    messages = prepend_system_message(messages, system_prompt)

    body = %{
      model: model_name,
      max_tokens: max_tokens,
      messages: format_messages(messages)
    }

    body =
      if tools != [] do
        Map.put(body, :tools, format_tools(tools))
      else
        body
      end

    headers = build_headers(api_key, opts)

    case Req.post("#{@base_url}/chat/completions",
           json: body,
           headers: headers,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_response(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error("OpenRouter API error: status=#{status}, body=#{inspect(body)}")
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        Logger.error("OpenRouter request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ============================================================================
  # Streaming Implementation
  # ============================================================================

  defp do_stream(model, messages, api_key, opts) do
    system_prompt = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    stream_to = Keyword.get(opts, :stream_to)

    model_name = resolve_model(model)
    messages = prepend_system_message(messages, system_prompt)

    body = %{
      model: model_name,
      max_tokens: max_tokens,
      messages: format_messages(messages),
      stream: true
    }

    body =
      if tools != [] do
        Map.put(body, :tools, format_tools(tools))
      else
        body
      end

    headers =
      build_headers(api_key, opts)
      |> Keyword.put(:accept, "text/event-stream")

    # 使用 Req 的 :self 模式处理流
    request =
      Req.new(
        url: "#{@base_url}/chat/completions",
        method: :post,
        json: body,
        headers: headers,
        receive_timeout: 120_000,
        into: :self
      )

    case Req.request(request) do
      {:ok, response} ->
        process_stream(response, stream_to)

      {:error, reason} ->
        Logger.error("OpenRouter stream request failed: #{inspect(reason)}")
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
        {events, new_buffer} = parse_sse_events(full_data)

        new_acc =
          Enum.reduce(events, acc, fn event, current_acc ->
            process_sse_event(event, current_acc, stream_to)
          end)

        receive_loop(response, new_acc, stream_to, new_buffer)

      {ref, :done} when ref == async_ref ->
        {:ok, finalize_response(acc)}

      {ref, {:error, reason}} when ref == async_ref ->
        {:error, reason}
    after
      120_000 ->
        {:error, :timeout}
    end
  end

  # Get async ref - handles different Req versions
  defp get_async_ref(%{body: %{ref: ref}}), do: ref
  defp get_async_ref(%{async: %{ref: ref}}), do: ref
  defp get_async_ref(response), do: response.body.ref

  defp parse_sse_events(data) do
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

    events =
      complete_lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn line ->
        line
        |> String.trim_leading("data: ")
        |> String.trim()
      end)
      |> Enum.reject(&(&1 == "[DONE]" || &1 == ""))

    {events, incomplete}
  end

  defp process_sse_event(event_data, acc, stream_to) do
    case Jason.decode(event_data) do
      {:ok, event} ->
        process_event(event, acc, stream_to)

      {:error, _} ->
        acc
    end
  end

  # OpenAI-compatible event processing
  defp process_event(%{"choices" => [%{"delta" => delta} | _]} = event, acc, stream_to) do
    content = delta["content"] || ""

    if stream_to && content != "" do
      send(stream_to, {:ai_chunk, %{content: content}})
    end

    # 处理工具调用 - OpenAI 按 index 增量发送
    new_tool_calls =
      if delta["tool_calls"] do
        Enum.reduce(delta["tool_calls"], acc.tool_calls, fn tc, current_calls ->
          index = tc["index"] || 0
          existing = Enum.at(current_calls, index)

          updated_call =
            if existing do
              existing_args = existing["arguments_raw"] || ""
              new_args = get_in(tc, ["function", "arguments"]) || ""

              existing
              |> Map.put("arguments_raw", existing_args <> new_args)
            else
              %{
                "id" => tc["id"],
                "name" => get_in(tc, ["function", "name"]),
                "arguments_raw" => get_in(tc, ["function", "arguments"]) || ""
              }
            end

          if existing do
            List.replace_at(current_calls, index, updated_call)
          else
            current_calls ++ [updated_call]
          end
        end)
      else
        acc.tool_calls
      end

    # 处理 finish_reason
    finish_reason =
      case get_in(event, ["choices", Access.at(0), "finish_reason"]) do
        nil -> acc.stop_reason
        reason -> reason
      end

    # 处理 usage
    usage = event["usage"] || %{}

    %{
      acc
      | content: acc.content <> content,
        tool_calls: new_tool_calls,
        tokens_in: usage["prompt_tokens"] || acc.tokens_in,
        tokens_out: usage["completion_tokens"] || acc.tokens_out,
        stop_reason: finish_reason
    }
  end

  defp process_event(_event, acc, _stream_to), do: acc

  defp finalize_response(acc) do
    finalized_tool_calls =
      Enum.map(acc.tool_calls, fn tc ->
        args_raw = tc["arguments_raw"] || ""

        input =
          case Jason.decode(args_raw) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

        %{
          "id" => tc["id"],
          "name" => tc["name"],
          "input" => input
        }
      end)

    %{acc | tool_calls: finalized_tool_calls}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp get_api_key do
    case Application.get_env(:clawd_ex, :openrouter_api_key) ||
           System.get_env("OPENROUTER_API_KEY") do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      key -> {:ok, key}
    end
  end

  @doc """
  解析模型名称
  
  支持的格式:
  - "anthropic/claude-3-opus" -> "anthropic/claude-3-opus"
  - "openrouter/auto" -> "openrouter/auto"
  - "auto" -> "openrouter/auto"
  """
  def resolve_model("auto"), do: "openrouter/auto"
  def resolve_model("openrouter/auto"), do: "openrouter/auto"
  def resolve_model(model), do: model

  defp build_headers(api_key, opts) do
    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"}
    ]

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

  defp prepend_system_message(messages, nil), do: messages

  defp prepend_system_message(messages, system_prompt) do
    [%{role: "system", content: system_prompt} | messages]
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]
      tool_calls = msg[:tool_calls] || msg["tool_calls"]
      tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]

      cond do
        # 工具结果消息
        role == "tool" && tool_call_id ->
          %{
            role: "tool",
            tool_call_id: tool_call_id,
            content: content
          }

        # 助手消息带工具调用
        role == "assistant" && tool_calls && tool_calls != [] ->
          formatted_tool_calls =
            Enum.map(tool_calls, fn tc ->
              %{
                id: tc["id"],
                type: "function",
                function: %{
                  name: tc["name"],
                  arguments: Jason.encode!(tc["input"] || tc["arguments"] || %{})
                }
              }
            end)

          msg = %{role: "assistant", tool_calls: formatted_tool_calls}
          if content && content != "", do: Map.put(msg, :content, content), else: msg

        # 普通消息
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

  defp parse_response(%{"choices" => [choice | _]} = resp) do
    message = choice["message"]
    usage = resp["usage"] || %{}

    tool_calls =
      (message["tool_calls"] || [])
      |> Enum.map(fn tc ->
        %{
          "id" => tc["id"],
          "name" => get_in(tc, ["function", "name"]),
          "input" =>
            case Jason.decode(get_in(tc, ["function", "arguments"]) || "{}") do
              {:ok, parsed} -> parsed
              _ -> %{}
            end
        }
      end)

    %{
      content: message["content"],
      tool_calls: tool_calls,
      tokens_in: usage["prompt_tokens"],
      tokens_out: usage["completion_tokens"],
      stop_reason: choice["finish_reason"],
      model: resp["model"]
    }
  end

  defp parse_response(resp) do
    Logger.warning("Unexpected OpenRouter response format: #{inspect(resp)}")
    %{content: nil, tool_calls: [], tokens_in: nil, tokens_out: nil, stop_reason: nil}
  end
end
