defmodule ClawdEx.AI.Chat do
  @moduledoc """
  AI 聊天补全服务
  支持 Anthropic, OpenAI, Google 等提供商
  
  OAuth 支持:
  - 自动检测 OAuth token (sk-ant-oat*)
  - 自动刷新过期 token
  - 使用 Claude Code 兼容的 headers 和 system prompt
  """

  alias ClawdEx.AI.OAuth
  alias ClawdEx.AI.OAuth.Anthropic, as: AnthropicOAuth

  @type message :: %{role: String.t(), content: String.t()}
  @type tool :: %{name: String.t(), description: String.t(), parameters: map()}

  @doc """
  发送聊天请求并获取响应
  """
  @spec complete(String.t(), [message()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def complete(model, messages, opts \\ []) do
    {provider, model_name} = parse_model(model)

    case provider do
      :anthropic -> complete_anthropic(model_name, messages, opts)
      :openai -> complete_openai(model_name, messages, opts)
      :google -> complete_google(model_name, messages, opts)
      _ -> {:error, :unsupported_provider}
    end
  end

  @doc """
  流式聊天响应
  """
  @spec stream(String.t(), [message()], keyword()) :: Enumerable.t()
  def stream(model, messages, opts \\ []) do
    {provider, model_name} = parse_model(model)

    case provider do
      :anthropic -> stream_anthropic(model_name, messages, opts)
      :openai -> stream_openai(model_name, messages, opts)
      _ -> {:error, :unsupported_provider}
    end
  end

  # Anthropic Claude API
  defp complete_anthropic(model, messages, opts) do
    system_prompt = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    # Get API key through OAuth module (handles token refresh)
    case OAuth.get_api_key(:anthropic) do
      {:ok, api_key} ->
        is_oauth = OAuth.oauth_token?(api_key)

        body = %{
          model: model,
          max_tokens: max_tokens,
          messages: format_messages_anthropic(messages)
        }

        # OAuth tokens require special system prompt format (Claude Code identity)
        body = if is_oauth do
          Map.put(body, :system, AnthropicOAuth.build_system_prompt(system_prompt))
        else
          if system_prompt, do: Map.put(body, :system, system_prompt), else: body
        end

        body = if tools != [], do: Map.put(body, :tools, format_tools_anthropic(tools, is_oauth)), else: body

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: anthropic_auth_headers(api_key)
             ) do
          {:ok, %{status: 200, body: body}} ->
            {:ok, parse_anthropic_response(body)}

          {:ok, %{status: status, body: body}} ->
            {:error, {:api_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # OpenAI API
  defp complete_openai(model, messages, opts) do
    api_key = get_api_key(:openai)
    tools = Keyword.get(opts, :tools, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      body = %{
        model: model,
        max_tokens: max_tokens,
        messages: messages
      }

      body = if tools != [], do: Map.put(body, :tools, format_tools_openai(tools)), else: body

      case Req.post("https://api.openai.com/v1/chat/completions",
             json: body,
             headers: [{"Authorization", "Bearer #{api_key}"}]
           ) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, parse_openai_response(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Google Gemini API
  defp complete_google(model, messages, opts) do
    api_key = get_api_key(:gemini)
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    if is_nil(api_key) do
      {:error, :missing_api_key}
    else
      url =
        "https://generativelanguage.googleapis.com/v1beta/models/#{model}:generateContent?key=#{api_key}"

      body = %{
        contents: format_messages_gemini(messages),
        generationConfig: %{maxOutputTokens: max_tokens}
      }

      case Req.post(url, json: body) do
        {:ok, %{status: 200, body: body}} ->
          {:ok, parse_gemini_response(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Streaming implementations (placeholder)
  defp stream_anthropic(_model, _messages, _opts), do: Stream.cycle([:not_implemented])
  defp stream_openai(_model, _messages, _opts), do: Stream.cycle([:not_implemented])

  # Helper functions
  defp parse_model(model) do
    case String.split(model, "/", parts: 2) do
      ["anthropic", name] -> {:anthropic, name}
      ["openai", name] -> {:openai, name}
      ["google", name] -> {:google, name}
      # 默认 Anthropic
      [name] -> {:anthropic, name}
      _ -> {:unknown, model}
    end
  end

  defp format_messages_anthropic(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]}
    end)
  end

  defp format_messages_gemini(messages) do
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

  defp format_tools_anthropic(tools, is_oauth) do
    Enum.map(tools, fn tool ->
      name = if is_oauth do
        # Claude Code uses specific tool name casing
        to_claude_code_name(tool[:name])
      else
        tool[:name]
      end

      %{
        name: name,
        description: tool[:description],
        input_schema: tool[:parameters]
      }
    end)
  end

  # Claude Code tool name mapping (case-sensitive)
  @claude_code_tools ~w(Read Write Edit Bash Grep Glob AskUserQuestion EnterPlanMode ExitPlanMode KillShell NotebookEdit Skill Task TaskOutput TodoWrite WebFetch WebSearch)

  defp to_claude_code_name(name) do
    lower_name = String.downcase(to_string(name))
    Enum.find(@claude_code_tools, name, fn cc_name ->
      String.downcase(cc_name) == lower_name
    end)
  end

  defp format_tools_openai(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool[:name],
          description: tool[:description],
          parameters: tool[:parameters]
        }
      }
    end)
  end

  defp parse_anthropic_response(%{"content" => content, "usage" => usage} = resp) do
    text =
      content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map(& &1["text"]) |> Enum.join("")

    tool_calls = content |> Enum.filter(&(&1["type"] == "tool_use"))

    %{
      content: text,
      tool_calls: tool_calls,
      tokens_in: usage["input_tokens"],
      tokens_out: usage["output_tokens"],
      stop_reason: resp["stop_reason"]
    }
  end

  defp parse_openai_response(%{"choices" => [choice | _], "usage" => usage}) do
    message = choice["message"]

    %{
      content: message["content"],
      tool_calls: message["tool_calls"] || [],
      tokens_in: usage["prompt_tokens"],
      tokens_out: usage["completion_tokens"],
      stop_reason: choice["finish_reason"]
    }
  end

  defp parse_gemini_response(%{"candidates" => [candidate | _]}) do
    content = candidate["content"]["parts"] |> Enum.map(& &1["text"]) |> Enum.join("")

    %{
      content: content,
      tool_calls: [],
      tokens_in: nil,
      tokens_out: nil,
      stop_reason: candidate["finishReason"]
    }
  end

  # OAuth tokens (sk-ant-oat*) need special headers to mimic Claude Code
  defp anthropic_auth_headers(api_key) do
    if OAuth.oauth_token?(api_key) do
      # OAuth token - use Claude Code compatible headers
      AnthropicOAuth.api_headers(api_key)
    else
      # Regular API key - use x-api-key header
      [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]
    end
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
