defmodule ClawdEx.Skills.Supervisor do
  @moduledoc """
  Supervisor for the skills system.

  Uses :rest_for_one strategy so that if Manager crashes,
  Registry and Watcher (which depend on it) are also restarted.

  Respects `:skills_enabled` config — when set to `false`, the
  supervisor starts with no children (no-op).
  """
  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Application.get_env(:clawd_ex, :skills_enabled, true) do
      children = [
        ClawdEx.Skills.Manager,
        ClawdEx.Skills.Registry,
        ClawdEx.Skills.Watcher
      ]

      Supervisor.init(children, strategy: :rest_for_one)
    else
      Logger.info("Skills system disabled via config :skills_enabled")
      Supervisor.init([], strategy: :one_for_one)
    end
  end
end
