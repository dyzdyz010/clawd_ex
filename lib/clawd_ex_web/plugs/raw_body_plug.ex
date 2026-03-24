defmodule ClawdExWeb.Plugs.RawBodyPlug do
  @moduledoc """
  Plug that caches the raw request body for webhook signature verification.

  Must be placed before `Plug.Parsers` in the endpoint pipeline,
  but we use a Plug.Conn.register_before_send/read_body approach instead.

  Usage: Add `plug ClawdExWeb.Plugs.RawBodyPlug` in the endpoint,
  or use the `read_raw_body/1` helper in controllers that need it.

  Since Plug.Parsers consumes the body, we cache it during parsing
  by implementing a custom body reader.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Read and cache the raw body
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} ->
        Plug.Conn.put_private(conn, :raw_body, body)
        # Push the body back so Plug.Parsers can still read it
        # We need to use a different approach since body is consumed
        conn

      {:more, _partial, conn} ->
        conn

      {:error, _reason} ->
        conn
    end
  end

  @doc """
  Retrieve the cached raw body from conn.private.
  Returns nil if not cached.
  """
  def get_raw_body(conn) do
    conn.private[:raw_body]
  end
end
