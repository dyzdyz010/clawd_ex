defmodule ClawdEx.Sessions.Message do
  @moduledoc """
  Message Schema - 单条消息记录
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @roles ~w(user assistant system tool)a

  schema "messages" do
    field :role, Ecto.Enum, values: @roles
    field :content, :string
    field :tool_calls, {:array, :map}, default: []
    field :tool_call_id, :string
    field :model, :string
    field :tokens_in, :integer
    field :tokens_out, :integer
    field :metadata, :map, default: %{}

    belongs_to :session, ClawdEx.Sessions.Session

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(role content session_id)a
  @optional_fields ~w(tool_calls tool_call_id model tokens_in tokens_out metadata)a

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:session_id)
  end
end
