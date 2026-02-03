defmodule ClawdExWeb.AgentFormLive do
  @moduledoc """
  Agent 创建/编辑表单
  """
  use ClawdExWeb, :live_view

  import ClawdExWeb.AgentFormComponents

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.AI.Models

  @impl true
  def mount(params, _session, socket) do
    {agent, title} =
      case params do
        %{"id" => id} ->
          agent = Repo.get!(Agent, id)
          {agent, "Edit Agent: #{agent.name}"}

        _ ->
          {%Agent{}, "New Agent"}
      end

    changeset = Agent.changeset(agent, %{})

    socket =
      socket
      |> assign(:page_title, title)
      |> assign(:agent, agent)
      |> assign(:form, to_form(changeset))
      |> assign(:available_models, Models.all() |> Map.keys() |> Enum.sort())

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    params = parse_config_param(params)

    changeset =
      socket.assigns.agent
      |> Agent.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"agent" => params}, socket) do
    params = parse_config_param(params)

    result =
      if socket.assigns.agent.id do
        socket.assigns.agent
        |> Agent.changeset(params)
        |> Repo.update()
      else
        %Agent{}
        |> Agent.changeset(params)
        |> Repo.insert()
      end

    case result do
      {:ok, _agent} ->
        socket =
          socket
          |> put_flash(
            :info,
            "Agent #{if socket.assigns.agent.id, do: "updated", else: "created"} successfully"
          )
          |> push_navigate(to: ~p"/agents")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp parse_config_param(params) do
    case params["config"] do
      nil -> params
      "" -> Map.put(params, "config", %{})
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, config} -> Map.put(params, "config", config)
          {:error, _} -> Map.put(params, "config", %{})
        end
      _ -> params
    end
  end

  defp model_options(models) do
    Enum.map(models, fn model ->
      {model, model}
    end)
  end
end
