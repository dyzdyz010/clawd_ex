defmodule ClawdExWeb.SessionDetailLive do
  @moduledoc """
  Session 详情页面 - 查看消息历史和会话信息
  """
  use ClawdExWeb, :live_view

  import Ecto.Query
  alias ClawdEx.Repo
  alias ClawdEx.Sessions.{Session, Message}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    session = Repo.get!(Session, id) |> Repo.preload(:agent)

    socket =
      socket
      |> assign(:page_title, "Session: #{truncate(session.session_key, 20)}")
      |> assign(:session, session)
      |> load_messages()

    {:ok, socket}
  end

  @impl true
  def handle_event("load_more", _, socket) do
    {:noreply, load_messages(socket, socket.assigns.offset + 50)}
  end

  @impl true
  def handle_event("delete_message", %{"id" => id}, socket) do
    message = Repo.get!(Message, id)
    {:ok, _} = Repo.delete(message)

    socket =
      socket
      |> put_flash(:info, "Message deleted")
      |> load_messages()

    {:noreply, socket}
  end

  defp load_messages(socket, offset \\ 0) do
    session = socket.assigns.session

    messages =
      from(m in Message,
        where: m.session_id == ^session.id,
        order_by: [asc: m.inserted_at],
        limit: 50,
        offset: ^offset
      )
      |> Repo.all()

    total_count =
      from(m in Message, where: m.session_id == ^session.id)
      |> Repo.aggregate(:count, :id)

    socket
    |> assign(:messages, messages)
    |> assign(:offset, offset)
    |> assign(:total_count, total_count)
    |> assign(:has_more, offset + length(messages) < total_count)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto px-4 py-8">
        <!-- Header -->
        <div class="flex items-center gap-4 mb-6">
          <.link navigate={~p"/sessions"} class="text-gray-400 hover:text-white">
            ← Back
          </.link>
          <h1 class="text-2xl font-bold flex-1 truncate">
            <%= @session.session_key %>
          </h1>
          <.session_state_badge state={@session.state} />
        </div>

        <!-- Session Info -->
        <div class="bg-gray-800 rounded-lg p-6 mb-6">
          <h2 class="text-lg font-semibold mb-4">Session Info</h2>
          <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div>
              <div class="text-sm text-gray-400">Agent</div>
              <div class="font-medium">
                <%= if @session.agent, do: @session.agent.name, else: "-" %>
              </div>
            </div>
            <div>
              <div class="text-sm text-gray-400">Channel</div>
              <div class="font-medium"><%= @session.channel %></div>
            </div>
            <div>
              <div class="text-sm text-gray-400">Messages</div>
              <div class="font-medium"><%= @session.message_count %></div>
            </div>
            <div>
              <div class="text-sm text-gray-400">Tokens</div>
              <div class="font-medium"><%= @session.token_count || 0 %></div>
            </div>
            <div>
              <div class="text-sm text-gray-400">Model Override</div>
              <div class="font-medium"><%= @session.model_override || "-" %></div>
            </div>
            <div>
              <div class="text-sm text-gray-400">Created</div>
              <div class="font-medium"><%= format_datetime(@session.inserted_at) %></div>
            </div>
            <div>
              <div class="text-sm text-gray-400">Last Activity</div>
              <div class="font-medium"><%= format_datetime(@session.last_activity_at) %></div>
            </div>
            <div>
              <div class="text-sm text-gray-400">Channel ID</div>
              <div class="font-medium text-xs"><%= @session.channel_id || "-" %></div>
            </div>
          </div>
        </div>

        <!-- Messages -->
        <div class="bg-gray-800 rounded-lg p-6">
          <div class="flex justify-between items-center mb-4">
            <h2 class="text-lg font-semibold">Messages (<%= @total_count %>)</h2>
            <.link navigate={~p"/chat?session=#{@session.session_key}"} class="btn-primary text-sm">
              Continue Chat →
            </.link>
          </div>

          <div class="space-y-4">
            <%= for message <- @messages do %>
              <.message_card message={message} />
            <% end %>
          </div>

          <%= if @has_more do %>
            <div class="mt-4 text-center">
              <button phx-click="load_more" class="btn-secondary">
                Load More
              </button>
            </div>
          <% end %>

          <%= if Enum.empty?(@messages) do %>
            <div class="text-center py-12 text-gray-500">
              No messages in this session
            </div>
          <% end %>
        </div>
      </div>
    """
  end

  defp message_card(assigns) do
    ~H"""
    <div class={"rounded-lg p-4 " <> message_bg(@message.role)}>
      <div class="flex items-start justify-between gap-4">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-2">
            <.role_badge role={@message.role} />
            <span class="text-xs text-gray-500">
              <%= format_datetime(@message.inserted_at) %>
            </span>
            <%= if @message.model do %>
              <span class="text-xs text-gray-600 font-mono">
                <%= @message.model %>
              </span>
            <% end %>
            <%= if @message.tokens_in || @message.tokens_out do %>
              <span class="text-xs text-gray-600">
                📊 <%= @message.tokens_in || 0 %> / <%= @message.tokens_out || 0 %>
              </span>
            <% end %>
          </div>
          <div class="prose prose-invert prose-sm max-w-none">
            <pre class="whitespace-pre-wrap text-sm text-gray-200 font-sans"><%= @message.content %></pre>
          </div>
          <%= if @message.tool_calls && length(@message.tool_calls) > 0 do %>
            <div class="mt-3 space-y-2">
              <div class="text-xs text-gray-400 font-medium">Tool Calls:</div>
              <%= for tool_call <- @message.tool_calls do %>
                <div class="bg-gray-900 rounded p-2 text-xs font-mono">
                  <div class="text-purple-400"><%= tool_call["function"]["name"] %></div>
                  <pre class="text-gray-500 mt-1 overflow-x-auto"><%= Jason.encode!(tool_call["function"]["arguments"], pretty: true) %></pre>
                </div>
              <% end %>
            </div>
          <% end %>
          <%= if @message.tool_call_id do %>
            <div class="mt-2 text-xs text-gray-500">
              Tool Call ID: <span class="font-mono"><%= @message.tool_call_id %></span>
            </div>
          <% end %>
        </div>
        <button
          phx-click="delete_message"
          phx-value-id={@message.id}
          data-confirm="Delete this message?"
          class="text-gray-500 hover:text-red-400 text-sm"
        >
          🗑
        </button>
      </div>
    </div>
    """
  end

  defp message_bg(:user), do: "bg-blue-900/30"
  defp message_bg(:assistant), do: "bg-gray-700"
  defp message_bg(:system), do: "bg-gray-800 border border-gray-600"
  defp message_bg(:tool), do: "bg-purple-900/30"
  defp message_bg(_), do: "bg-gray-700"

  defp role_badge(assigns) do
    {bg, text} = case assigns.role do
      :user -> {"bg-blue-600", "User"}
      :assistant -> {"bg-green-600", "Assistant"}
      :system -> {"bg-gray-600", "System"}
      :tool -> {"bg-purple-600", "Tool"}
      _ -> {"bg-gray-600", "?"}
    end

    assigns = assign(assigns, bg: bg, text: text)

    ~H"""
    <span class={"text-xs px-2 py-0.5 rounded font-medium #{@bg}"}><%= @text %></span>
    """
  end

  defp session_state_badge(assigns) do
    {bg, text} = case assigns.state do
      :active -> {"bg-green-500", "Active"}
      :idle -> {"bg-gray-500", "Idle"}
      :compacting -> {"bg-yellow-500", "Compacting"}
      :archived -> {"bg-red-500", "Archived"}
      _ -> {"bg-gray-500", "Unknown"}
    end

    assigns = assign(assigns, bg: bg, text: text)

    ~H"""
    <span class={"text-xs px-2 py-1 rounded-full #{@bg}"}><%= @text %></span>
    """
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp truncate(nil, _), do: ""
  defp truncate(string, max) when byte_size(string) > max do
    String.slice(string, 0, max) <> "..."
  end
  defp truncate(string, _), do: string
end
