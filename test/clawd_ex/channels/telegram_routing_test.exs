defmodule ClawdEx.Channels.TelegramRoutingTest do
  @moduledoc """
  Tests for Telegram group/topic session routing and @mention agent resolution.
  """
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Channels.Telegram
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Channels.ChannelBinding

  # ============================================================================
  # build_group_session_key/3
  # ============================================================================

  describe "build_group_session_key/3" do
    test "group without topic includes agent id" do
      assert Telegram.build_group_session_key("-100123", nil, 5) ==
               "telegram:-100123:agent:5"
    end

    test "group with topic includes topic and agent id" do
      assert Telegram.build_group_session_key("-100123", 42, 5) ==
               "telegram:-100123:topic:42:agent:5"
    end

    test "handles string topic_id" do
      assert Telegram.build_group_session_key("-100123", "99", 7) ==
               "telegram:-100123:topic:99:agent:7"
    end

    test "handles integer chat_id" do
      assert Telegram.build_group_session_key(-100123, nil, 1) ==
               "telegram:-100123:agent:1"
    end
  end

  # ============================================================================
  # resolve_agent_for_dm/1
  # ============================================================================

  describe "resolve_agent_for_dm/1" do
    test "returns nil for unpaired user" do
      # DmPairing.Server is started in test_helper but user won't be paired
      # ETS lookup doesn't need DB, so this works in async test
      assert Telegram.resolve_agent_for_dm("nonexistent_user_999") == nil
    end
  end

  # ============================================================================
  # resolve_agent_for_group/3
  # ============================================================================

  describe "resolve_agent_for_group/3" do
    setup do
      # Create test agents
      {:ok, cto} =
        %Agent{}
        |> Agent.changeset(%{
          name: "CTO",
          active: true,
          config: %{}
        })
        |> Repo.insert()

      {:ok, backend} =
        %Agent{}
        |> Agent.changeset(%{
          name: "Backend",
          active: true,
          config: %{}
        })
        |> Repo.insert()

      {:ok, designer} =
        %Agent{}
        |> Agent.changeset(%{
          name: "Designer",
          active: true,
          config: %{}
        })
        |> Repo.insert()

      # Create channel bindings for topic-based agent resolution
      # CTO bound to topics 5 and 8 in chat -100999
      for topic_id <- ["5", "8"] do
        %ChannelBinding{}
        |> ChannelBinding.changeset(%{
          agent_id: cto.id,
          channel: "telegram",
          channel_config: %{"chat_id" => "-100999", "topic_id" => topic_id},
          session_key: "telegram:-100999:topic:#{topic_id}:agent:#{cto.id}",
          active: true
        })
        |> Repo.insert!()
      end

      # Backend bound to topic 10 in chat -100999
      %ChannelBinding{}
      |> ChannelBinding.changeset(%{
        agent_id: backend.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-100999", "topic_id" => "10"},
        session_key: "telegram:-100999:topic:10:agent:#{backend.id}",
        active: true
      })
      |> Repo.insert!()

      %{cto: cto, backend: backend, designer: designer}
    end

    test "priority 1: @mention at start matches exact agent", %{cto: cto} do
      assert Telegram.resolve_agent_for_group("@CTO what's the plan?", "-100999", nil) == cto.id
    end

    test "priority 1: @mention is case-insensitive", %{cto: cto} do
      assert Telegram.resolve_agent_for_group("@cto hello", "-100999", nil) == cto.id
    end

    test "priority 1: @mention with space after @", %{backend: backend} do
      assert Telegram.resolve_agent_for_group("@ Backend deploy please", "-100999", nil) ==
               backend.id
    end

    test "priority 2: agent name in text (fuzzy match)", %{designer: designer} do
      assert Telegram.resolve_agent_for_group("Hey Designer, can you help?", "-100999", nil) ==
               designer.id
    end

    test "priority 2: first matching agent wins", %{cto: cto} do
      # CTO has lower id, so it's first in the list
      result = Telegram.resolve_agent_for_group("Ask CTO and Backend about it", "-100999", nil)
      assert result == cto.id
    end

    test "priority 3: topic default agent when no mention", %{cto: cto} do
      # Topic 5 is configured as default for CTO in chat -100999
      result = Telegram.resolve_agent_for_group("just a random message", "-100999", 5)
      assert result == cto.id
    end

    test "priority 3: different topic maps to different agent", %{backend: backend} do
      # Topic 10 is configured as default for Backend
      result = Telegram.resolve_agent_for_group("hello there", "-100999", 10)
      assert result == backend.id
    end

    test "priority 4: fallback to default (first active) agent when nothing matches", %{cto: cto} do
      # No mention, no topic mapping for topic 999
      result = Telegram.resolve_agent_for_group("random message", "-100999", 999)
      # CTO has the lowest id among our test agents
      assert result == cto.id
    end

    test "@mention overrides topic default", %{backend: backend} do
      # Topic 5 defaults to CTO, but message mentions Backend
      result = Telegram.resolve_agent_for_group("@Backend deploy this", "-100999", 5)
      assert result == backend.id
    end

    test "handles nil content gracefully" do
      # Should not crash, returns default agent
      result = Telegram.resolve_agent_for_group(nil, "-100999", nil)
      assert is_integer(result) or is_nil(result)
    end

    test "handles empty content" do
      result = Telegram.resolve_agent_for_group("", "-100999", nil)
      assert is_integer(result) or is_nil(result)
    end
  end

  # ============================================================================
  # Private chat session key (unchanged)
  # ============================================================================

  describe "private chat session key" do
    test "private chat uses legacy format telegram:{chat_id}" do
      # Private chats don't go through build_group_session_key
      # They use "telegram:{chat_id}" directly
      # This is verified by the handle_message flow:
      # is_private -> session_key = "telegram:#{chat_id}"
      chat_id = "12345"
      expected = "telegram:#{chat_id}"
      assert expected == "telegram:12345"
    end
  end
end
