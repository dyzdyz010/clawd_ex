defmodule ClawdEx.Tools.AgentsListTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.AgentsList

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

    test "returns empty list when no agents configured" do
      # Default config has no agents
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

  describe "AgentsList with configured agents" do
    setup do
      # Save original config
      original = Application.get_env(:clawd_ex, :agents)

      # Set test config
      Application.put_env(:clawd_ex, :agents,
        agents: ["agent-alpha", "agent-beta", "agent-gamma"],
        allow_any: true
      )

      on_exit(fn ->
        if original do
          Application.put_env(:clawd_ex, :agents, original)
        else
          Application.delete_env(:clawd_ex, :agents)
        end
      end)

      :ok
    end

    test "lists all configured agents" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert result =~ "agent-alpha"
      assert result =~ "agent-beta"
      assert result =~ "agent-gamma"
      assert result =~ "Allow Any:** true"
    end

    test "filters agents by pattern" do
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
  end

  describe "AgentsList with allow_any false" do
    setup do
      original = Application.get_env(:clawd_ex, :agents)

      Application.put_env(:clawd_ex, :agents,
        agents: ["restricted-agent"],
        allow_any: false
      )

      on_exit(fn ->
        if original do
          Application.put_env(:clawd_ex, :agents, original)
        else
          Application.delete_env(:clawd_ex, :agents)
        end
      end)

      :ok
    end

    test "shows allow_any as false" do
      assert {:ok, result} = AgentsList.execute(%{}, %{})
      assert result =~ "Allow Any:** false"
    end
  end
end
