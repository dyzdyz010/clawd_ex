defmodule ClawdEx.Repo.Migrations.AddCronJobNotify do
  use Ecto.Migration

  def change do
    alter table(:cron_jobs) do
      # Notification targets: list of %{channel, target, auto}
      add :notify, :jsonb, default: "[]"
      # Dedicated session for storing results (for webchat)
      add :result_session_key, :string
    end

    create index(:cron_jobs, [:result_session_key])
  end
end
