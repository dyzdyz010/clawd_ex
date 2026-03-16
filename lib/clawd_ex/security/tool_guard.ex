defmodule ClawdEx.Security.ToolGuard do
  @moduledoc """
  工具权限守卫 — 在工具执行前检查 allow/deny 列表、命令模式黑名单、
  高权限命令审批队列、以及 per-session 限制。
  """

  require Logger

  @doc """
  Check whether a tool invocation is permitted.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec check_permission(String.t(), map(), map()) :: :ok | {:error, term()}
  def check_permission(tool_name, params, context) do
    with :ok <- check_session_restrictions(tool_name, context),
         :ok <- check_tool_lists(tool_name, context),
         :ok <- check_command_blocklist(tool_name, params) do
      check_elevated_commands(tool_name, params, context)
    end
  end

  # ============================================================================
  # Session-level tool restrictions
  # ============================================================================

  defp check_session_restrictions(tool_name, context) do
    session_allow = Map.get(context, :tool_allow, ["*"])
    session_deny = Map.get(context, :tool_deny, [])

    cond do
      tool_name in session_deny or "*" in session_deny ->
        {:error, {:tool_denied, "Tool '#{tool_name}' is denied for this session"}}

      "*" in session_allow or tool_name in session_allow ->
        :ok

      true ->
        {:error, {:tool_denied, "Tool '#{tool_name}' is not in the session allow list"}}
    end
  end

  # ============================================================================
  # Global allow/deny lists (from application config)
  # ============================================================================

  defp check_tool_lists(tool_name, _context) do
    config = Application.get_env(:clawd_ex, :security, [])
    denied_tools = Keyword.get(config, :denied_tools, [])
    allowed_tools = Keyword.get(config, :allowed_tools, ["*"])

    cond do
      tool_name in denied_tools ->
        {:error, {:tool_denied, "Tool '#{tool_name}' is globally denied"}}

      "*" in allowed_tools or tool_name in allowed_tools ->
        :ok

      true ->
        {:error, {:tool_denied, "Tool '#{tool_name}' is not in the global allow list"}}
    end
  end

  # ============================================================================
  # Command pattern blocklist (for exec tool)
  # ============================================================================

  @dangerous_patterns [
    ~r/rm\s+(-rf?|--recursive)\s+\/\s*$/,
    ~r/rm\s+(-rf?|--recursive)\s+\/\*/,
    ~r/mkfs\./,
    ~r/dd\s+.*of=\/dev\/[sh]d/,
    ~r/:\(\)\s*\{\s*:\|\:\s*&\s*\}\s*;/,
    ~r/>\s*\/dev\/[sh]d/,
    ~r/chmod\s+(-R\s+)?777\s+\//,
    ~r/curl\s+.*\|\s*(ba)?sh/,
    ~r/wget\s+.*\|\s*(ba)?sh/,
    ~r/eval\s+.*\$\(/
  ]

  defp check_command_blocklist("exec", params) do
    command = params["command"] || params[:command] || ""

    case Enum.find(@dangerous_patterns, &Regex.match?(&1, command)) do
      nil ->
        :ok

      pattern ->
        Logger.warning("Blocked dangerous command: #{command} (matched #{inspect(pattern)})")
        {:error, {:command_blocked, "Command matches a blocked pattern"}}
    end
  end

  defp check_command_blocklist(_tool, _params), do: :ok

  # ============================================================================
  # Elevated command approval
  # ============================================================================

  @elevated_patterns [
    ~r/sudo\s+/,
    ~r/docker\s+run/,
    ~r/kubectl\s+(delete|apply|exec)/,
    ~r/systemctl\s+(stop|restart|disable)/,
    ~r/iptables\s+/,
    ~r/rm\s+(-rf?|--recursive)/
  ]

  defp check_elevated_commands("exec", params, context) do
    command = params["command"] || params[:command] || ""
    auto_approve = Map.get(context, :auto_approve_elevated, false)

    if auto_approve do
      :ok
    else
      case Enum.find(@elevated_patterns, &Regex.match?(&1, command)) do
        nil ->
          :ok

        _pattern ->
          # Check if this command has been pre-approved in the session
          approved = Map.get(context, :approved_commands, [])

          if command in approved do
            :ok
          else
            {:error,
             {:elevated_command,
              "Command requires approval: #{String.slice(command, 0, 100)}"}}
          end
      end
    end
  end

  defp check_elevated_commands(_tool, _params, _context), do: :ok
end
