defmodule ClawdEx.Webhooks.Webhook do
  @moduledoc """
  Webhook Schema — 外部 Webhook 注册和配置。
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "webhooks" do
    field :name, :string
    field :url, :string
    field :secret, :string
    field :events, {:array, :string}, default: []
    field :enabled, :boolean, default: true
    field :headers, :map, default: %{}
    field :retry_count, :integer, default: 0
    field :last_triggered_at, :utc_datetime

    has_many :deliveries, ClawdEx.Webhooks.Delivery

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name url secret events)a
  @optional_fields ~w(enabled headers retry_count last_triggered_at)a

  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:url, ~r/^https?:\/\//)
    |> validate_length(:events, min: 1)
    |> unique_constraint(:name)
  end
end
