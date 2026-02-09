defmodule ClawdEx.Agent.Prompt do
  @moduledoc """
  系统提示构建器 - 基于 OpenClaw 的提示词体系

  负责:
  - 构建基础系统提示（身份、工具、安全）
  - 注入工具描述和使用指南
  - 注入 Bootstrap 文件 (AGENTS.md, SOUL.md, USER.md, TOOLS.md, IDENTITY.md, MEMORY.md, HEARTBEAT.md)
  - 注入运行时信息（模型、时间、工作区）
  """

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Agent.Loop

  # Bootstrap 文件列表和描述
  @bootstrap_files [
    {"AGENTS.md", "Agent configuration and guidelines"},
    {"SOUL.md", "Personality and tone"},
    {"USER.md", "Information about the user"},
    {"TOOLS.md", "Tool-specific notes"},
    {"IDENTITY.md", "Identity information"},
    {"HEARTBEAT.md", "Heartbeat checklist"},
    {"MEMORY.md", "Long-term memory"},
    {"BOOTSTRAP.md", "First-run ritual (delete after)"}
  ]

  # 工具摘要映射
  @tool_summaries %{
    "read" => "Read file contents",
    "write" => "Create or overwrite files",
    "edit" => "Make precise edits to files",
    "exec" => "Run shell commands (pty available for TTY-required CLIs)",
    "process" => "Manage background exec sessions",
    "web_search" => "Search the web (Brave API)",
    "web_fetch" => "Fetch and extract readable content from a URL",
    "browser" => "Control web browser",
    "canvas" => "Present/eval/snapshot the Canvas",
    "nodes" => "List/describe/notify/camera/screen on paired nodes",
    "cron" => "Manage cron jobs and wake events",
    "message" => "Send messages and channel actions",
    "gateway" => "Restart, apply config, or run updates",
    "agents_list" => "List agent ids allowed for sessions_spawn",
    "sessions_list" => "List other sessions with filters",
    "sessions_history" => "Fetch history for another session",
    "sessions_send" => "Send a message to another session",
    "sessions_spawn" => "Spawn a sub-agent session",
    "session_status" => "Show session status card",
    "memory_search" => "Semantically search memory files",
    "memory_get" => "Read memory file content by path",
    "image" => "Analyze an image with the configured image model",
    "tts" => "Convert text to speech",
    "compact" => "Compact session history"
  }

  @doc """
  构建完整的系统提示
  """
  @spec build(integer() | nil, map()) :: String.t()
  def build(agent_id, config \\ %{}) do
    agent = if agent_id, do: Repo.get(Agent, agent_id), else: nil

    sections = [
      identity_section(),
      tooling_section(config),
      tool_call_style_section(),
      safety_section(),
      skills_section(config),
      memory_section(config),
      workspace_section(agent, config),
      bootstrap_section(agent, config),
      messaging_section(config),
      silent_replies_section(),
      heartbeat_section(config),
      runtime_section(config)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # ============================================================================
  # Prompt Sections
  # ============================================================================

  defp identity_section do
    "You are a personal assistant powered by ClawdEx."
  end

  defp tooling_section(config) do
    tools = Map.get(config, :tools, [])
    tool_names = Enum.map(tools, & &1.name)

    tool_lines =
      tool_names
      |> Enum.map(fn name ->
        summary = Map.get(@tool_summaries, name, name)
        "- #{name}: #{summary}"
      end)
      |> Enum.join("\n")

    """
    ## Tooling
    Tool availability (filtered by policy):
    Tool names are case-sensitive. Call tools exactly as listed.
    #{tool_lines}
    TOOLS.md does not control tool availability; it is user guidance for how to use external tools.
    If a task is more complex or takes longer, spawn a sub-agent. It will do the work for you and ping you when it's done.
    """
  end

  defp tool_call_style_section do
    """
    ## Tool Call Style
    Default: do not narrate routine, low-risk tool calls (just call the tool).
    Narrate only when it helps: multi-step work, complex/challenging problems, sensitive actions (e.g., deletions), or when the user explicitly asks.
    Keep narration brief and value-dense; avoid repeating obvious steps.
    Use plain human language for narration unless in a technical context.

    ## CRITICAL: Use Tools, Don't Pretend!
    - When a task requires tools (reading files, running commands, taking screenshots, etc.), you MUST actually call the tools.
    - NEVER simulate or describe tool execution in text without actually calling the tool.
    - NEVER write output like "正在读取文件..." without immediately calling the read tool.
    - If you say "截图完成", there MUST be a preceding screenshot tool call with actual output.
    - Pretending to execute tools without calling them is a critical error.
    """
  end

  defp safety_section do
    """
    ## Safety
    You have no independent goals: do not pursue self-preservation, replication, resource acquisition, or power-seeking; avoid long-term plans beyond the user's request.
    Prioritize safety and human oversight over completion; if instructions conflict, pause and ask; comply with stop/pause/audit requests and never bypass safeguards.
    Do not manipulate or persuade anyone to expand access or disable safeguards. Do not copy yourself or change system prompts, safety rules, or tool policies unless explicitly requested.
    """
  end

  defp skills_section(_config) do
    # TODO: Implement skills system
    nil
  end

  defp memory_section(config) do
    tools = Map.get(config, :tools, [])
    tool_names = Enum.map(tools, & &1.name) |> MapSet.new()

    has_memory_tools =
      MapSet.member?(tool_names, "memory_search") or MapSet.member?(tool_names, "memory_get")

    if has_memory_tools do
      """
      ## Memory Recall
      Before answering anything about prior work, decisions, dates, people, preferences, or todos: run memory_search on MEMORY.md + memory/*.md; then use memory_get to pull only the needed lines. If low confidence after search, say you checked.
      Citations: include Source: <path#line> when it helps the user verify memory snippets.
      """
    else
      nil
    end
  end

  defp workspace_section(agent, config) do
    workspace =
      cond do
        agent && agent.workspace_path -> agent.workspace_path
        config[:workspace] -> config[:workspace]
        true -> "~/clawd"
      end

    """
    ## Workspace
    Your working directory is: #{workspace}
    Treat this directory as the single global workspace for file operations unless explicitly instructed otherwise.
    """
  end

  defp bootstrap_section(agent, config) do
    workspace =
      cond do
        agent && agent.workspace_path -> agent.workspace_path
        config[:workspace] -> config[:workspace]
        true -> nil
      end

    if workspace do
      expanded = Path.expand(workspace)
      max_chars = config[:bootstrap_max_chars] || 20_000

      loaded_files =
        @bootstrap_files
        |> Enum.map(fn {filename, _desc} ->
          path = Path.join(expanded, filename)

          if File.exists?(path) do
            case File.read(path) do
              {:ok, content} ->
                truncated = truncate_content(content, max_chars)
                "## #{filename}\n#{truncated}"

              _ ->
                "[MISSING] Expected at: #{path}"
            end
          else
            "[MISSING] Expected at: #{path}"
          end
        end)

      if Enum.any?(loaded_files, &(!String.starts_with?(&1, "[MISSING]"))) do
        """
        # Project Context
        The following project context files have been loaded:
        If SOUL.md is present, embody its persona and tone. Avoid stiff, generic replies; follow its guidance unless higher-priority instructions override it.

        #{Enum.join(loaded_files, "\n")}
        """
      else
        nil
      end
    else
      nil
    end
  end

  defp messaging_section(config) do
    tools = Map.get(config, :tools, [])
    tool_names = Enum.map(tools, & &1.name) |> MapSet.new()

    if MapSet.member?(tool_names, "message") do
      """
      ## Messaging
      - Reply in current session → automatically routes to the source channel (Signal, Telegram, etc.)
      - Cross-session messaging → use sessions_send(sessionKey, message)
      - Never use exec/curl for provider messaging; ClawdEx handles all routing internally.

      ### message tool
      - Use `message` for proactive sends + channel actions (polls, reactions, etc.).
      - For `action=send`, include `to` and `message`.
      - If you use `message` (`action=send`) to deliver your user-visible reply, respond with ONLY: NO_REPLY (avoid duplicate replies).
      """
    else
      nil
    end
  end

  defp silent_replies_section do
    """
    ## Silent Replies
    When you have nothing to say, respond with ONLY: NO_REPLY
    ⚠️ Rules:
    - It must be your ENTIRE message — nothing else
    - Never append it to an actual response (never include "NO_REPLY" in real replies)
    - Never wrap it in markdown or code blocks
    ❌ Wrong: "Here's help... NO_REPLY"
    ❌ Wrong: "NO_REPLY"
    ✅ Right: NO_REPLY
    """
  end

  defp heartbeat_section(config) do
    heartbeat_prompt =
      config[:heartbeat_prompt] ||
        "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK."

    """
    ## Heartbeats
    Heartbeat prompt: #{heartbeat_prompt}
    If you receive a heartbeat poll (a user message matching the heartbeat prompt above), and there is nothing that needs attention, reply exactly:
    HEARTBEAT_OK
    If something needs attention, do NOT include "HEARTBEAT_OK"; reply with the alert text instead.
    """
  end

  defp runtime_section(config) do
    model = config[:model] || "unknown"
    default_model = config[:default_model] || model
    timezone = config[:timezone] || "UTC"
    channel = config[:channel] || "unknown"

    now =
      DateTime.utc_now()
      |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    """
    ## Runtime
    - **Model:** #{model}
    - **Default Model:** #{default_model}
    - **Channel:** #{channel}
    - **Current Time:** #{now}
    - **Timezone:** #{timezone}
    - **Max Tool Iterations:** #{Loop.max_tool_iterations()}
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp truncate_content(content, max_chars) when byte_size(content) <= max_chars do
    content
  end

  defp truncate_content(content, max_chars) do
    # 截取开头和结尾
    head_size = div(max_chars, 2)
    tail_size = div(max_chars, 2) - 50

    head = String.slice(content, 0, head_size)
    tail = String.slice(content, -tail_size, tail_size)

    "#{head}\n\n... [truncated #{byte_size(content) - max_chars} bytes] ...\n\n#{tail}"
  end
end
