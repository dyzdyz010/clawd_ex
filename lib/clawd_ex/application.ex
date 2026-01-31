defmodule ClawdEx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClawdExWeb.Telemetry,
      ClawdEx.Repo,
      # Note: Finch for Telegex is started by Telegex.Application, don't duplicate
      {DNSCluster, query: Application.get_env(:clawd_ex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ClawdEx.PubSub},
      # Session Registry for process lookup
      {Registry, keys: :unique, name: ClawdEx.SessionRegistry},
      # Agent Loop Registry
      {Registry, keys: :unique, name: ClawdEx.AgentLoopRegistry},
      # OAuth credential manager (handles token refresh)
      ClawdEx.AI.OAuth,
      # Background process manager
      ClawdEx.Tools.Process,
      # Node registry for paired devices
      ClawdEx.Nodes.Registry,
      # Browser CDP client
      ClawdEx.Browser.CDP,
      # Browser server (manages Chrome process)
      ClawdEx.Browser.Server,
      # Session Manager (DynamicSupervisor)
      ClawdEx.Sessions.SessionManager,
      # Discord channel (optional, starts if configured)
      ClawdEx.Channels.DiscordSupervisor,
      # Start to serve requests, typically the last entry
      ClawdExWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClawdEx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClawdExWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
