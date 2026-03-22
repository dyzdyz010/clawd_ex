defmodule ClawdEx.Cron.Supervisor do
  @moduledoc """
  Supervisor for the Cron subsystem.

  Supervises:
  - `ClawdEx.Cron.Scheduler` — the scheduling engine GenServer
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      ClawdEx.Cron.Scheduler
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
