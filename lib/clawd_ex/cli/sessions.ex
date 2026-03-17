defmodule ClawdEx.CLI.Sessions do
  @moduledoc """
  CLI sessions command - list active sessions and view session history.

  Usage:
    clawd_ex sessions list [--limit N]
    clawd_ex sessions history <session_key> [--limit N]
  """

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Sessions.{Session, Message, SessionManager}

  def run(args, opts \\ [])

  def run(["list" | _rest], opts) do
    if opts[:help] do
      print_list_help()
    else
      list_sessions(opts)
    end
  end

  def run(["history", session_key | _rest], opts) do
    if opts[:help] do
      print_history_help()
    else
      show_history(session_key, opts)
    end
  end

  def run(["history" | _rest], _opts) do
    IO.puts("Error: session_key is required.\n")
    print_history_help()
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown sessions subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # sessions list
  # ---------------------------------------------------------------------------

  defp list_sessions(opts) do
    {parse_opts, _, _} =
      OptionParser.parse([], switches: [limit: :integer], aliases: [l: :limit])

    limit = opts[:limit] || parse_opts[:limit] || 50

    # Get active session keys from SessionManager (in-memory workers)
    active_keys = SessionManager.list_sessions()

    # Also query DB for recent sessions
    sessions =
      Session
      |> order_by([s], desc: s.last_activity_at)
      |> limit(^limit)
      |> preload(:agent)
      |> Repo.all()

    if Enum.empty?(sessions) do
      IO.puts("No sessions found.")
    else
      IO.puts("""
      ┌─────────────────────────────────────────────────────────────────────────────────┐
      │                              Sessions                                          │
      └─────────────────────────────────────────────────────────────────────────────────┘
      """)

      # Header
      IO.puts(
        String.pad_trailing("SESSION KEY", 40) <>
          String.pad_trailing("AGENT", 16) <>
          String.pad_trailing("CHANNEL", 10) <>
          String.pad_trailing("MSGS", 6) <>
          String.pad_trailing("ACTIVE", 8) <>
          "LAST ACTIVITY"
      )

      IO.puts(String.duplicate("─", 110))

      Enum.each(sessions, fn session ->
        is_active = session.session_key in active_keys
        agent_name = if session.agent, do: session.agent.name, else: "—"

        last_activity =
          if session.last_activity_at do
            format_datetime(session.last_activity_at)
          else
            "—"
          end

        IO.puts(
          String.pad_trailing(truncate(session.session_key, 38), 40) <>
            String.pad_trailing(truncate(agent_name, 14), 16) <>
            String.pad_trailing(session.channel || "—", 10) <>
            String.pad_trailing(to_string(session.message_count || 0), 6) <>
            String.pad_trailing(if(is_active, do: "✓", else: "—"), 8) <>
            last_activity
        )
      end)

      IO.puts("")
      IO.puts("Total: #{length(sessions)} sessions (#{length(active_keys)} active workers)")
    end
  end

  # ---------------------------------------------------------------------------
  # sessions history
  # ---------------------------------------------------------------------------

  defp show_history(session_key, opts) do
    limit = opts[:limit] || 20

    session =
      Session
      |> where([s], s.session_key == ^session_key)
      |> preload(:agent)
      |> Repo.one()

    case session do
      nil ->
        IO.puts("Session not found: #{session_key}")

      session ->
        messages =
          Message
          |> where([m], m.session_id == ^session.id)
          |> order_by([m], desc: m.inserted_at)
          |> limit(^limit)
          |> Repo.all()
          |> Enum.reverse()

        agent_name = if session.agent, do: session.agent.name, else: "—"

        IO.puts("""
        ┌─────────────────────────────────────────────────────────────────────────────────┐
        │                           Session History                                      │
        └─────────────────────────────────────────────────────────────────────────────────┘

        Session:  #{session.session_key}
        Agent:    #{agent_name}
        Channel:  #{session.channel || "—"}
        State:    #{session.state}
        Messages: #{session.message_count || 0}
        """)

        if Enum.empty?(messages) do
          IO.puts("  No messages found.")
        else
          IO.puts(String.duplicate("─", 80))

          Enum.each(messages, fn msg ->
            role_tag = format_role(msg.role)
            timestamp = format_datetime(msg.inserted_at)
            content = truncate(msg.content || "", 200)

            IO.puts("  #{role_tag} [#{timestamp}]")
            IO.puts("  #{content}")
            IO.puts("")
          end)

          IO.puts("Showing #{length(messages)} of #{session.message_count || 0} messages")
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp format_role(:user), do: "👤 user"
  defp format_role(:assistant), do: "🤖 assistant"
  defp format_role(:system), do: "⚙️  system"
  defp format_role(:tool), do: "🔧 tool"
  defp format_role(role), do: "   #{role}"

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime(_), do: "—"

  defp truncate(nil, _max), do: "—"

  defp truncate(str, max) when is_binary(str) do
    str = String.replace(str, "\n", " ")

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
    Usage: clawd_ex sessions <subcommand> [options]

    Subcommands:
      list                      List sessions
      history <session_key>     Show session message history

    Options:
      --limit N    Maximum number of results (default: 50 for list, 20 for history)
      --help       Show this help message
    """)
  end

  defp print_list_help do
    IO.puts("""
    Usage: clawd_ex sessions list [options]

    List all sessions with their status.

    Options:
      --limit N    Maximum number of sessions to show (default: 50)
      --help       Show this help message
    """)
  end

  defp print_history_help do
    IO.puts("""
    Usage: clawd_ex sessions history <session_key> [options]

    Show message history for a specific session.

    Options:
      --limit N    Maximum number of messages to show (default: 20)
      --help       Show this help message
    """)
  end
end
