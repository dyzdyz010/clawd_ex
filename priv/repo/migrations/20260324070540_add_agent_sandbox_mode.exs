defmodule ClawdEx.Repo.Migrations.AddAgentSandboxMode do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :sandbox_mode, :string, default: "unrestricted"
      add :extra_denied_commands, {:array, :string}, default: []
    end
  end
end
