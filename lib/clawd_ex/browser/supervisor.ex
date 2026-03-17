defmodule ClawdEx.Browser.Supervisor do
  @moduledoc """
  Supervisor for browser-related processes.

  Uses :rest_for_one strategy so that if CDP crashes,
  Server (which depends on it) is also restarted.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      ClawdEx.Browser.CDP,
      ClawdEx.Browser.Server
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
