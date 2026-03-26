defmodule ClawdEx.Repo.Migrations.EnableAgentAutoStart do
  use Ecto.Migration

  def up do
    # Enable auto_start and always_on for ALL active agents
    # heartbeat_interval_seconds stays at 0 — no LLM heartbeat
    execute """
    UPDATE agents
    SET auto_start = true, always_on = true
    WHERE active = true
    """
  end

  def down do
    execute """
    UPDATE agents
    SET auto_start = false, always_on = false
    """
  end
end
