defmodule ClawdExWeb.CronJobFormLive do
  use ClawdExWeb, :live_view

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Automation
  alias ClawdEx.Automation.CronJob
  alias ClawdEx.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    agents = Repo.all(from(a in Agent, order_by: a.name))
    sessions = load_active_sessions()

    {:ok, assign(socket, agents: agents, sessions: sessions)}
  end

  defp load_active_sessions do
    from(s in ClawdEx.Sessions.Session,
      where: s.state == :active,
      order_by: [desc: s.last_activity_at],
      limit: 50,
      select: %{
        session_key: s.session_key,
        channel: s.channel,
        last_activity: s.last_activity_at
      }
    )
    |> Repo.all()
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    job = %CronJob{}
    changeset = Automation.change_job(job)

    socket
    |> assign(page_title: "New Cron Job")
    |> assign(job: job)
    |> assign(form: to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    job = Automation.get_job(id)
    changeset = Automation.change_job(job)

    socket
    |> assign(page_title: "Edit: #{job.name}")
    |> assign(job: job)
    |> assign(form: to_form(changeset))
  end

  @impl true
  def handle_event("validate", %{"cron_job" => params}, socket) do
    changeset =
      socket.assigns.job
      |> Automation.change_job(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"cron_job" => params}, socket) do
    save_job(socket, socket.assigns.live_action, params)
  end

  defp save_job(socket, :new, params) do
    case Automation.create_job(params) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cron job created successfully")
         |> push_navigate(to: ~p"/cron")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_job(socket, :edit, params) do
    case Automation.update_job(socket.assigns.job, params) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cron job updated successfully")
         |> push_navigate(to: ~p"/cron")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto">
      <!-- Header -->
      <div class="mb-6">
        <.link navigate={~p"/cron"} class="text-gray-400 hover:text-white text-sm flex items-center gap-1 mb-2">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
          </svg>
          Back to Cron Jobs
        </.link>
        <h1 class="text-2xl font-bold text-white"><%= @page_title %></h1>
      </div>

      <!-- Form -->
      <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
        <div class="bg-gray-800 rounded-lg p-6 space-y-6">
          <!-- Name -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Name *</label>
            <.input
              field={@form[:name]}
              type="text"
              placeholder="daily-backup"
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <!-- Description -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Description</label>
            <.input
              field={@form[:description]}
              type="textarea"
              rows="2"
              placeholder="What does this job do?"
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <!-- Schedule -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Schedule (Cron Expression) *</label>
            <.input
              field={@form[:schedule]}
              type="text"
              placeholder="0 9 * * *"
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500 font-mono"
            />
            <p class="text-xs text-gray-500 mt-1">
              Format: minute hour day month weekday (e.g., "0 9 * * *" = every day at 9:00 AM)
            </p>
          </div>

          <!-- Command -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Command / Text *</label>
            <.input
              field={@form[:command]}
              type="textarea"
              rows="3"
              placeholder="The command or message to execute..."
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <!-- Agent -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Agent</label>
            <.input
              field={@form[:agent_id]}
              type="select"
              options={[{"None", nil}] ++ Enum.map(@agents, &{&1.name, &1.id})}
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <!-- Timezone -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Timezone</label>
            <.input
              field={@form[:timezone]}
              type="select"
              options={timezone_options()}
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <!-- Enabled -->
          <div class="flex items-center gap-3">
            <.input
              field={@form[:enabled]}
              type="checkbox"
              class="w-5 h-5 bg-gray-700 border-gray-600 rounded focus:ring-blue-500 text-blue-600"
            />
            <label class="text-sm text-gray-300">Enabled</label>
          </div>
        </div>

        <!-- Execution Settings -->
        <div class="bg-gray-800 rounded-lg p-6 space-y-6">
          <h3 class="text-lg font-medium text-white">Execution Settings</h3>

          <!-- Payload Type -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Execution Mode</label>
            <.input
              field={@form[:payload_type]}
              type="select"
              options={[
                {"System Event - Inject into existing session", "system_event"},
                {"Agent Turn - Run in isolated session", "agent_turn"}
              ]}
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
            <p class="text-xs text-gray-500 mt-1">
              System Event: Sends message to an existing session. Agent Turn: Creates a temporary session.
            </p>
          </div>

          <!-- Session Key (for system_event) -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Target Session (for System Event)</label>
            <.input
              field={@form[:session_key]}
              type="select"
              options={session_options(@sessions)}
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
            <p class="text-xs text-gray-500 mt-1">
              Select a session to inject the message into. "Auto" will use the most recent active session.
            </p>
          </div>

          <!-- Target Channel -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Deliver Results To</label>
            <.input
              field={@form[:target_channel]}
              type="select"
              options={[
                {"Don't deliver (store only)", ""},
                {"Telegram", "telegram"},
                {"Discord", "discord"},
                {"WebChat (PubSub)", "webchat"}
              ]}
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <!-- Cleanup (for agent_turn) -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Session Cleanup (for Agent Turn)</label>
            <.input
              field={@form[:cleanup]}
              type="select"
              options={[
                {"Delete session after completion", "delete"},
                {"Keep session history", "keep"}
              ]}
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          <!-- Timeout -->
          <div>
            <label class="block text-sm font-medium text-gray-300 mb-2">Timeout (seconds)</label>
            <.input
              field={@form[:timeout_seconds]}
              type="number"
              min="10"
              max="3600"
              class="w-full bg-gray-700 border-gray-600 text-white rounded-lg px-4 py-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>
        </div>

        <!-- Actions -->
        <div class="flex justify-end gap-3">
          <.link navigate={~p"/cron"} class="btn-secondary">
            Cancel
          </.link>
          <button type="submit" class="btn-primary">
            <%= if @live_action == :new, do: "Create Job", else: "Update Job" %>
          </button>
        </div>
      </.form>

      <!-- Cron Help -->
      <div class="mt-8 bg-gray-800 rounded-lg p-6">
        <h3 class="text-lg font-medium text-white mb-4">Cron Expression Help</h3>
        <div class="space-y-2 text-sm">
          <div class="grid grid-cols-5 gap-2 text-gray-400">
            <div>Minute</div>
            <div>Hour</div>
            <div>Day</div>
            <div>Month</div>
            <div>Weekday</div>
          </div>
          <div class="grid grid-cols-5 gap-2 text-gray-300 font-mono">
            <div>0-59</div>
            <div>0-23</div>
            <div>1-31</div>
            <div>1-12</div>
            <div>0-6</div>
          </div>
          <div class="border-t border-gray-700 pt-4 mt-4">
            <h4 class="text-gray-300 font-medium mb-2">Examples:</h4>
            <ul class="space-y-1 text-gray-400">
              <li><code class="text-blue-400">0 9 * * *</code> - Every day at 9:00 AM</li>
              <li><code class="text-blue-400">*/15 * * * *</code> - Every 15 minutes</li>
              <li><code class="text-blue-400">0 0 * * 0</code> - Every Sunday at midnight</li>
              <li><code class="text-blue-400">0 9 1 * *</code> - First day of every month at 9:00 AM</li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp timezone_options do
    [
      {"UTC", "UTC"},
      {"America/New_York", "America/New_York"},
      {"America/Los_Angeles", "America/Los_Angeles"},
      {"Europe/London", "Europe/London"},
      {"Europe/Berlin", "Europe/Berlin"},
      {"Asia/Shanghai", "Asia/Shanghai"},
      {"Asia/Tokyo", "Asia/Tokyo"},
      {"Asia/Singapore", "Asia/Singapore"},
      {"Australia/Sydney", "Australia/Sydney"}
    ]
  end

  defp session_options(sessions) do
    auto_option = [{"Auto (most recent active session)", ""}]

    session_opts =
      Enum.map(sessions, fn s ->
        # Format: "telegram:12345 (2m ago)"
        time_ago = format_time_ago(s.last_activity)
        label = "#{s.channel}:#{short_key(s.session_key)} (#{time_ago})"
        {label, s.session_key}
      end)

    auto_option ++ session_opts
  end

  defp short_key(session_key) do
    case String.split(session_key, ":", parts: 2) do
      [_channel, rest] -> String.slice(rest, 0, 12) <> "..."
      _ -> String.slice(session_key, 0, 15) <> "..."
    end
  end

  defp format_time_ago(nil), do: "never"

  defp format_time_ago(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
