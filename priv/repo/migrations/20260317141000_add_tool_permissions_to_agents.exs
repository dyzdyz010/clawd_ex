defmodule ClawdEx.Repo.Migrations.AddToolPermissionsToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :allowed_tools, {:array, :string}, default: []
      add :denied_tools, {:array, :string}, default: []
    end
  end
end
