defmodule ClawdExWeb.AgentFormLive do
  @moduledoc """
  Agent 创建/编辑表单
  """
  use ClawdExWeb, :live_view

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
      |> assign(:changeset, changeset)
      |> assign(:available_models, Models.all() |> Map.keys() |> Enum.sort())

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    changeset =
      socket.assigns.agent
      |> Agent.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  @impl true
  def handle_event("save", %{"agent" => params}, socket) do
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
      {:ok, agent} ->
        socket =
          socket
          |> put_flash(:info, "Agent #{if socket.assigns.agent.id, do: "updated", else: "created"} successfully")
          |> push_navigate(to: ~p"/agents")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
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
            for={@changeset}
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
                field={@changeset[:name]}
                type="text"
                placeholder="My Agent"
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white"
              />
            </div>

            <!-- Default Model -->
            <div>
              <label class="block text-sm font-medium mb-2">Default Model</label>
              <.form_input
                field={@changeset[:default_model]}
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
                field={@changeset[:workspace_path]}
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
                field={@changeset[:system_prompt]}
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
              <.form_input
                field={@changeset[:config]}
                type="textarea"
                rows="4"
                placeholder="{}"
                value={Jason.encode!(@changeset.data.config || %{}, pretty: true)}
                class="w-full bg-gray-700 border-gray-600 rounded-lg px-4 py-2 text-white font-mono text-sm"
              />
              <p class="text-xs text-gray-400 mt-1">
                Additional configuration in JSON format
              </p>
            </div>

            <!-- Active -->
            <div class="flex items-center gap-3">
              <.form_input
                field={@changeset[:active]}
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

  # Custom form input component
  defp form_input(assigns) do
    assigns = assign_new(assigns, :type, fn -> "text" end)
    assigns = assign_new(assigns, :class, fn -> "" end)
    assigns = assign_new(assigns, :rows, fn -> 3 end)
    assigns = assign_new(assigns, :placeholder, fn -> "" end)
    assigns = assign_new(assigns, :options, fn -> [] end)

    ~H"""
    <%= case @type do %>
      <% "textarea" -> %>
        <textarea
          name={@field.name}
          id={@field.id}
          rows={@rows}
          placeholder={@placeholder}
          class={@class <> input_error_class(@field)}
        ><%= @field.value %></textarea>
      <% "select" -> %>
        <select name={@field.name} id={@field.id} class={@class <> input_error_class(@field)}>
          <%= for {label, value} <- @options do %>
            <option value={value} selected={@field.value == value}><%= label %></option>
          <% end %>
        </select>
      <% "checkbox" -> %>
        <input
          type="checkbox"
          name={@field.name}
          id={@field.id}
          value="true"
          checked={@field.value == true or @field.value == "true"}
          class={@class}
        />
        <input type="hidden" name={@field.name} value="false" />
      <% _ -> %>
        <input
          type={@type}
          name={@field.name}
          id={@field.id}
          value={@field.value}
          placeholder={@placeholder}
          class={@class <> input_error_class(@field)}
        />
    <% end %>
    <%= if @field.errors != [] do %>
      <div class="text-red-400 text-sm mt-1">
        <%= for error <- @field.errors do %>
          <span><%= format_error(error) %></span>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp input_error_class(field) do
    if field.errors != [], do: " border-red-500", else: ""
  end

  defp format_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
