defmodule ClawdEx.Security.ExecGuard do
  @moduledoc """
  检查 exec 命令是否需要审批。

  Supports:
  - Global dangerous pattern detection
  - Per-agent extra blocked command patterns (stored in agent.extra_denied_commands)
  - Config-based disable via :exec_approval
  """

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

  @doc """
  Check if command needs approval.

  Returns :ok or {:needs_approval, reason}.

  Accepts optional extra_patterns (list of regex strings) for per-agent blocking.
  """
  def check(command, extra_patterns \\ []) do
    if Application.get_env(:clawd_ex, :exec_approval, true) do
      case find_dangerous_pattern(command) do
        nil ->
          case find_extra_pattern(command, extra_patterns) do
            nil -> :ok
            reason -> {:needs_approval, reason}
          end

        reason ->
          {:needs_approval, reason}
      end
    else
      :ok
    end
  end

  @doc "Returns true if command matches any dangerous pattern"
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

  defp find_extra_pattern(_command, []), do: nil

  defp find_extra_pattern(command, extra_patterns) when is_list(extra_patterns) do
    Enum.find_value(extra_patterns, fn pattern_str ->
      case Regex.compile(pattern_str) do
        {:ok, regex} ->
          if Regex.match?(regex, command) do
            "Command matches agent-specific blocked pattern: #{pattern_str}"
          end

        {:error, _} ->
          nil
      end
    end)
  end
end
