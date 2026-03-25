defmodule ClawdEx.Agents.WorkspaceManager do
  @moduledoc """
  Per-agent workspace management.
  Creates workspace directories and renders agent-specific templates.
  """

  require Logger

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Agents.Template

  @workspaces_root "~/.clawd/workspaces"

  @doc """
  Initialize workspace for an agent.
  Creates the workspace directory, renders all templates, and updates workspace_path in DB.

  If the agent already has a workspace_path, uses that path.
  Otherwise generates one under #{@workspaces_root}/{slug}/.
  """
  def init_agent_workspace(%Agent{} = agent) do
    workspace = resolve_workspace(agent)
    expanded = Path.expand(workspace)

    with :ok <- File.mkdir_p(expanded),
         :ok <- File.mkdir_p(Path.join(expanded, "memory")) do
      # Load team from DB
      team = load_team(agent.id)

      # Set workspace on agent for template rendering
      agent_with_workspace = %{agent | workspace_path: expanded}

      # Render and write templates
      templates = Template.render(agent_with_workspace, team)

      Enum.each(templates, fn {filename, content} ->
        File.write!(Path.join(expanded, filename), content)
      end)

      # Also create MEMORY.md if it doesn't exist
      memory_path = Path.join(expanded, "MEMORY.md")

      unless File.exists?(memory_path) do
        File.write!(memory_path, "# Memory\n\n## Lessons Learned\n\n## Active Projects\n\n")
      end

      # Update workspace_path in DB if it wasn't set
      if is_nil(agent.workspace_path) or agent.workspace_path == "" do
        agent
        |> Agent.changeset(%{workspace_path: expanded})
        |> Repo.update()
      end

      Logger.info("Initialized workspace for agent #{agent.name}: #{expanded}")
      {:ok, expanded}
    else
      {:error, reason} ->
        Logger.error("Failed to init workspace for agent #{agent.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Refresh TEAM.md for an agent from current DB state.
  """
  def refresh_team_md(%Agent{} = agent) do
    workspace = agent.workspace_path

    if workspace do
      expanded = Path.expand(workspace)
      team = load_team(agent.id)
      content = Template.team_md(agent, team)

      case File.write(Path.join(expanded, "TEAM.md"), content) do
        :ok ->
          Logger.debug("Refreshed TEAM.md for agent #{agent.name}")
          :ok

        {:error, reason} ->
          Logger.warning("Failed to refresh TEAM.md for agent #{agent.name}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :no_workspace}
    end
  end

  @doc """
  Convert agent name to kebab-case slug for directory naming.

  ## Examples

      iex> ClawdEx.Agents.WorkspaceManager.slug("Backend Dev")
      "backend-dev"

      iex> ClawdEx.Agents.WorkspaceManager.slug("UI/UX Designer")
      "ui-ux-designer"

      iex> ClawdEx.Agents.WorkspaceManager.slug("CTO")
      "cto"
  """
  def slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  @doc """
  Backfill all existing active agents with capabilities and per-agent workspaces.
  Updates capabilities from role map (if currently empty) and creates workspace dirs.
  """
  def backfill_all do
    agents = Repo.all(from(a in Agent, where: a.active == true))

    results =
      Enum.map(agents, fn agent ->
        # Update capabilities if empty
        caps =
          if agent.capabilities == [] do
            Template.role_capabilities(agent.name)
          else
            agent.capabilities
          end

        {:ok, updated} =
          agent
          |> Agent.changeset(%{capabilities: caps})
          |> Repo.update()

        case init_agent_workspace(updated) do
          {:ok, path} ->
            Logger.info("Backfilled agent #{agent.name} → #{path}")
            {:ok, agent.name, path}

          {:error, reason} ->
            Logger.warning("Failed to backfill agent #{agent.name}: #{inspect(reason)}")
            {:error, agent.name, reason}
        end
      end)

    ok_count = Enum.count(results, &match?({:ok, _, _}, &1))
    err_count = Enum.count(results, &match?({:error, _, _}, &1))
    Logger.info("Backfill complete: #{ok_count} ok, #{err_count} errors")
    results
  end

  # Resolve workspace path: use existing or generate from slug
  defp resolve_workspace(%Agent{workspace_path: path})
       when is_binary(path) and path != "" do
    path
  end

  defp resolve_workspace(%Agent{name: name}) do
    Path.join(@workspaces_root, slug(name))
  end

  # Load all active agents except the given one, for TEAM.md
  defp load_team(exclude_agent_id) do
    Repo.all(
      from(a in Agent,
        where: a.active == true and a.id != ^exclude_agent_id,
        order_by: [asc: a.id],
        select: %{
          id: a.id,
          name: a.name,
          capabilities: a.capabilities,
          default_model: a.default_model
        }
      )
    )
  end
end
