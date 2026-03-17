defmodule ClawdEx.CLI.Gateway do
  @moduledoc """
  CLI gateway command - manage the Phoenix gateway.

  Usage:
    clawd_ex gateway status   - Show gateway status
    clawd_ex gateway restart  - Gracefully restart the gateway
  """

  def run(args, opts \\ [])

  def run(["status" | _rest], opts) do
    if opts[:help] do
      print_status_help()
    else
      show_status()
    end
  end

  def run(["restart" | _rest], opts) do
    if opts[:help] do
      print_restart_help()
    else
      restart_gateway()
    end
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown gateway subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # gateway status
  # ---------------------------------------------------------------------------

  defp show_status do
    endpoint = ClawdExWeb.Endpoint

    IO.puts("""
    ┌─────────────────────────────────────────────────────────────────────────────────┐
    │                            Gateway Status                                      │
    └─────────────────────────────────────────────────────────────────────────────────┘
    """)

    # Check if endpoint is running
    case Process.whereis(endpoint) do
      nil ->
        IO.puts("  Status:  ✗ Not running")

      pid ->
        IO.puts("  Status:  ✓ Running (PID: #{inspect(pid)})")

        # Port
        port = get_port()
        IO.puts("  Port:    #{port}")

        # URL
        url = endpoint_url()
        IO.puts("  URL:     #{url}")

        # Server config
        server_enabled = Application.get_env(:clawd_ex, endpoint)[:server] || false
        IO.puts("  Server:  #{if server_enabled, do: "enabled", else: "disabled (endpoint only)"}")

        # Auth status
        auth_config = Application.get_env(:clawd_ex, :auth) || []
        auth_enabled = Keyword.get(auth_config, :enabled, false)
        IO.puts("  Auth:    #{if auth_enabled, do: "enabled", else: "disabled"}")
    end

    IO.puts("")
  end

  defp get_port do
    config = Application.get_env(:clawd_ex, ClawdExWeb.Endpoint) || []
    http_config = config[:http] || []

    cond do
      is_list(http_config) and Keyword.has_key?(http_config, :port) ->
        http_config[:port]

      true ->
        4000
    end
  end

  defp endpoint_url do
    config = Application.get_env(:clawd_ex, ClawdExWeb.Endpoint) || []
    url_config = config[:url] || []
    host = url_config[:host] || "localhost"
    port = get_port()
    "http://#{host}:#{port}"
  end

  # ---------------------------------------------------------------------------
  # gateway restart
  # ---------------------------------------------------------------------------

  defp restart_gateway do
    if Application.get_env(:clawd_ex, :env) == :test do
      IO.puts("✗ Cannot restart gateway in test environment.")
      :error
    else
      IO.puts("Restarting gateway...")

      case Supervisor.restart_child(ClawdEx.Supervisor, ClawdExWeb.Endpoint) do
        {:ok, _pid} ->
          IO.puts("✓ Gateway restarted successfully.")
          :ok

        {:error, :running} ->
          # Already running, stop then start
          case do_restart() do
            :ok ->
              IO.puts("✓ Gateway restarted successfully.")
              :ok

            {:error, reason} ->
              IO.puts("✗ Failed to restart gateway: #{inspect(reason)}")
              :error
          end

        {:error, reason} ->
          IO.puts("✗ Failed to restart gateway: #{inspect(reason)}")
          :error
      end
    end
  end

  defp do_restart do
    with :ok <- Supervisor.terminate_child(ClawdEx.Supervisor, ClawdExWeb.Endpoint),
         {:ok, _pid} <- Supervisor.restart_child(ClawdEx.Supervisor, ClawdExWeb.Endpoint) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------

  defp print_help do
    IO.puts("""
    Usage: clawd_ex gateway <subcommand> [options]

    Subcommands:
      status    Show gateway status (port, connections, auth)
      restart   Gracefully restart the gateway

    Options:
      --help    Show this help message
    """)
  end

  defp print_status_help do
    IO.puts("""
    Usage: clawd_ex gateway status [options]

    Show the Phoenix gateway status including port, URL, and auth config.

    Options:
      --help  Show this help message
    """)
  end

  defp print_restart_help do
    IO.puts("""
    Usage: clawd_ex gateway restart [options]

    Gracefully restart the Phoenix gateway endpoint.
    Not available in test environment.

    Options:
      --help  Show this help message
    """)
  end
end
