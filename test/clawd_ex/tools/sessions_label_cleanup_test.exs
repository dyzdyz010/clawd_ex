defmodule ClawdEx.Tools.SessionsLabelCleanupTest do
  @moduledoc """
  Tests for label and cleanup features across sessions_spawn, sessions_list, and sessions_send.
  """
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.{SessionsSpawn, SessionsList, SessionsSend}
  alias ClawdEx.Sessions.{Session, SessionManager}
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Repo

  # ============================================================================
  # Label stored in metadata on spawn
  # ============================================================================

  describe "label stored in metadata on spawn" do
    setup do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "label-meta-test-#{System.unique_integer()}"})
        |> Repo.insert()

      context = %{
        session_id: 1,
        session_key: "test:label:parent",
        agent_id: agent.id,
        config: %{workspace: "/tmp"}
      }

      on_exit(fn ->
        SessionManager.list_sessions()
        |> Enum.filter(&String.contains?(&1, "subagent"))
        |> Enum.each(&SessionManager.stop_session/1)
      end)

      %{agent: agent, context: context}
    end

    test "spawn stores label and cleanup in session metadata", %{context: context} do
      # With label
      params = %{"task" => "test label storage", "label" => "my-worker", "cleanup" => "keep"}
      assert {:ok, result} = SessionsSpawn.execute(params, context)
      child_key = result.childSessionKey
      assert result.label == "my-worker"

      Process.sleep(200)

      session = Repo.get_by(Session, session_key: child_key)
      assert session != nil
      assert session.metadata["label"] == "my-worker"
      assert session.metadata["cleanup"] == "keep"
    end

    test "spawn without label does not set label", %{context: context} do
      params = %{"task" => "no label task"}
      assert {:ok, result} = SessionsSpawn.execute(params, context)
      refute Map.has_key?(result, :label)

      Process.sleep(200)

      session = Repo.get_by(Session, session_key: result.childSessionKey)
      assert session != nil
      refute Map.has_key?(session.metadata, "label")
    end
  end

  # ============================================================================
  # sessions_list label filtering
  # ============================================================================

  describe "sessions_list label filtering" do
    setup do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "list-label-test-#{System.unique_integer()}"})
        |> Repo.insert()

      {:ok, session_a} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-label-a-#{System.unique_integer()}",
          channel: "subagent",
          agent_id: agent.id,
          state: :active,
          metadata: %{"label" => "worker-alpha"},
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, session_b} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-label-b-#{System.unique_integer()}",
          channel: "subagent",
          agent_id: agent.id,
          state: :active,
          metadata: %{"label" => "worker-beta"},
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, session_no_label} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-no-label-#{System.unique_integer()}",
          channel: "subagent",
          agent_id: agent.id,
          state: :active,
          metadata: %{},
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, _} = Registry.register(ClawdEx.SessionRegistry, session_a.session_key, %{})
      {:ok, _} = Registry.register(ClawdEx.SessionRegistry, session_b.session_key, %{})
      {:ok, _} = Registry.register(ClawdEx.SessionRegistry, session_no_label.session_key, %{})

      on_exit(fn ->
        Registry.unregister(ClawdEx.SessionRegistry, session_a.session_key)
        Registry.unregister(ClawdEx.SessionRegistry, session_b.session_key)
        Registry.unregister(ClawdEx.SessionRegistry, session_no_label.session_key)
      end)

      %{
        agent: agent,
        session_a: session_a,
        session_b: session_b,
        session_no_label: session_no_label
      }
    end

    test "filters sessions by label and shows label in output", %{session_a: session_a} do
      {:ok, result} = SessionsList.execute(%{"label" => "worker-alpha"}, %{})

      assert result.count == 1
      session_output = hd(result.sessions)
      assert session_output.sessionKey == session_a.session_key
      assert session_output.label == "worker-alpha"
    end

    test "returns empty when label not found" do
      {:ok, result} = SessionsList.execute(%{"label" => "nonexistent-label"}, %{})
      assert result.count == 0
      assert result.sessions == []
    end

    test "returns all sessions when no label filter", %{
      session_no_label: session_no_label
    } do
      {:ok, result} = SessionsList.execute(%{}, %{})
      assert result.count >= 3

      # Session without label should not have label key
      no_label_output =
        Enum.find(result.sessions, fn s -> s.sessionKey == session_no_label.session_key end)

      assert no_label_output != nil
      refute Map.has_key?(no_label_output, :label)
    end
  end

  # ============================================================================
  # sessions_send label addressing
  # ============================================================================

  describe "sessions_send label addressing" do
    test "returns error when neither sessionKey nor label provided" do
      result = SessionsSend.execute(%{"message" => "hello"}, %{})
      assert {:error, msg} = result
      assert msg =~ "sessionKey or label"
    end

    test "resolves label to session and returns error if label not found" do
      result =
        SessionsSend.execute(
          %{"label" => "ghost-label", "message" => "hello"},
          %{session_key: "sender"}
        )

      assert {:error, msg} = result
      assert msg =~ "sessionKey or label"
    end
  end

  # ============================================================================
  # sessions_send label addressing with real DB sessions
  # ============================================================================

  describe "sessions_send label addressing with DB" do
    setup do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "send-label-test-#{System.unique_integer()}"})
        |> Repo.insert()

      session_key = "test-send-label-#{System.unique_integer()}"

      {:ok, _session} =
        %Session{}
        |> Session.changeset(%{
          session_key: session_key,
          channel: "subagent",
          agent_id: agent.id,
          state: :active,
          metadata: %{"label" => "target-worker"},
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, _} = Registry.register(ClawdEx.SessionRegistry, session_key, %{})

      on_exit(fn ->
        Registry.unregister(ClawdEx.SessionRegistry, session_key)
      end)

      %{session_key: session_key}
    end

    test "finds session by label and attempts to send" do
      result =
        SessionsSend.execute(
          %{"label" => "target-worker", "message" => "hello via label"},
          %{session_key: "sender:session"}
        )

      case result do
        {:error, msg} -> refute msg =~ "sessionKey or label"
        {:ok, _} -> :ok
      end
    end
  end

  # ============================================================================
  # Cleanup parameter schema
  # ============================================================================

  describe "cleanup and label parameter schema" do
    test "sessions_spawn includes cleanup and label in parameters" do
      params = SessionsSpawn.parameters()
      assert params.properties[:cleanup].type == "string"
      assert params.properties[:cleanup].enum == ["delete", "keep"]
      assert params.properties[:label].type == "string"
    end

    test "cleanup defaults to keep when not provided" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "cleanup-default-#{System.unique_integer()}"})
        |> Repo.insert()

      context = %{agent_id: agent.id, session_key: "parent:main"}
      assert {:ok, result} = SessionsSpawn.execute(%{"task" => "default cleanup"}, context)

      Process.sleep(200)

      session = Repo.get_by(Session, session_key: result.childSessionKey)
      assert session != nil
      assert session.metadata["cleanup"] == "keep"

      SessionManager.stop_session(result.childSessionKey)
    end

    test "sessions_list and sessions_send include label in parameters" do
      list_params = SessionsList.parameters()
      assert Map.has_key?(list_params.properties, :label)

      send_params = SessionsSend.parameters()
      assert Map.has_key?(send_params[:properties], :label)
    end
  end
end
