defmodule ClawdEx.Agents.SeederBindingTest do
  @moduledoc "Tests for Seeder channel_bindings sync"
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Agents.{Agent, Seeder}
  alias ClawdEx.Channels.ChannelBinding

  import Ecto.Query

  describe "sync! with channel_bindings" do
    test "creates bindings from agents.json on first sync" do
      # The actual agents.json has channel_bindings defined
      # After sync!, each agent should have corresponding bindings in DB
      Seeder.sync!()

      # Check that CTO agent has a binding
      cto = Repo.one(from a in Agent, where: a.name == "CTO")
      assert cto != nil

      bindings = Repo.all(from cb in ChannelBinding, where: cb.agent_id == ^cto.id and cb.active == true)
      assert length(bindings) >= 1

      # Verify binding config
      binding = hd(bindings)
      assert binding.channel == "telegram"
      assert binding.channel_config["chat_id"] == "-1003768565369"
      assert binding.channel_config["topic_id"] == "144"
      assert binding.session_key == "telegram:-1003768565369:topic:144:agent:#{cto.id}"
    end

    test "idempotent — running sync! twice doesn't duplicate bindings" do
      Seeder.sync!()
      count1 = Repo.aggregate(ChannelBinding, :count, :id)

      Seeder.sync!()
      count2 = Repo.aggregate(ChannelBinding, :count, :id)

      assert count1 == count2
    end

    test "deactivates bindings removed from config" do
      # First sync creates bindings
      Seeder.sync!()

      cto = Repo.one(from a in Agent, where: a.name == "CTO")
      bindings_before = Repo.all(from cb in ChannelBinding, where: cb.agent_id == ^cto.id and cb.active == true)
      assert length(bindings_before) >= 1

      # Manually create an extra binding that's NOT in agents.json
      {:ok, extra_binding} =
        %ChannelBinding{}
        |> ChannelBinding.changeset(%{
          agent_id: cto.id,
          channel: "telegram",
          channel_config: %{"chat_id" => "-100fake", "topic_id" => "999"},
          session_key: "telegram:-100fake:topic:999:agent:#{cto.id}",
          active: true
        })
        |> Repo.insert()

      # Run sync again — the extra binding should be deactivated
      Seeder.sync!()

      updated_extra = Repo.get(ChannelBinding, extra_binding.id)
      assert updated_extra.active == false

      # The original bindings should still be active
      original_bindings =
        Repo.all(
          from cb in ChannelBinding,
            where: cb.agent_id == ^cto.id and cb.active == true and cb.id != ^extra_binding.id
        )

      assert length(original_bindings) >= 1
    end

    test "creates bindings for all agents in agents.json" do
      Seeder.sync!()

      # All agents should have at least one active binding
      agents = Repo.all(from a in Agent, where: a.active == true)
      assert length(agents) >= 11  # 11 agents in agents.json

      Enum.each(agents, fn agent ->
        bindings = Repo.all(from cb in ChannelBinding, where: cb.agent_id == ^agent.id and cb.active == true)
        assert length(bindings) >= 1, "Agent #{agent.name} should have at least 1 binding"
      end)
    end
  end
end
