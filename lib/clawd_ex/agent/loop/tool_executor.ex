defmodule ClawdEx.Agent.Loop.ToolExecutor do
  @moduledoc """
  Tool execution logic for the agent loop.

  Handles tool loading, parameter extraction, execution, and result formatting.
  """

  require Logger

  @doc "Load available tools based on agent config"
  def load_tools(config) do
    allowed = Map.get(config, :tools_allow, ["*"])
    denied = Map.get(config, :tools_deny, [])

    ClawdEx.Tools.Registry.list_tools(allow: allowed, deny: denied)
  end

  @doc "Format tool specs for AI provider consumption"
  def format_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters
      }
    end)
  end

  @doc "Execute a single tool call"
  def execute_tool(tool_call, data) do
    tool_name = tool_call["name"] || get_in(tool_call, ["function", "name"])
    params = extract_tool_params(tool_call)

    context = %{
      session_id: data.session_id,
      agent_id: data.agent_id,
      run_id: data.run_id
    }

    Logger.debug("Executing tool #{tool_name} with params: #{inspect(params)}")

    case ClawdEx.Tools.Registry.execute(tool_name, params, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Extract tool parameters, compatible with both Anthropic and OpenAI formats"
  def extract_tool_params(tool_call) do
    raw_args =
      tool_call["input"] ||
        tool_call["arguments"] ||
        get_in(tool_call, ["function", "arguments"])

    cond do
      is_map(raw_args) ->
        raw_args

      is_binary(raw_args) ->
        case Jason.decode(raw_args) do
          {:ok, parsed} -> parsed
          {:error, _} -> %{}
        end

      true ->
        %{}
    end
  end

  @doc "Format a tool result as a string for the AI"
  def format_tool_result({:ok, result}) when is_binary(result), do: result
  def format_tool_result({:ok, result}), do: Jason.encode!(result)
  def format_tool_result({:error, reason}), do: "Error: #{inspect(reason)}"

  @doc "Sanitize params for broadcast (strip sensitive data)"
  def sanitize_params(params) when is_map(params) do
    params
    |> Map.take(["action", "command", "path", "url", "query", "sessionId"])
    |> Map.new(fn {k, v} ->
      {k,
       if(is_binary(v) && String.length(v) > 100, do: String.slice(v, 0..97) <> "...", else: v)}
    end)
  end

  def sanitize_params(_), do: %{}

  @doc "Format tool execution results as progress summary"
  def format_tools_progress(results, iteration) do
    tool_summaries =
      Enum.map(results, fn {tool_call, result} ->
        name = tool_call["name"] || get_in(tool_call, ["function", "name"]) || "unknown"
        status = if match?({:ok, _}, result), do: "✓", else: "✗"
        "#{status} #{name}"
      end)
      |> Enum.join(", ")

    "Round #{iteration}: #{tool_summaries}"
  end
end
