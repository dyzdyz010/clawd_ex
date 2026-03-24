defmodule ClawdEx.ACP.Doctor do
  @moduledoc """
  Diagnostic tool for ACP agent availability.

  Checks whether each known CLI agent (claude, codex, gemini, pi) is
  installed, resolves its path, and extracts its version string.
  """

  require Logger

  @agents ["claude", "codex", "gemini", "pi"]

  @type agent_status :: %{
          available: boolean(),
          path: String.t() | nil,
          version: String.t() | nil
        }

  @type check_result :: %{
          agents: [{String.t(), agent_status()}],
          summary: String.t()
        }

  @doc """
  Run a full diagnostic check on all known agents.

  Returns a map with `:agents` (list of `{name, status}` tuples) and
  a human-readable `:summary`.
  """
  @spec check() :: check_result()
  def check do
    results =
      Enum.map(@agents, fn agent ->
        {agent, check_agent(agent)}
      end)

    %{agents: results, summary: format_summary(results)}
  end

  @doc """
  Check a single agent by name.
  """
  @spec check_agent(String.t()) :: agent_status()
  def check_agent(name) do
    case System.find_executable(name) do
      nil ->
        %{available: false, path: nil, version: nil}

      path ->
        version = get_version(name, path)
        %{available: true, path: path, version: version}
    end
  end

  @doc """
  Return the list of agent names that are checked.
  """
  @spec known_agents() :: [String.t()]
  def known_agents, do: @agents

  # ============================================================================
  # Version Extraction
  # ============================================================================

  @doc false
  def get_version(name, path) do
    version_args = version_args_for(name)

    try do
      case System.cmd(path, version_args, stderr_to_stdout: true) do
        {output, 0} ->
          extract_version(output)

        {output, _code} ->
          # Some CLIs return non-zero for --version (looking at you, codex)
          extract_version(output)
      end
    rescue
      e ->
        Logger.debug("[Doctor] Failed to get version for #{name}: #{Exception.message(e)}")
        nil
    catch
      :error, _ -> nil
    end
  end

  defp version_args_for("claude"), do: ["--version"]
  defp version_args_for("codex"), do: ["--version"]
  defp version_args_for("gemini"), do: ["--version"]
  defp version_args_for("pi"), do: ["--version"]
  defp version_args_for(_), do: ["--version"]

  @doc """
  Extract a version string from CLI output.

  Handles common formats:
  - "claude 2.1.76"
  - "v0.110.0"
  - "0.28.2"
  - "version 1.2.3"
  """
  @spec extract_version(String.t()) :: String.t() | nil
  def extract_version(output) do
    output = String.trim(output)

    cond do
      # "tool v1.2.3" or "tool 1.2.3"
      match = Regex.run(~r/v?(\d+\.\d+\.\d+(?:-[\w.]+)?)/, output) ->
        Enum.at(match, 1)

      # Just a bare version on a line
      match = Regex.run(~r/^(\d+\.\d+\.\d+)$/m, output) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  # ============================================================================
  # Summary Formatting
  # ============================================================================

  defp format_summary(results) do
    available = Enum.filter(results, fn {_, s} -> s.available end)
    unavailable = Enum.filter(results, fn {_, s} -> not s.available end)

    parts = []

    parts =
      if length(available) > 0 do
        agents_str =
          available
          |> Enum.map(fn {name, s} ->
            v = if s.version, do: " (#{s.version})", else: ""
            "#{name}#{v}"
          end)
          |> Enum.join(", ")

        parts ++ ["✅ Available: #{agents_str}"]
      else
        parts ++ ["⚠️  No agents available"]
      end

    parts =
      if length(unavailable) > 0 do
        names = unavailable |> Enum.map(fn {name, _} -> name end) |> Enum.join(", ")
        parts ++ ["❌ Not found: #{names}"]
      else
        parts
      end

    Enum.join(parts, "\n")
  end
end
