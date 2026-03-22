defmodule ClawdExWeb.Api.FallbackController do
  @moduledoc """
  Translates controller action results into valid `Plug.Conn` responses.

  Used as the fallback controller for API controllers via `action_fallback/1`.
  """
  use ClawdExWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "Resource not found"}})
  end

  def call(conn, {:error, :tool_not_found}) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "tool_not_found", message: "Tool not found"}})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    errors = format_changeset_errors(changeset)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "validation_error", message: "Validation failed", details: errors}})
  end

  def call(conn, {:error, :bad_request, message}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: %{code: "bad_request", message: message}})
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{error: %{code: "internal_error", message: inspect(reason)}})
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
