defmodule ClawdEx.Skills.Registry do
  @moduledoc """
  GenServer that maintains a registry of loaded and eligible skills.

  Loads skills at startup and supports hot-reload via `refresh/0`.
  """

  use GenServer

  require Logger

  alias ClawdEx.Skills.{Loader, Gate, Skill}

  # ============================================================================
  # Client API
  # ============================================================================

  @doc "Start the Skills Registry."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all eligible skills."
  @spec list_skills() :: [Skill.t()]
  def list_skills do
    GenServer.call(__MODULE__, :list_skills)
  end

  @doc "Get a skill by name."
  @spec get_skill(String.t()) :: Skill.t() | nil
  def get_skill(name) do
    GenServer.call(__MODULE__, {:get_skill, name})
  end

  @doc "Refresh skills from disk."
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "列出所有已加载的 skills（包括不符合 gate 条件的）"
  @spec list_all_skills() :: [Skill.t()]
  def list_all_skills do
    GenServer.call(__MODULE__, :list_all_skills)
  end

  @doc "启用或禁用指定 skill"
  @spec toggle_skill(String.t(), boolean()) :: :ok | {:error, :not_found}
  def toggle_skill(name, enabled?) do
    GenServer.call(__MODULE__, {:toggle_skill, name, enabled?})
  end

  @doc "获取 skill 详细信息，包括 gating 状态"
  @spec get_skill_details(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_skill_details(name) do
    GenServer.call(__MODULE__, {:get_skill_details, name})
  end

  @doc "返回 skill 每个 requirement 的满足状态"
  @spec skill_gate_status(Skill.t()) :: map()
  def skill_gate_status(%Skill{} = skill) do
    Gate.detailed_status(skill)
  end

  @doc """
  Build the XML prompt fragment for available skills.
  """
  @spec skills_prompt() :: String.t() | nil
  def skills_prompt do
    case list_skills() do
      [] ->
        nil

      skills ->
        entries =
          skills
          |> Enum.map(fn skill ->
            """
              <skill>
                <name>#{skill.name}</name>
                <description>#{skill.description}</description>
                <location>#{skill.location}</location>
              </skill>\
            """
          end)
          |> Enum.join("\n")

        """
        <available_skills>
        #{entries}
        </available_skills>\
        """
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    all_skills = Loader.load_all(opts)
    eligible = Gate.filter_eligible(all_skills)
    Logger.info("Skills registry loaded #{length(eligible)} eligible skill(s) out of #{length(all_skills)} total")
    {:ok, %{all_skills: all_skills, skills: eligible, opts: opts, disabled: MapSet.new()}}
  end

  @impl true
  def handle_call(:list_skills, _from, state) do
    # 返回 eligible 且未被手动禁用的 skills
    active = Enum.reject(state.skills, fn s -> MapSet.member?(state.disabled, s.name) end)
    {:reply, active, state}
  end

  @impl true
  def handle_call(:list_all_skills, _from, state) do
    {:reply, state.all_skills, state}
  end

  @impl true
  def handle_call({:get_skill, name}, _from, state) do
    skill = Enum.find(state.all_skills, fn s -> s.name == name end)
    {:reply, skill, state}
  end

  @impl true
  def handle_call({:toggle_skill, name, enabled?}, _from, state) do
    case Enum.find(state.all_skills, fn s -> s.name == name end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _skill ->
        disabled =
          if enabled?,
            do: MapSet.delete(state.disabled, name),
            else: MapSet.put(state.disabled, name)

        {:reply, :ok, %{state | disabled: disabled}}
    end
  end

  @impl true
  def handle_call({:get_skill_details, name}, _from, state) do
    case Enum.find(state.all_skills, fn s -> s.name == name end) do
      nil ->
        {:reply, {:error, :not_found}, state}

      skill ->
        details = %{
          skill: skill,
          eligible: Gate.eligible?(skill),
          gate_status: Gate.detailed_status(skill),
          disabled: MapSet.member?(state.disabled, name)
        }

        {:reply, {:ok, details}, state}
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    all_skills = Loader.load_all(state.opts)
    eligible = Gate.filter_eligible(all_skills)
    Logger.info("Skills registry refreshed: #{length(eligible)} eligible skill(s) out of #{length(all_skills)} total")
    {:noreply, %{state | all_skills: all_skills, skills: eligible}}
  end
end
