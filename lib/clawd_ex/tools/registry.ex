defmodule ClawdEx.Tools.Registry do
  @moduledoc """
  Tool Registry — manages tool discovery, lookup, and execution.

  Tools are auto-discovered from `ClawdEx.Tools.*` modules that implement
  the `ClawdEx.Tools.Tool` behaviour. No manual registration needed.
  """

  require Logger

  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  # All tool modules — single source of truth.
  # To add a new tool: create a module implementing ClawdEx.Tools.Tool, add it here.
  @tool_modules [
    # File system
    ClawdEx.Tools.Read,
    ClawdEx.Tools.Write,
    ClawdEx.Tools.Edit,
    # Runtime
    ClawdEx.Tools.Exec,
    ClawdEx.Tools.Process,
    # Memory
    ClawdEx.Tools.MemoryTool,
    ClawdEx.Tools.MemorySearch,
    ClawdEx.Tools.MemoryGet,
    # Sessions
    ClawdEx.Tools.SessionStatus,
    ClawdEx.Tools.SessionsHistory,
    ClawdEx.Tools.SessionsList,
    ClawdEx.Tools.SessionsSend,
    ClawdEx.Tools.SessionsSpawn,
    ClawdEx.Tools.AgentsList,
    # Web
    ClawdEx.Tools.WebSearch,
    ClawdEx.Tools.WebFetch,
    # Automation
    ClawdEx.Tools.Compact,
    ClawdEx.Tools.Gateway,
    ClawdEx.Tools.Cron,
    ClawdEx.Tools.Message,
    # Browser & Nodes
    ClawdEx.Tools.Browser,
    ClawdEx.Tools.Nodes,
    ClawdEx.Tools.Canvas,
    # Media
    ClawdEx.Tools.Image,
    ClawdEx.Tools.Tts,
    # Task management
    ClawdEx.Tools.TaskTool,
    # Agent-to-Agent
    ClawdEx.Tools.A2A,
    # Patch
    ClawdEx.Tools.ApplyPatch
  ]

  # Build name → module mapping at compile time
  @tools Map.new(@tool_modules, fn mod -> {mod.name(), mod} end)

  # Claude Code name → internal name mapping (for OAuth/Claude Code interop)
  @claude_code_to_internal %{
    "Bash" => "exec",
    "Read" => "read",
    "Write" => "write",
    "Edit" => "edit",
    "WebFetch" => "web_fetch",
    "WebSearch" => "web_search",
    "Browser" => "browser",
    "Canvas" => "canvas",
    "Process" => "process",
    "Memory" => "memory",
    "MemorySearch" => "memory_search",
    "MemoryGet" => "memory_get",
    "SessionStatus" => "session_status",
    "SessionsHistory" => "sessions_history",
    "SessionsList" => "sessions_list",
    "SessionsSend" => "sessions_send",
    "SessionsSpawn" => "sessions_spawn",
    "AgentsList" => "agents_list",
    "Cron" => "cron",
    "Gateway" => "gateway",
    "Message" => "message",
    "Nodes" => "nodes",
    "Image" => "image",
    "Tts" => "tts",
    "Compact" => "compact",
    "Task" => "task",
    "A2A" => "a2a",
    "ApplyPatch" => "apply_patch"
  }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "List available tools (filtered by allow/deny)"
  @spec list_tools(keyword()) :: [tool_spec()]
  def list_tools(opts \\ []) do
    allowed = Keyword.get(opts, :allow, ["*"])
    denied = Keyword.get(opts, :deny, [])

    builtin =
      @tools
      |> Map.keys()
      |> Enum.filter(&tool_allowed?(&1, allowed, denied))
      |> Enum.map(&get_tool_spec/1)
      |> Enum.reject(&is_nil/1)

    # Merge plugin-provided tools (Elixir beam plugins)
    plugin_beam_tools =
      try do
        ClawdEx.Plugins.Manager.get_tools()
        |> Enum.map(fn mod ->
          %{name: mod.name(), description: mod.description(), parameters: mod.parameters()}
        end)
        |> Enum.filter(&tool_allowed?(&1.name, allowed, denied))
      rescue
        _ -> []
      end

    # Merge plugin-provided tools (Node.js plugins via bridge)
    plugin_node_tools =
      try do
        ClawdEx.Plugins.Manager.get_tool_specs()
        |> Enum.map(fn spec ->
          %{
            name: Map.get(spec, :name, Map.get(spec, "name")),
            description: Map.get(spec, :description, Map.get(spec, "description", "")),
            parameters: Map.get(spec, :parameters, Map.get(spec, "parameters", %{}))
          }
        end)
        |> Enum.filter(&tool_allowed?(&1.name, allowed, denied))
      rescue
        _ -> []
      end

    plugin_tools = plugin_beam_tools ++ plugin_node_tools

    # Merge MCP-provided tools (lowest priority: builtin > plugin > mcp)
    mcp_tools =
      try do
        ClawdEx.MCP.ToolProxy.list_tools()
        |> Enum.filter(&tool_allowed?(&1.name, allowed, denied))
      rescue
        _ -> []
      end

    builtin ++ plugin_tools ++ mcp_tools
  end

  @doc "List tools for an agent (filtered by agent's allowed/denied tools)"
  @spec list_tools_for_agent(map() | struct()) :: [tool_spec()]
  def list_tools_for_agent(agent) do
    allowed = agent_field(agent, :allowed_tools, [])
    denied = agent_field(agent, :denied_tools, [])

    if allowed == [] and denied == [] do
      list_tools()
    else
      list_tools(allow: normalize_allow(allowed), deny: denied)
    end
  end

  @doc "Execute a tool by name"
  @spec execute(String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def execute(tool_name, params, context) do
    canonical = resolve_tool_name(tool_name)
    module = Map.get(@tools, canonical) || find_plugin_tool(canonical)

    case module do
      nil ->
        # Check if it's a Node.js plugin tool
        case find_node_plugin_tool(canonical) do
          {plugin_id, _spec} ->
            try do
              ClawdEx.Plugins.Manager.call_tool(plugin_id, canonical, params, context)
            rescue
              e ->
                Logger.error("Plugin tool execution error: #{inspect(e)}")
                {:error, {:execution_error, Exception.message(e)}}
            catch
              :exit, reason ->
                Logger.error("Plugin tool call exit: #{inspect(reason)}")
                {:error, {:execution_error, "Plugin bridge unavailable"}}
            end

          nil ->
            # Check if it's an MCP tool before giving up
            if find_mcp_tool(canonical) do
              try do
                ClawdEx.MCP.ToolProxy.execute(canonical, params, context)
              rescue
                e ->
                  Logger.error("MCP tool execution error: #{inspect(e)}")
                  {:error, {:execution_error, Exception.message(e)}}
              end
            else
              Logger.warning("Tool not found: #{tool_name}")
              {:error, :tool_not_found}
            end
        end

      mod ->
        case ClawdEx.Security.ToolGuard.check_permission(canonical, params, context) do
          :ok ->
            try do
              mod.execute(params, context)
            rescue
              e ->
                Logger.error("Tool execution error: #{inspect(e)}")
                {:error, {:execution_error, Exception.message(e)}}
            end

          {:error, reason} ->
            Logger.warning("Tool permission denied: #{tool_name} — #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  @doc "Resolve a tool name to its canonical internal name"
  @spec resolve_tool_name(String.t()) :: String.t()
  def resolve_tool_name(tool_name) do
    cond do
      Map.has_key?(@tools, tool_name) -> tool_name
      Map.has_key?(@tools, String.downcase(tool_name)) -> String.downcase(tool_name)
      Map.has_key?(@claude_code_to_internal, tool_name) -> Map.get(@claude_code_to_internal, tool_name)
      true -> tool_name
    end
  end

  @doc "Get a tool's spec (name, description, parameters)"
  @spec get_tool_spec(String.t()) :: tool_spec() | nil
  def get_tool_spec(tool_name) do
    module =
      Map.get(@tools, tool_name) ||
        Map.get(@tools, String.downcase(tool_name))

    case module do
      nil -> nil
      mod -> %{name: mod.name(), description: mod.description(), parameters: mod.parameters()}
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp agent_field(agent, field, default) when is_atom(field) do
    cond do
      is_map(agent) and Map.has_key?(agent, field) ->
        Map.get(agent, field, default)

      is_map(agent) and Map.has_key?(agent, Atom.to_string(field)) ->
        Map.get(agent, Atom.to_string(field), default)

      true ->
        default
    end
  end

  defp normalize_allow([]), do: ["*"]
  defp normalize_allow(allowed), do: allowed

  defp find_plugin_tool(name) do
    try do
      ClawdEx.Plugins.Manager.get_tools()
      |> Enum.find(fn mod -> mod.name() == name end)
    rescue
      _ -> nil
    end
  end

  defp find_node_plugin_tool(name) do
    try do
      ClawdEx.Plugins.Manager.get_tool_specs()
      |> Enum.find(fn spec ->
        tool_name = Map.get(spec, :name, Map.get(spec, "name"))
        tool_name == name
      end)
      |> case do
        nil -> nil
        spec ->
          plugin_id = Map.get(spec, :plugin_id, Map.get(spec, "plugin_id"))
          {plugin_id, spec}
      end
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  defp find_mcp_tool(name) do
    try do
      ClawdEx.MCP.ToolProxy.mcp_tool?(name)
    rescue
      _ -> false
    end
  end

  defp tool_allowed?(name, allowed, denied) do
    if name in denied || "*" in denied do
      false
    else
      "*" in allowed || name in allowed
    end
  end
end

# ============================================================================
# Tool Behaviour
# ============================================================================

defmodule ClawdEx.Tools.Tool do
  @moduledoc """
  Tool behaviour — all tools must implement these callbacks.
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map(), context :: map()) :: {:ok, any()} | {:error, term()}
end
