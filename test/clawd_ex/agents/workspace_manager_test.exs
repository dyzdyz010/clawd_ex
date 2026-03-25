defmodule ClawdEx.Agents.WorkspaceManagerTest do
  use ClawdEx.DataCase, async: true

  alias ClawdEx.Agents.Agent
  alias ClawdEx.Agents.WorkspaceManager

  describe "slug/1" do
    test "converts simple name to lowercase" do
      assert WorkspaceManager.slug("CTO") == "cto"
    end

    test "converts spaces to hyphens" do
      assert WorkspaceManager.slug("Backend Dev") == "backend-dev"
    end

    test "converts slashes and special chars to hyphens" do
      assert WorkspaceManager.slug("UI/UX Designer") == "ui-ux-designer"
    end

    test "collapses multiple special chars into single hyphen" do
      assert WorkspaceManager.slug("QA   Engineer") == "qa-engineer"
    end

    test "trims leading and trailing hyphens" do
      assert WorkspaceManager.slug("  default  ") == "default"
    end

    test "handles already kebab-case names" do
      assert WorkspaceManager.slug("backend-dev") == "backend-dev"
    end
  end

  describe "init_agent_workspace/1" do
    setup do
      # Use a temp directory for workspaces
      tmp_dir = Path.join(System.tmp_dir!(), "clawd_test_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "creates workspace directory and template files", %{tmp_dir: tmp_dir} do
      workspace_path = Path.join(tmp_dir, "test-agent")

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "test-agent-#{System.unique_integer([:positive])}",
          workspace_path: workspace_path,
          capabilities: ["coding", "testing"]
        })
        |> Repo.insert()

      assert {:ok, ^workspace_path} = WorkspaceManager.init_agent_workspace(agent)

      # Verify directory was created
      assert File.dir?(workspace_path)
      assert File.dir?(Path.join(workspace_path, "memory"))

      # Verify template files were written
      assert File.exists?(Path.join(workspace_path, "AGENTS.md"))
      assert File.exists?(Path.join(workspace_path, "SOUL.md"))
      assert File.exists?(Path.join(workspace_path, "IDENTITY.md"))
      assert File.exists?(Path.join(workspace_path, "TEAM.md"))
      assert File.exists?(Path.join(workspace_path, "MEMORY.md"))

      # Verify content contains agent info
      agents_md = File.read!(Path.join(workspace_path, "AGENTS.md"))
      assert agents_md =~ agent.name
    end

    test "generates workspace_path when not set", %{tmp_dir: _tmp_dir} do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "workspace-gen-test-#{System.unique_integer([:positive])}",
          capabilities: ["coding"]
        })
        |> Repo.insert()

      assert is_nil(agent.workspace_path)

      assert {:ok, path} = WorkspaceManager.init_agent_workspace(agent)
      assert String.contains?(path, ".clawd/workspaces/")

      # Verify DB was updated
      reloaded = Repo.get!(Agent, agent.id)
      assert reloaded.workspace_path == path

      # Cleanup
      File.rm_rf(path)
    end

    test "includes team members in TEAM.md", %{tmp_dir: tmp_dir} do
      # Create a teammate first
      {:ok, teammate} =
        %Agent{}
        |> Agent.changeset(%{
          name: "teammate-#{System.unique_integer([:positive])}",
          capabilities: ["architecture"]
        })
        |> Repo.insert()

      workspace_path = Path.join(tmp_dir, "team-test")

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "team-test-agent-#{System.unique_integer([:positive])}",
          workspace_path: workspace_path,
          capabilities: ["coding"]
        })
        |> Repo.insert()

      assert {:ok, _} = WorkspaceManager.init_agent_workspace(agent)

      team_md = File.read!(Path.join(workspace_path, "TEAM.md"))
      assert team_md =~ teammate.name

      # Cleanup teammate workspace if generated
      if teammate_reloaded = Repo.get(Agent, teammate.id) do
        if teammate_reloaded.workspace_path, do: File.rm_rf(teammate_reloaded.workspace_path)
      end
    end
  end

  describe "refresh_team_md/1" do
    setup do
      tmp_dir = Path.join(System.tmp_dir!(), "clawd_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      {:ok, tmp_dir: tmp_dir}
    end

    test "updates TEAM.md file", %{tmp_dir: tmp_dir} do
      workspace_path = Path.join(tmp_dir, "refresh-test")
      File.mkdir_p!(workspace_path)

      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "refresh-test-#{System.unique_integer([:positive])}",
          workspace_path: workspace_path,
          capabilities: ["coding"]
        })
        |> Repo.insert()

      assert :ok = WorkspaceManager.refresh_team_md(agent)
      assert File.exists?(Path.join(workspace_path, "TEAM.md"))

      content = File.read!(Path.join(workspace_path, "TEAM.md"))
      assert content =~ "Team Directory"
      assert content =~ agent.name
    end

    test "returns error when no workspace_path set" do
      {:ok, agent} =
        %Agent{}
        |> Agent.changeset(%{
          name: "no-workspace-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert()

      assert {:error, :no_workspace} = WorkspaceManager.refresh_team_md(agent)
    end
  end
end
