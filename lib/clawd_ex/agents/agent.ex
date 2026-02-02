defmodule ClawdEx.Agents.Agent do
  @moduledoc """
  Agent Schema - 代理配置和状态
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :workspace_path, :string
    field :default_model, :string, default: "anthropic/claude-sonnet-4-20250514"
    field :system_prompt, :string
    field :config, :map, default: %{}
    field :active, :boolean, default: true

    has_many :sessions, ClawdEx.Sessions.Session
    has_many :memory_chunks, ClawdEx.Memory.Chunk

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(workspace_path default_model system_prompt config active)a

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:name)
  end
end
