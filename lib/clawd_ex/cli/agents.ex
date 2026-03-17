defmodule ClawdEx.CLI.Agents do
  @moduledoc """
  CLI agents command - list and manage agents.

  Usage:
    clawd_ex agents list
    clawd_ex agents add <name> [--model MODEL] [--system-prompt PROMPT]
  """

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  def run(args, opts \\ [])

  def run(["list" | _rest], opts) do
    if opts[:help] do
      print_list_help()
    else
      list_agents(opts)
    end
  end

  def run(["add", name | _rest], opts) do
    if opts[:help] do
      print_add_help()
    else
      add_agent(name, opts)
    end
  end

  def run(["add" | _rest], _opts) do
    IO.puts("Error: agent name is required.\n")
    print_add_help()
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown agents subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # agents list
  # ---------------------------------------------------------------------------

  defp list_agents(_opts) do
    agents =
      Agent
      |> order_by([a], asc: a.name)
      |> Repo.all()

    if Enum.empty?(agents) do
      IO.puts("No agents found.")
    else
      IO.puts("""
      ┌─────────────────────────────────────────────────────────────────────────────────┐
      │                                Agents                                          │
      └─────────────────────────────────────────────────────────────────────────────────┘
      """)

      IO.puts(
        String.pad_trailing("ID", 6) <>
          String.pad_trailing("NAME", 24) <>
          String.pad_trailing("MODEL", 30) <>
          String.pad_trailing("ACTIVE", 8) <>
          "SESSIONS"
      )

      IO.puts(String.duplicate("─", 80))

      Enum.each(agents, fn agent ->
        session_count = count_sessions(agent.id)

        IO.puts(
          String.pad_trailing(to_string(agent.id), 6) <>
            String.pad_trailing(truncate(agent.name, 22), 24) <>
            String.pad_trailing(truncate(agent.default_model || "—", 28), 30) <>
            String.pad_trailing(if(agent.active, do: "✓", else: "✗"), 8) <>
            to_string(session_count)
        )
      end)

      IO.puts("")
      IO.puts("Total: #{length(agents)} agents")
    end
  end

  defp count_sessions(agent_id) do
    ClawdEx.Sessions.Session
    |> where([s], s.agent_id == ^agent_id)
    |> select([s], count(s.id))
    |> Repo.one() || 0
  end

  # ---------------------------------------------------------------------------
  # agents add
  # ---------------------------------------------------------------------------

  defp add_agent(name, opts) do
    {parsed, _, _} =
      OptionParser.parse([], switches: [model: :string, system_prompt: :string])

    model = opts[:model] || parsed[:model]
    system_prompt = opts[:system_prompt] || parsed[:system_prompt]

    attrs = %{name: name}
    attrs = if model, do: Map.put(attrs, :default_model, model), else: attrs
    attrs = if system_prompt, do: Map.put(attrs, :system_prompt, system_prompt), else: attrs

    case %Agent{} |> Agent.changeset(attrs) |> Repo.insert() do
      {:ok, agent} ->
        IO.puts("""
        ✓ Agent created successfully!

          ID:     #{agent.id}
          Name:   #{agent.name}
          Model:  #{agent.default_model || "default"}
          Active: #{agent.active}
        """)

      {:error, changeset} ->
        IO.puts("✗ Failed to create agent:")

        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
            opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
          end)
        end)
        |> Enum.each(fn {field, errors} ->
          Enum.each(errors, fn error ->
            IO.puts("  #{field}: #{error}")
          end)
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp truncate(nil, _max), do: "—"

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
    Usage: clawd_ex agents <subcommand> [options]

    Subcommands:
      list                  List all agents
      add <name>            Create a new agent

    Options:
      --help                Show this help message
    """)
  end

  defp print_list_help do
    IO.puts("""
    Usage: clawd_ex agents list [options]

    List all configured agents.

    Options:
      --help    Show this help message
    """)
  end

  defp print_add_help do
    IO.puts("""
    Usage: clawd_ex agents add <name> [options]

    Create a new agent.

    Options:
      --model MODEL              Set the default model
      --system-prompt PROMPT     Set the system prompt
      --help                     Show this help message
    """)
  end
end
