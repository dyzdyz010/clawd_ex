defmodule ClawdExWeb.SkillsLive do
  @moduledoc """
  Skills management page - list, search/filter, enable/disable, view skill details
  """
  use ClawdExWeb, :live_view

  alias ClawdEx.Skills.{Registry, Gate}

  @impl true
  def mount(_params, _session, socket) do
    all_skills = load_skills()

    {:ok,
     assign(socket,
       page_title: "Skills",
       skills: all_skills,
       filtered_skills: all_skills,
       expanded: nil,
       search: "",
       status_filter: "all"
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(search: search) |> apply_filters()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(status_filter: status) |> apply_filters()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Registry.refresh()
    Process.sleep(100)

    all_skills = load_skills()

    {:noreply,
     socket
     |> assign(skills: all_skills)
     |> apply_filters()
     |> put_flash(:info, "Skills refreshed")}
  end

  @impl true
  def handle_event("toggle", %{"name" => name, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"
    Registry.toggle_skill(name, !enabled?)

    all_skills = load_skills()

    {:noreply,
     socket
     |> assign(skills: all_skills)
     |> apply_filters()}
  end

  @impl true
  def handle_event("expand", %{"name" => name}, socket) do
    expanded = if socket.assigns.expanded == name, do: nil, else: name
    {:noreply, assign(socket, expanded: expanded)}
  end

  defp apply_filters(socket) do
    search = String.downcase(socket.assigns.search)
    status = socket.assigns.status_filter

    filtered =
      socket.assigns.skills
      |> filter_by_search(search)
      |> filter_by_status(status)

    assign(socket, filtered_skills: filtered)
  end

  defp filter_by_search(skills, ""), do: skills

  defp filter_by_search(skills, search) do
    Enum.filter(skills, fn detail ->
      String.contains?(String.downcase(detail.skill.name), search) ||
        String.contains?(String.downcase(detail.skill.description || ""), search)
    end)
  end

  defp filter_by_status(skills, "all"), do: skills
  defp filter_by_status(skills, "eligible"), do: Enum.filter(skills, & &1.eligible)
  defp filter_by_status(skills, "unavailable"), do: Enum.filter(skills, &(!&1.eligible))
  defp filter_by_status(skills, "disabled"), do: Enum.filter(skills, & &1.disabled)
  defp filter_by_status(skills, _), do: skills

  defp load_skills do
    all = Registry.list_all_skills()

    all
    |> Enum.map(fn skill ->
      case Registry.get_skill_details(skill.name) do
        {:ok, details} ->
          details

        _ ->
          %{
            skill: skill,
            eligible: Gate.eligible?(skill),
            gate_status: Gate.detailed_status(skill),
            disabled: false
          }
      end
    end)
    |> Enum.sort_by(fn d -> d.skill.name end)
  end

  defp skill_status(detail) do
    cond do
      detail.disabled -> {:disabled, "Disabled", "bg-gray-500/20 text-gray-400"}
      detail.eligible -> {:loaded, "Loaded", "bg-green-500/20 text-green-400"}
      true -> {:error, "Unavailable", "bg-red-500/20 text-red-400"}
    end
  end

  defp source_badge(source) do
    case source do
      :bundled -> {"Bundled", "bg-blue-600"}
      :managed -> {"Managed", "bg-purple-600"}
      :workspace -> {"Workspace", "bg-green-600"}
      _ -> {"Unknown", "bg-gray-600"}
    end
  end

  defp render_skill_content(content) when is_binary(content) do
    # Strip frontmatter before rendering
    body =
      case Regex.run(~r/\A---\n.*?\n---\n(.*)/s, content) do
        [_, body] -> body
        _ -> content
      end

    ClawdExWeb.ContentRenderer.render_content(body)
  end

  defp render_skill_content(_), do: Phoenix.HTML.raw("")

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 p-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-white">Skills</h1>
          <p class="text-gray-400 text-sm mt-1">Manage loaded skills and their requirements</p>
        </div>
        <button
          phx-click="refresh"
          class="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg transition-colors"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
            />
          </svg>
          Refresh
        </button>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="bg-gray-800 rounded-lg p-4">
          <div class="text-2xl font-bold text-white"><%= length(@skills) %></div>
          <div class="text-xs text-gray-500 mt-1">Total Skills</div>
        </div>
        <div class="bg-gray-800 rounded-lg p-4">
          <div class="text-2xl font-bold text-green-400">
            <%= Enum.count(@skills, &(&1.eligible && !&1.disabled)) %>
          </div>
          <div class="text-xs text-gray-500 mt-1">Loaded</div>
        </div>
        <div class="bg-gray-800 rounded-lg p-4">
          <div class="text-2xl font-bold text-red-400">
            <%= Enum.count(@skills, &(!&1.eligible)) %>
          </div>
          <div class="text-xs text-gray-500 mt-1">Unavailable</div>
        </div>
        <div class="bg-gray-800 rounded-lg p-4">
          <div class="text-2xl font-bold text-gray-400">
            <%= Enum.count(@skills, & &1.disabled) %>
          </div>
          <div class="text-xs text-gray-500 mt-1">Disabled</div>
        </div>
      </div>

      <!-- Search & Filter -->
      <div class="flex flex-col sm:flex-row gap-4">
        <div class="relative flex-1">
          <svg
            class="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
            />
          </svg>
          <input
            type="text"
            value={@search}
            phx-keyup="search"
            phx-value-search={@search}
            phx-debounce="200"
            name="search"
            placeholder="Search skills by name or description..."
            class="w-full pl-10 pr-4 py-2 bg-gray-800 border border-gray-700 rounded-lg text-white placeholder-gray-500 focus:outline-none focus:border-blue-500"
          />
        </div>
        <div class="flex gap-2">
          <.filter_btn current={@status_filter} value="all" label="All" />
          <.filter_btn current={@status_filter} value="eligible" label="Loaded" />
          <.filter_btn current={@status_filter} value="unavailable" label="Unavailable" />
          <.filter_btn current={@status_filter} value="disabled" label="Disabled" />
        </div>
      </div>

      <!-- Skills List -->
      <div class="space-y-3">
        <%= for detail <- @filtered_skills do %>
          <% {_status_key, status_label, status_classes} = skill_status(detail) %>
          <% {source_label, source_color} = source_badge(detail.skill.source) %>
          <div class="bg-gray-800 rounded-lg overflow-hidden">
            <!-- Skill Row -->
            <div
              class="flex items-center justify-between p-4 cursor-pointer hover:bg-gray-700/50 transition-colors"
              phx-click="expand"
              phx-value-name={detail.skill.name}
            >
              <div class="flex items-center gap-4 flex-1 min-w-0">
                <!-- Status Indicator -->
                <div class={[
                  "w-3 h-3 rounded-full flex-shrink-0",
                  if(detail.eligible && !detail.disabled, do: "bg-green-500", else: if(detail.disabled, do: "bg-gray-500", else: "bg-red-500"))
                ]} />

                <div class="min-w-0 flex-1">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="text-white font-medium"><%= detail.skill.name %></span>
                    <span class={"text-xs px-2 py-0.5 rounded-full text-white #{source_color}"}>
                      <%= source_label %>
                    </span>
                    <span class={"text-xs px-2 py-0.5 rounded-full #{status_classes}"}>
                      <%= status_label %>
                    </span>
                  </div>
                  <p class="text-sm text-gray-400 truncate mt-0.5">
                    <%= detail.skill.description %>
                  </p>
                </div>
              </div>

              <div class="flex items-center gap-3 flex-shrink-0 ml-4">
                <!-- Toggle -->
                <button
                  phx-click="toggle"
                  phx-value-name={detail.skill.name}
                  phx-value-enabled={to_string(!detail.disabled)}
                  class={[
                    "relative inline-flex h-6 w-11 items-center rounded-full transition-colors",
                    if(!detail.disabled, do: "bg-blue-600", else: "bg-gray-600")
                  ]}
                  title={if(!detail.disabled, do: "Disable", else: "Enable")}
                >
                  <span class={[
                    "inline-block h-4 w-4 transform rounded-full bg-white transition-transform",
                    if(!detail.disabled, do: "translate-x-6", else: "translate-x-1")
                  ]} />
                </button>

                <!-- Expand Arrow -->
                <svg
                  class={[
                    "w-5 h-5 text-gray-400 transition-transform",
                    if(@expanded == detail.skill.name, do: "rotate-180")
                  ]}
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </div>
            </div>

            <!-- Expanded Content -->
            <%= if @expanded == detail.skill.name do %>
              <div class="border-t border-gray-700 p-4 space-y-4">
                <!-- Location -->
                <div class="flex items-center gap-2 text-sm">
                  <svg
                    class="w-4 h-4 text-gray-500"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                    />
                  </svg>
                  <code class="text-gray-400"><%= detail.skill.location %></code>
                </div>

                <!-- Gate Status / Requirements -->
                <div>
                  <h4 class="text-sm font-medium text-gray-300 mb-2">Requirements</h4>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                    <%= for {bin, found} <- detail.gate_status.bins.details do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={if(found, do: "text-green-400", else: "text-red-400")}>
                          <%= if found, do: "✓", else: "✗" %>
                        </span>
                        <span class="text-gray-300">
                          bin: <code class="text-blue-400"><%= bin %></code>
                        </span>
                      </div>
                    <% end %>
                    <%= for {bin, found} <- detail.gate_status.any_bins.details do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={if(found, do: "text-green-400", else: "text-yellow-400")}>
                          <%= if found, do: "✓", else: "?" %>
                        </span>
                        <span class="text-gray-300">
                          anyBin: <code class="text-blue-400"><%= bin %></code>
                        </span>
                      </div>
                    <% end %>
                    <%= for {var, set} <- detail.gate_status.env.details do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={if(set, do: "text-green-400", else: "text-red-400")}>
                          <%= if set, do: "✓", else: "✗" %>
                        </span>
                        <span class="text-gray-300">
                          env: <code class="text-blue-400"><%= var %></code>
                        </span>
                      </div>
                    <% end %>
                    <%= if detail.gate_status.os.required do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={if(detail.gate_status.os.met, do: "text-green-400", else: "text-red-400")}>
                          <%= if detail.gate_status.os.met, do: "✓", else: "✗" %>
                        </span>
                        <span class="text-gray-300">
                          OS: <code class="text-blue-400"><%= inspect(detail.gate_status.os.required) %></code>
                        </span>
                      </div>
                    <% end %>
                    <%= if Enum.empty?(detail.gate_status.bins.details) && Enum.empty?(detail.gate_status.any_bins.details) && Enum.empty?(detail.gate_status.env.details) && !detail.gate_status.os.required do %>
                      <span class="text-sm text-gray-500">No specific requirements</span>
                    <% end %>
                  </div>
                </div>

                <!-- SKILL.md Content (rendered as HTML) -->
                <div>
                  <h4 class="text-sm font-medium text-gray-300 mb-2">SKILL.md</h4>
                  <div class="bg-gray-900 rounded-lg p-4 prose prose-invert prose-sm max-w-none overflow-x-auto">
                    <%= render_skill_content(detail.skill.content) %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if Enum.empty?(@filtered_skills) do %>
          <div class="bg-gray-800 rounded-lg p-8 text-center">
            <%= if @search != "" || @status_filter != "all" do %>
              <svg
                class="w-12 h-12 mx-auto mb-4 text-gray-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
              <p class="text-gray-400">No skills match your search criteria</p>
              <button
                phx-click="search"
                phx-value-search=""
                class="text-blue-400 hover:text-blue-300 text-sm mt-2"
              >
                Clear filters
              </button>
            <% else %>
              <svg
                class="w-12 h-12 mx-auto mb-4 text-gray-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M14.121 14.121L19 19m-7-7l7-7m-7 7l-7 7m7-7l-7-7"
                />
              </svg>
              <p class="text-gray-400">
                No skills loaded. Add SKILL.md files to priv/skills/ or refresh.
              </p>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp filter_btn(assigns) do
    classes =
      if assigns.current == assigns.value do
        "bg-blue-600 text-white"
      else
        "bg-gray-700 text-gray-300 hover:bg-gray-600"
      end

    assigns = assign(assigns, :classes, classes)

    ~H"""
    <button
      phx-click="filter_status"
      phx-value-status={@value}
      class={"px-3 py-2 rounded-lg text-sm transition-colors #{@classes}"}
    >
      {@label}
    </button>
    """
  end
end
