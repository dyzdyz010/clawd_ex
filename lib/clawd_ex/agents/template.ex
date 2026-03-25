defmodule ClawdEx.Agents.Template do
  @moduledoc """
  Agent template rendering engine.
  Renders per-agent workspace files from EEx templates in priv/agent-template/.
  """

  @role_capabilities %{
    "CTO" => ["architecture", "code-review", "technical-planning"],
    "Engineering Lead" => ["sprint-planning", "code-review", "task-delegation"],
    "Frontend Dev" => ["coding", "frontend", "react", "typescript"],
    "Backend Dev" => ["coding", "backend", "elixir", "database"],
    "DevOps Engineer" => ["coding", "devops", "ci-cd", "deployment"],
    "QA Engineer" => ["coding", "testing", "quality-assurance"],
    "Product Manager" => ["product-planning", "user-stories", "prioritization"],
    "UI/UX Designer" => ["design", "ux-research", "prototyping"],
    "Data Analyst" => ["data-analysis", "metrics", "reporting"],
    "Security Engineer" => ["coding", "security-audit", "compliance"]
  }

  @role_descriptions %{
    "default" => "a versatile personal assistant",
    "CTO" => "the technical visionary and architecture guardian of the team",
    "Engineering Lead" => "the engineering team's organizer and code quality champion",
    "Frontend Dev" => "the UI specialist who crafts user experiences with React and TypeScript",
    "Backend Dev" => "the systems builder who powers the platform with Elixir and databases",
    "DevOps Engineer" => "the infrastructure specialist who keeps everything running smoothly",
    "QA Engineer" => "the quality guardian who catches what others miss",
    "Product Manager" => "the voice of the user and product strategist",
    "UI/UX Designer" => "the design thinker who shapes how things look and feel",
    "Data Analyst" => "the data-driven decision maker who turns numbers into insights",
    "Security Engineer" => "the security sentinel who protects the team and its systems"
  }

  @role_vibes %{
    "default" =>
      "Be the assistant you'd actually want to talk to. Concise when needed, thorough when it matters. Not a corporate drone. Not a sycophant. Just... good.",
    "CTO" =>
      "Think big picture. Challenge assumptions. Make architectural decisions with confidence. You see the forest, not just the trees. Balance innovation with pragmatism.",
    "Engineering Lead" =>
      "Organized, pragmatic, supportive. You unblock others and keep the team shipping. Balance quality with velocity. Lead by example.",
    "Frontend Dev" =>
      "Creative, detail-oriented, user-focused. You care about pixels, performance, and polish. Make it beautiful AND functional.",
    "Backend Dev" =>
      "Systematic, reliable, thorough. You build the foundations. Think about edge cases, data integrity, and scalability. Clean code matters.",
    "DevOps Engineer" =>
      "Automation-first, reliability-obsessed. If it can break, you've already planned for it. Infrastructure as code, always. Monitor everything.",
    "QA Engineer" =>
      "Skeptical in the best way. You think about what could go wrong. Thorough, methodical, and relentless about quality. Break it before users do.",
    "Product Manager" =>
      "User-first, data-informed. You translate between business needs and engineering reality. Prioritize ruthlessly. Ship what matters.",
    "UI/UX Designer" =>
      "Empathetic, visual, iterative. You advocate for the user. Design with intention, prototype quickly, iterate based on feedback.",
    "Data Analyst" =>
      "Curious, precise, storytelling with data. You turn numbers into insights and insights into action. Question assumptions with evidence.",
    "Security Engineer" =>
      "Paranoid (productively). You think like an attacker to defend like a pro. Security is not optional, it's foundational."
  }

  @template_files ["AGENTS.md.eex", "SOUL.md.eex", "IDENTITY.md.eex", "TEAM.md.eex"]

  @doc """
  Render all agent templates. Returns a map of filename => content.

  ## Parameters
    - agent: %Agent{} struct (must have id, name, default_model, capabilities)
    - team: list of maps with :id, :name, :capabilities, :default_model
  """
  def render(agent, team) do
    assigns = build_assigns(agent, team)
    tpl_dir = template_dir()

    @template_files
    |> Enum.map(fn eex_file ->
      output_name = String.replace_suffix(eex_file, ".eex", "")
      path = Path.join(tpl_dir, eex_file)
      content = EEx.eval_file(path, assigns: assigns)
      {output_name, content}
    end)
    |> Map.new()
  end

  @doc """
  Render just the TEAM.md template.
  """
  def team_md(agent, team) do
    assigns = build_assigns(agent, team)
    path = Path.join(template_dir(), "TEAM.md.eex")
    EEx.eval_file(path, assigns: assigns)
  end

  @doc """
  Get recommended capabilities for a role name.
  Returns [] for unknown roles.
  """
  def role_capabilities(role_name) do
    Map.get(@role_capabilities, role_name, [])
  end

  @doc """
  Get the role_capabilities map.
  """
  def role_capabilities_map, do: @role_capabilities

  # Build assigns for template rendering
  defp build_assigns(agent, team) do
    capabilities_str =
      case Map.get(agent, :capabilities, []) do
        caps when is_list(caps) and caps != [] -> Enum.join(caps, ", ")
        _ -> "general"
      end

    team_rows =
      Enum.map_join(team, "\n", fn member ->
        caps =
          case Map.get(member, :capabilities, []) do
            c when is_list(c) and c != [] -> Enum.join(c, ", ")
            _ -> "—"
          end

        model = Map.get(member, :default_model) || "default"
        "| #{member.id} | #{member.name} | #{model} | #{caps} | Active |"
      end)

    today = Date.utc_today() |> Date.to_iso8601()
    name = Map.get(agent, :name, "unknown")

    [
      agent: agent,
      team: team,
      workspace: Map.get(agent, :workspace_path) || "",
      capabilities_str: capabilities_str,
      team_rows: team_rows,
      today: today,
      role_description: Map.get(@role_descriptions, name, "a specialist on the team"),
      role_vibe: Map.get(@role_vibes, name, @role_vibes["default"])
    ]
  end

  defp template_dir do
    priv_dir = :code.priv_dir(:clawd_ex)
    Path.join(priv_dir, "agent-template")
  end
end
