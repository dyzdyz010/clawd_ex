defmodule ClawdEx.Repo.Migrations.AddAgentAlwaysOnFields do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :auto_start, :boolean, default: false, null: false
      add :capabilities, {:array, :string}, default: [], null: false
      add :heartbeat_interval_seconds, :integer, default: 0, null: false
      add :always_on, :boolean, default: false, null: false
    end
  end
end
