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

  describe "name/0" do
    test "returns session_status" do
      assert SessionStatus.name() == "session_status"
    end
  end

  describe "parameters/0" do
    test "includes model property" do
      params = SessionStatus.parameters()
      assert params[:properties][:model]
      assert params[:properties][:model][:type] == "string"
    end

    test "includes session_key property" do
      params = SessionStatus.parameters()
      assert params[:properties][:session_key]
    end
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
    test "sets model_override when model parameter provided" do
      {_agent, session} = create_test_session()

      assert {:ok, status} =
               SessionStatus.execute(
                 %{"model" => "gpt-4-turbo"},
                 %{session_id: session.id}
               )

      assert String.contains?(status, "gpt-4-turbo")

      # Verify it was persisted
      updated = Repo.get!(Session, session.id)
      assert updated.model_override == "gpt-4-turbo"
    end

    test "updates existing model_override" do
      {_agent, session} = create_test_session(%{model_override: "old-model"})

      assert {:ok, status} =
               SessionStatus.execute(
                 %{"model" => "new-model"},
                 %{session_id: session.id}
               )

      assert String.contains?(status, "new-model")

      updated = Repo.get!(Session, session.id)
      assert updated.model_override == "new-model"
    end

    test "does not change model_override when model param is empty string" do
      {_agent, session} = create_test_session(%{model_override: "keep-me"})

      assert {:ok, status} =
               SessionStatus.execute(
                 %{"model" => ""},
                 %{session_id: session.id}
               )

      assert String.contains?(status, "keep-me")

      updated = Repo.get!(Session, session.id)
      assert updated.model_override == "keep-me"
    end

    test "does not change model_override when no model param" do
      {_agent, session} = create_test_session(%{model_override: "original"})

      assert {:ok, status} =
               SessionStatus.execute(%{}, %{session_id: session.id})

      assert String.contains?(status, "original")

      updated = Repo.get!(Session, session.id)
      assert updated.model_override == "original"
    end

    test "shows 'default' when no model_override set" do
      {_agent, session} = create_test_session()

      assert {:ok, status} =
               SessionStatus.execute(%{}, %{session_id: session.id})

      assert String.contains?(status, "default")
    end
  end
end
