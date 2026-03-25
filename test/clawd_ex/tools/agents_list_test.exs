defmodule ClawdEx.Tools.AgentsListTest do
  use ClawdEx.DataCase, async: false

  alias ClawdEx.Tools.AgentsList
  alias ClawdEx.Agents.Agent

  describe "AgentsList tool" do
    test "returns tool metadata" do
      assert AgentsList.name() == "agents_list"
      assert is_binary(AgentsList.description())
      assert is_map(AgentsList.parameters())
    end

    test "parameters has correct structure" do
      params = AgentsList.parameters()
      assert params.type == "object"
      assert is_map(params.properties)
      assert Map.has_key?(params.properties, :filter)
    end

    test "returns empty list when no agents in DB" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert is_binary(result)
      assert result =~ "Available Agents"
      assert result =~ "Allow Any:"
    end

    test "executes with filter parameter" do
      assert {:ok, result} = AgentsList.execute(%{"filter" => "test"}, %{})
      assert is_binary(result)
    end

    test "executes with atom filter parameter" do
      assert {:ok, result} = AgentsList.execute(%{filter: "test"}, %{})
      assert is_binary(result)
    end

    test "handles empty filter" do
      assert {:ok, result} = AgentsList.execute(%{"filter" => ""}, %{})
      assert is_binary(result)
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

    test "filter is case insensitive" do
      assert {:ok, result} = AgentsList.execute(%{"filter" => "BETA"}, %{})
      assert result =~ "agent-beta"
    end

    test "shows count when filtering" do
      assert {:ok, result} = AgentsList.execute(%{"filter" => "gamma"}, %{})
      assert result =~ "(1/3 shown)"
    end

    test "filters by capability" do
      assert {:ok, result} = AgentsList.execute(%{"filter" => "testing"}, %{})
      assert result =~ "agent-beta"
      refute result =~ "agent-alpha"
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

    test "only shows active agents" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert result =~ "active-agent"
      refute result =~ "inactive-agent"
    end

    test "shows allow_any as true" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert result =~ "Allow Any:** true"
    end
  end
end
