defmodule ClawdEx.Channels.ChannelBinding do
  @moduledoc """
  Schema for channel bindings — maps agents to permanent channel locations.

  Each binding represents "this agent is permanently present in this channel location".
  On boot (or at runtime), each active binding auto-starts a persistent SessionWorker GenServer.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "channel_bindings" do
    belongs_to :agent, ClawdEx.Agents.Agent
    field :channel, :string
    field :channel_config, :map, default: %{}
    field :session_key, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(agent_id channel channel_config session_key)a
  @optional_fields ~w(active)a

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:channel, max: 50)
    |> validate_length(:session_key, max: 255)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:session_key)
    |> unique_constraint([:agent_id, :channel, :channel_config],
      name: :channel_bindings_agent_id_channel_channel_config_index
    )
  end
end
