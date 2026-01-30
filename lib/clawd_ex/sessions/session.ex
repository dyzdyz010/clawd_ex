defmodule ClawdEx.Sessions.Session do
  @moduledoc """
  Session Schema - 会话状态和消息历史
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @session_states ~w(active idle compacting archived)a

  schema "sessions" do
    field :session_key, :string
    field :channel, :string
    field :channel_id, :string
    field :state, Ecto.Enum, values: @session_states, default: :active
    field :model_override, :string
    field :token_count, :integer, default: 0
    field :message_count, :integer, default: 0
    field :metadata, :map, default: %{}
    field :last_activity_at, :utc_datetime

    belongs_to :agent, ClawdEx.Agents.Agent
    has_many :messages, ClawdEx.Sessions.Message

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(session_key channel agent_id)a
  @optional_fields ~w(channel_id state model_override token_count message_count metadata last_activity_at)a

  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:session_key)
    |> foreign_key_constraint(:agent_id)
  end
end
