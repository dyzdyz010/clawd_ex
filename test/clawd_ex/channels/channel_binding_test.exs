defmodule ClawdEx.Channels.ChannelBindingTest do
  @moduledoc "Schema changeset validation and unique constraint tests for ChannelBinding"
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Channels.ChannelBinding
  alias ClawdEx.Agents.Agent

  setup do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{name: "test_agent_#{System.unique_integer([:positive])}", active: true})
      |> Repo.insert()

    %{agent: agent}
  end

  describe "changeset/2" do
    test "valid changeset with all required fields", %{agent: agent} do
      attrs = %{
        agent_id: agent.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-100123", "topic_id" => "42"},
        session_key: "telegram:-100123:topic:42:agent:#{agent.id}"
      }

      changeset = ChannelBinding.changeset(%ChannelBinding{}, attrs)
      assert changeset.valid?
    end

    test "invalid without agent_id" do
      attrs = %{
        channel: "telegram",
        channel_config: %{"chat_id" => "-100123"},
        session_key: "telegram:-100123:agent:1"
      }

      changeset = ChannelBinding.changeset(%ChannelBinding{}, attrs)
      refute changeset.valid?
      assert %{agent_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without channel" do
      attrs = %{
        agent_id: 1,
        channel_config: %{"chat_id" => "-100123"},
        session_key: "telegram:-100123:agent:1"
      }

      changeset = ChannelBinding.changeset(%ChannelBinding{}, attrs)
      refute changeset.valid?
      assert %{channel: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without session_key" do
      attrs = %{
        agent_id: 1,
        channel: "telegram",
        channel_config: %{"chat_id" => "-100123"}
      }

      changeset = ChannelBinding.changeset(%ChannelBinding{}, attrs)
      refute changeset.valid?
      assert %{session_key: ["can't be blank"]} = errors_on(changeset)
    end

    test "channel_config defaults to empty map" do
      attrs = %{
        agent_id: 1,
        channel: "telegram",
        session_key: "telegram:test:agent:1"
      }

      changeset = ChannelBinding.changeset(%ChannelBinding{}, attrs)
      # channel_config has a default of %{}, so the changeset is valid
      # even without explicitly providing it (the default satisfies the requirement)
      config = Ecto.Changeset.get_field(changeset, :channel_config)
      assert config == %{}
    end

    test "defaults active to true", %{agent: agent} do
      attrs = %{
        agent_id: agent.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-100123"},
        session_key: "telegram:-100123:agent:#{agent.id}"
      }

      changeset = ChannelBinding.changeset(%ChannelBinding{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :active) == true
    end
  end

  describe "unique constraints" do
    test "unique session_key constraint", %{agent: agent} do
      attrs = %{
        agent_id: agent.id,
        channel: "telegram",
        channel_config: %{"chat_id" => "-100123", "topic_id" => "1"},
        session_key: "telegram:-100123:topic:1:agent:#{agent.id}"
      }

      assert {:ok, _} = %ChannelBinding{} |> ChannelBinding.changeset(attrs) |> Repo.insert()

      # Same session_key should fail
      {:ok, agent2} =
        %Agent{}
        |> Agent.changeset(%{name: "test_agent2_#{System.unique_integer([:positive])}", active: true})
        |> Repo.insert()

      attrs2 = %{attrs | agent_id: agent2.id, channel_config: %{"chat_id" => "-100999"}}

      assert {:error, changeset} =
               %ChannelBinding{} |> ChannelBinding.changeset(attrs2) |> Repo.insert()

      assert %{session_key: ["has already been taken"]} = errors_on(changeset)
    end

    test "unique (agent_id, channel, channel_config) constraint", %{agent: agent} do
      config = %{"chat_id" => "-100123", "topic_id" => "42"}

      attrs = %{
        agent_id: agent.id,
        channel: "telegram",
        channel_config: config,
        session_key: "telegram:-100123:topic:42:agent:#{agent.id}"
      }

      assert {:ok, _} = %ChannelBinding{} |> ChannelBinding.changeset(attrs) |> Repo.insert()

      # Same agent + channel + config but different session_key
      attrs2 = %{attrs | session_key: "different_key"}

      assert {:error, changeset} =
               %ChannelBinding{} |> ChannelBinding.changeset(attrs2) |> Repo.insert()

      assert %{agent_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "foreign key constraint on agent_id" do
      attrs = %{
        agent_id: 999_999_999,
        channel: "telegram",
        channel_config: %{"chat_id" => "-100123"},
        session_key: "telegram:-100123:agent:999999999"
      }

      assert {:error, changeset} =
               %ChannelBinding{} |> ChannelBinding.changeset(attrs) |> Repo.insert()

      assert %{agent_id: ["does not exist"]} = errors_on(changeset)
    end
  end
end
