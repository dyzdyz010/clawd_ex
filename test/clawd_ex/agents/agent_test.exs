defmodule ClawdEx.Agents.AgentTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Agents.Agent

  describe "changeset/2 new fields" do
    test "auto_start defaults to false" do
      changeset = Agent.changeset(%Agent{}, %{name: "test-agent-#{System.unique_integer([:positive])}"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :auto_start) == false
    end

    test "capabilities defaults to empty list" do
      changeset = Agent.changeset(%Agent{}, %{name: "test-agent-#{System.unique_integer([:positive])}"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :capabilities) == []
    end

    test "heartbeat_interval_seconds defaults to 0" do
      changeset = Agent.changeset(%Agent{}, %{name: "test-agent-#{System.unique_integer([:positive])}"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :heartbeat_interval_seconds) == 0
    end

    test "always_on defaults to false" do
      changeset = Agent.changeset(%Agent{}, %{name: "test-agent-#{System.unique_integer([:positive])}"})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :always_on) == false
    end

    test "can set auto_start to true" do
      changeset = Agent.changeset(%Agent{}, %{
        name: "test-agent-#{System.unique_integer([:positive])}",
        auto_start: true
      })
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :auto_start) == true
    end

    test "can set capabilities" do
      changeset = Agent.changeset(%Agent{}, %{
        name: "test-agent-#{System.unique_integer([:positive])}",
        capabilities: ["code_review", "testing", "deployment"]
      })
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :capabilities) == ["code_review", "testing", "deployment"]
    end

    test "can set heartbeat_interval_seconds" do
      changeset = Agent.changeset(%Agent{}, %{
        name: "test-agent-#{System.unique_integer([:positive])}",
        heartbeat_interval_seconds: 30
      })
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :heartbeat_interval_seconds) == 30
    end

    test "can set always_on to true" do
      changeset = Agent.changeset(%Agent{}, %{
        name: "test-agent-#{System.unique_integer([:positive])}",
        always_on: true
      })
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :always_on) == true
    end

    test "persists new fields to database" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "persist-test-#{System.unique_integer([:positive])}",
          auto_start: true,
          capabilities: ["a2a", "code"],
          heartbeat_interval_seconds: 60,
          always_on: true
        })
        |> Repo.insert()

      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.auto_start == true
      assert reloaded.capabilities == ["a2a", "code"]
      assert reloaded.heartbeat_interval_seconds == 60
      assert reloaded.always_on == true
    end
  end
end
