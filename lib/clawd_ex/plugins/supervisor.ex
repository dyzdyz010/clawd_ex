defmodule ClawdEx.Plugins.Supervisor do
  @moduledoc """
  Supervisor for the plugin system.

  Manages:
  - Plugins.Manager — plugin lifecycle and registry
  - NodeBridge — Node.js sidecar for JS plugins (started on demand)
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ClawdEx.Plugins.Manager
      # NodeBridge will be added in Phase 2
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
