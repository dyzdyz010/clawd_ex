defmodule ClawdEx.AI.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude AI Provider — native Messages API.

  NOT OpenAI-compatible, uses Anthropic's own format with:
  - system as top-level field (not a message)
  - tool_use / tool_result content blocks
  - x-api-key header (or OAuth Bearer token)

  Supports OAuth tokens (sk-ant-oat*) with automatic refresh and
  Claude Code compatible headers.
  """

  @behaviour ClawdEx.AI.Provider

  require Logger

  alias ClawdEx.AI.OAuth
  alias ClawdEx.AI.OAuth.Anthropic, as: AnthropicOAuth

  # ============================================================================
  # Provider Behaviour
  # ============================================================================

  @impl true
  def name, do: :anthropic

  @impl true
  def configured? do
    match?({:ok, _}, OAuth.get_api_key(:anthropic))
  end

  @impl true
  def chat(model, messages, opts \\ []) do
    system_prompt = Keyword.get(opts, :system)
    tools = Keyword.get(opts, :tools, [])
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    case OAuth.get_api_key(:anthropic) do
      {:ok, api_key} ->
        is_oauth = OAuth.oauth_token?(api_key)

        body = %{
          model: model,
          max_tokens: max_tokens,
          messages: format_messages(messages)
        }

        # OAuth tokens require special system prompt format (Claude Code identity)
        body =
          if is_oauth do
            Map.put(body, :system, AnthropicOAuth.build_system_prompt(system_prompt))
          else
            if system_prompt, do: Map.put(body, :system, system_prompt), else: body
          end

        body =
          if tools != [],
            do: Map.put(body, :tools, format_tools(tools, is_oauth)),
            else: body

        case Req.post("https://api.anthropic.com/v1/messages",
               json: body,
               headers: auth_headers(api_key),
               retry: :transient,
               retry_delay: fn attempt -> attempt * 1000 end,
               max_retries: 3,
               receive_timeout: 120_000
             ) do
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
    # Placeholder — full streaming is handled by ClawdEx.AI.Stream
    {:error, :not_implemented}
  end

  @impl true
  def resolve_model(model), do: model

  # ============================================================================
  # Formatting
  # ============================================================================

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{role: msg[:role] || msg["role"], content: msg[:content] || msg["content"]}
    end)
  end

  defp format_tools(tools, is_oauth) do
    Enum.map(tools, fn tool ->
      name =
        if is_oauth do
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

  # ============================================================================
  # Response Parsing
  # ============================================================================

  defp parse_response(%{"content" => content, "usage" => usage} = resp) do
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

  # ============================================================================
  # Auth
  # ============================================================================

  defp auth_headers(api_key) do
    if OAuth.oauth_token?(api_key) do
      AnthropicOAuth.api_headers(api_key)
    else
      [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"}
      ]
    end
  end
end
