defmodule ClawdExWeb.CronJobsLive do
  use ClawdExWeb, :live_view

  alias ClawdEx.Automation

  @impl true
  def mount(_params, _session, socket) do
    jobs = Automation.list_jobs()
    stats = Automation.get_stats()

    {:ok,
     assign(socket,
       page_title: "Cron Jobs",
       jobs: jobs,
       stats: stats,
       filter: "all"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = Map.get(params, "filter", "all")
    jobs = load_jobs(filter)

    {:noreply, assign(socket, filter: filter, jobs: jobs)}
  end

  @impl true
  def handle_event("toggle", %{"id" => id}, socket) do
    job = Automation.get_job(id)

    case Automation.toggle_job(job) do
      {:ok, _updated} ->
        jobs = load_jobs(socket.assigns.filter)
        stats = Automation.get_stats()
        {:noreply, assign(socket, jobs: jobs, stats: stats)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to toggle job")}
    end
  end

  @impl true
  def handle_event("run_now", %{"id" => id}, socket) do
    job = Automation.get_job(id)

    case Automation.run_job_now(job) do
      {:ok, _run} ->
        {:noreply, put_flash(socket, :info, "Job started")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to run job")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    job = Automation.get_job(id)

    case Automation.delete_job(job) do
      {:ok, _} ->
        jobs = load_jobs(socket.assigns.filter)
        stats = Automation.get_stats()
        {:noreply, assign(socket, jobs: jobs, stats: stats)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete job")}
    end
  end

  defp load_jobs("enabled"), do: Automation.list_jobs(enabled_only: true)
  defp load_jobs(_), do: Automation.list_jobs()

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-white">Cron Jobs</h1>
          <p class="text-gray-400 text-sm mt-1">Manage scheduled tasks</p>
        </div>
        <.link navigate={~p"/cron/new"} class="btn-primary">
          <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          New Job
        </.link>
      </div>

      <!-- Stats -->
      <div class="grid grid-cols-2 md:grid-cols-5 gap-4">
        <.stat_card label="Total Jobs" value={@stats.total_jobs} />
        <.stat_card label="Enabled" value={@stats.enabled_jobs} color="green" />
        <.stat_card label="Disabled" value={@stats.disabled_jobs} color="gray" />
        <.stat_card label="Total Runs" value={@stats.total_runs} color="blue" />
        <.stat_card label="Failed Runs" value={@stats.failed_runs} color="red" />
      </div>

      <!-- Filters -->
      <div class="flex gap-2">
        <.filter_button filter={@filter} value="all" label="All" />
        <.filter_button filter={@filter} value="enabled" label="Enabled Only" />
      </div>

      <!-- Jobs List -->
      <div class="bg-gray-800 rounded-lg overflow-hidden">
        <%= if Enum.empty?(@jobs) do %>
          <div class="p-8 text-center text-gray-400">
            <svg class="w-12 h-12 mx-auto mb-4 opacity-50" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <p>No cron jobs yet</p>
            <.link navigate={~p"/cron/new"} class="text-blue-400 hover:underline mt-2 inline-block">
              Create your first job
            </.link>
          </div>
        <% else %>
          <table class="w-full">
            <thead class="bg-gray-700/50">
              <tr>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Name</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Schedule</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Last Run</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Runs</th>
                <th class="px-4 py-3 text-left text-xs font-medium text-gray-400 uppercase">Status</th>
                <th class="px-4 py-3 text-right text-xs font-medium text-gray-400 uppercase">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-700">
              <%= for job <- @jobs do %>
                <tr class="hover:bg-gray-700/30">
                  <td class="px-4 py-3">
                    <.link navigate={~p"/cron/#{job.id}"} class="font-medium text-white hover:text-blue-400">
                      <%= job.name %>
                    </.link>
                    <%= if job.description do %>
                      <p class="text-xs text-gray-500 truncate max-w-xs"><%= job.description %></p>
                    <% end %>
                  </td>
                  <td class="px-4 py-3">
                    <code class="text-sm text-gray-300 bg-gray-700 px-2 py-1 rounded">
                      <%= job.schedule %>
                    </code>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-400">
                    <%= if job.last_run_at do %>
                      <%= format_datetime(job.last_run_at) %>
                    <% else %>
                      <span class="text-gray-500">Never</span>
                    <% end %>
                  </td>
                  <td class="px-4 py-3 text-sm text-gray-400">
                    <%= job.run_count %>
                  </td>
                  <td class="px-4 py-3">
                    <.status_badge enabled={job.enabled} />
                  </td>
                  <td class="px-4 py-3 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <button
                        phx-click="run_now"
                        phx-value-id={job.id}
                        class="text-blue-400 hover:text-blue-300"
                        title="Run Now"
                      >
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                        </svg>
                      </button>
                      <button
                        phx-click="toggle"
                        phx-value-id={job.id}
                        class={if job.enabled, do: "text-yellow-400 hover:text-yellow-300", else: "text-green-400 hover:text-green-300"}
                        title={if job.enabled, do: "Disable", else: "Enable"}
                      >
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <%= if job.enabled do %>
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 9v6m4-6v6m7-3a9 9 0 11-18 0 9 9 0 0118 0z" />
                          <% else %>
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
                          <% end %>
                        </svg>
                      </button>
                      <.link navigate={~p"/cron/#{job.id}/edit"} class="text-gray-400 hover:text-white">
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
                        </svg>
                      </.link>
                      <button
                        phx-click="delete"
                        phx-value-id={job.id}
                        data-confirm="Are you sure you want to delete this job?"
                        class="text-red-400 hover:text-red-300"
                      >
                        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
                        </svg>
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp stat_card(assigns) do
    color_classes =
      case assigns[:color] do
        "green" -> "text-green-400"
        "red" -> "text-red-400"
        "blue" -> "text-blue-400"
        "gray" -> "text-gray-400"
        _ -> "text-white"
      end

    assigns = assign(assigns, :color_classes, color_classes)

    ~H"""
    <div class="bg-gray-800 rounded-lg p-4">
      <div class={"text-2xl font-bold #{@color_classes}"}><%= @value %></div>
      <div class="text-xs text-gray-500 mt-1"><%= @label %></div>
    </div>
    """
  end

  defp filter_button(assigns) do
    active = assigns.filter == assigns.value

    classes =
      if active do
        "bg-blue-600 text-white"
      else
        "bg-gray-700 text-gray-300 hover:bg-gray-600"
      end

    assigns = assign(assigns, :classes, classes)

    ~H"""
    <.link patch={~p"/cron?filter=#{@value}"} class={"px-4 py-2 rounded-lg text-sm #{@classes}"}>
      <%= @label %>
    </.link>
    """
  end

  defp status_badge(assigns) do
    {text, classes} =
      if assigns.enabled do
        {"Enabled", "bg-green-500/20 text-green-400"}
      else
        {"Disabled", "bg-gray-500/20 text-gray-400"}
      end

    assigns = assign(assigns, text: text, classes: classes)

    ~H"""
    <span class={"px-2 py-1 rounded text-xs font-medium #{@classes}"}>
      <%= @text %>
    </span>
    """
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
