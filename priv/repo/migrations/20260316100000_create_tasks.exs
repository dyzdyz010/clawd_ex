defmodule ClawdEx.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title, :string, null: false
      add :description, :text
      add :status, :string, default: "pending", null: false
      add :priority, :integer, default: 5
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :session_key, :string
      add :parent_task_id, references(:tasks, on_delete: :nilify_all)
      add :context, :map, default: %{}
      add :result, :map, default: %{}
      add :max_retries, :integer, default: 3
      add :retry_count, :integer, default: 0
      add :timeout_seconds, :integer, default: 600
      add :scheduled_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :last_heartbeat_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:status])
    create index(:tasks, [:agent_id])
    create index(:tasks, [:session_key])
    create index(:tasks, [:parent_task_id])
    create index(:tasks, [:priority, :inserted_at])
  end
end
