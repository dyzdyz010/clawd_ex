defmodule ClawdEx.CLI.Skills do
  @moduledoc """
  CLI skills command - list, inspect, and refresh loaded skills.

  Usage:
    clawd_ex skills list [--source bundled|managed|workspace] [--search term]
    clawd_ex skills info <name>
    clawd_ex skills refresh
  """

  alias ClawdEx.Skills.Manager

  def run(args, opts \\ [])

  def run(["list" | _rest], opts) do
    if opts[:help] do
      print_list_help()
    else
      list_skills(opts)
    end
  end

  def run(["info", name | _rest], opts) do
    if opts[:help] do
      print_info_help()
    else
      show_skill_info(name)
    end
  end

  def run(["info" | _], _opts) do
    IO.puts("Usage: clawd_ex skills info <name>\n")
    IO.puts("Provide a skill name to inspect.")
  end

  def run(["refresh" | _rest], opts) do
    if opts[:help] do
      print_refresh_help()
    else
      refresh_skills()
    end
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown skills subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # skills list
  # ---------------------------------------------------------------------------

  defp list_skills(opts) do
    skills =
      try do
        filter_opts = build_filter_opts(opts)
        Manager.list_skills(filter_opts)
      catch
        :exit, _ ->
          IO.puts("✗ Skills Manager is not running.")
          []
      end

    disabled =
      try do
        Manager.disabled_set()
      catch
        :exit, _ -> MapSet.new()
      end

    if Enum.empty?(skills) do
      IO.puts("No skills loaded.")
    else
      IO.puts("""
      ┌─────────────────────────────────────────────────────────────────────────────────┐
      │                              Loaded Skills                                     │
      └─────────────────────────────────────────────────────────────────────────────────┘
      """)

      IO.puts(
        "  " <>
          String.pad_trailing("NAME", 24) <>
          String.pad_trailing("ENABLED", 10) <>
          String.pad_trailing("SOURCE", 12) <>
          "DESCRIPTION"
      )

      IO.puts("  " <> String.duplicate("─", 76))

      skills
      |> Enum.sort_by(& &1.name)
      |> Enum.each(fn skill ->
        enabled = if MapSet.member?(disabled, skill.name), do: "✗", else: "✓"
        source = skill.source |> to_string()
        desc = truncate(skill.description || "—", 30)

        IO.puts(
          "  " <>
            String.pad_trailing(truncate(skill.name, 22), 24) <>
            String.pad_trailing(enabled, 10) <>
            String.pad_trailing(source, 12) <>
            desc
        )
      end)

      enabled_count = Enum.count(skills, fn s -> not MapSet.member?(disabled, s.name) end)
      disabled_count = length(skills) - enabled_count

      IO.puts("")
      IO.puts("  Total: #{length(skills)} skills (#{enabled_count} enabled, #{disabled_count} disabled)")
    end
  end

  defp build_filter_opts(opts) do
    filter_opts = []
    filter_opts = if opts[:source], do: [{:source, String.to_atom(opts[:source])} | filter_opts], else: filter_opts
    filter_opts = if opts[:search], do: [{:search, opts[:search]} | filter_opts], else: filter_opts
    filter_opts
  end

  # ---------------------------------------------------------------------------
  # skills info <name>
  # ---------------------------------------------------------------------------

  defp show_skill_info(name) do
    result =
      try do
        Manager.get_skill_info(name)
      catch
        :exit, _ ->
          IO.puts("✗ Skills Manager is not running.")
          :error
      end

    case result do
      {:ok, info} ->
        skill = info.skill

        IO.puts("""
        ┌─────────────────────────────────────────────────────────────────────────────────┐
        │  Skill: #{String.pad_trailing(skill.name, 68)}│
        └─────────────────────────────────────────────────────────────────────────────────┘

          Name:        #{skill.name}
          Description: #{skill.description}
          Source:      #{skill.source}
          Location:    #{skill.location}
          Eligible:    #{if info.eligible, do: "✓", else: "✗"}
          Disabled:    #{if info.disabled, do: "✓ (manually disabled)", else: "✗"}
        """)

        case info.gate_status do
          status when is_map(status) and map_size(status) > 0 ->
            IO.puts("  Gate Requirements:")

            Enum.each(status, fn {req, met?} ->
              icon = if met?, do: "✓", else: "✗"
              IO.puts("    #{icon} #{req}")
            end)

            IO.puts("")

          _ ->
            IO.puts("  Gate Requirements: none\n")
        end

        if skill.metadata != %{} do
          IO.puts("  Metadata:")

          Enum.each(skill.metadata, fn {k, v} ->
            IO.puts("    #{k}: #{inspect(v)}")
          end)

          IO.puts("")
        end

      {:error, :not_found} ->
        IO.puts("✗ Skill '#{name}' not found.")
        IO.puts("  Use 'clawd_ex skills list' to see available skills.")

      :error ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # skills refresh
  # ---------------------------------------------------------------------------

  defp refresh_skills do
    IO.puts("Refreshing skills from disk...")

    try do
      {:ok, skills} = Manager.load_all_skills()
      IO.puts("✓ Reloaded #{length(skills)} skill(s) from disk.")

      enabled_count =
        try do
          disabled = Manager.disabled_set()
          Enum.count(skills, fn s -> not MapSet.member?(disabled, s.name) end)
        catch
          :exit, _ -> length(skills)
        end

      IO.puts("  #{enabled_count} enabled, #{length(skills) - enabled_count} disabled.")
    catch
      :exit, _ ->
        IO.puts("✗ Skills Manager is not running.")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 1) <> "…"
    else
      str
    end
  end

  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------

  defp print_help do
    IO.puts("""
    Usage: clawd_ex skills <subcommand> [options]

    Subcommands:
      list      List all loaded skills
      info      Show detailed info for a skill
      refresh   Reload all skills from disk

    Options:
      --help  Show this help message
    """)
  end

  defp print_list_help do
    IO.puts("""
    Usage: clawd_ex skills list [options]

    List all loaded skills with their status.
    Shows name, enabled state, source, and description.

    Options:
      --source <bundled|managed|workspace>  Filter by source
      --search <term>                       Search by name or description
      --help                                Show this help message
    """)
  end

  defp print_info_help do
    IO.puts("""
    Usage: clawd_ex skills info <name>

    Show detailed information for a specific skill, including:
    - Description, source, and location
    - Gate eligibility and requirement status
    - Enabled/disabled state
    - Metadata

    Options:
      --help  Show this help message
    """)
  end

  defp print_refresh_help do
    IO.puts("""
    Usage: clawd_ex skills refresh

    Reload all skills from disk (bundled, managed, workspace, and extra dirs).
    Useful after adding or modifying skill files without restarting the server.

    Options:
      --help  Show this help message
    """)
  end
end
