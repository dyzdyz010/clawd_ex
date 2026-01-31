defmodule ClawdEx.Sessions.CompactionTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Sessions.{Compaction, Session, Message}
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Repo

  describe "estimate_tokens/1" do
    test "estimates tokens for a string" do
      # English text: ~4 chars per token
      text = String.duplicate("a", 100)
      tokens = Compaction.estimate_tokens(text)
      assert tokens == 25
    end

    test "estimates tokens for messages" do
      messages = [
        %{role: "user", content: String.duplicate("a", 100)},
        %{role: "assistant", content: String.duplicate("b", 200)}
      ]
      tokens = Compaction.estimate_tokens(messages)
      assert tokens == 75  # 25 + 50
    end

    test "handles empty content" do
      messages = [%{role: "user", content: nil}]
      tokens = Compaction.estimate_tokens(messages)
      assert tokens == 0
    end
  end

  describe "get_context_window/2" do
    test "returns known model context window" do
      assert Compaction.get_context_window("anthropic/claude-sonnet-4") == 200_000
      assert Compaction.get_context_window("openai/gpt-4o") == 128_000
    end

    test "returns default for unknown model" do
      assert Compaction.get_context_window("unknown/model") == 200_000
    end

    test "uses custom context window if provided" do
      assert Compaction.get_context_window("anthropic/claude-sonnet-4", context_window: 50_000) == 50_000
    end
  end

  describe "check_needed/2" do
    setup do
      agent = create_agent()
      session = create_session(agent)
      {:ok, agent: agent, session: session}
    end

    test "returns :ok when token count is below threshold", %{session: session} do
      # Create a few small messages
      create_message(session, :user, "Hello")
      create_message(session, :assistant, "Hi there!")

      assert :ok = Compaction.check_needed(session, compaction_threshold: 0.8)
    end

    test "returns {:needs_compaction, token_count} when above threshold", %{session: session} do
      # Create many messages to exceed threshold
      # With a small context window, this should trigger
      for i <- 1..50 do
        create_message(session, :user, "Message #{i}: " <> String.duplicate("x", 1000))
        create_message(session, :assistant, "Response #{i}: " <> String.duplicate("y", 1000))
      end

      result = Compaction.check_needed(session, context_window: 10_000, compaction_threshold: 0.5)
      assert {:needs_compaction, _token_count} = result
    end
  end

  describe "compact/2" do
    setup do
      agent = create_agent()
      session = create_session(agent)
      {:ok, agent: agent, session: session}
    end

    test "returns ok with message when too few messages", %{session: session} do
      create_message(session, :user, "Hello")
      create_message(session, :assistant, "Hi!")

      assert {:ok, "No compaction needed - too few messages"} = Compaction.compact(session, keep_recent: 10)
    end

    # Note: Full compaction test would require mocking the AI.Chat module
    # since it makes actual API calls
  end

  # Helper functions
  defp create_agent do
    %Agent{}
    |> Agent.changeset(%{
      name: "test-agent-#{System.unique_integer([:positive])}",
      workspace_path: "/tmp/test",
      default_model: "anthropic/claude-sonnet-4"
    })
    |> Repo.insert!()
  end

  defp create_session(agent) do
    %Session{}
    |> Session.changeset(%{
      session_key: "test-session-#{System.unique_integer([:positive])}",
      channel: "test",
      agent_id: agent.id
    })
    |> Repo.insert!()
  end

  defp create_message(session, role, content) do
    %Message{}
    |> Message.changeset(%{
      session_id: session.id,
      role: role,
      content: content
    })
    |> Repo.insert!()
  end
end
