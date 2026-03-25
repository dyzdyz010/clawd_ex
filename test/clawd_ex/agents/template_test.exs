defmodule ClawdEx.Agents.TemplateTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Agents.Template

  @agent %{
    id: 42,
    name: "Backend Dev",
    default_model: "anthropic/claude-sonnet-4",
    capabilities: ["coding", "backend", "elixir", "database"],
    workspace_path: "/tmp/test-workspace-backend-dev"
  }

  @team [
    %{id: 1, name: "default", default_model: "anthropic/claude-opus-4", capabilities: []},
    %{
      id: 2,
      name: "CTO",
      default_model: "anthropic/claude-opus-4",
      capabilities: ["architecture", "code-review", "technical-planning"]
    },
    %{
      id: 3,
      name: "Frontend Dev",
      default_model: "anthropic/claude-sonnet-4",
      capabilities: ["coding", "frontend", "react", "typescript"]
    }
  ]

  describe "render/2" do
    test "returns a map with all 4 template files" do
      result = Template.render(@agent, @team)

      assert Map.has_key?(result, "AGENTS.md")
      assert Map.has_key?(result, "SOUL.md")
      assert Map.has_key?(result, "IDENTITY.md")
      assert Map.has_key?(result, "TEAM.md")
      assert map_size(result) == 4
    end

    test "AGENTS.md contains agent name and capabilities" do
      %{"AGENTS.md" => content} = Template.render(@agent, @team)

      assert content =~ "Backend Dev"
      assert content =~ "coding, backend, elixir, database"
      assert content =~ "the systems builder"
    end

    test "SOUL.md contains agent name and role-specific vibe" do
      %{"SOUL.md" => content} = Template.render(@agent, @team)

      assert content =~ "Backend Dev"
      assert content =~ "Systematic, reliable, thorough"
    end

    test "IDENTITY.md contains agent id, name, model, and capabilities" do
      %{"IDENTITY.md" => content} = Template.render(@agent, @team)

      assert content =~ "Backend Dev"
      assert content =~ "42"
      assert content =~ "anthropic/claude-sonnet-4"
      assert content =~ "coding, backend, elixir, database"
    end

    test "TEAM.md contains team members table" do
      %{"TEAM.md" => content} = Template.render(@agent, @team)

      # Should contain the agent's own identity
      assert content =~ "Backend Dev"
      assert content =~ "42"

      # Should contain team members
      assert content =~ "CTO"
      assert content =~ "Frontend Dev"
      assert content =~ "architecture, code-review, technical-planning"

      # Should contain A2A instructions
      assert content =~ "a2a"
      assert content =~ "discover"
    end

    test "TEAM.md shows dash for members with no capabilities" do
      %{"TEAM.md" => content} = Template.render(@agent, @team)

      # The "default" agent has empty capabilities
      assert content =~ "| 1 | default |"
      # Check the row contains a dash for empty capabilities
      default_row =
        content
        |> String.split("\n")
        |> Enum.find(&String.contains?(&1, "| 1 | default |"))

      assert default_row =~ "—"
    end

    test "renders with empty team" do
      result = Template.render(@agent, [])

      assert Map.has_key?(result, "TEAM.md")
      %{"TEAM.md" => content} = result
      assert content =~ "Backend Dev"
      # Table header still present
      assert content =~ "| ID | Name |"
    end

    test "renders with agent having no capabilities" do
      agent = %{@agent | capabilities: []}
      %{"AGENTS.md" => content} = Template.render(agent, @team)

      # Should not show capabilities line when empty
      refute content =~ "Your capabilities: **general**"
    end

    test "renders with unknown role name" do
      agent = %{@agent | name: "Custom Agent"}
      result = Template.render(agent, @team)

      %{"SOUL.md" => soul} = result
      assert soul =~ "Custom Agent"
      assert soul =~ "a specialist on the team"
    end
  end

  describe "team_md/2" do
    test "renders only the TEAM.md content" do
      content = Template.team_md(@agent, @team)

      assert content =~ "Team Directory"
      assert content =~ "Backend Dev"
      assert content =~ "CTO"
    end
  end

  describe "role_capabilities/1" do
    test "returns capabilities for known roles" do
      assert Template.role_capabilities("CTO") == [
               "architecture",
               "code-review",
               "technical-planning"
             ]

      assert Template.role_capabilities("Backend Dev") == [
               "coding",
               "backend",
               "elixir",
               "database"
             ]

      assert Template.role_capabilities("QA Engineer") == [
               "coding",
               "testing",
               "quality-assurance"
             ]
    end

    test "returns empty list for unknown roles" do
      assert Template.role_capabilities("Unknown Role") == []
      assert Template.role_capabilities("default") == []
    end
  end

  describe "role_capabilities_map/0" do
    test "returns the full role capabilities map" do
      map = Template.role_capabilities_map()

      assert is_map(map)
      assert map_size(map) == 10
      assert Map.has_key?(map, "CTO")
      assert Map.has_key?(map, "Security Engineer")
    end
  end
end
