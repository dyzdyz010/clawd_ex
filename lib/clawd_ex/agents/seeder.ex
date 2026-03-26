defmodule ClawdEx.Agents.Seeder do
  @moduledoc """
  Agent config seeder — syncs priv/agents.json → DB on startup.

  Single source of truth is the JSON file. On each boot:
  - Creates agents that exist in JSON but not in DB
  - Updates existing agents if JSON differs from DB
  - Does NOT delete agents missing from JSON (safety)

  This eliminates config drift between code and database.
  """

  require Logger

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  import Ecto.Query

  @doc """
  Sync agents from priv/agents.json into the database.
  Called during application startup (after Repo is ready).
  """
  def sync! do
    case load_agent_definitions() do
      {:ok, definitions} ->
        Logger.info("[AgentSeeder] Syncing #{length(definitions)} agent definitions...")
        results = Enum.map(definitions, &upsert_agent/1)

        created = Enum.count(results, fn {action, _} -> action == :created end)
        updated = Enum.count(results, fn {action, _} -> action == :updated end)
        unchanged = Enum.count(results, fn {action, _} -> action == :unchanged end)
        errors = Enum.count(results, fn {action, _} -> action == :error end)

        Logger.info(
          "[AgentSeeder] Done: #{created} created, #{updated} updated, #{unchanged} unchanged, #{errors} errors"
        )

        :ok

      {:error, reason} ->
        Logger.warning("[AgentSeeder] Skipped: #{reason}")
        :ok
    end
  end

  defp load_agent_definitions do
    path = Path.join(:code.priv_dir(:clawd_ex), "agents.json")

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, definitions} when is_list(definitions) ->
              {:ok, definitions}

            {:ok, _} ->
              {:error, "agents.json must be a JSON array"}

            {:error, err} ->
              {:error, "Failed to parse agents.json: #{inspect(err)}"}
          end

        {:error, reason} ->
          {:error, "Failed to read agents.json: #{inspect(reason)}"}
      end
    else
      {:error, "agents.json not found at #{path}"}
    end
  end

  defp upsert_agent(definition) do
    name = Map.fetch!(definition, "name")

    case Repo.one(from(a in Agent, where: a.name == ^name)) do
      nil ->
        create_agent(name, definition)

      existing ->
        maybe_update_agent(existing, definition)
    end
  end

  defp create_agent(name, definition) do
    attrs = build_attrs(definition)

    case %Agent{} |> Agent.changeset(attrs) |> Repo.insert() do
      {:ok, agent} ->
        Logger.info("[AgentSeeder] Created: #{name} (id: #{agent.id})")
        {:created, agent}

      {:error, changeset} ->
        Logger.error("[AgentSeeder] Failed to create #{name}: #{inspect(changeset.errors)}")
        {:error, name}
    end
  end

  defp maybe_update_agent(existing, definition) do
    attrs = build_attrs(definition)

    # Only update if something changed
    changes =
      Enum.filter(attrs, fn {key, value} ->
        current = Map.get(existing, key)
        normalize(current) != normalize(value)
      end)
      |> Map.new()

    if map_size(changes) == 0 do
      {:unchanged, existing}
    else
      case existing |> Agent.changeset(changes) |> Repo.update() do
        {:ok, agent} ->
          changed_keys = Map.keys(changes) |> Enum.join(", ")
          Logger.info("[AgentSeeder] Updated: #{existing.name} (#{changed_keys})")
          {:updated, agent}

        {:error, changeset} ->
          Logger.error(
            "[AgentSeeder] Failed to update #{existing.name}: #{inspect(changeset.errors)}"
          )

          {:error, existing.name}
      end
    end
  end

  defp build_attrs(definition) do
    %{
      name: Map.fetch!(definition, "name"),
      default_model: Map.get(definition, "default_model", "anthropic/claude-opus-4-6"),
      capabilities: Map.get(definition, "capabilities", []),
      config: Map.get(definition, "config", %{}),
      active: Map.get(definition, "active", true),
      auto_start: Map.get(definition, "auto_start", false),
      always_on: Map.get(definition, "always_on", false)
    }
  end

  # Normalize values for comparison (handle list vs MapSet, string vs atom, etc.)
  defp normalize(value) when is_list(value), do: Enum.sort(Enum.map(value, &to_string/1))
  defp normalize(value), do: value
end
