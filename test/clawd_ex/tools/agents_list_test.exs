defmodule ClawdEx.Tools.AgentsListTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.AgentsList
  alias ClawdEx.Agents.Agent

  describe "AgentsList tool" do
    test "returns formatted output with various filter inputs" do
      # No filter
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert is_binary(result)
      assert result =~ "Available Agents"
      assert result =~ "Allow Any:"

      # String filter, atom filter, empty filter all work
      assert {:ok, _} = AgentsList.execute(%{"filter" => "test"}, %{})
      assert {:ok, _} = AgentsList.execute(%{filter: "test"}, %{})
      assert {:ok, _} = AgentsList.execute(%{"filter" => ""}, %{})
    end
  end

  describe "AgentsList with agents in DB" do
    setup do
      {:ok, _a1} =
        %Agent{}
        |> Agent.changeset(%{name: "agent-alpha", capabilities: ["code", "review"]})
        |> Repo.insert()

      {:ok, _a2} =
        %Agent{}
        |> Agent.changeset(%{name: "agent-beta", capabilities: ["testing"]})
        |> Repo.insert()

      {:ok, _a3} =
        %Agent{}
        |> Agent.changeset(%{name: "agent-gamma", capabilities: ["deploy"]})
        |> Repo.insert()

      :ok
    end

    test "lists all agents from DB" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert result =~ "agent-alpha"
      assert result =~ "agent-beta"
      assert result =~ "agent-gamma"
      assert result =~ "Allow Any:** true"
    end

    test "filters agents by name" do
      assert {:ok, result} = AgentsList.execute(%{"filter" => "alpha"}, %{})
      assert result =~ "agent-alpha"
      refute result =~ "agent-beta"
      refute result =~ "agent-gamma"
      assert result =~ "(1/3 shown)"
    end

    test "filters by name (case insensitive) and capability" do
      # Case insensitive name filter
      assert {:ok, result} = AgentsList.execute(%{"filter" => "BETA"}, %{})
      assert result =~ "agent-beta"
      assert result =~ "(1/3 shown)"

      # Capability filter
      assert {:ok, result2} = AgentsList.execute(%{"filter" => "testing"}, %{})
      assert result2 =~ "agent-beta"
      refute result2 =~ "agent-alpha"
    end

    test "displays agent id and capabilities" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert result =~ "id:"
      assert result =~ "capabilities:"
    end
  end

  describe "AgentsList with inactive agents" do
    setup do
      {:ok, _active} =
        %Agent{}
        |> Agent.changeset(%{name: "active-agent", active: true})
        |> Repo.insert()

      {:ok, _inactive} =
        %Agent{}
        |> Agent.changeset(%{name: "inactive-agent", active: false})
        |> Repo.insert()

      :ok
    end

    test "only shows active agents with allow_any" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert result =~ "active-agent"
      refute result =~ "inactive-agent"
      assert result =~ "Allow Any:** true"
    end
  end
end
