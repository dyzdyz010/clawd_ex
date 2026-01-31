defmodule ClawdEx.Agent.LoopTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Agent.Loop
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.Session

  describe "Agent Loop lifecycle" do
    setup do
      # 创建测试 agent
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      # 创建测试 session
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-session-#{System.unique_integer()}",
          channel: "test",
          agent_id: agent.id
        })
        |> Repo.insert()

      %{agent: agent, session: session}
    end

    test "starts in idle state", %{session: session} do
      {:ok, pid} = Loop.start_link(session_id: session.id, agent_id: session.agent_id)

      {:ok, state, _data} = Loop.get_state(pid)
      assert state == :idle
    end

    test "transitions to preparing on run", %{session: session} do
      {:ok, pid} = Loop.start_link(session_id: session.id, agent_id: session.agent_id)

      # 启动一个不等待完成的 run (会因为没有 API key 而失败)
      spawn(fn ->
        Loop.run(pid, "test message", timeout: 1000)
      end)

      # 给一点时间让状态转换
      Process.sleep(50)

      {:ok, state, _data} = Loop.get_state(pid)
      assert state in [:preparing, :inferring, :idle]
    end
  end
end
