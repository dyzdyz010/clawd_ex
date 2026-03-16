defmodule ClawdEx.Repo.Migrations.CreateA2aMessages do
  use Ecto.Migration

  def change do
    create table(:a2a_messages) do
      add :message_id, :string, null: false
      add :from_agent_id, references(:agents, on_delete: :nilify_all)
      add :to_agent_id, references(:agents, on_delete: :nilify_all)
      add :type, :string, null: false
      add :content, :text
      add :metadata, :map, default: %{}
      add :reply_to, :string
      add :status, :string, default: "pending", null: false
      add :ttl_seconds, :integer, default: 300
      add :processed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:a2a_messages, [:message_id])
    create index(:a2a_messages, [:from_agent_id])
    create index(:a2a_messages, [:to_agent_id])
    create index(:a2a_messages, [:status])
    create index(:a2a_messages, [:reply_to])
    create index(:a2a_messages, [:type])
  end
end
