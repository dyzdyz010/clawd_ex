Postgrex.Types.define(
  ClawdEx.PostgresTypes,
  [Pgvector.Extensions.Vector] ++ Ecto.Adapters.Postgres.extensions(),
  []
)
