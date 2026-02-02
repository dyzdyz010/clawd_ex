defmodule ClawdEx.AI.Stream do
  @moduledoc """
  流式 AI 响应处理

  支持:
  - Anthropic Claude (SSE) - 包括 OAuth token
  - OpenAI GPT (SSE)
  - Google Gemini (SSE)
  """

  require Logger

  alias ClawdEx.AI.{Models, OAuth}
  alias ClawdEx.AI.OAuth.Anthropic, as: AnthropicOAuth

  @type message :: %{role: String.t(), content: String.t()}
  @type stream_opts :: [
          system: String.t() | nil,
          tools: [map()],
          max_tokens: integer(),
          stream_to: pid() | nil
        ]

  @doc """
  流式聊天补全 - 发送流式块到指定进程
  """
  @spec complete(String.t(), [message()], stream_opts()) :: {:ok, map()} | {:error, term()}
  def complete(model, messages, opts \\ []) do
    {provider, model_name} = parse_model(model)
    stream_to = Keyword.get(opts, :stream_to)

    case provider do
      :anthropic -> stream_anthropic(model_name, messages, opts, stream_to)
      :openai -> stream_openai(model_name, messages, opts, stream_to)
      :google -> stream_google(model_name, messages, opts, stream_to)
      :openrouter -> stream_openrouter(model_name, messages, opts)
      _ -> {:error, :unsupported_provider}
    end
  end

  # ============================================================================
  # Anthropic Claude Streaming
  # ============================================================================

  defp stream_anthropic(model, messages, opts, stream_to) do
    case OAuth.get_api_key(:anthropic) do
      {:ok, api_key} ->
        is_oauth = OAuth.oauth_token?(api_key)
        system_prompt = Keyword.get(opts, :system)
        tools = Keyword.get(opts, :tools, [])
        max_tokens = Keyword.get(opts, :max_tokens, 4096)

        body = %{
          model: model,
          max_tokens: max_tokens,
          messages: format_messages_anthropic(messages),
          stream: true
        }

        # OAuth tokens require special system prompt format
        body = if is_oauth do
          Map.put(body, :system, AnthropicOAuth.build_system_prompt(system_prompt))
        else
          if system_prompt, do: Map.put(body, :system, system_prompt), else: body
        end

        body = if tools != [], do: Map.put(body, :tools, format_tools_for_oauth(tools, is_oauth)), else: body

        # OAuth tokens need Claude Code compatible headers
        # Note: Override accept header for SSE streaming
        headers = if is_oauth do
          AnthropicOAuth.api_headers(api_key)
          |> Enum.reject(fn {k, _} -> k == "accept" end)
          |> Kernel.++([
            {"content-type", "application/json"},
            {"accept", "text/event-stream"}
          ])
        else
          [
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"},
            {"content-type", "application/json"},
            {"accept", "text/event-stream"}
          ]
        end

        # 使用 Req 的流式处理
        case stream_request(
               "https://api.anthropic.com/v1/messages",
               body,
               headers,
               stream_to,
               :anthropic
             ) do
          {:ok, accumulated} -> {:ok, accumulated}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Format tools for OAuth (Claude Code naming convention)
  defp format_tools_for_oauth(tools, true = _is_oauth) do
    Enum.map(tools, fn tool ->
      name = tool[:name] || tool["name"]
      %{
        tool |
        name: to_claude_code_name(name)
      }
    end)
  end
  defp format_tools_for_oauth(tools, false), do: tools

  # Claude Code tool name mapping
  @claude_code_tools ~w(Read Write Edit Bash Grep Glob AskUserQuestion EnterPlanMode ExitPlanMode KillShell NotebookEdit Skill Task TaskOutput TodoWrite WebFetch WebSearch)

  defp to_claude_code_name(name) do
    lower_name = String.downcase(to_string(name))
    Enum.find(@claude_code_tools, name, fn cc_name ->
      String.downcase(cc_name) == lower_name
    end)
  end

  # ============================================================================
  # OpenAI Streaming
  # ============================================================================

  defp stream_openai(model, messages, opts, stream_to) do
    api_key = get_api_key(:openai)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      system_prompt = Keyword.get(opts, :system)
      tools = Keyword.get(opts, :tools, [])
      max_tokens = Keyword.get(opts, :max_tokens, 4096)

      # 将系统提示添加到消息开头
      messages =
        if system_prompt do
          [%{role: "system", content: system_prompt} | messages]
        else
          messages
        end

      body = %{
        model: model,
        max_tokens: max_tokens,
        messages: messages,
        stream: true
      }

      body =
        if tools != [] do
          Map.put(body, :tools, format_tools_openai(tools))
        else
          body
        end

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"},
        {"accept", "text/event-stream"}
      ]

      case stream_request(
             "https://api.openai.com/v1/chat/completions",
             body,
             headers,
             stream_to,
             :openai
           ) do
        {:ok, accumulated} -> {:ok, accumulated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ============================================================================
  # Google Gemini Streaming
  # ============================================================================

  defp stream_google(model, messages, opts, stream_to) do
    api_key = get_api_key(:gemini)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      max_tokens = Keyword.get(opts, :max_tokens, 4096)

      url =
        "https://generativelanguage.googleapis.com/v1beta/models/#{model}:streamGenerateContent?key=#{api_key}&alt=sse"

      body = %{
        contents: format_messages_gemini(messages),
        generationConfig: %{maxOutputTokens: max_tokens}
      }

      headers = [
        {"content-type", "application/json"},
        {"accept", "text/event-stream"}
      ]

      case stream_request(url, body, headers, stream_to, :gemini) do
        {:ok, accumulated} -> {:ok, accumulated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # ============================================================================
  # Stream Processing
  # ============================================================================

  defp stream_request(url, body, headers, stream_to, provider) do
    # 累积器
    acc = %{
      content: "",
      tool_calls: [],
      tokens_in: nil,
      tokens_out: nil,
      stop_reason: nil
    }

    # 使用 Req 发送请求
    request =
      Req.new(
        url: url,
        method: :post,
        json: body,
        headers: headers,
        receive_timeout: 120_000,
        into: :self
      )

    case Req.request(request) do
      {:ok, response} ->
        # 检查 HTTP 状态码
        status = response.status

        if status >= 200 and status < 300 do
          process_stream(response, acc, stream_to, provider)
        else
          # API 错误，尝试读取错误信息
          error_body =
            case response.body do
              %{ref: ref} = async_body -> 
                # 尝试从流式响应中读取错误
                read_error_from_stream(async_body, ref, "")
              body when is_binary(body) -> body
              body -> inspect(body)
            end

          Logger.error("AI API error: HTTP #{status} - #{error_body}")
          {:error, {:api_error, status, error_body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_stream(response, acc, stream_to, provider) do
    case receive_loop(response, acc, stream_to, provider, "") do
      {:ok, final_acc} ->
        # 最终处理：解析 OpenAI 累积的 JSON 参数
        {:ok, finalize_response(final_acc, provider)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_loop(response, acc, stream_to, provider, buffer) do
    # Req 0.5.x: async ref is in response.body.ref
    async_ref = get_async_ref(response)
    
    receive do
      {ref, {:data, data}} when ref == async_ref ->
        # 合并 buffer 和新数据
        full_data = buffer <> data

        # 按行分割处理 SSE
        {events, new_buffer} = parse_sse_events(full_data)

        # 处理每个事件
        new_acc =
          Enum.reduce(events, acc, fn event, current_acc ->
            process_sse_event(event, current_acc, stream_to, provider)
          end)

        receive_loop(response, new_acc, stream_to, provider, new_buffer)

      {ref, :done} when ref == async_ref ->
        {:ok, acc}

      {ref, {:error, reason}} when ref == async_ref ->
        {:error, reason}
    after
      120_000 ->
        {:error, :timeout}
    end
  end

  # Read error message from streaming response
  defp read_error_from_stream(_body, ref, acc) do
    receive do
      {^ref, {:data, data}} ->
        read_error_from_stream(nil, ref, acc <> data)
      {^ref, :done} ->
        parse_error_response(acc)
      {^ref, {:error, _reason}} ->
        parse_error_response(acc)
    after
      5000 ->
        if acc == "", do: "HTTP error (no body)", else: parse_error_response(acc)
    end
  end
  
  defp parse_error_response(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} -> msg
      {:ok, %{"error" => error}} when is_binary(error) -> error
      {:ok, parsed} -> inspect(parsed)
      {:error, _} -> body
    end
  end

  # Get async ref - handles different Req versions
  defp get_async_ref(%{body: %{ref: ref}}), do: ref
  defp get_async_ref(%{async: %{ref: ref}}), do: ref
  defp get_async_ref(response), do: response.body.ref

  # 最终处理：解析 OpenAI 的 JSON arguments
  defp finalize_response(acc, :openai) do
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

  defp finalize_response(acc, :anthropic) do
    # Parse accumulated JSON for tool inputs
    finalized_tool_calls =
      Enum.map(acc.tool_calls, fn tc ->
        input_raw = tc["input_raw"] || ""

        input =
          if input_raw != "" do
            case Jason.decode(input_raw) do
              {:ok, parsed} -> parsed
              {:error, _} -> %{}
            end
          else
            tc["input"] || %{}
          end

        %{
          "id" => tc["id"],
          "name" => tc["name"],
          "input" => input
        }
      end)

    %{acc | tool_calls: finalized_tool_calls}
  end

  defp finalize_response(acc, _provider), do: acc

  defp parse_sse_events(data) do
    lines = String.split(data, "\n")

    # 检查最后一行是否完整
    {complete_lines, incomplete} =
      if String.ends_with?(data, "\n") do
        {lines, ""}
      else
        case List.pop_at(lines, -1) do
          {nil, []} -> {[], ""}
          {last, rest} -> {rest, last}
        end
      end

    # 解析完整的事件
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

  defp process_sse_event(event_data, acc, stream_to, provider) do
    case Jason.decode(event_data) do
      {:ok, event} ->
        process_event(event, acc, stream_to, provider)

      {:error, _} ->
        acc
    end
  end

  # Anthropic event processing - text delta
  defp process_event(
         %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta"} = delta},
         acc,
         stream_to,
         :anthropic
       ) do
    text = delta["text"] || ""

    if stream_to && text != "" do
      send(stream_to, {:ai_chunk, %{content: text}})
    end

    %{acc | content: acc.content <> text}
  end

  # Anthropic event processing - tool input JSON delta
  defp process_event(
         %{"type" => "content_block_delta", "index" => index, "delta" => %{"type" => "input_json_delta", "partial_json" => json_fragment}},
         acc,
         _stream_to,
         :anthropic
       ) do
    # Find the tool_call with matching block_index and accumulate JSON
    updated_tool_calls =
      Enum.map(acc.tool_calls, fn tc ->
        if tc["block_index"] == index do
          existing_raw = tc["input_raw"] || ""
          Map.put(tc, "input_raw", existing_raw <> json_fragment)
        else
          tc
        end
      end)

    %{acc | tool_calls: updated_tool_calls}
  end

  # Fallback for other content_block_delta types
  defp process_event(
         %{"type" => "content_block_delta"},
         acc,
         _stream_to,
         :anthropic
       ) do
    acc
  end

  defp process_event(
         %{"type" => "message_delta", "delta" => delta, "usage" => usage},
         acc,
         _stream_to,
         :anthropic
       ) do
    %{acc | stop_reason: delta["stop_reason"], tokens_out: usage["output_tokens"]}
  end

  defp process_event(
         %{"type" => "message_start", "message" => message},
         acc,
         _stream_to,
         :anthropic
       ) do
    %{acc | tokens_in: message["usage"]["input_tokens"]}
  end

  defp process_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => %{"type" => "tool_use"} = block},
         acc,
         _stream_to,
         :anthropic
       ) do
    tool_call = %{
      "id" => block["id"],
      "name" => block["name"],
      "input" => %{},
      "input_raw" => "",
      "block_index" => index
    }

    %{acc | tool_calls: acc.tool_calls ++ [tool_call]}
  end

  # OpenAI event processing
  # OpenAI 流式 tool_calls 是增量的，需要按 index 累积
  defp process_event(%{"choices" => [%{"delta" => delta} | _]} = event, acc, stream_to, :openai) do
    content = delta["content"] || ""

    if stream_to && content != "" do
      send(stream_to, {:ai_chunk, %{content: content}})
    end

    # 处理工具调用 - OpenAI 按 index 增量发送
    new_tool_calls =
      if delta["tool_calls"] do
        Enum.reduce(delta["tool_calls"], acc.tool_calls, fn tc, current_calls ->
          index = tc["index"] || 0

          # 获取或创建该 index 的 tool_call
          existing = Enum.at(current_calls, index)

          updated_call =
            if existing do
              # 累积 arguments (JSON 字符串片段)
              existing_args = existing["arguments_raw"] || ""
              new_args = get_in(tc, ["function", "arguments"]) || ""

              existing
              |> Map.put("arguments_raw", existing_args <> new_args)
            else
              # 新的 tool_call
              %{
                "id" => tc["id"],
                "name" => get_in(tc, ["function", "name"]),
                "arguments_raw" => get_in(tc, ["function", "arguments"]) || ""
              }
            end

          # 更新或追加
          if existing do
            List.replace_at(current_calls, index, updated_call)
          else
            current_calls ++ [updated_call]
          end
        end)
      else
        acc.tool_calls
      end

    # 处理 usage
    usage = event["usage"] || %{}

    %{
      acc
      | content: acc.content <> content,
        tool_calls: new_tool_calls,
        tokens_in: usage["prompt_tokens"] || acc.tokens_in,
        tokens_out: usage["completion_tokens"] || acc.tokens_out
    }
  end

  # Gemini event processing
  defp process_event(
         %{"candidates" => [%{"content" => %{"parts" => parts}} | _]},
         acc,
         stream_to,
         :gemini
       ) do
    text =
      parts
      |> Enum.filter(&Map.has_key?(&1, "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("")

    if stream_to && text != "" do
      send(stream_to, {:ai_chunk, %{content: text}})
    end

    %{acc | content: acc.content <> text}
  end

  # Fallback
  defp process_event(_event, acc, _stream_to, _provider), do: acc

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_model(model) do
    # 使用中心化的 Models 模块解析
    Models.parse(model)
  end

  # ============================================================================
  # OpenRouter Streaming (via dedicated provider module)
  # ============================================================================

  defp stream_openrouter(model, messages, opts) do
    ClawdEx.AI.Providers.OpenRouter.stream(model, messages, opts)
  end

  defp format_messages_anthropic(messages) do
    Enum.map(messages, fn msg ->
      role = msg[:role] || msg["role"]
      content = msg[:content] || msg["content"]
      tool_calls = msg[:tool_calls] || msg["tool_calls"]
      tool_call_id = msg[:tool_call_id] || msg["tool_call_id"]

      cond do
        # 工具结果消息
        role == "tool" && tool_call_id ->
          %{
            role: "user",
            content: [
              %{
                type: "tool_result",
                tool_use_id: tool_call_id,
                content: content
              }
            ]
          }

        # 助手消息带工具调用
        role == "assistant" && tool_calls && tool_calls != [] ->
          content_blocks =
            if content && content != "" do
              [%{type: "text", text: content}]
            else
              []
            end

          tool_use_blocks =
            Enum.map(tool_calls, fn tc ->
              %{
                type: "tool_use",
                id: tc["id"],
                name: tc["name"],
                input: tc["input"] || tc["arguments"] || %{}
              }
            end)

          %{role: "assistant", content: content_blocks ++ tool_use_blocks}

        # 普通消息
        true ->
          %{role: role, content: content}
      end
    end)
  end

  defp format_messages_gemini(messages) do
    Enum.map(messages, fn msg ->
      role =
        case msg[:role] || msg["role"] do
          "user" -> "user"
          "assistant" -> "model"
          # Gemini 不支持 system role
          "system" -> "user"
          _ -> "user"
        end

      %{role: role, parts: [%{text: msg[:content] || msg["content"]}]}
    end)
  end

  defp format_tools_openai(tools) do
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

  defp get_api_key(:openai) do
    case OAuth.get_api_key(:openai) do
      {:ok, key} -> key
      _ -> nil
    end
  end

  defp get_api_key(:gemini) do
    case OAuth.get_api_key(:gemini) do
      {:ok, key} -> key
      _ -> nil
    end
  end
end
