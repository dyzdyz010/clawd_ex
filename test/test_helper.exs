ExUnit.start()

# Only configure sandbox if Repo is started
if Process.whereis(ClawdEx.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(ClawdEx.Repo, :manual)
end
