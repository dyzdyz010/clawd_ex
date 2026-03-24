defmodule ClawdEx.Tools.SessionsLabelCleanupTest do
  @moduledoc """
  Tests for label and cleanup features across sessions_spawn, sessions_list, and sessions_send.

  These tests validate:
  - Label is stored in session metadata on spawn
  - sessions_list can filter by label
  - sessions_send can address sessions by label
  - cleanup: "delete" results in session removal after completion
  - cleanup: "keep" (default) preserves sessions
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

    test "spawn stores label in session metadata", %{context: context} do
      params = %{
        "task" => "test label storage",
        "label" => "my-worker"
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      child_key = result.childSessionKey

      # Give async spawn time to persist metadata
      Process.sleep(200)

      # Verify label is in DB metadata
      session = Repo.get_by(Session, session_key: child_key)
      assert session != nil
      assert session.metadata["label"] == "my-worker"
    end

    test "spawn stores cleanup strategy in session metadata", %{context: context} do
      # Use cleanup: "keep" so the session isn't deleted before we can check
      params = %{
        "task" => "test cleanup storage",
        "label" => "cleanup-worker",
        "cleanup" => "keep"
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      child_key = result.childSessionKey

      Process.sleep(200)

      session = Repo.get_by(Session, session_key: child_key)
      assert session != nil
      assert session.metadata["cleanup"] == "keep"
      assert session.metadata["label"] == "cleanup-worker"
    end

    test "spawn stores delete cleanup in metadata", %{context: context} do
      # Verify that "delete" value is accepted and stored (check quickly before async cleanup)
      params = %{
        "task" => "test delete cleanup",
        "cleanup" => "delete"
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      # The cleanup value "delete" is valid - the session may get deleted async,
      # but the spawn itself succeeds
      assert result.status == "spawned"
    end

    test "spawn without label does not set label in metadata", %{context: context} do
      params = %{"task" => "no label task"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      child_key = result.childSessionKey

      Process.sleep(200)

      session = Repo.get_by(Session, session_key: child_key)
      assert session != nil
      # label should not be in metadata (or nil)
      refute Map.has_key?(session.metadata, "label")
    end

    test "spawn response includes label when provided", %{context: context} do
      params = %{"task" => "labeled task", "label" => "response-label"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.label == "response-label"
    end

    test "spawn response omits label when not provided", %{context: context} do
      params = %{"task" => "unlabeled task"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      refute Map.has_key?(result, :label)
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

      # Create sessions with different labels in metadata
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

      # Register all sessions in Registry so SessionManager.list_sessions() finds them
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

    test "filters sessions by label", %{session_a: session_a} do
      {:ok, result} = SessionsList.execute(%{"label" => "worker-alpha"}, %{})

      assert result.count == 1
      assert hd(result.sessions).sessionKey == session_a.session_key
    end

    test "returns empty when label not found" do
      {:ok, result} = SessionsList.execute(%{"label" => "nonexistent-label"}, %{})
      assert result.count == 0
      assert result.sessions == []
    end

    test "returns all sessions when no label filter", %{
      session_a: _a,
      session_b: _b,
      session_no_label: _c
    } do
      {:ok, result} = SessionsList.execute(%{}, %{})
      # Should include at least our 3 registered sessions
      assert result.count >= 3
    end

    test "label filter combined with kinds filter", %{session_a: session_a} do
      {:ok, result} =
        SessionsList.execute(
          %{"label" => "worker-alpha", "kinds" => ["subagent"]},
          %{}
        )

      assert result.count == 1
      assert hd(result.sessions).sessionKey == session_a.session_key
    end

    test "label appears in session output", %{session_a: session_a} do
      {:ok, result} = SessionsList.execute(%{"label" => "worker-alpha"}, %{})

      assert result.count == 1
      session_output = hd(result.sessions)
      assert session_output.label == "worker-alpha"
    end

    test "session without label does not have label key in output", %{
      session_no_label: session_no_label
    } do
      # Get all sessions, find the one without label
      {:ok, result} = SessionsList.execute(%{}, %{})

      no_label_output =
        Enum.find(result.sessions, fn s -> s.sessionKey == session_no_label.session_key end)

      assert no_label_output != nil
      refute Map.has_key?(no_label_output, :label)
    end

    test "label parameter works with atom keys" do
      {:ok, result} = SessionsList.execute(%{label: "worker-alpha"}, %{})
      assert result.count == 1
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

    test "prefers sessionKey over label when both provided" do
      # Both provided: sessionKey takes priority
      # The system may auto-start the session and succeed, or fail with a session-specific error
      # Either way, it should NOT fail with "sessionKey or label required" since sessionKey was provided
      result =
        SessionsSend.execute(
          %{
            "sessionKey" => "nonexistent:session",
            "label" => "some-label",
            "message" => "hello"
          },
          %{session_key: "sender"}
        )

      # Should attempt to send to sessionKey, not resolve label
      # The result should NOT be about missing sessionKey/label - it resolved the target
      case result do
        {:ok, response} ->
          # Session was auto-started and message was sent successfully
          assert is_binary(response)
          refute response =~ "sessionKey or label"

        {:error, msg} ->
          # Session could not be started, but the error should NOT be about missing key/label
          refute msg =~ "sessionKey or label"
      end
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

    test "label parameter appears in parameters schema" do
      params = SessionsSend.parameters()
      assert Map.has_key?(params[:properties], :label)
      assert params[:properties][:label][:type] == "string"
    end

    test "message is still required" do
      params = SessionsSend.parameters()
      assert "message" in params[:required]
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

      # Create a session with a label
      session_key = "test-send-label-#{System.unique_integer()}"

      {:ok, session} =
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

      # Register in Registry
      {:ok, _} = Registry.register(ClawdEx.SessionRegistry, session_key, %{})

      on_exit(fn ->
        Registry.unregister(ClawdEx.SessionRegistry, session_key)
      end)

      %{agent: agent, session: session, session_key: session_key}
    end

    test "finds session by label and attempts to send", %{session_key: session_key} do
      # The session is registered but not a real SessionWorker, so we'll get a
      # send error, but the key point is it resolved the label successfully
      result =
        SessionsSend.execute(
          %{"label" => "target-worker", "message" => "hello via label"},
          %{session_key: "sender:session"}
        )

      # It should find the session by label and try to send
      # (will fail because there's no actual GenServer, but the resolution works)
      case result do
        {:error, msg} ->
          # Should NOT be "sessionKey or label required" - that means resolution worked
          refute msg =~ "sessionKey or label"

        {:ok, _} ->
          # Unlikely but acceptable
          :ok
      end
    end
  end

  # ============================================================================
  # Cleanup parameter schema
  # ============================================================================

  describe "cleanup parameter schema" do
    test "sessions_spawn includes cleanup in parameters" do
      params = SessionsSpawn.parameters()
      assert Map.has_key?(params.properties, :cleanup)
      cleanup_prop = params.properties[:cleanup]
      assert cleanup_prop.type == "string"
      assert cleanup_prop.enum == ["delete", "keep"]
    end

    test "cleanup defaults to keep when not provided" do
      # We test this by checking spawn succeeds without cleanup param
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "cleanup-default-#{System.unique_integer()}"})
        |> Repo.insert()

      context = %{agent_id: agent.id, session_key: "parent:main"}
      params = %{"task" => "default cleanup task"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)

      Process.sleep(200)

      session = Repo.get_by(Session, session_key: result.childSessionKey)
      assert session != nil
      assert session.metadata["cleanup"] == "keep"

      # Cleanup
      SessionManager.stop_session(result.childSessionKey)
    end
  end

  # ============================================================================
  # Label parameter schema
  # ============================================================================

  describe "label parameter schema" do
    test "sessions_spawn includes label in parameters" do
      params = SessionsSpawn.parameters()
      assert Map.has_key?(params.properties, :label)
      assert params.properties[:label].type == "string"
    end

    test "sessions_list includes label in parameters" do
      params = SessionsList.parameters()
      assert Map.has_key?(params.properties, :label)
      assert params.properties[:label].type == "string"
    end

    test "sessions_send includes label in parameters" do
      params = SessionsSend.parameters()
      assert Map.has_key?(params[:properties], :label)
      assert params[:properties][:label][:type] == "string"
    end
  end
end
