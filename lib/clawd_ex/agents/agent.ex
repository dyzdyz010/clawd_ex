defmodule ClawdEx.Agents.Agent do
  @moduledoc """
  Agent Schema - 代理配置和状态
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ClawdEx.AI.Models

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :workspace_path, :string
    field :default_model, :string
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
    |> put_default_model()
    |> unique_constraint(:name)
  end

  @doc """
  获取 agent 的有效模型（考虑默认值）
  """
  def effective_model(%__MODULE__{default_model: nil}), do: Models.default()
  def effective_model(%__MODULE__{default_model: ""}), do: Models.default()
  def effective_model(%__MODULE__{default_model: model}), do: Models.resolve(model)

  # 如果未设置 default_model，使用系统默认
  defp put_default_model(changeset) do
    case get_field(changeset, :default_model) do
      nil -> put_change(changeset, :default_model, Models.default())
      "" -> put_change(changeset, :default_model, Models.default())
      _ -> changeset
    end
  end
end
