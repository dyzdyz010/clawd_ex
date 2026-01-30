defmodule ClawdEx.Memory.Chunk do
  @moduledoc """
  记忆块 Schema - 存储文本块及其向量嵌入
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "memory_chunks" do
    field :content, :string
    field :source_file, :string
    field :source_type, Ecto.Enum, values: [:memory_file, :session, :document]
    field :start_line, :integer
    field :end_line, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_model, :string
    field :metadata, :map, default: %{}

    belongs_to :agent, ClawdEx.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(content source_file source_type agent_id)a
  @optional_fields ~w(start_line end_line embedding embedding_model metadata)a

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:agent_id)
  end
end
