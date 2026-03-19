defmodule ClawdEx.MCP.Supervisor do
  @moduledoc """
  Top-level supervisor for the MCP subsystem.

  Starts:
  - MCP process Registry (for Connection name lookup)
  - ServerManager (manages Connection lifecycle + auto-starts configured servers)
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for MCP connection name lookup
      {Registry, keys: :unique, name: ClawdEx.MCP.Registry},
      # Server Manager (auto-starts configured servers on init)
      ClawdEx.MCP.ServerManager
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
