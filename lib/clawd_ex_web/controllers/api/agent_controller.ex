defmodule ClawdExWeb.Api.AgentController do
  @moduledoc """
  Agent CRUD REST API controller.
  """
  use ClawdExWeb, :controller

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  import Ecto.Query

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  GET /api/v1/agents — List all agents
  """
  def index(conn, params) do
    query =
      from(a in Agent, order_by: [asc: a.name])
      |> maybe_filter_active(params)

    agents = Repo.all(query)

    json(conn, %{
      data: Enum.map(agents, &format_agent/1),
      total: length(agents)
    })
  end

  @doc """
  GET /api/v1/agents/:id — Get agent details
  """
  def show(conn, %{"id" => id}) do
    case Repo.get(Agent, id) do
      nil -> {:error, :not_found}
      agent -> json(conn, %{data: format_agent_detail(agent)})
    end
  end

  @doc """
  POST /api/v1/agents — Create a new agent
  """
  def create(conn, %{"agent" => agent_params}) do
    changeset = Agent.changeset(%Agent{}, agent_params)

    case Repo.insert(changeset) do
      {:ok, agent} ->
        conn
        |> put_status(:created)
        |> json(%{data: format_agent_detail(agent)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Also support flat params (no "agent" wrapper)
  def create(conn, params) when is_map(params) do
    # Filter out path params like "id" and action params
    agent_params =
      params
      |> Map.drop(["action", "controller"])

    create(conn, %{"agent" => agent_params})
  end

  @doc """
  PUT /api/v1/agents/:id — Update an agent
  """
  def update(conn, %{"id" => id} = params) do
    case Repo.get(Agent, id) do
      nil ->
        {:error, :not_found}

      agent ->
        agent_params = params["agent"] || Map.drop(params, ["id", "action", "controller"])
        changeset = Agent.changeset(agent, agent_params)

        case Repo.update(changeset) do
          {:ok, updated} ->
            json(conn, %{data: format_agent_detail(updated)})

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  # Private helpers

  defp maybe_filter_active(query, %{"active" => "true"}) do
    where(query, [a], a.active == true)
  end

  defp maybe_filter_active(query, %{"active" => "false"}) do
    where(query, [a], a.active == false)
  end

  defp maybe_filter_active(query, _), do: query

  defp format_agent(%Agent{} = agent) do
    %{
      id: agent.id,
      name: agent.name,
      default_model: agent.default_model,
      active: agent.active,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end

  defp format_agent_detail(%Agent{} = agent) do
    %{
      id: agent.id,
      name: agent.name,
      workspace_path: agent.workspace_path,
      default_model: agent.default_model,
      system_prompt: agent.system_prompt,
      config: agent.config,
      active: agent.active,
      allowed_tools: agent.allowed_tools,
      denied_tools: agent.denied_tools,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end
end
