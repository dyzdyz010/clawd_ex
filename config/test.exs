import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
database_url = System.get_env("DATABASE_URL")

if database_url do
  config :clawd_ex, ClawdEx.Repo,
    url: database_url <> "#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2,
    types: ClawdEx.PostgresTypes
else
  config :clawd_ex, ClawdEx.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "clawd_ex_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2,
    types: ClawdEx.PostgresTypes
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :clawd_ex, ClawdExWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "JsroH24aGRxCezz1CRlWy3ZumKlTkrpPuVNjBMVb/GBqhrPjudm1GfJ3+S8x8t+K",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Disable Discord in tests
config :clawd_ex, discord_enabled: false
