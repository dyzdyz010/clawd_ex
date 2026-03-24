defmodule ClawdEx.ACP.Supervisor do
  @moduledoc """
  Top-level supervisor for the ACP subsystem.

  Manages:
  - ACP.SessionRegistry (process name registry for ACP sessions)
  - ACP.Registry (backend registration and lookup)
  - ACP.SessionSupervisor (DynamicSupervisor for ACP session GenServers)
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Process registry for ACP session lookup by session_key
      {Registry, keys: :unique, name: ClawdEx.ACP.SessionRegistry},
      # Backend registry
      ClawdEx.ACP.Registry,
      # Dynamic supervisor for ACP session processes
      {DynamicSupervisor, name: ClawdEx.ACP.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
