defmodule ClawdEx.Repo.Migrations.AddSecurityFields do
  use Ecto.Migration

  def change do
    # --- Agent security fields ---
    alter table(:agents) do
      add :allowed_groups, {:array, :string}, default: []
      add :pairing_code, :string
    end

    create unique_index(:agents, [:pairing_code], where: "pairing_code IS NOT NULL")

    # --- DM Pairings table ---
    create table(:dm_pairings) do
      add :user_id, :string, null: false
      add :channel, :string, null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :paired_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dm_pairings, [:user_id, :channel])
    create index(:dm_pairings, [:agent_id])
  end
end
