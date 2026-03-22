defmodule ClawdExWeb.Plugs.RequireScopePlug do
  @moduledoc """
  Plug that enforces scope-based access control.

  Checks conn.assigns.auth_scope against the required scope and HTTP method.

  Scope hierarchy:
  - :read  → GET only
  - :write → GET, POST, PUT, PATCH, DELETE
  - :admin → everything (superset of :write)

  Usage in router:
      plug ClawdExWeb.Plugs.RequireScopePlug, scope: :admin
  """

  import Plug.Conn
  @behaviour Plug

  @read_methods ~w(GET HEAD OPTIONS)
  @write_methods ~w(POST PUT PATCH DELETE)

  @impl Plug
  def init(opts) do
    required = Keyword.get(opts, :scope, :read)
    %{required_scope: required}
  end

  @impl Plug
  def call(conn, %{required_scope: required_scope}) do
    auth_scope = conn.assigns[:auth_scope] || :read

    if scope_allowed?(auth_scope, required_scope, conn.method) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{
        error: %{
          code: "forbidden",
          message: "Insufficient scope. Required: #{required_scope}, got: #{auth_scope}"
        }
      }))
      |> halt()
    end
  end

  # Admin scope has full access
  defp scope_allowed?(:admin, _required, _method), do: true

  # Write scope can do read + write operations
  defp scope_allowed?(:write, :write, method), do: method in (@read_methods ++ @write_methods)
  defp scope_allowed?(:write, :read, method), do: method in @read_methods

  # Read scope can only do read operations
  defp scope_allowed?(:read, :read, method), do: method in @read_methods

  # Everything else is denied
  defp scope_allowed?(_scope, _required, _method), do: false
end
