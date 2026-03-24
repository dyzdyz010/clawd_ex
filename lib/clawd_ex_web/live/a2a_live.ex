defmodule ClawdExWeb.A2ALive do
  @moduledoc "A2A (Agent-to-Agent) communication monitor with message log and agent registry"
  use ClawdExWeb, :live_view

  import Ecto.Query

  alias ClawdEx.Repo
  alias ClawdEx.A2A.Message
  alias ClawdEx.A2A.Router, as: A2ARouter
  alias ClawdEx.Agents.Agent

  import ClawdExWeb.Helpers.SafeParse

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ClawdEx.PubSub, "a2a:monitor")
      # Refresh registry periodically
      :timer.send_interval(15_000, self(), :refresh_registry)
    end

    agents = Repo.all(from(a in Agent, where: a.active == true, order_by: a.name))

    socket =
      socket
      |> assign(:page_title, "A2A Communication")
      |> assign(:filter_type, "all")
      |> assign(:filter_status, "all")
      |> assign(:filter_agent, "all")
      |> assign(:tab, "messages")
      |> assign(:agents, agents)
      |> assign(:agent_map, Map.new(agents, &{&1.id, &1.name}))
      |> load_messages()
      |> load_registry()
      |> load_stats()

    {:ok, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, socket |> assign(:filter_type, type) |> load_messages()}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, socket |> assign(:filter_status, status) |> load_messages()}
  end

  @impl true
  def handle_event("filter_agent", %{"agent" => agent_id}, socket) do
    {:noreply, socket |> assign(:filter_agent, agent_id) |> load_messages()}
  end

  @impl true
  def handle_event("mark_processed", %{"id" => message_id}, socket) do
    A2ARouter.mark_processed(message_id)
    Process.sleep(100)
    {:noreply, socket |> load_messages() |> load_stats()}
  end

  @impl true
  def handle_info(:refresh_registry, socket) do
    {:noreply, load_registry(socket)}
  end

  @impl true
  def handle_info({:a2a_message, _msg}, socket) do
    {:noreply, socket |> load_messages() |> load_stats()}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ============================================================================
  # Data Loading
  # ============================================================================

  defp load_messages(socket) do
    query =
      from(m in Message,
        left_join: fa in Agent, on: fa.id == m.from_agent_id,
        left_join: ta in Agent, on: ta.id == m.to_agent_id,
        preload: [from_agent: fa, to_agent: ta],
        order_by: [desc: m.inserted_at],
        limit: 100
      )

    query =
      case socket.assigns.filter_type do
        "all" -> query
        type -> from(m in query, where: m.type == ^type)
      end

    query =
      case socket.assigns.filter_status do
        "all" -> query
        status -> from(m in query, where: m.status == ^status)
      end

    query =
      case socket.assigns.filter_agent do
        "all" ->
          query

        agent_id_str ->
          agent_id = safe_to_integer(agent_id_str)
          from(m in query, where: m.from_agent_id == ^agent_id or m.to_agent_id == ^agent_id)
      end

    messages = Repo.all(query)
    assign(socket, :messages, messages)
  end

  defp load_registry(socket) do
    registry =
      case A2ARouter.discover() do
        {:ok, agents} -> agents
        _ -> []
      end

    assign(socket, :registry, registry)
  end

  defp load_stats(socket) do
    stats = %{
      total: Repo.aggregate(Message, :count),
      pending: Repo.aggregate(from(m in Message, where: m.status == "pending"), :count),
      delivered: Repo.aggregate(from(m in Message, where: m.status == "delivered"), :count),
      processed: Repo.aggregate(from(m in Message, where: m.status == "processed"), :count),
      expired: Repo.aggregate(from(m in Message, where: m.status == "expired"), :count)
    }

    assign(socket, :stats, stats)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp type_badge_classes(type) do
    case type do
      "request" -> "bg-blue-500/20 text-blue-400"
      "response" -> "bg-green-500/20 text-green-400"
      "notification" -> "bg-purple-500/20 text-purple-400"
      "delegation" -> "bg-yellow-500/20 text-yellow-400"
      _ -> "bg-gray-500/20 text-gray-400"
    end
  end

  defp type_icon(type) do
    case type do
      "request" -> "M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
      "response" -> "M3 10h10a8 8 0 018 8v2M3 10l6 6m-6-6l6-6"
      "notification" -> "M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
      "delegation" -> "M17 8l4 4m0 0l-4 4m4-4H3"
      _ -> "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
    end
  end

  defp status_badge_classes(status) do
    case status do
      "pending" -> "bg-gray-500/20 text-gray-400"
      "delivered" -> "bg-blue-500/20 text-blue-400"
      "processed" -> "bg-green-500/20 text-green-400"
      "failed" -> "bg-red-500/20 text-red-400"
      "expired" -> "bg-yellow-500/20 text-yellow-400"
      _ -> "bg-gray-500/20 text-gray-400"
    end
  end

  defp format_time(nil), do: "-"

  defp format_time(datetime) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, datetime, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
    end
  end

  defp format_datetime(nil), do: "-"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp truncate_content(nil, _), do: ""
  defp truncate_content(content, max) when byte_size(content) > max do
    String.slice(content, 0, max) <> "..."
  end
  defp truncate_content(content, _), do: content
end
