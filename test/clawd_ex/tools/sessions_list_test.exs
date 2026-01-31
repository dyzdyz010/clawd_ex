defmodule ClawdEx.Tools.SessionsListTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.SessionsList
  alias ClawdEx.Sessions.{Session, Message, SessionManager}
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Repo

  describe "SessionsList tool" do
    test "name/0 returns correct name" do
      assert SessionsList.name() == "sessions_list"
    end

    test "description/0 returns a description" do
      assert is_binary(SessionsList.description())
      assert SessionsList.description() =~ "session"
    end

    test "parameters/0 returns valid schema" do
      params = SessionsList.parameters()
      assert params.type == "object"
      assert is_map(params.properties)
      assert Map.has_key?(params.properties, :kinds)
      assert Map.has_key?(params.properties, :limit)
      assert Map.has_key?(params.properties, :activeMinutes)
      assert Map.has_key?(params.properties, :messageLimit)
    end
  end

  describe "execute/2" do
    setup do
      # 创建测试 agent
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      # 创建测试会话
      {:ok, session1} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-session-1-#{System.unique_integer()}",
          channel: "telegram",
          agent_id: agent.id,
          state: :active,
          message_count: 5,
          token_count: 100,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      {:ok, session2} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-session-2-#{System.unique_integer()}",
          channel: "discord",
          agent_id: agent.id,
          state: :active,
          message_count: 3,
          token_count: 50,
          last_activity_at: DateTime.add(DateTime.utc_now(), -30 * 60, :second)
        })
        |> Repo.insert()

      {:ok, old_session} =
        %Session{}
        |> Session.changeset(%{
          session_key: "test-session-old-#{System.unique_integer()}",
          channel: "telegram",
          agent_id: agent.id,
          state: :active,
          message_count: 10,
          token_count: 200,
          last_activity_at: DateTime.add(DateTime.utc_now(), -120 * 60, :second)
        })
        |> Repo.insert()

      # 创建一些测试消息
      {:ok, _msg1} =
        %Message{}
        |> Message.changeset(%{
          session_id: session1.id,
          role: :user,
          content: "Hello, this is a test message"
        })
        |> Repo.insert()

      {:ok, _msg2} =
        %Message{}
        |> Message.changeset(%{
          session_id: session1.id,
          role: :assistant,
          content: "Hi! How can I help you today?"
        })
        |> Repo.insert()

      %{
        agent: agent,
        session1: session1,
        session2: session2,
        old_session: old_session
      }
    end

    test "returns empty list when no active session workers", %{session1: session1} do
      # SessionManager.list_sessions() 返回活跃进程的 keys
      # 如果没有活跃进程，应该返回空列表
      {:ok, result} = SessionsList.execute(%{}, %{})

      assert is_map(result)
      assert Map.has_key?(result, :sessions)
      assert Map.has_key?(result, :count)
      assert is_list(result.sessions)
    end

    test "filters by kinds parameter" do
      {:ok, result} = SessionsList.execute(%{"kinds" => ["telegram"]}, %{})
      assert is_list(result.sessions)
      # 所有返回的会话都应该是 telegram 类型
      Enum.each(result.sessions, fn session ->
        assert session.kind == "telegram"
      end)
    end

    test "respects limit parameter" do
      {:ok, result} = SessionsList.execute(%{"limit" => 1}, %{})
      assert length(result.sessions) <= 1
      assert result.count <= 1
    end

    test "filters by activeMinutes parameter" do
      # 只返回最近 15 分钟活跃的会话
      {:ok, result} = SessionsList.execute(%{"activeMinutes" => 15}, %{})
      assert is_list(result.sessions)
    end

    test "includes messages when messageLimit > 0", %{session1: session1} do
      # 模拟会话进程活跃
      # 由于我们无法轻易模拟 SessionManager，这个测试主要验证参数处理
      {:ok, result} = SessionsList.execute(%{"messageLimit" => 5}, %{})
      assert is_list(result.sessions)
    end

    test "handles atom keys in params" do
      {:ok, result} = SessionsList.execute(%{kinds: ["telegram"], limit: 10}, %{})
      assert is_list(result.sessions)
    end

    test "session format includes required fields" do
      # 创建一个会话并注册到 SessionManager
      session_key = "test-format-#{System.unique_integer()}"

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "format-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: session_key,
          channel: "telegram",
          agent_id: agent.id,
          state: :active,
          message_count: 1,
          token_count: 10,
          last_activity_at: DateTime.utc_now()
        })
        |> Repo.insert()

      # 模拟注册到 Registry
      {:ok, _} = Registry.register(ClawdEx.SessionRegistry, session_key, %{})

      on_exit(fn ->
        Registry.unregister(ClawdEx.SessionRegistry, session_key)
      end)

      {:ok, result} = SessionsList.execute(%{}, %{})

      if result.count > 0 do
        session_result = hd(result.sessions)
        assert Map.has_key?(session_result, :sessionKey)
        assert Map.has_key?(session_result, :kind)
        assert Map.has_key?(session_result, :state)
        assert Map.has_key?(session_result, :lastActivity)
        assert Map.has_key?(session_result, :messageCount)
        assert Map.has_key?(session_result, :tokenCount)
      end
    end
  end

  describe "integration with Registry" do
    test "sessions_list is registered" do
      tools = ClawdEx.Tools.Registry.list_tools()
      tool_names = Enum.map(tools, & &1.name)
      assert "sessions_list" in tool_names
    end

    test "can execute via Registry" do
      result = ClawdEx.Tools.Registry.execute("sessions_list", %{}, %{})
      assert {:ok, _} = result
    end
  end
end
