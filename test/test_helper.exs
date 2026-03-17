ExUnit.start(exclude: [:requires_chrome])

# Only configure sandbox if Repo is started
if Process.whereis(ClawdEx.Repo) do
  Ecto.Adapters.SQL.Sandbox.mode(ClawdEx.Repo, :manual)

  # Also increase DynamicSupervisor max_restarts for SessionManager
  # to prevent cascading crashes in test environment
  # (spawned SessionWorkers may fail on sandbox-revoked DB connections)
end
