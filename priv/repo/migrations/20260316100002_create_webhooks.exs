defmodule ClawdEx.Repo.Migrations.CreateWebhooks do
  use Ecto.Migration

  def change do
    create table(:webhooks) do
      add :name, :string, null: false
      add :url, :string, null: false
      add :secret, :string, null: false
      add :events, {:array, :string}, default: [], null: false
      add :enabled, :boolean, default: true, null: false
      add :headers, :map, default: %{}
      add :retry_count, :integer, default: 0
      add :last_triggered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:webhooks, [:name])
    create index(:webhooks, [:enabled])

    create table(:webhook_deliveries) do
      add :webhook_id, references(:webhooks, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :payload, :map, default: %{}, null: false
      add :status, :string, default: "pending", null: false
      add :response_code, :integer
      add :response_body, :text
      add :attempts, :integer, default: 0
      add :next_retry_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_deliveries, [:webhook_id])
    create index(:webhook_deliveries, [:status])
    create index(:webhook_deliveries, [:next_retry_at])
  end
end
