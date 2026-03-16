defmodule ClawdEx.Skills.Manager do
  @moduledoc """
  Skills Manager — GenServer for dynamic skill lifecycle management.

  Provides higher-level operations on top of the Loader:
  - Load/reload skills from disk
  - Enable/disable individual skills (persisted in state)
  - Hot-reload a single skill by name
  - List skills with filtering (source, enabled, search)
  - Skill metadata retrieval
  """
  use GenServer

  require Logger

  alias ClawdEx.Skills.{Loader, Gate, Skill}

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Load (or reload) all skills from configured directories."
  @spec load_all_skills() :: {:ok, [Skill.t()]}
  def load_all_skills do
    GenServer.call(__MODULE__, :load_all_skills)
  end

  @doc "Enable a skill by name."
  @spec enable_skill(String.t()) :: :ok | {:error, :not_found}
  def enable_skill(name) do
    GenServer.call(__MODULE__, {:set_enabled, name, true})
  end

  @doc "Disable a skill by name."
  @spec disable_skill(String.t()) :: :ok | {:error, :not_found}
  def disable_skill(name) do
    GenServer.call(__MODULE__, {:set_enabled, name, false})
  end

  @doc "Check whether a skill is disabled."
  @spec disabled?(String.t()) :: boolean()
  def disabled?(name) do
    GenServer.call(__MODULE__, {:disabled?, name})
  end

  @doc "Return the current set of disabled skill names."
  @spec disabled_set() :: MapSet.t()
  def disabled_set do
    GenServer.call(__MODULE__, :disabled_set)
  end

  @doc "Hot-reload a single skill by name from its on-disk location."
  @spec reload_skill(String.t()) :: {:ok, Skill.t()} | {:error, term()}
  def reload_skill(name) do
    GenServer.call(__MODULE__, {:reload_skill, name})
  end

  @doc "Get detailed skill info including gate status."
  @spec get_skill_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_skill_info(name) do
    GenServer.call(__MODULE__, {:get_skill_info, name})
  end

  @doc """
  List skills with optional filters.

  Options:
  - `:enabled_only` — only return enabled & eligible skills (default false)
  - `:source` — filter by source atom (:bundled, :managed, :workspace)
  - `:search` — substring match on name or description
  """
  @spec list_skills(keyword()) :: [Skill.t()]
  def list_skills(opts \\ []) do
    GenServer.call(__MODULE__, {:list_skills, opts})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    skills = Loader.load_all(opts)
    by_name = index_by_name(skills)
    Logger.info("Skills Manager loaded #{map_size(by_name)} skill(s)")
    {:ok, %{skills: by_name, disabled: MapSet.new(), opts: opts}}
  end

  @impl true
  def handle_call(:load_all_skills, _from, state) do
    skills = Loader.load_all(state.opts)
    by_name = index_by_name(skills)
    Logger.info("Skills Manager reloaded #{map_size(by_name)} skill(s)")
    new_state = %{state | skills: by_name}
    # Notify Registry to refresh its view
    notify_registry()
    {:reply, {:ok, Map.values(by_name)}, new_state}
  end

  @impl true
  def handle_call({:set_enabled, name, enabled?}, _from, state) do
    if Map.has_key?(state.skills, name) do
      disabled =
        if enabled?,
          do: MapSet.delete(state.disabled, name),
          else: MapSet.put(state.disabled, name)

      {:reply, :ok, %{state | disabled: disabled}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:disabled?, name}, _from, state) do
    {:reply, MapSet.member?(state.disabled, name), state}
  end

  @impl true
  def handle_call(:disabled_set, _from, state) do
    {:reply, state.disabled, state}
  end

  @impl true
  def handle_call({:reload_skill, name}, _from, state) do
    case Map.get(state.skills, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      existing_skill ->
        case Loader.parse_skill_file(existing_skill.location, existing_skill.source) do
          {:ok, reloaded} ->
            new_skills = Map.put(state.skills, reloaded.name, reloaded)
            Logger.info("Skills Manager hot-reloaded skill: #{name}")
            notify_registry()
            {:reply, {:ok, reloaded}, %{state | skills: new_skills}}

          {:error, reason} ->
            Logger.warning("Skills Manager failed to reload skill #{name}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_skill_info, name}, _from, state) do
    case Map.get(state.skills, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      skill ->
        info = %{
          skill: skill,
          eligible: Gate.eligible?(skill),
          gate_status: Gate.detailed_status(skill),
          disabled: MapSet.member?(state.disabled, name),
          source: skill.source
        }

        {:reply, {:ok, info}, state}
    end
  end

  @impl true
  def handle_call({:list_skills, opts}, _from, state) do
    skills =
      state.skills
      |> Map.values()
      |> maybe_filter_enabled(opts, state.disabled)
      |> maybe_filter_source(opts)
      |> maybe_filter_search(opts)

    {:reply, skills, state}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp index_by_name(skills) do
    Map.new(skills, fn s -> {s.name, s} end)
  end

  defp notify_registry do
    # Best-effort: Registry may not be started yet during boot
    try do
      ClawdEx.Skills.Registry.refresh()
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp maybe_filter_enabled(skills, opts, disabled) do
    if Keyword.get(opts, :enabled_only, false) do
      skills
      |> Enum.filter(&Gate.eligible?/1)
      |> Enum.reject(fn s -> MapSet.member?(disabled, s.name) end)
    else
      skills
    end
  end

  defp maybe_filter_source(skills, opts) do
    case Keyword.get(opts, :source) do
      nil -> skills
      source -> Enum.filter(skills, fn s -> s.source == source end)
    end
  end

  defp maybe_filter_search(skills, opts) do
    case Keyword.get(opts, :search) do
      nil ->
        skills

      term ->
        down = String.downcase(term)

        Enum.filter(skills, fn s ->
          String.contains?(String.downcase(s.name), down) ||
            String.contains?(String.downcase(s.description), down)
        end)
    end
  end
end
