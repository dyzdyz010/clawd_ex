defmodule ClawdEx.Repo.Migrations.AddA2aPriority do
  use Ecto.Migration

  def change do
    alter table(:a2a_messages) do
      add :priority, :integer, default: 5, null: false
    end

    create index(:a2a_messages, [:priority])
    create index(:a2a_messages, [:to_agent_id, :status, :priority])
  end
end
