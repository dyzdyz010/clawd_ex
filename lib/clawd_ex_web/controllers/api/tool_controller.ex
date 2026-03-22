defmodule ClawdExWeb.Api.ToolController do
  @moduledoc """
  Tool listing and execution REST API controller.
  """
  use ClawdExWeb, :controller

  alias ClawdEx.Tools.Registry, as: ToolRegistry

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  GET /api/v1/tools — List all available tools
  """
  def index(conn, _params) do
    tools = ToolRegistry.list_tools()

    json(conn, %{
      data: Enum.map(tools, &format_tool/1),
      total: length(tools)
    })
  end

  @doc """
  POST /api/v1/tools/:name/execute — Execute a tool
  """
  def execute(conn, %{"name" => name} = params) do
    tool_params = params["params"] || params["arguments"] || %{}

    # Build a minimal context for tool execution
    context = %{
      session_key: "api:rest:#{name}",
      channel: "api",
      source: "rest_api"
    }

    case ToolRegistry.execute(name, tool_params, context) do
      {:ok, result} ->
        json(conn, %{
          tool: name,
          status: "ok",
          result: format_tool_result(result)
        })

      {:error, :tool_not_found} ->
        {:error, :tool_not_found}

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: %{
            code: "tool_execution_error",
            message: inspect(reason)
          }
        })
    end
  end

  # Private helpers

  defp format_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  end

  defp format_tool_result(result) when is_binary(result), do: result
  defp format_tool_result(result) when is_map(result), do: result
  defp format_tool_result(result) when is_list(result), do: result
  defp format_tool_result(result), do: inspect(result)
end
