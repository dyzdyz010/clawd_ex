defmodule ClawdEx.Repo.Migrations.CreateCronJobs do
  use Ecto.Migration

  def change do
    create table(:cron_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :schedule, :string, null: false  # cron expression like "0 9 * * *"
      add :command, :text, null: false     # command to execute
      add :agent_id, :string               # which agent owns this job
      add :enabled, :boolean, default: true, null: false
      add :timezone, :string, default: "UTC"
      add :last_run_at, :utc_datetime_usec
      add :next_run_at, :utc_datetime_usec
      add :run_count, :integer, default: 0, null: false
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cron_jobs, [:agent_id])
    create index(:cron_jobs, [:enabled])
    create index(:cron_jobs, [:next_run_at])
    create unique_index(:cron_jobs, [:name, :agent_id])

    # Job run history table
    create table(:cron_job_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :job_id, references(:cron_jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
      add :status, :string, null: false  # "running", "completed", "failed", "timeout"
      add :exit_code, :integer
      add :output, :text
      add :error, :text
      add :duration_ms, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cron_job_runs, [:job_id])
    create index(:cron_job_runs, [:started_at])
    create index(:cron_job_runs, [:status])
  end
end
