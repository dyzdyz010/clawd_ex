defmodule ClawdEx.Tools.SessionsHistoryTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Tools.SessionsHistory
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.{Session, Message}

  describe "name/0" do
    test "returns correct name" do
      assert SessionsHistory.name() == "sessions_history"
    end
  end

  describe "parameters/0" do
    test "defines sessionKey as required" do
      params = SessionsHistory.parameters()
      assert params.required == ["sessionKey"]
      assert Map.has_key?(params.properties, :sessionKey)
    end

    test "defines optional limit and includeTools" do
      params = SessionsHistory.parameters()
      assert Map.has_key?(params.properties, :limit)
      assert Map.has_key?(params.properties, :includeTools)
    end
  end

  describe "execute/2" do
    setup do
      # Create test agent
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{name: "test-agent-#{System.unique_integer()}"})
        |> Repo.insert()

      # Create test session
      session_key = "test:session:#{System.unique_integer()}"

      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          session_key: session_key,
          channel: "test",
          agent_id: agent.id
        })
        |> Repo.insert()

      %{agent: agent, session: session, session_key: session_key}
    end

    test "returns error when sessionKey is missing" do
      assert {:error, "sessionKey is required"} = SessionsHistory.execute(%{}, %{})
      assert {:error, "sessionKey is required"} = SessionsHistory.execute(%{"sessionKey" => ""}, %{})
    end

    test "returns error when session not found" do
      assert {:error, msg} = SessionsHistory.execute(%{"sessionKey" => "nonexistent:key"}, %{})
      assert msg =~ "Session not found"
    end

    test "returns empty messages for new session", %{session_key: session_key} do
      assert {:ok, result} = SessionsHistory.execute(%{"sessionKey" => session_key}, %{})
      assert result.sessionKey == session_key
      assert result.channel == "test"
      assert result.messageCount == 0
      assert result.messages == []
    end

    test "returns messages in chronological order", %{session: session, session_key: session_key} do
      # Insert messages
      now = DateTime.utc_now()

      messages_attrs = [
        %{role: :user, content: "Hello", session_id: session.id, inserted_at: now},
        %{
          role: :assistant,
          content: "Hi there!",
          session_id: session.id,
          inserted_at: DateTime.add(now, 1, :second)
        },
        %{
          role: :user,
          content: "How are you?",
          session_id: session.id,
          inserted_at: DateTime.add(now, 2, :second)
        }
      ]

      for attrs <- messages_attrs do
        %Message{}
        |> Message.changeset(attrs)
        |> Repo.insert!()
      end

      assert {:ok, result} = SessionsHistory.execute(%{"sessionKey" => session_key}, %{})
      assert result.messageCount == 3

      contents = Enum.map(result.messages, & &1.content)
      assert contents == ["Hello", "Hi there!", "How are you?"]
    end

    test "respects limit parameter", %{session: session, session_key: session_key} do
      # Insert 5 messages
      for i <- 1..5 do
        %Message{}
        |> Message.changeset(%{
          role: :user,
          content: "Message #{i}",
          session_id: session.id
        })
        |> Repo.insert!()
      end

      assert {:ok, result} = SessionsHistory.execute(%{"sessionKey" => session_key, "limit" => 2}, %{})
      assert result.messageCount == 2
    end

    test "filters tool messages when includeTools is false", %{
      session: session,
      session_key: session_key
    } do
      now = DateTime.utc_now()

      # Insert mixed messages
      messages = [
        %{role: :user, content: "Use the tool", session_id: session.id, inserted_at: now},
        %{
          role: :assistant,
          content: "Calling tool",
          session_id: session.id,
          tool_calls: [%{"id" => "call_1", "type" => "function"}],
          inserted_at: DateTime.add(now, 1, :second)
        },
        %{
          role: :tool,
          content: "Tool result",
          session_id: session.id,
          tool_call_id: "call_1",
          inserted_at: DateTime.add(now, 2, :second)
        },
        %{
          role: :assistant,
          content: "Here's the result",
          session_id: session.id,
          inserted_at: DateTime.add(now, 3, :second)
        }
      ]

      for attrs <- messages do
        %Message{}
        |> Message.changeset(attrs)
        |> Repo.insert!()
      end

      # With tools (default)
      assert {:ok, with_tools} =
               SessionsHistory.execute(%{"sessionKey" => session_key, "includeTools" => true}, %{})

      assert with_tools.messageCount == 4

      # Without tool messages
      assert {:ok, without_tools} =
               SessionsHistory.execute(
                 %{"sessionKey" => session_key, "includeTools" => false},
                 %{}
               )

      assert without_tools.messageCount == 3
      roles = Enum.map(without_tools.messages, & &1.role)
      refute :tool in roles
    end

    test "includes tool_calls and tool_call_id in response", %{
      session: session,
      session_key: session_key
    } do
      # Insert assistant message with tool call
      %Message{}
      |> Message.changeset(%{
        role: :assistant,
        content: "Let me check",
        session_id: session.id,
        tool_calls: [%{"id" => "call_123", "type" => "function", "name" => "read"}]
      })
      |> Repo.insert!()

      # Insert tool result
      %Message{}
      |> Message.changeset(%{
        role: :tool,
        content: "file contents",
        session_id: session.id,
        tool_call_id: "call_123"
      })
      |> Repo.insert!()

      assert {:ok, result} = SessionsHistory.execute(%{"sessionKey" => session_key}, %{})

      [assistant_msg, tool_msg] = result.messages

      assert assistant_msg.toolCalls == [%{"id" => "call_123", "type" => "function", "name" => "read"}]
      assert tool_msg.toolCallId == "call_123"
    end

    test "includes model and tokens when present", %{session: session, session_key: session_key} do
      %Message{}
      |> Message.changeset(%{
        role: :assistant,
        content: "Response",
        session_id: session.id,
        model: "claude-3-opus",
        tokens_in: 100,
        tokens_out: 50
      })
      |> Repo.insert!()

      assert {:ok, result} = SessionsHistory.execute(%{"sessionKey" => session_key}, %{})
      [msg] = result.messages

      assert msg.model == "claude-3-opus"
      assert msg.tokensIn == 100
      assert msg.tokensOut == 50
    end

    test "supports atom keys in params", %{session_key: session_key} do
      assert {:ok, result} = SessionsHistory.execute(%{sessionKey: session_key}, %{})
      assert result.sessionKey == session_key
    end
  end
end
