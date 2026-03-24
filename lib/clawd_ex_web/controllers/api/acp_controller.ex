defmodule ClawdExWeb.Api.AcpController do
  @moduledoc """
  REST API controller for ACP (Agent Communication Protocol) management.

  Provides endpoints to:
  - List available ACP agents/backends
  - View and manage active ACP sessions
  - Run health diagnostics
  """
  use ClawdExWeb, :controller

  alias ClawdEx.ACP.{Registry, Session}

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  GET /api/v1/acp/agents — List available ACP agents and their backend mapping.
  """
  def list_agents(conn, _params) do
    backends = Registry.list_backends()
    agent_map = Registry.agent_backend_map()

    agents =
      Enum.map(agent_map, fn {agent_id, backend_id} ->
        backend_info = Map.get(backends, backend_id)

        %{
          agent_id: agent_id,
          backend_id: backend_id,
          available: backend_info != nil && Map.get(backend_info, :healthy, false),
          backend_module:
            if(backend_info, do: inspect(Map.get(backend_info, :module)), else: nil)
        }
      end)

    json(conn, %{data: agents, total: length(agents)})
  end

  @doc """
  GET /api/v1/acp/sessions — List all active ACP sessions.
  """
  def list_sessions(conn, _params) do
    sessions = Session.list_sessions()
    json(conn, %{data: sessions, total: length(sessions)})
  end

  @doc """
  GET /api/v1/acp/sessions/:key — Get details of a specific ACP session.
  """
  def show_session(conn, %{"key" => key}) do
    decoded_key = URI.decode(key)

    case Session.get_status(decoded_key) do
      {:ok, info} ->
        json(conn, %{data: info})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  DELETE /api/v1/acp/sessions/:key — Close and clean up an ACP session.
  """
  def close_session(conn, %{"key" => key}) do
    decoded_key = URI.decode(key)

    case Session.close(decoded_key) do
      :ok ->
        json(conn, %{status: "closed", session_key: decoded_key})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  GET /api/v1/acp/doctor — Run health diagnostics on all ACP backends.
  """
  def doctor(conn, _params) do
    case Registry.health_check() do
      {:ok, results} ->
        backends = Registry.list_backends()
        all_healthy = Enum.all?(results, fn {_, healthy} -> healthy end)

        report = %{
          status: if(all_healthy, do: "healthy", else: "degraded"),
          backends:
            Enum.map(results, fn {id, healthy} ->
              backend_info = Map.get(backends, id, %{})

              %{
                id: id,
                healthy: healthy,
                module: inspect(Map.get(backend_info, :module, :unknown)),
                registered_at: Map.get(backend_info, :registered_at)
              }
            end),
          agent_map: Registry.agent_backend_map(),
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        json(conn, %{data: report})

      {:error, reason} ->
        json(conn, %{
          data: %{
            status: "error",
            error: inspect(reason),
            checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }
        })
    end
  end
end
