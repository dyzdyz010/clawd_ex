defmodule ClawdEx.Memory.Chunk do
  @moduledoc """
  记忆块 Schema - 存储文本块及其向量嵌入

  支持多种记忆类型：
  - `:episodic` - 情景记忆（对话、事件）
  - `:semantic` - 语义记忆（事实、知识）
  - `:procedural` - 程序记忆（技能、流程）
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "memory_chunks" do
    field :content, :string
    field :source_file, :string
    # 兼容旧的 source_type，同时支持新的记忆类型
    field :source_type, :string
    field :start_line, :integer
    field :end_line, :integer
    field :embedding, Pgvector.Ecto.Vector
    field :embedding_model, :string
    field :metadata, :map, default: %{}

    belongs_to :agent, ClawdEx.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(content)a
  @optional_fields ~w(source_file source_type start_line end_line embedding embedding_model metadata agent_id)a

  def changeset(chunk, attrs) do
    chunk
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:agent_id)
  end

  @doc """
  为直接插入构建 attrs map（绕过 changeset）
  """
  def build_attrs(content, opts \\ []) do
    now = DateTime.utc_now()

    %{
      content: content,
      source_file: Keyword.get(opts, :source, "unknown"),
      source_type: opts |> Keyword.get(:type, :episodic) |> to_string(),
      start_line: Keyword.get(opts, :start_line, 1),
      end_line: Keyword.get(opts, :end_line, 1),
      embedding: Keyword.get(opts, :embedding),
      embedding_model: Keyword.get(opts, :embedding_model),
      metadata: Keyword.get(opts, :metadata, %{}),
      agent_id: Keyword.get(opts, :agent_id),
      inserted_at: now,
      updated_at: now
    }
  end
end
