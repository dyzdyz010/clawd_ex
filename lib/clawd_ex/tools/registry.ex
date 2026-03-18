defmodule ClawdEx.Tools.Registry do
  @moduledoc """
  工具注册表

  管理所有可用工具的注册、查找和执行。
  """

  require Logger

  @type tool_spec :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  # 工具模块映射
  @tools %{
    # 文件系统
    "read" => ClawdEx.Tools.Read,
    "write" => ClawdEx.Tools.Write,
    "edit" => ClawdEx.Tools.Edit,
    # 运行时
    "exec" => ClawdEx.Tools.Exec,
    "process" => ClawdEx.Tools.Process,
    # 记忆（统一接口）
    "memory" => ClawdEx.Tools.MemoryTool,
    "memory_search" => ClawdEx.Tools.MemorySearch,
    "memory_get" => ClawdEx.Tools.MemoryGet,
    # 会话
    "session_status" => ClawdEx.Tools.SessionStatus,
    "sessions_history" => ClawdEx.Tools.SessionsHistory,
    "sessions_list" => ClawdEx.Tools.SessionsList,
    "sessions_send" => ClawdEx.Tools.SessionsSend,
    "sessions_spawn" => ClawdEx.Tools.SessionsSpawn,
    "agents_list" => ClawdEx.Tools.AgentsList,
    # Web
    "web_search" => ClawdEx.Tools.WebSearch,
    "web_fetch" => ClawdEx.Tools.WebFetch,
    # 自动化
    "compact" => ClawdEx.Tools.Compact,
    "gateway" => ClawdEx.Tools.Gateway,
    "cron" => ClawdEx.Tools.Cron,
    "message" => ClawdEx.Tools.Message,
    # 浏览器 & 节点
    "browser" => ClawdEx.Tools.Browser,
    "nodes" => ClawdEx.Tools.Nodes,
    "canvas" => ClawdEx.Tools.Canvas,
    # 媒体
    "image" => ClawdEx.Tools.Image,
    "tts" => ClawdEx.Tools.Tts,
    # 任务管理
    "task" => ClawdEx.Tools.TaskTool,
    # Agent-to-Agent 通信
    "a2a" => ClawdEx.Tools.A2A,
    # Patch
    "apply_patch" => ClawdEx.Tools.ApplyPatch
  }

  @doc """
  列出可用工具
  """
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

    # Merge plugin-provided tools
    plugin_tools =
      try do
        ClawdEx.Plugins.Manager.get_tools()
        |> Enum.map(fn mod ->
          %{name: mod.name(), description: mod.description(), parameters: mod.parameters()}
        end)
        |> Enum.filter(&tool_allowed?(&1.name, allowed, denied))
      rescue
        _ -> []
      end

    builtin ++ plugin_tools
  end

  @doc """
  列出 agent 可用的工具（根据 agent 的 allowed_tools / denied_tools 过滤）
  """
  @spec list_tools_for_agent(map() | struct()) :: [tool_spec()]
  def list_tools_for_agent(agent) do
    allowed = agent_field(agent, :allowed_tools, [])
    denied = agent_field(agent, :denied_tools, [])

    # If no permissions configured, return all tools
    if allowed == [] and denied == [] do
      list_tools()
    else
      list_tools(allow: normalize_allow(allowed), deny: denied)
    end
  end

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

  # If allowed is empty list, treat as allow-all
  defp normalize_allow([]), do: ["*"]
  defp normalize_allow(allowed), do: allowed

  # Claude Code name -> ClawdEx name reverse mapping
  @claude_code_to_clawd %{
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

  @doc """
  执行工具
  """
  @spec execute(String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def execute(tool_name, params, context) do
    # Resolve canonical tool name
    canonical = resolve_tool_name(tool_name)

    module = Map.get(@tools, canonical) || find_plugin_tool(canonical)

    case module do
      nil ->
        Logger.warning("Tool not found: #{tool_name}")
        {:error, :tool_not_found}

      mod ->
        # Security check before execution
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

  @doc """
  Resolve a tool name to its canonical internal name.
  """
  @spec resolve_tool_name(String.t()) :: String.t()
  def resolve_tool_name(tool_name) do
    cond do
      Map.has_key?(@tools, tool_name) -> tool_name
      Map.has_key?(@tools, String.downcase(tool_name)) -> String.downcase(tool_name)
      Map.has_key?(@claude_code_to_clawd, tool_name) -> Map.get(@claude_code_to_clawd, tool_name)
      true -> tool_name
    end
  end

  @doc """
  获取工具规格
  """
  @spec get_tool_spec(String.t()) :: tool_spec() | nil
  def get_tool_spec(tool_name) do
    module =
      Map.get(@tools, tool_name) ||
        Map.get(@tools, String.downcase(tool_name))

    case module do
      nil ->
        nil

      mod ->
        %{
          name: mod.name(),
          description: mod.description(),
          parameters: mod.parameters()
        }
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp find_plugin_tool(name) do
    try do
      ClawdEx.Plugins.Manager.get_tools()
      |> Enum.find(fn mod -> mod.name() == name end)
    rescue
      _ -> nil
    end
  end

  defp tool_allowed?(name, allowed, denied) do
    # Deny 优先
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
  工具行为定义
  """

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(params :: map(), context :: map()) :: {:ok, any()} | {:error, term()}
end
