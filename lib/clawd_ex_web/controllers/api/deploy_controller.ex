defmodule ClawdExWeb.Api.DeployController do
  @moduledoc """
  Deploy management REST API controller.

  Provides endpoints for deployment status, trigger, history, and rollback.
  All endpoints require admin scope.
  """
  use ClawdExWeb, :controller

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  GET /api/v1/deploy/status — Current deploy status
  """
  def status(conn, _params) do
    {:ok, deploy_status} = ClawdEx.Deploy.Manager.status()
    json(conn, deploy_status)
  end

  @doc """
  POST /api/v1/deploy/trigger — Trigger a new deployment
  """
  def trigger(conn, _params) do
    case ClawdEx.Deploy.Manager.trigger() do
      {:ok, deploy} ->
        conn
        |> put_status(202)
        |> json(%{
          status: "triggered",
          message: "Deployment started in background",
          deploy_id: deploy.id,
          started_at: deploy.started_at
        })

      {:error, :deploy_in_progress} ->
        conn
        |> put_status(409)
        |> json(%{
          error: %{
            code: "conflict",
            message: "A deployment is already in progress"
          }
        })
    end
  end

  @doc """
  GET /api/v1/deploy/history — Deployment history
  """
  def history(conn, _params) do
    {:ok, deploys} = ClawdEx.Deploy.Manager.history()

    # Omit verbose output from list view
    deploys_summary = Enum.map(deploys, fn deploy ->
      Map.drop(deploy, [:output])
    end)

    json(conn, %{deploys: deploys_summary, total: length(deploys)})
  end

  @doc """
  POST /api/v1/deploy/rollback — Rollback to previous version
  """
  def rollback(conn, _params) do
    case ClawdEx.Deploy.Manager.rollback() do
      {:ok, deploy} ->
        conn
        |> put_status(202)
        |> json(%{
          status: "triggered",
          message: "Rollback started in background",
          deploy_id: deploy.id,
          started_at: deploy.started_at
        })

      {:error, :deploy_in_progress} ->
        conn
        |> put_status(409)
        |> json(%{
          error: %{
            code: "conflict",
            message: "A deployment is already in progress"
          }
        })
    end
  end
end
