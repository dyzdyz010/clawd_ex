defmodule ClawdEx.MCP.ToolProxy do
  @moduledoc """
  MCP Tool Proxy — aggregates tools from multiple MCP connections
  and routes tool execution to the correct connection.

  Acts as a bridge between ClawdEx's tool system and MCP servers.
  Tools are exposed with a prefixed name: `mcp__{server_name}__{tool_name}`
  to avoid conflicts with built-in and plugin tools.
  """

  require Logger

  alias ClawdEx.MCP.{Connection, ServerManager}

  @mcp_tool_prefix "mcp__"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  List all tools from all active MCP connections.

  Returns tools with server-prefixed names to avoid conflicts.
  Each tool has the format: mcp__{server_name}__{tool_name}
  """
  @spec list_tools() :: [map()]
  def list_tools do
    ServerManager.list_servers()
    |> Enum.filter(fn {_name, info} -> info.status == :ready end)
    |> Enum.flat_map(fn {name, _info} ->
      case get_connection_tools(name) do
        {:ok, tools} ->
          Enum.map(tools, fn tool ->
            tool_name = tool["name"] || Map.get(tool, :name, "unknown")
            prefixed_name = "#{@mcp_tool_prefix}#{name}__#{tool_name}"

            %{
              name: prefixed_name,
              description: tool["description"] || Map.get(tool, :description, ""),
              parameters: tool["inputSchema"] || Map.get(tool, :parameters, %{}),
              source: :mcp,
              server: name,
              original_name: tool_name
            }
          end)

        {:error, _reason} ->
          []
      end
    end)
  end

  @doc """
  Execute an MCP tool by its prefixed name.

  Parses the server name and tool name from the prefixed format,
  then routes to the correct connection.
  """
  @spec execute(String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def execute(prefixed_name, arguments \\ %{}, _context \\ %{}) do
    case parse_tool_name(prefixed_name) do
      {:ok, server_name, tool_name} ->
        case ServerManager.get_connection(server_name) do
          {:ok, pid} ->
            case Connection.call_tool(pid, tool_name, arguments) do
              {:ok, result} -> format_result(result)
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, {:connection_not_found, server_name, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Check if a tool name is an MCP tool"
  @spec mcp_tool?(String.t()) :: boolean()
  def mcp_tool?(name) when is_binary(name) do
    String.starts_with?(name, @mcp_tool_prefix)
  end

  def mcp_tool?(_), do: false

  @doc "Get the MCP tool prefix"
  @spec prefix() :: String.t()
  def prefix, do: @mcp_tool_prefix

  @doc "Parse a prefixed tool name into {server, tool}"
  @spec parse_tool_name(String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def parse_tool_name(prefixed_name) do
    case String.replace_prefix(prefixed_name, @mcp_tool_prefix, "") do
      ^prefixed_name ->
        {:error, {:not_mcp_tool, prefixed_name}}

      rest ->
        case String.split(rest, "__", parts: 2) do
          [server_name, tool_name] when server_name != "" and tool_name != "" ->
            {:ok, server_name, tool_name}

          _ ->
            {:error, {:invalid_mcp_tool_name, prefixed_name}}
        end
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp get_connection_tools(server_name) do
    case ServerManager.get_connection(server_name) do
      {:ok, pid} ->
        try do
          Connection.list_tools(pid)
        catch
          :exit, _ -> {:error, :connection_down}
        end

      error ->
        error
    end
  end

  defp format_result(%{"content" => content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&(Map.get(&1, "type") == "text"))
      |> Enum.map(&Map.get(&1, "text", ""))
      |> Enum.join("\n")

    {:ok, text}
  end

  defp format_result(result) do
    {:ok, result}
  end
end
