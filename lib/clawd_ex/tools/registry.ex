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
    "read" => ClawdEx.Tools.Read,
    "write" => ClawdEx.Tools.Write,
    "edit" => ClawdEx.Tools.Edit,
    "exec" => ClawdEx.Tools.Exec,
    "process" => ClawdEx.Tools.Process,
    "memory_search" => ClawdEx.Tools.MemorySearch,
    "memory_get" => ClawdEx.Tools.MemoryGet,
    "session_status" => ClawdEx.Tools.SessionStatus,
    "sessions_history" => ClawdEx.Tools.SessionsHistory,
    "sessions_list" => ClawdEx.Tools.SessionsList,
    "sessions_send" => ClawdEx.Tools.SessionsSend,
    "sessions_spawn" => ClawdEx.Tools.SessionsSpawn,
    "web_search" => ClawdEx.Tools.WebSearch,
    "web_fetch" => ClawdEx.Tools.WebFetch,
    "compact" => ClawdEx.Tools.Compact,
    "agents_list" => ClawdEx.Tools.AgentsList,
    "gateway" => ClawdEx.Tools.Gateway,
    "cron" => ClawdEx.Tools.Cron,
    "message" => ClawdEx.Tools.Message,
    "browser" => ClawdEx.Tools.Browser,
    "nodes" => ClawdEx.Tools.Nodes,
    "canvas" => ClawdEx.Tools.Canvas
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

  @doc """
  执行工具
  """
  @spec execute(String.t(), map(), map()) :: {:ok, any()} | {:error, term()}
  def execute(tool_name, params, context) do
    case Map.get(@tools, tool_name) do
      nil ->
        Logger.warning("Tool not found: #{tool_name}")
        {:error, :tool_not_found}

      module ->
        try do
          module.execute(params, context)
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
    case Map.get(@tools, tool_name) do
      nil ->
        nil

      module ->
        %{
          name: module.name(),
          description: module.description(),
          parameters: module.parameters()
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
