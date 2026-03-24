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
    field :allowed_tools, {:array, :string}, default: []
    field :denied_tools, {:array, :string}, default: []
    field :sandbox_mode, :string, default: "unrestricted"
    field :extra_denied_commands, {:array, :string}, default: []
    field :auto_start, :boolean, default: false
    field :capabilities, {:array, :string}, default: []
    field :heartbeat_interval_seconds, :integer, default: 0
    field :always_on, :boolean, default: false
    field :allowed_groups, {:array, :string}, default: []
    field :pairing_code, :string

    has_many :sessions, ClawdEx.Sessions.Session
    has_many :memory_chunks, ClawdEx.Memory.Chunk
    has_many :dm_pairings, ClawdEx.Security.DmPairing

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(name)a
  @optional_fields ~w(workspace_path default_model system_prompt config active allowed_tools denied_tools sandbox_mode extra_denied_commands auto_start capabilities heartbeat_interval_seconds always_on allowed_groups pairing_code)a

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> put_default_model()
    |> validate_inclusion(:sandbox_mode, ~w(unrestricted workspace strict))
    |> unique_constraint(:name)
    |> unique_constraint(:pairing_code)
    |> maybe_generate_pairing_code()
  end

  @doc """
  Check if a group ID is allowed for this agent.
  Empty allowed_groups means all groups are allowed (backward compatible).
  """
  def group_allowed?(%__MODULE__{allowed_groups: []}), do: true
  def group_allowed?(%__MODULE__{allowed_groups: nil}), do: true
  def group_allowed?(%__MODULE__{allowed_groups: groups}, group_id) when is_list(groups) do
    groups == [] or to_string(group_id) in Enum.map(groups, &to_string/1)
  end

  # Generate a pairing code if not already set
  defp maybe_generate_pairing_code(changeset) do
    case get_field(changeset, :pairing_code) do
      nil ->
        code = generate_pairing_code()
        put_change(changeset, :pairing_code, code)
      _ ->
        changeset
    end
  end

  defp generate_pairing_code do
    :crypto.strong_rand_bytes(6) |> Base.encode32(case: :lower, padding: false)
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
