defmodule ClawdEx.Repo.Migrations.AddCronJobPayloadType do
  use Ecto.Migration

  def change do
    alter table(:cron_jobs) do
      # "system_event" or "agent_turn"
      add :payload_type, :string, default: "system_event"
      # Target channel for results (e.g., "telegram", "discord", "webchat")
      add :target_channel, :string
      # Target session key for system_event mode
      add :session_key, :string
      # For agent_turn: cleanup strategy ("delete" or "keep")
      add :cleanup, :string, default: "delete"
      # Timeout in seconds
      add :timeout_seconds, :integer, default: 300
    end
  end
end
