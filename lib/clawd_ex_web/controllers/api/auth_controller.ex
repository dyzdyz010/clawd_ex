defmodule ClawdExWeb.Api.AuthController do
  @moduledoc """
  API Key management endpoints.

  All endpoints require admin scope.
  """

  use ClawdExWeb, :controller

  action_fallback ClawdExWeb.Api.FallbackController

  @doc """
  GET /api/v1/auth/keys — List all API keys (sanitized).
  """
  def index(conn, _params) do
    keys = ClawdEx.Security.ApiKey.list_keys()

    conn
    |> put_status(200)
    |> json(%{data: keys})
  end

  @doc """
  POST /api/v1/auth/keys — Create a new API key.

  Body: { "name": "my-key", "scope": "read" }
  """
  def create(conn, params) do
    name = Map.get(params, "name", "unnamed")
    scope = Map.get(params, "scope", "read")

    case ClawdEx.Security.ApiKey.generate_key(%{name: name, scope: scope}) do
      {:ok, key_info} ->
        conn
        |> put_status(201)
        |> json(%{data: key_info})

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: %{code: "bad_request", message: inspect(reason)}})
    end
  end

  @doc """
  DELETE /api/v1/auth/keys/:id — Revoke an API key.
  """
  def delete(conn, %{"id" => id}) do
    case ClawdEx.Security.ApiKey.revoke_key(id) do
      :ok ->
        conn
        |> put_status(200)
        |> json(%{data: %{id: id, revoked: true}})

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: %{code: "not_found", message: "API key not found"}})
    end
  end
end
