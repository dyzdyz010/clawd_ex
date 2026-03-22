defmodule ClawdExWeb.Plugs.RateLimitPlug do
  @moduledoc """
  Rate limiting plug using ETS counters.

  Limits requests per minute based on IP address or API key.
  Configurable via application config:

      config :clawd_ex, :rate_limit,
        max_requests: 60,
        window_ms: 60_000

  Returns 429 Too Many Requests with Retry-After header when exceeded.
  """

  import Plug.Conn
  @behaviour Plug

  @table :clawd_rate_limits
  @default_max_requests 60
  @default_window_ms 60_000

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    ensure_table()

    identifier = get_identifier(conn)
    now = System.monotonic_time(:millisecond)
    {max_requests, window_ms} = get_config()

    case check_rate(identifier, now, max_requests, window_ms) do
      {:ok, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", to_string(max(0, max_requests - count)))

      {:error, retry_after_ms} ->
        retry_after_s = max(1, div(retry_after_ms, 1000))

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("retry-after", to_string(retry_after_s))
        |> put_resp_header("x-ratelimit-limit", to_string(max_requests))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> send_resp(429, Jason.encode!(%{
          error: %{
            code: "rate_limited",
            message: "Too many requests. Retry after #{retry_after_s} seconds."
          }
        }))
        |> halt()
    end
  end

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])

      _ ->
        :ok
    end
  end

  defp get_identifier(conn) do
    # Prefer API key ID, fall back to IP
    case conn.assigns[:api_key_id] do
      nil ->
        ip = conn.remote_ip |> :inet.ntoa() |> to_string()
        {:ip, ip}

      key_id ->
        {:key, key_id}
    end
  end

  defp check_rate(identifier, now, max_requests, window_ms) do
    window_start = now - window_ms

    case :ets.lookup(@table, identifier) do
      [{^identifier, count, window_started}] when window_started > window_start ->
        if count >= max_requests do
          retry_after = window_started + window_ms - now
          {:error, retry_after}
        else
          :ets.update_counter(@table, identifier, {2, 1})
          {:ok, count + 1}
        end

      _ ->
        # New window or expired window
        :ets.insert(@table, {identifier, 1, now})
        {:ok, 1}
    end
  end

  defp get_config do
    rate_config = Application.get_env(:clawd_ex, :rate_limit, [])
    max_requests = Keyword.get(rate_config, :max_requests, @default_max_requests)
    window_ms = Keyword.get(rate_config, :window_ms, @default_window_ms)
    {max_requests, window_ms}
  end

  @doc """
  Reset rate limit counters. Useful for testing.
  """
  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end

    :ok
  end
end
