defmodule ClawdEx.Security.ExecGuard do
  @moduledoc "检查 exec 命令是否需要审批"

  # 高风险命令模式
  @dangerous_patterns [
    ~r/\brm\s+-rf?\s/,
    ~r/\bsudo\b/,
    ~r/\bdd\s+if=/,
    ~r/\bmkfs\b/,
    ~r/\bformat\b/,
    ~r/\breboot\b/,
    ~r/\bshutdown\b/,
    ~r/\bkill\s+-9/,
    ~r/\bchmod\s+777/,
    ~r/\bcurl\b.*\|\s*(sh|bash)/,
    ~r/>\s*\/dev\/sd/,
    ~r/\bdrop\s+database\b/i,
    ~r/\btruncate\b/i
  ]

  @doc "Check if command needs approval. Returns :ok or {:needs_approval, reason}"
  def check(command) do
    if Application.get_env(:clawd_ex, :exec_approval, true) do
      case find_dangerous_pattern(command) do
        nil -> :ok
        reason -> {:needs_approval, reason}
      end
    else
      :ok
    end
  end

  def dangerous?(command) do
    check(command) != :ok
  end

  defp find_dangerous_pattern(command) do
    Enum.find_value(@dangerous_patterns, fn pattern ->
      if Regex.match?(pattern, command) do
        "Command matches dangerous pattern: #{inspect(pattern.source)}"
      end
    end)
  end
end
