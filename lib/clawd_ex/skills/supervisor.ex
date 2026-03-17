defmodule ClawdEx.Skills.Supervisor do
  @moduledoc """
  Supervisor for the skills system.

  Uses :rest_for_one strategy so that if Manager crashes,
  Registry and Watcher (which depend on it) are also restarted.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ClawdEx.Skills.Manager,
      ClawdEx.Skills.Registry,
      ClawdEx.Skills.Watcher
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
