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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto px-4 py-8">
        <div class="flex items-center gap-4 mb-8">
          <.link navigate={~p"/agents"} class="text-gray-400 hover:text-white">
            ← Back
          </.link>
          <h1 class="text-2xl font-bold"><%= @page_title %></h1>
        </div>

        <div class="bg-gray-800 rounded-lg p-6">
          <.form
            for={@form}
            phx-change="validate"
            phx-submit="save"
            class="space-y-6"
          >
            <!-- Name -->
            <div>
              <label class="block text-sm font-medium mb-2">
                Name <span class="text-red-400">*</span>
              </label>
              <.form_input
                field={@form[:name]}
                type="text"
                placeholder="My Agent"
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white"
              />
            </div>

            <!-- Default Model -->
            <div>
              <label class="block text-sm font-medium mb-2">Default Model</label>
              <.form_input
                field={@form[:default_model]}
                type="select"
                options={model_options(@available_models)}
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white"
              />
              <p class="text-xs text-gray-400 mt-1">
                The AI model to use for this agent's conversations
              </p>
            </div>

            <!-- Workspace Path -->
            <div>
              <label class="block text-sm font-medium mb-2">Workspace Path</label>
              <.form_input
                field={@form[:workspace_path]}
                type="text"
                placeholder="/path/to/workspace"
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white font-mono text-sm"
              />
              <p class="text-xs text-gray-400 mt-1">
                Local directory for the agent's file operations
              </p>
            </div>

            <!-- System Prompt -->
            <div>
              <label class="block text-sm font-medium mb-2">System Prompt</label>
              <.form_input
                field={@form[:system_prompt]}
                type="textarea"
                rows="8"
                placeholder="You are a helpful assistant..."
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white font-mono text-sm"
              />
              <p class="text-xs text-gray-400 mt-1">
                Instructions that define the agent's behavior and personality
              </p>
            </div>

            <!-- Config (JSON) -->
            <div>
              <label class="block text-sm font-medium mb-2">Config (JSON)</label>
              <textarea
                name="agent[config]"
                id="agent_config"
                rows="4"
                placeholder="{}"
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white font-mono text-sm"
              ><%= Jason.encode!(@agent.config || %{}, pretty: true) %></textarea>
              <p class="text-xs text-gray-400 mt-1">
                Additional configuration in JSON format
              </p>
            </div>

            <!-- Active -->
            <div class="flex items-center gap-3">
              <.form_input
                field={@form[:active]}
                type="checkbox"
                class="w-5 h-5 bg-gray-700 border-gray-600 rounded"
              />
              <label class="text-sm font-medium">Active</label>
              <span class="text-xs text-gray-400">
                Inactive agents won't process new messages
              </span>
            </div>

            <!-- Actions -->
            <div class="flex gap-4 pt-4 border-t border-gray-700">
              <button type="submit" class="btn-primary flex-1">
                <%= if @agent.id, do: "Update Agent", else: "Create Agent" %>
              </button>
              <.link navigate={~p"/agents"} class="btn-secondary">
                Cancel
              </.link>
            </div>
          </.form>
        </div>
      </div>
    """
  end

  defp model_options(models) do
    Enum.map(models, fn model ->
      {model, model}
    end)
  end
end
