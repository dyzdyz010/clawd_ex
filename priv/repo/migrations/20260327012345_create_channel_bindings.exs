defmodule ClawdEx.Repo.Migrations.CreateChannelBindings do
  use Ecto.Migration

  def change do
    create table(:channel_bindings) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :channel, :string, size: 50, null: false
      add :channel_config, :map, null: false, default: %{}
      add :session_key, :string, size: 255, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:channel_bindings, [:session_key])
    create unique_index(:channel_bindings, [:agent_id, :channel, :channel_config],
             name: :channel_bindings_agent_id_channel_channel_config_index)
    create index(:channel_bindings, [:agent_id])
    create index(:channel_bindings, [:active])
  end
end
