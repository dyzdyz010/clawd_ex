defmodule ClawdEx.Tools.AgentsList do
  @moduledoc """
  代理列表工具

  列出可用的代理 ID，返回代理列表和 allowAny 标志。
  用于多代理场景，支持 allowlist 过滤。
  """
  @behaviour ClawdEx.Tools.Tool

  import Ecto.Query

  @impl true
  def name, do: "agents_list"

  @impl true
  def description do
    "List available agent IDs. Returns the list of agents and whether spawning arbitrary agents is allowed."
  end

  @impl true
  def parameters do
    %{
      type: "object",
      properties: %{
        filter: %{
          type: "string",
          description: "Optional filter pattern to match agent names or capabilities (substring match)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(params, _context) do
    agents = list_agents_from_db()
    filter = params["filter"] || params[:filter]

    filtered =
      if filter && filter != "" do
        filter_agents(agents, filter)
      else
        agents
      end

    {:ok,
     format_result(%{
       agents: filtered,
       allow_any: true,
       total: length(agents),
       filtered: length(filtered)
     })}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp list_agents_from_db do
    try do
      ClawdEx.Repo.all(
        from(a in ClawdEx.Agents.Agent,
          where: a.active == true,
          order_by: a.id,
          select: %{
            id: a.id,
            name: a.name,
            capabilities: a.capabilities,
            default_model: a.default_model
          }
        )
      )
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp filter_agents(agents, pattern) do
    pattern_lower = String.downcase(pattern)

    Enum.filter(agents, fn agent ->
      name_match =
        agent.name
        |> to_string()
        |> String.downcase()
        |> String.contains?(pattern_lower)

      cap_match =
        Enum.any?(agent.capabilities || [], fn cap ->
          cap |> to_string() |> String.downcase() |> String.contains?(pattern_lower)
        end)

      name_match or cap_match
    end)
  end

  defp format_result(%{agents: agents, allow_any: allow_any, total: total, filtered: filtered}) do
    agents_list =
      if agents == [] do
        "  (none found)"
      else
        agents
        |> Enum.map(fn agent ->
          caps = (agent.capabilities || []) |> Enum.join(", ")

          if caps != "" do
            "  - #{agent.name} (id: #{agent.id}) — capabilities: #{caps}"
          else
            "  - #{agent.name} (id: #{agent.id})"
          end
        end)
        |> Enum.join("\n")
      end

    count_info =
      if total != filtered do
        " (#{filtered}/#{total} shown)"
      else
        ""
      end

    """
    ## Available Agents#{count_info}

    #{agents_list}

    **Allow Any:** #{allow_any}
    """
  end
end
