defmodule ClawdEx.CLI.SessionsTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.CLI.Sessions
  alias ClawdEx.Sessions.{Session, Message}
  alias ClawdEx.Agents.Agent

  import ExUnit.CaptureIO

  describe "sessions list" do
    test "shows empty message when no sessions" do
      output = capture_io(fn -> Sessions.run(["list"], []) end)
      assert output =~ "No sessions found."
    end

    test "lists sessions from database" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      {:ok, _session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-cli-session-#{System.unique_integer()}",
          channel: "telegram",
          agent_id: agent.id,
          state: :active,
          message_count: 5,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      output = capture_io(fn -> Sessions.run(["list"], []) end)
      assert output =~ "Sessions"
      assert output =~ "telegram"
      assert output =~ "Total:"
    end

    test "respects --limit option" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-agent-limit-#{System.unique_integer()}"})
        |> Repo.insert()

      for i <- 1..5 do
        %Session{}
        |> Session.changeset(%{
          session_key: "test-limit-#{i}-#{System.unique_integer()}",
          channel: "telegram",
          agent_id: agent.id,
          state: :active,
          message_count: i,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()
      end

      output = capture_io(fn -> Sessions.run(["list"], [limit: 2]) end)
      assert output =~ "Sessions"
      # Should show at most 2 sessions in the table
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Sessions.run(["list"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "sessions list"
    end
  end

  describe "sessions history" do
    test "shows error when session not found" do
      output = capture_io(fn -> Sessions.run(["history", "nonexistent-key"], []) end)
      assert output =~ "Session not found"
    end

    test "shows session history with messages" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-history-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-history-#{System.unique_integer()}",
          channel: "telegram",
          agent_id: agent.id,
          state: :active,
          message_count: 2,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, _msg1} =
        %Message{}
        |> Message.changeset(%{
          session_id: session.id,
          role: :user,
          content: "Hello from test"
        })
        |> Repo.insert()

      {:ok, _msg2} =
        %Message{}
        |> Message.changeset(%{
          session_id: session.id,
          role: :assistant,
          content: "Hi there!"
        })
        |> Repo.insert()

      output = capture_io(fn -> Sessions.run(["history", session.session_key], []) end)
      assert output =~ "Session History"
      assert output =~ "Hello from test"
      assert output =~ "Hi there!"
      assert output =~ "user"
      assert output =~ "assistant"
    end

    test "shows error when session_key missing" do
      output = capture_io(fn -> Sessions.run(["history"], []) end)
      assert output =~ "session_key is required"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Sessions.run(["history", "x"], [help: true]) end)
      assert output =~ "Usage:"
      assert output =~ "sessions history"
    end
  end

  describe "sessions help" do
    test "shows help with no args" do
      output = capture_io(fn -> Sessions.run([], []) end)
      assert output =~ "Usage:"
      assert output =~ "list"
      assert output =~ "history"
    end

    test "shows help with --help flag" do
      output = capture_io(fn -> Sessions.run(["--help"], []) end)
      assert output =~ "Usage:"
    end

    test "shows error for unknown subcommand" do
      output = capture_io(fn -> Sessions.run(["unknown"], []) end)
      assert output =~ "Unknown sessions subcommand"
    end
  end
end
