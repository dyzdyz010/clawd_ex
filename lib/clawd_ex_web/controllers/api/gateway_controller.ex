defmodule ClawdExWeb.Api.GatewayController do
  @moduledoc """
  Gateway status and health REST API controller.
  """
  use ClawdExWeb, :controller

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  GET /api/v1/gateway/status — Gateway status + statistics
  """
  def status(conn, _params) do
    uptime_seconds = :erlang.statistics(:wall_clock) |> elem(0) |> div(1000)

    sessions = ClawdEx.Sessions.SessionManager.list_sessions()

    agents_count =
      try do
        import Ecto.Query
        ClawdEx.Repo.aggregate(ClawdEx.Agents.Agent, :count)
      rescue
        _ -> 0
      end

    active_agents =
      try do
        import Ecto.Query
        ClawdEx.Repo.aggregate(
          from(a in ClawdEx.Agents.Agent, where: a.active == true),
          :count
        )
      rescue
        _ -> 0
      end

    nodes_info = get_nodes_info()

    json(conn, %{
      version: Application.spec(:clawd_ex, :vsn) |> to_string(),
      uptime_seconds: uptime_seconds,
      port: get_port(),
      auth_enabled: auth_enabled?(),
      nodes: nodes_info,
      sessions: %{
        active: length(sessions),
        total: length(sessions)
      },
      agents: %{
        total: agents_count,
        active: active_agents
      }
    })
  end

  @doc """
  GET /api/v1/gateway/health — Detailed health check
  """
  def health(conn, _params) do
    result = ClawdEx.Health.full_check()

    checks =
      Map.new(result.checks, fn {name, check} ->
        {name, %{
          status: to_string(check.status),
          details: Map.get(check, :message, nil)
        }}
      end)

    overall_status = if result.healthy, do: "ok", else: "degraded"
    status_code = if result.healthy, do: 200, else: 503

    conn
    |> put_status(status_code)
    |> json(%{
      status: overall_status,
      checks: checks,
      timestamp: DateTime.to_iso8601(result.timestamp)
    })
  end

  # Private helpers

  defp get_port do
    case Application.get_env(:clawd_ex, ClawdExWeb.Endpoint) do
      nil -> 4000
      config -> get_in(config, [:http, :port]) || 4000
    end
  end

  defp auth_enabled? do
    token =
      Application.get_env(:clawd_ex, :api_token) ||
        System.get_env("CLAWD_API_TOKEN") ||
        Application.get_env(:clawd_ex, :gateway_token)

    not (is_nil(token) or token == "")
  end

  defp get_nodes_info do
    try do
      nodes = ClawdEx.Nodes.Registry.list_nodes()
      connected = Enum.count(nodes, fn n -> n.status == :connected end)
      pending = Enum.count(nodes, fn n -> n.status == :pending end)
      %{total: length(nodes), connected: connected, pending: pending}
    rescue
      _ -> %{total: 0, connected: 0, pending: 0}
    end
  end
end
