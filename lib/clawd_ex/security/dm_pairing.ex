defmodule ClawdEx.Security.DmPairing do
  @moduledoc """
  DM Pairing — manages user-to-agent bindings for private messages.

  When a user sends a DM to the bot (Telegram/Discord), we need to know
  which Agent should handle it. This module provides:

  - Ecto schema for persistent storage (`dm_pairings` table)
  - GenServer with ETS cache for fast lookups
  - Pairing flow: user sends `/pair <code>` → binds to Agent
  - Lookup: given (user_id, channel) → returns agent_id or :not_paired
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  # ============================================================================
  # Ecto Schema
  # ============================================================================

  schema "dm_pairings" do
    field :user_id, :string
    field :channel, :string
    field :paired_at, :utc_datetime

    belongs_to :agent, Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(pairing, attrs) do
    pairing
    |> cast(attrs, [:user_id, :channel, :agent_id, :paired_at])
    |> validate_required([:user_id, :channel, :agent_id, :paired_at])
    |> unique_constraint([:user_id, :channel])
    |> foreign_key_constraint(:agent_id)
  end

  # ============================================================================
  # GenServer for cached lookups
  # ============================================================================

  defmodule Server do
    @moduledoc false
    use GenServer

    @table :dm_pairings_cache

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @doc "Look up the paired agent_id for a user on a channel."
    def lookup(user_id, channel) do
      case :ets.lookup(@table, {to_string(user_id), to_string(channel)}) do
        [{_, agent_id}] -> {:ok, agent_id}
        [] -> :not_paired
      end
    end

    @doc "Pair a user to an agent using a pairing code."
    def pair(user_id, channel, pairing_code) do
      GenServer.call(__MODULE__, {:pair, to_string(user_id), to_string(channel), pairing_code})
    end

    @doc "Remove a pairing."
    def unpair(user_id, channel) do
      GenServer.call(__MODULE__, {:unpair, to_string(user_id), to_string(channel)})
    end

    @doc "Clear all cached pairings. Useful for testing."
    def clear do
      GenServer.call(__MODULE__, :clear)
    end

    # --- GenServer Callbacks ---

    @impl true
    def init(_opts) do
      table = :ets.new(@table, [:set, :named_table, :protected, read_concurrency: true])
      send(self(), :load_from_db)
      {:ok, %{table: table}}
    end

    @impl true
    def handle_info(:load_from_db, state) do
      try do
        pairings =
          ClawdEx.Security.DmPairing
          |> Repo.all()

        Enum.each(pairings, fn p ->
          :ets.insert(@table, {{p.user_id, p.channel}, p.agent_id})
        end)
      rescue
        _ -> :ok
      end

      {:noreply, state}
    end

    @impl true
    def handle_call({:pair, user_id, channel, code}, _from, state) do
      result = do_pair(user_id, channel, code)
      {:reply, result, state}
    end

    def handle_call({:unpair, user_id, channel}, _from, state) do
      result = do_unpair(user_id, channel)
      {:reply, result, state}
    end

    def handle_call(:clear, _from, state) do
      :ets.delete_all_objects(@table)
      {:reply, :ok, state}
    end

    # --- Private ---

    defp do_pair(user_id, channel, code) do
      # Find agent by pairing code
      case Repo.get_by(Agent, pairing_code: code) do
        nil ->
          {:error, :invalid_code}

        agent ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          attrs = %{
            user_id: user_id,
            channel: channel,
            agent_id: agent.id,
            paired_at: now
          }

          result =
            case Repo.get_by(ClawdEx.Security.DmPairing, user_id: user_id, channel: channel) do
              nil ->
                %ClawdEx.Security.DmPairing{}
                |> ClawdEx.Security.DmPairing.changeset(attrs)
                |> Repo.insert()

              existing ->
                existing
                |> ClawdEx.Security.DmPairing.changeset(attrs)
                |> Repo.update()
            end

          case result do
            {:ok, pairing} ->
              :ets.insert(@table, {{user_id, channel}, pairing.agent_id})
              {:ok, %{agent_id: agent.id, agent_name: agent.name}}

            {:error, changeset} ->
              {:error, changeset}
          end
      end
    end

    defp do_unpair(user_id, channel) do
      case Repo.get_by(ClawdEx.Security.DmPairing, user_id: user_id, channel: channel) do
        nil ->
          {:error, :not_found}

        pairing ->
          Repo.delete(pairing)
          :ets.delete(@table, {user_id, channel})
          :ok
      end
    end
  end
end
