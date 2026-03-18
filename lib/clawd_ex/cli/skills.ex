defmodule ClawdEx.CLI.Skills do
  @moduledoc """
  CLI skills command - list loaded skills.

  Usage:
    clawd_ex skills list
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
      list    List all loaded skills

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
      --help  Show this help message
    """)
  end
end
