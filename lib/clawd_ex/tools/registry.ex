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
    # 记忆
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
    # 媒体 (新增)
    "image" => ClawdEx.Tools.Image,
    "tts" => ClawdEx.Tools.Tts
  }

  @doc """
  列出可用工具
  """
  @spec list_tools(keyword()) :: [tool_spec()]
  def list_tools(opts \\ []) do
    allowed = Keyword.get(opts, :allow, ["*"])
    denied = Keyword.get(opts, :deny, [])

    @tools
    |> Map.keys()
    |> Enum.filter(&tool_allowed?(&1, allowed, denied))
    |> Enum.map(&get_tool_spec/1)
    |> Enum.reject(&is_nil/1)
  end

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
    "Compact" => "compact"
  }

  @doc """
  执行工具
  """
  @spec execute(String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def execute(tool_name, params, context) do
    # Try exact match first, then case-insensitive, then Claude Code name mapping
    module =
      Map.get(@tools, tool_name) ||
        Map.get(@tools, String.downcase(tool_name)) ||
        Map.get(@tools, Map.get(@claude_code_to_clawd, tool_name, ""))

    case module do
      nil ->
        Logger.warning("Tool not found: #{tool_name}")
        {:error, :tool_not_found}

      mod ->
        try do
          mod.execute(params, context)
        rescue
          e ->
            Logger.error("Tool execution error: #{inspect(e)}")
            {:error, {:execution_error, Exception.message(e)}}
        end
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
