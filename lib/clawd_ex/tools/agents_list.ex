defmodule ClawdEx.Tools.AgentsList do
  @moduledoc """
  代理列表工具

  列出可用的代理 ID，返回代理列表和 allowAny 标志。
  用于多代理场景，支持 allowlist 过滤。
  """
  @behaviour ClawdEx.Tools.Tool

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
          description: "Optional filter pattern to match agent IDs (substring match)"
        }
      },
      required: []
    }
  end

  @impl true
  def execute(params, _context) do
    config = get_agents_config()
    agents = config[:agents] || []
    allow_any = config[:allow_any] || false

    # Apply filter if provided
    filter = params["filter"] || params[:filter]

    filtered_agents =
      if filter && filter != "" do
        filter_agents(agents, filter)
      else
        agents
      end

    result = %{
      agents: filtered_agents,
      allow_any: allow_any,
      total: length(agents),
      filtered: length(filtered_agents)
    }

    {:ok, format_result(result)}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp get_agents_config do
    Application.get_env(:clawd_ex, :agents, [])
  end

  defp filter_agents(agents, pattern) do
    pattern_lower = String.downcase(pattern)

    Enum.filter(agents, fn agent ->
      agent
      |> to_string()
      |> String.downcase()
      |> String.contains?(pattern_lower)
    end)
  end

  defp format_result(%{agents: agents, allow_any: allow_any, total: total, filtered: filtered}) do
    agents_list =
      if agents == [] do
        "  (none configured)"
      else
        agents
        |> Enum.map(&"  - #{&1}")
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
