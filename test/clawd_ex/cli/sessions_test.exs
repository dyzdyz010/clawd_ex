defmodule ClawdEx.CLI.SessionsTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.CLI.Sessions
  alias ClawdEx.Sessions.{Session, Message}
  alias ClawdEx.Agents.Agent

  import ExUnit.CaptureIO

  test "sessions list shows sessions from database" do
    output = capture_io(fn -> Sessions.run(["list"], []) end)
    assert output =~ "No sessions found."

    {:ok, agent} =
      %Agent{} |> Agent.changeset(%{name: "test-agent-#{System.unique_integer()}"}) |> Repo.insert()

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

  test "sessions history shows messages" do
    {:ok, agent} =
      %Agent{} |> Agent.changeset(%{name: "test-history-agent-#{System.unique_integer()}"}) |> Repo.insert()

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

    %Message{} |> Message.changeset(%{session_id: session.id, role: :user, content: "Hello from test"}) |> Repo.insert!()
    %Message{} |> Message.changeset(%{session_id: session.id, role: :assistant, content: "Hi there!"}) |> Repo.insert!()

    output = capture_io(fn -> Sessions.run(["history", session.session_key], []) end)
    assert output =~ "Session History"
    assert output =~ "Hello from test"
    assert output =~ "Hi there!"
  end

  test "sessions history errors for missing/nonexistent session" do
    output = capture_io(fn -> Sessions.run(["history"], []) end)
    assert output =~ "session_key is required"

    output = capture_io(fn -> Sessions.run(["history", "nonexistent-key"], []) end)
    assert output =~ "Session not found"
  end

  test "shows help with no args or --help" do
    for args <- [[], ["--help"]] do
      output = capture_io(fn -> Sessions.run(args, []) end)
      assert output =~ "Usage:"
    end
  end

  test "shows error for unknown subcommand" do
    output = capture_io(fn -> Sessions.run(["unknown"], []) end)
    assert output =~ "Unknown sessions subcommand"
  end
end
