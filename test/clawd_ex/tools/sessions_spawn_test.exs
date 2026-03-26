defmodule ClawdEx.Tools.SessionsSpawnTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.SessionsSpawn
  alias ClawdEx.Sessions.SessionManager

  describe "parameters/0" do
    test "returns schema with required task and all expected fields" do
      params = SessionsSpawn.parameters()
      assert params.type == "object"
      assert "task" in params.required

      props = params.properties
      assert Map.has_key?(props, :task)
      assert Map.has_key?(props, :label)
      assert Map.has_key?(props, :agentId)
      assert Map.has_key?(props, :model)
      assert Map.has_key?(props, :runTimeoutSeconds)
      assert Map.has_key?(props, :cleanup)
      assert Map.has_key?(props, :streamTo)
      assert props[:streamTo].enum == ["parent"]
      assert Map.has_key?(props, :runtime)
      assert props[:runtime].enum == ["subagent", "acp"]
      assert Map.has_key?(props, :mode)
      assert props[:mode].enum == ["run", "session"]
    end
  end

  describe "execute/2" do
    setup do
      {:ok, agent} =
        %ClawdEx.Agents.Agent{}
        |> ClawdEx.Agents.Agent.changeset(%{name: "test-agent"})
        |> ClawdEx.Repo.insert()

      context = %{
        session_id: 1,
        session_key: "test:parent:session",
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

    test "returns error when task is missing or empty", %{context: context} do
      assert {:error, "task is required"} = SessionsSpawn.execute(%{}, context)
      assert {:error, "task is required"} = SessionsSpawn.execute(%{"task" => ""}, context)
    end

    test "spawns subagent with correct session key format and agent_id", %{
      agent: agent,
      context: context
    } do
      params = %{"task" => "echo Hello from subagent", "label" => "test-subagent"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.status == "spawned"
      assert result.label == "test-subagent"

      # Verify session key format: agent:{id}:subagent:{uuid}
      [prefix, agent_id, subagent, uuid] = String.split(result.childSessionKey, ":")
      assert prefix == "agent"
      assert agent_id == "#{agent.id}"
      assert subagent == "subagent"
      assert String.length(uuid) > 10
    end

    test "timeout handling - respects custom and caps at 3600", %{context: context} do
      assert {:ok, _} = SessionsSpawn.execute(%{"task" => "quick", "runTimeoutSeconds" => 5}, context)
      # Should succeed (internally capped to 3600)
      assert {:ok, _} = SessionsSpawn.execute(%{"task" => "task", "runTimeoutSeconds" => 99999}, context)
    end

    test "cleanup options - keep, delete, and boolean backward compat", %{context: context} do
      assert {:ok, _} = SessionsSpawn.execute(%{"task" => "t", "cleanup" => "keep"}, context)
      assert {:ok, _} = SessionsSpawn.execute(%{"task" => "t", "cleanup" => "delete"}, context)
      # true should be converted to :delete
      assert {:ok, _} = SessionsSpawn.execute(%{"task" => "t", "cleanup" => true}, context)
    end

    test "accepts streamTo and thinking parameters", %{context: context} do
      assert {:ok, result} =
               SessionsSpawn.execute(
                 %{"task" => "streaming", "streamTo" => "parent", "thinking" => "high"},
                 context
               )

      assert result.status == "spawned"
    end

    test "runtime defaults to subagent", %{context: context} do
      assert {:ok, result} = SessionsSpawn.execute(%{"task" => "test"}, context)
      assert result.status == "spawned"
      assert result.childSessionKey =~ "subagent"

      # Explicit subagent runtime also works
      assert {:ok, result2} =
               SessionsSpawn.execute(%{"task" => "test", "runtime" => "subagent"}, context)

      assert result2.childSessionKey =~ "subagent"
    end

    test "unknown runtime returns error", %{context: context} do
      assert {:error, msg} =
               SessionsSpawn.execute(%{"task" => "test", "runtime" => "invalid"}, context)

      assert msg =~ "Unknown runtime"
    end
  end

  describe "Telegram topic support" do
    setup do
      {:ok, agent} =
        %ClawdEx.Agents.Agent{}
        |> ClawdEx.Agents.Agent.changeset(%{
          name: "topic-test-agent-#{System.unique_integer()}"
        })
        |> ClawdEx.Repo.insert()

      %{agent: agent}
    end

    test "works with and without topic in session_key", %{agent: agent} do
      # With topic
      context_with_topic = %{
        agent_id: agent.id,
        session_key: "agent:ceo:telegram:group:-1003768565369:topic:21",
        channel: "telegram",
        channel_to: "-1003768565369"
      }

      assert {:ok, result} =
               SessionsSpawn.execute(%{"task" => "topic test"}, context_with_topic)

      assert result.status == "spawned"

      # Without topic
      context_no_topic = %{
        agent_id: agent.id,
        session_key: "agent:ceo:telegram:group:-1003768565369",
        channel: "telegram",
        channel_to: "-1003768565369"
      }

      assert {:ok, result2} =
               SessionsSpawn.execute(%{"task" => "no topic test"}, context_no_topic)

      assert result2.status == "spawned"
    end
  end

  describe "subagent spawn restriction" do
    setup do
      {:ok, agent} =
        %ClawdEx.Agents.Agent{}
        |> ClawdEx.Agents.Agent.changeset(%{
          name: "restriction-test-agent-#{System.unique_integer()}"
        })
        |> ClawdEx.Repo.insert()

      %{agent: agent}
    end

    test "rejects spawn from subagent session", %{agent: agent} do
      context = %{
        agent_id: agent.id,
        session_key: "agent:#{agent.id}:subagent:abc123"
      }

      assert {:error, message} = SessionsSpawn.execute(%{"task" => "nested task"}, context)
      assert message =~ "not allowed from sub-agent"
    end

    test "allows spawn from main session", %{agent: agent} do
      context = %{
        agent_id: agent.id,
        session_key: "agent:#{agent.id}:main"
      }

      assert {:ok, result} = SessionsSpawn.execute(%{"task" => "normal task"}, context)
      assert result.status == "spawned"
    end
  end

  describe "timeout handling" do
    setup do
      {:ok, agent} =
        %ClawdEx.Agents.Agent{}
        |> ClawdEx.Agents.Agent.changeset(%{
          name: "timeout-test-agent-#{System.unique_integer()}"
        })
        |> ClawdEx.Repo.insert()

      context = %{
        agent_id: agent.id,
        session_key: "agent:#{agent.id}:main",
        session_id: 1,
        channel: "telegram",
        channel_to: "-12345"
      }

      %{context: context}
    end

    test "spawn with very short timeout succeeds", %{context: context} do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "session:#{context[:session_key]}")

      params = %{
        "task" => "this will timeout",
        "runTimeoutSeconds" => 1,
        "label" => "timeout-test"
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.status == "spawned"

      receive do
        {:subagent_timeout, data} ->
          assert data.label == "timeout-test"
          assert data.timeoutSeconds == 1
          assert data.message =~ "超时"
      after
        5_000 -> :ok
      end
    end

    test "timeout with cleanup delete cleans up session", %{context: context} do
      params = %{
        "task" => "timeout cleanup task",
        "runTimeoutSeconds" => 1,
        "cleanup" => "delete",
        "label" => "timeout-cleanup"
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.status == "spawned"

      cleaned_up =
        Enum.any?(1..10, fn _ ->
          Process.sleep(1000)
          sessions = SessionManager.list_sessions()
          not Enum.any?(sessions, &String.contains?(&1, result.childSessionKey))
        end)

      assert cleaned_up,
             "Session #{result.childSessionKey} should have been cleaned up after timeout"
    end
  end

  describe "runtime=acp" do
    setup do
      :ok = ClawdEx.ACP.Registry.register_backend("cli", ClawdEx.ACP.MockBackend)

      on_exit(fn ->
        ClawdEx.ACP.Registry.unregister_backend("cli")
      end)

      {:ok, agent} =
        %ClawdEx.Agents.Agent{}
        |> ClawdEx.Agents.Agent.changeset(%{
          name: "acp-spawn-agent-#{System.unique_integer()}"
        })
        |> ClawdEx.Repo.insert()

      context = %{
        agent_id: agent.id,
        session_key: "agent:#{agent.id}:main",
        session_id: 1,
        channel: "telegram",
        channel_to: "-12345",
        config: %{workspace: "/tmp"}
      }

      %{agent: agent, context: context}
    end

    test "spawns ACP session and returns accepted status", %{context: context} do
      params = %{
        "task" => "Write a hello world",
        "runtime" => "acp",
        "agentId" => "codex",
        "label" => "test-acp"
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.status == "accepted"
      assert result.runtime == "acp"
      assert result.agentId == "codex"
      assert result.label == "test-acp"
      assert result.childSessionKey =~ ":acp:"
      assert result.mode == "run"

      Process.sleep(500)
      ClawdEx.ACP.Session.close(result.childSessionKey)
    end

    test "defaults agentId to codex", %{context: context} do
      params = %{"task" => "some task", "runtime" => "acp"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.agentId == "codex"

      Process.sleep(200)
      ClawdEx.ACP.Session.close(result.childSessionKey)
    end

    test "supports mode parameter", %{context: context} do
      params = %{"task" => "persistent", "runtime" => "acp", "mode" => "session"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.mode == "session"

      Process.sleep(200)
      ClawdEx.ACP.Session.close(result.childSessionKey)
    end

    test "session key contains acp identifier", %{context: context, agent: agent} do
      params = %{"task" => "test", "runtime" => "acp"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.childSessionKey =~ "agent:#{agent.id}:acp:"

      Process.sleep(200)
      ClawdEx.ACP.Session.close(result.childSessionKey)
    end

    test "still blocks subagent sessions from spawning ACP", %{agent: agent} do
      context = %{
        agent_id: agent.id,
        session_key: "agent:#{agent.id}:subagent:abc123"
      }

      assert {:error, msg} =
               SessionsSpawn.execute(%{"task" => "should fail", "runtime" => "acp"}, context)

      assert msg =~ "not allowed from sub-agent"
    end
  end
end
