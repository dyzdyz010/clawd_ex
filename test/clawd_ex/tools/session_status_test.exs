defmodule ClawdEx.Tools.SessionStatusTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.SessionStatus
  alias ClawdEx.Sessions.Session
  alias ClawdEx.Agents.Agent

  @moduletag :session_status

  defp create_test_session(attrs \\ %{}) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "session-status-test-#{System.unique_integer([:positive])}"})
      |> Repo.insert()

    defaults = %{
      session_key: "status-test-#{System.unique_integer([:positive])}",
      channel: "test",
      agent_id: agent.id,
      state: :active,
      message_count: 5,
      token_count: 1000,
      last_activity_at: DateTime.utc_now()
    }

    {:ok, session} =
      %Session{}
      |> Session.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    {agent, session}
  end

  describe "execute/2 - basic status" do
    test "returns session status" do
      {_agent, session} = create_test_session()

      assert {:ok, status} =
               SessionStatus.execute(%{}, %{session_id: session.id})

      assert is_binary(status)
      assert String.contains?(status, session.session_key)
      assert String.contains?(status, "active")
    end

    test "returns error when no session context" do
      assert {:error, "No session context available"} =
               SessionStatus.execute(%{}, %{})
    end

    test "returns error for non-existent session" do
      assert {:error, "Session not found"} =
               SessionStatus.execute(%{}, %{session_id: -1})
    end
  end

  describe "execute/2 - model override" do
    test "sets, updates, and persists model_override" do
      {_agent, session} = create_test_session()

      # Set model
      assert {:ok, status} =
               SessionStatus.execute(%{"model" => "anthropic/claude-sonnet-4-5"}, %{session_id: session.id})
      assert String.contains?(status, "anthropic/claude-sonnet-4-5")
      assert Repo.get!(Session, session.id).model_override == "anthropic/claude-sonnet-4-5"

      # Update model
      assert {:ok, status} =
               SessionStatus.execute(%{"model" => "opus"}, %{session_id: session.id})
      assert String.contains?(status, "opus")
      assert Repo.get!(Session, session.id).model_override == "opus"

      # Accepts alias
      assert {:ok, _} = SessionStatus.execute(%{"model" => "sonnet"}, %{session_id: session.id})
      assert Repo.get!(Session, session.id).model_override == "sonnet"
    end

    test "does not change model_override when param is empty or absent" do
      {_agent, session} = create_test_session(%{model_override: "keep-me"})

      # Empty string
      assert {:ok, _} = SessionStatus.execute(%{"model" => ""}, %{session_id: session.id})
      assert Repo.get!(Session, session.id).model_override == "keep-me"

      # No model param
      assert {:ok, _} = SessionStatus.execute(%{}, %{session_id: session.id})
      assert Repo.get!(Session, session.id).model_override == "keep-me"
    end

    test "shows 'default' when no model_override and resets with 'default'/'Default'" do
      {_agent, session} = create_test_session()

      assert {:ok, status} = SessionStatus.execute(%{}, %{session_id: session.id})
      assert String.contains?(status, "default")

      # Set then reset with "default"
      SessionStatus.execute(%{"model" => "opus"}, %{session_id: session.id})
      assert {:ok, _} = SessionStatus.execute(%{"model" => "default"}, %{session_id: session.id})
      assert is_nil(Repo.get!(Session, session.id).model_override)

      # Reset with "Default" (case insensitive)
      SessionStatus.execute(%{"model" => "opus"}, %{session_id: session.id})
      assert {:ok, _} = SessionStatus.execute(%{"model" => "Default"}, %{session_id: session.id})
      assert is_nil(Repo.get!(Session, session.id).model_override)
    end

    test "returns error for unknown model and does not change override" do
      {_agent, session} = create_test_session()

      assert {:error, msg} =
               SessionStatus.execute(%{"model" => "nonexistent-model-xyz"}, %{session_id: session.id})
      assert String.contains?(msg, "Unknown model")
      assert is_nil(Repo.get!(Session, session.id).model_override)
    end
  end
end
