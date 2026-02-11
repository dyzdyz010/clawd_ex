defmodule ClawdExWeb.SkillsLive do
  @moduledoc """
  Skills 管理页面 - 列出、启用/禁用、查看 skills 详情
  """
  use ClawdExWeb, :live_view

  alias ClawdEx.Skills.{Registry, Gate}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Skills",
       skills: load_skills(),
       expanded: nil
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Registry.refresh()
    # 给 GenServer 一点时间处理 cast
    Process.sleep(100)

    {:noreply,
     socket
     |> assign(skills: load_skills())
     |> put_flash(:info, "Skills refreshed")}
  end

  @impl true
  def handle_event("toggle", %{"name" => name, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"
    Registry.toggle_skill(name, !enabled?)

    {:noreply, assign(socket, skills: load_skills())}
  end

  @impl true
  def handle_event("expand", %{"name" => name}, socket) do
    expanded = if socket.assigns.expanded == name, do: nil, else: name
    {:noreply, assign(socket, expanded: expanded)}
  end

  defp load_skills do
    all = Registry.list_all_skills()

    all
    |> Enum.map(fn skill ->
      case Registry.get_skill_details(skill.name) do
        {:ok, details} -> details
        _ -> %{skill: skill, eligible: Gate.eligible?(skill), gate_status: Gate.detailed_status(skill), disabled: false}
      end
    end)
    |> Enum.sort_by(fn d -> d.skill.name end)
  end

  defp source_badge(source) do
    case source do
      :bundled -> {"Bundled", "bg-blue-600"}
      :managed -> {"Managed", "bg-purple-600"}
      :workspace -> {"Workspace", "bg-green-600"}
      _ -> {"Unknown", "bg-gray-600"}
    end
  end

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
        <button phx-click="refresh" class="flex items-center gap-2 bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-lg transition-colors">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15" />
          </svg>
          Refresh
        </button>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div class="bg-gray-800 rounded-lg p-4">
          <div class="text-2xl font-bold text-white"><%= length(@skills) %></div>
          <div class="text-sm text-gray-400">Total Skills</div>
        </div>
        <div class="bg-gray-800 rounded-lg p-4">
          <div class="text-2xl font-bold text-green-400"><%= Enum.count(@skills, & &1.eligible) %></div>
          <div class="text-sm text-gray-400">Eligible</div>
        </div>
        <div class="bg-gray-800 rounded-lg p-4">
          <div class="text-2xl font-bold text-red-400"><%= Enum.count(@skills, &(!&1.eligible)) %></div>
          <div class="text-sm text-gray-400">Unavailable</div>
        </div>
      </div>

      <!-- Skills List -->
      <div class="space-y-3">
        <%= for detail <- @skills do %>
          <% {source_label, source_color} = source_badge(detail.skill.source) %>
          <div class="bg-gray-800 rounded-lg overflow-hidden">
            <!-- Skill Row -->
            <div class="flex items-center justify-between p-4 cursor-pointer hover:bg-gray-750" phx-click="expand" phx-value-name={detail.skill.name}>
              <div class="flex items-center gap-4 flex-1 min-w-0">
                <!-- Status Indicator -->
                <div class={"w-3 h-3 rounded-full flex-shrink-0 #{if detail.eligible && !detail.disabled, do: "bg-green-500", else: "bg-gray-500"}"} />

                <div class="min-w-0 flex-1">
                  <div class="flex items-center gap-2">
                    <span class="text-white font-medium"><%= detail.skill.name %></span>
                    <span class={"text-xs px-2 py-0.5 rounded-full text-white #{source_color}"}><%= source_label %></span>
                    <%= unless detail.eligible do %>
                      <span class="text-xs px-2 py-0.5 rounded-full bg-red-600/30 text-red-400">Requirements not met</span>
                    <% end %>
                  </div>
                  <p class="text-sm text-gray-400 truncate"><%= detail.skill.description %></p>
                </div>
              </div>

              <div class="flex items-center gap-3 flex-shrink-0">
                <!-- Toggle -->
                <button
                  phx-click="toggle"
                  phx-value-name={detail.skill.name}
                  phx-value-enabled={to_string(!detail.disabled)}
                  class={"relative inline-flex h-6 w-11 items-center rounded-full transition-colors #{if !detail.disabled, do: "bg-blue-600", else: "bg-gray-600"}"}
                >
                  <span class={"inline-block h-4 w-4 transform rounded-full bg-white transition-transform #{if !detail.disabled, do: "translate-x-6", else: "translate-x-1"}"} />
                </button>

                <!-- Expand Arrow -->
                <svg class={"w-5 h-5 text-gray-400 transition-transform #{if @expanded == detail.skill.name, do: "rotate-180"}"} fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
                </svg>
              </div>
            </div>

            <!-- Expanded Content -->
            <%= if @expanded == detail.skill.name do %>
              <div class="border-t border-gray-700 p-4 space-y-4">
                <!-- Gate Status -->
                <div>
                  <h4 class="text-sm font-medium text-gray-300 mb-2">Requirements</h4>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                    <%= for {bin, found} <- detail.gate_status.bins.details do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={"#{if found, do: "text-green-400", else: "text-red-400"}"}><%= if found, do: "✓", else: "✗" %></span>
                        <span class="text-gray-300">bin: <code class="text-blue-400"><%= bin %></code></span>
                      </div>
                    <% end %>
                    <%= for {bin, found} <- detail.gate_status.any_bins.details do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={"#{if found, do: "text-green-400", else: "text-yellow-400"}"}><%= if found, do: "✓", else: "?" %></span>
                        <span class="text-gray-300">anyBin: <code class="text-blue-400"><%= bin %></code></span>
                      </div>
                    <% end %>
                    <%= for {var, set} <- detail.gate_status.env.details do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={"#{if set, do: "text-green-400", else: "text-red-400"}"}><%= if set, do: "✓", else: "✗" %></span>
                        <span class="text-gray-300">env: <code class="text-blue-400"><%= var %></code></span>
                      </div>
                    <% end %>
                    <%= if detail.gate_status.os.required do %>
                      <div class="flex items-center gap-2 text-sm">
                        <span class={"#{if detail.gate_status.os.met, do: "text-green-400", else: "text-red-400"}"}><%= if detail.gate_status.os.met, do: "✓", else: "✗" %></span>
                        <span class="text-gray-300">OS: <code class="text-blue-400"><%= inspect(detail.gate_status.os.required) %></code></span>
                      </div>
                    <% end %>
                    <%= if Enum.empty?(detail.gate_status.bins.details) && Enum.empty?(detail.gate_status.any_bins.details) && Enum.empty?(detail.gate_status.env.details) && !detail.gate_status.os.required do %>
                      <span class="text-sm text-gray-500">No specific requirements</span>
                    <% end %>
                  </div>
                </div>

                <!-- SKILL.md Content -->
                <div>
                  <h4 class="text-sm font-medium text-gray-300 mb-2">SKILL.md</h4>
                  <pre class="bg-gray-900 rounded-lg p-4 text-sm text-gray-300 overflow-x-auto whitespace-pre-wrap"><%= detail.skill.content %></pre>
                </div>

                <!-- Metadata -->
                <div>
                  <h4 class="text-sm font-medium text-gray-300 mb-2">Location</h4>
                  <code class="text-sm text-gray-400"><%= detail.skill.location %></code>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <%= if Enum.empty?(@skills) do %>
          <div class="bg-gray-800 rounded-lg p-8 text-center">
            <p class="text-gray-400">No skills loaded. Add SKILL.md files to priv/skills/ or refresh.</p>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
