defmodule ClawdEx.A2A.Supervisor do
  @moduledoc """
  Supervisor for A2A (agent-to-agent) communication processes.

  Uses :one_for_one strategy — each child is independent.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: ClawdEx.A2AMailboxRegistry},
      {DynamicSupervisor, name: ClawdEx.A2AMailboxSupervisor, strategy: :one_for_one},
      ClawdEx.A2A.Router
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
