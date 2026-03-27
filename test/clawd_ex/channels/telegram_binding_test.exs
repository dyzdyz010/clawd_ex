defmodule ClawdEx.Channels.TelegramBindingTest do
  @moduledoc "Tests for Telegram channel binding callbacks"
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Channels.Telegram
  alias ClawdEx.Channels.ChannelBinding
  alias ClawdEx.Agents.Agent

  describe "build_session_key/2" do
    test "builds key with chat_id and topic_id" do
      config = %{"chat_id" => "-1003768565369", "topic_id" => "144"}
      assert Telegram.build_session_key(42, config) ==
               "telegram:-1003768565369:topic:144:agent:42"
    end

    test "builds key with chat_id only" do
      config = %{"chat_id" => "-1003768565369"}
      assert Telegram.build_session_key(42, config) ==
               "telegram:-1003768565369:agent:42"
    end

    test "handles integer agent_id" do
      config = %{"chat_id" => "-100123", "topic_id" => "5"}
      key = Telegram.build_session_key(1, config)
      assert key == "telegram:-100123:topic:5:agent:1"
    end
  end

  describe "resolve_agent_for_group uses channel_bindings" do
    setup do
      {:ok, agent_a} =
        %Agent{}
        |> Agent.changeset(%{name: "AgentA", active: true, config: %{}})
        |> Repo.insert()

      {:ok, agent_b} =
        %Agent{}
        |> Agent.changeset(%{name: "AgentB", active: true, config: %{}})
        |> Repo.insert()

      # Create binding for AgentA → topic 100
      %ChannelBinding{}
      |> ChannelBinding.changeset(%{
        agent_id: agent_a.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-200000", "topic_id" => "100"},
        session_key: "telegram:-200000:topic:100:agent:#{agent_a.id}",
        active: true
      })
      |> Repo.insert!()

      # Create binding for AgentB → topic 200
      %ChannelBinding{}
      |> ChannelBinding.changeset(%{
        agent_id: agent_b.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-200000", "topic_id" => "200"},
        session_key: "telegram:-200000:topic:200:agent:#{agent_b.id}",
        active: true
      })
      |> Repo.insert!()

      %{agent_a: agent_a, agent_b: agent_b}
    end

    test "resolves agent from binding for topic 100", %{agent_a: agent_a} do
      result = Telegram.resolve_agent_for_group("hello", "-200000", "100")
      assert result == agent_a.id
    end

    test "resolves agent from binding for topic 200", %{agent_b: agent_b} do
      result = Telegram.resolve_agent_for_group("hello", "-200000", "200")
      assert result == agent_b.id
    end

    test "@mention overrides binding", %{agent_b: agent_b} do
      # Topic 100 maps to AgentA, but @AgentB should override
      result = Telegram.resolve_agent_for_group("@AgentB help", "-200000", "100")
      assert result == agent_b.id
    end

    test "falls back to default agent when no binding for topic", %{agent_a: agent_a} do
      # Topic 999 has no binding — should fall back to first active agent
      result = Telegram.resolve_agent_for_group("hello", "-200000", "999")
      assert result == agent_a.id
    end

    test "inactive binding is not used", %{agent_a: agent_a, agent_b: agent_b} do
      # Create an inactive binding for AgentB → topic 300
      %ChannelBinding{}
      |> ChannelBinding.changeset(%{
        agent_id: agent_b.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-200000", "topic_id" => "300"},
        session_key: "telegram:-200000:topic:300:agent:#{agent_b.id}",
        active: false
      })
      |> Repo.insert!()

      # Topic 300 has inactive binding, should fall back to default (agent_a)
      result = Telegram.resolve_agent_for_group("hello", "-200000", "300")
      assert result == agent_a.id
    end
  end
end
