defmodule ClawdEx.Agent.Loop.Broadcaster do
  @moduledoc """
  PubSub broadcasting for agent loop events.

  Extracted from Agent.Loop to keep the state machine focused on flow control.
  """

  @doc "Broadcast a streaming chunk"
  def broadcast_chunk(data, chunk) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent:#{data.session_id}",
      {:agent_chunk, data.run_id, chunk}
    )
  end

  @doc "Broadcast a status update"
  def broadcast_status(data, status, details) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent:#{data.session_id}",
      {:agent_status, data.run_id, status, details}
    )
  end

  @doc "Broadcast run started event"
  def broadcast_run_started(data) do
    broadcast_status(data, :started, %{
      model: data.model,
      started_at: data.started_at
    })
  end

  @doc "Broadcast inferring event"
  def broadcast_inferring(data) do
    broadcast_status(data, :inferring, %{
      iteration: data.tool_iterations
    })
  end

  @doc "Broadcast run completion"
  def broadcast_run_done(data, content) do
    broadcast_status(data, :done, %{
      content_preview: String.slice(content || "", 0..100)
    })
  end

  @doc "Broadcast run error"
  def broadcast_run_error(data, reason) do
    broadcast_status(data, :error, %{
      reason: inspect(reason)
    })
  end

  @doc "Broadcast tool execution results"
  def broadcast_tools_done(data, results) do
    summaries =
      Enum.map(results, fn {tool_call, result} ->
        tool_name = tool_call["name"] || get_in(tool_call, ["function", "name"]) || "unknown"
        result_summary = summarize_tool_result(result)
        %{tool: tool_name, result: result_summary}
      end)

    broadcast_status(data, :tools_done, %{
      tools: summaries,
      count: length(results),
      iteration: data.tool_iterations
    })
  end

  @doc "Broadcast a text segment (before tool calls)"
  def broadcast_segment(data, content, opts) do
    Phoenix.PubSub.broadcast(
      ClawdEx.PubSub,
      "agent:#{data.session_id}",
      {:agent_segment, data.run_id, content,
       %{
         session_id: data.session_id,
         continuing: Keyword.get(opts, :continuing, false)
       }}
    )
  end

  @doc "Summarize a tool result for broadcast (truncate long output)"
  def summarize_tool_result({:ok, result}) when is_binary(result) do
    if String.length(result) > 200 do
      String.slice(result, 0..197) <> "..."
    else
      result
    end
  end

  def summarize_tool_result({:ok, result}) do
    result |> inspect() |> String.slice(0..200)
  end

  def summarize_tool_result({:error, reason}) do
    "Error: #{inspect(reason)}" |> String.slice(0..200)
  end
end
