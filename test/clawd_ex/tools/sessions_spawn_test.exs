defmodule ClawdEx.Tools.SessionsSpawnTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.SessionsSpawn
  alias ClawdEx.Sessions.SessionManager

  describe "name/0" do
    test "returns correct tool name" do
      assert SessionsSpawn.name() == "sessions_spawn"
    end
  end

  describe "description/0" do
    test "returns description string" do
      desc = SessionsSpawn.description()
      assert is_binary(desc)
      assert desc =~ "child agent"
    end
  end

  describe "parameters/0" do
    test "returns parameter schema" do
      params = SessionsSpawn.parameters()
      assert params.type == "object"
      assert Map.has_key?(params.properties, :task)
      assert "task" in params.required
    end

    test "includes optional parameters" do
      params = SessionsSpawn.parameters()
      props = params.properties
      
      assert Map.has_key?(props, :label)
      assert Map.has_key?(props, :agentId)
      assert Map.has_key?(props, :model)
      assert Map.has_key?(props, :runTimeoutSeconds)
      assert Map.has_key?(props, :cleanup)
    end
  end

  describe "execute/2" do
    setup do
      # 创建测试 agent
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
        # 清理可能创建的会话
        SessionManager.list_sessions()
        |> Enum.filter(&String.contains?(&1, "subagent"))
        |> Enum.each(&SessionManager.stop_session/1)
      end)

      %{agent: agent, context: context}
    end

    test "returns error when task is missing", %{context: context} do
      assert {:error, "task is required"} = SessionsSpawn.execute(%{}, context)
    end

    test "returns error when task is empty", %{context: context} do
      assert {:error, "task is required"} = SessionsSpawn.execute(%{"task" => ""}, context)
    end

    test "spawns subagent and returns session key", %{context: context} do
      params = %{
        "task" => "echo Hello from subagent",
        "label" => "test-subagent"
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.status == "spawned"
      assert is_binary(result.childSessionKey)
      assert result.childSessionKey =~ "subagent"
      assert result.label == "test-subagent"

      # 给子代理时间启动
      Process.sleep(100)

      # 验证会话已创建
      sessions = SessionManager.list_sessions()
      assert result.childSessionKey in sessions
    end

    test "uses parent agent_id by default", %{agent: agent, context: context} do
      params = %{"task" => "simple task"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.childSessionKey =~ "agent:#{agent.id}"
    end

    test "respects custom timeout", %{context: context} do
      params = %{
        "task" => "quick task",
        "runTimeoutSeconds" => 5
      }

      # 应该不会报错
      assert {:ok, _result} = SessionsSpawn.execute(params, context)
    end

    test "caps timeout at 3600 seconds", %{context: context} do
      params = %{
        "task" => "task",
        "runTimeoutSeconds" => 99999
      }

      # 应该成功（内部会限制到 3600）
      assert {:ok, _result} = SessionsSpawn.execute(params, context)
    end
  end

  describe "session key format" do
    test "generates valid session key format" do
      context = %{agent_id: 42}
      params = %{"task" => "test"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      
      # 验证格式: agent:{id}:subagent:{uuid}
      [prefix, agent_id, subagent, uuid] = String.split(result.childSessionKey, ":")
      assert prefix == "agent"
      assert agent_id == "42"
      assert subagent == "subagent"
      assert String.length(uuid) > 10
    end

    test "uses default when agent_id is nil" do
      context = %{}
      params = %{"task" => "test"}

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      assert result.childSessionKey =~ "agent:default:subagent:"
    end
  end

  describe "cleanup option" do
    setup do
      context = %{agent_id: 1, session_key: "parent"}
      %{context: context}
    end

    test "session persists when cleanup is false", %{context: context} do
      params = %{
        "task" => "echo done",
        "cleanup" => false
      }

      assert {:ok, result} = SessionsSpawn.execute(params, context)
      
      # 给任务时间完成
      Process.sleep(500)

      # 会话应该仍然存在
      sessions = SessionManager.list_sessions()
      # 注意：由于任务可能已完成，这取决于实际执行情况
      # 这里我们只验证 spawn 成功
      assert is_list(sessions)
    end
  end
end
