defmodule ClawdEx.Webhooks.Delivery do
  @moduledoc """
  Webhook Delivery Schema — 单次投递记录，含重试状态。
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(pending success failed)

  schema "webhook_deliveries" do
    field :event_type, :string
    field :payload, :map, default: %{}
    field :status, :string, default: "pending"
    field :response_code, :integer
    field :response_body, :string
    field :attempts, :integer, default: 0
    field :next_retry_at, :utc_datetime

    belongs_to :webhook, ClawdEx.Webhooks.Webhook

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(webhook_id event_type payload)a
  @optional_fields ~w(status response_code response_body attempts next_retry_at)a

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:webhook_id)
  end

  def statuses, do: @statuses
end
