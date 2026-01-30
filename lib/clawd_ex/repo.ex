defmodule ClawdEx.Repo do
  use Ecto.Repo,
    otp_app: :clawd_ex,
    adapter: Ecto.Adapters.Postgres
end
