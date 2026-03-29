defmodule ClawdEx.Agent.Prompt do
  @moduledoc """
  系统提示构建器 - 基于 OpenClaw 的提示词体系

  负责:
  - 构建基础系统提示（身份、工具、安全）
  - 注入工具描述和使用指南
  - 注入 Bootstrap 文件 (AGENTS.md, SOUL.md, USER.md, TOOLS.md, IDENTITY.md, MEMORY.md, HEARTBEAT.md)
  - 注入运行时信息（模型、时间、工作区）
  """

  require Logger

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
    "compact" => "Compact session history",
    "a2a" => "Agent-to-Agent communication: discover agents, send notifications, make requests, delegate tasks, broadcast messages"
  }

  @doc """
  构建完整的系统提示
  """
  @spec build(integer() | nil, map()) :: String.t()
  def build(agent_id, config \\ %{}) do
    agent = if agent_id, do: Repo.get(Agent, agent_id), else: nil
    metadata = config[:inbound_metadata] || %{}
    is_group = metadata[:is_group] || false

    sections = [
      identity_section(agent),
      agent_context_section(agent, metadata),
      tooling_section(config),
      tool_call_style_section(),
      safety_section(),
      skills_section(config),
      memory_section(config),
      workspace_section(agent, config),
      bootstrap_section(agent, config, is_group),
      inbound_context_section(metadata, agent),
      group_chat_section(metadata),
      reply_tags_section(),
      messaging_section(config),
      silent_replies_section(),
      heartbeat_section(config),
      session_startup_section(config, is_group),
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

  defp identity_section(nil) do
    "You are a personal assistant powered by ClawdEx."
  end

  defp identity_section(agent) do
    role =
      if agent.config["role_description"],
        do: "\nRole: #{agent.config["role_description"]}",
        else: ""

    expertise =
      if agent.config["expertise"],
        do: "\nExpertise: #{Enum.join(agent.config["expertise"], ", ")}",
        else: ""

    "You are **#{agent.name}**, an AI agent powered by ClawdEx.#{role}#{expertise}"
  end

  defp agent_context_section(nil, _metadata), do: nil
  defp agent_context_section(_agent, %{is_group: false}), do: nil
  defp agent_context_section(_agent, metadata) when metadata == %{} or metadata == nil, do: nil

  defp agent_context_section(agent, metadata) do
    if metadata[:is_group] do
      other_agents = list_other_active_agents(agent)

      team_list =
        Enum.map_join(other_agents, "\n", fn a ->
          caps =
            if a.capabilities != [],
              do: " — #{Enum.join(a.capabilities, ", ")}",
              else: ""

          "- #{a.name} (id: #{a.id})#{caps}"
        end)

      channel_info = build_channel_info(agent, metadata)

      """
      ## Team Context
      You are part of a multi-agent team. Other agents in this workspace:
      #{team_list}
      #{channel_info}
      ### Communication Rules
      - Users address you by name (e.g. "@#{agent.name}" or "#{agent.name}")
      - Only respond when addressed to you or when the message is relevant to your role
      - To collaborate with another agent, use the `a2a` tool with action "send" or "request"
      - When you need another agent's expertise, delegate via A2A rather than attempting it yourself
      - Keep responses focused on your area of expertise

      ### CRITICAL: Actions Must Be Real
      - When you say "I'll delegate to X" or "I've assigned this to Y", you MUST actually call the a2a tool in the same turn
      - Saying you did something without calling the tool is lying — never do this
      - If you cannot execute an action (tool unavailable, error, etc.), say so honestly instead of pretending
      - "I'll do X" means you call the tool NOW, not later
      """
    else
      nil
    end
  end

  # Build channel info section showing the agent's default topics and how to send to them
  defp build_channel_info(agent, metadata) do
    channel = metadata[:channel] || "unknown"
    chat_id = metadata[:channel_id] || metadata[:chat_id]
    default_topics = get_in(agent.config || %{}, ["default_topics"])

    topic_ids = resolve_topic_ids(default_topics, channel, chat_id)

    if chat_id || topic_ids != [] do
      lines = ["### Your Channel Info"]

      lines =
        if chat_id do
          lines ++ ["- #{channel} group: #{channel}:#{chat_id}"]
        else
          lines
        end

      lines =
        if topic_ids != [] do
          ids_str = Enum.join(topic_ids, ", ")
          lines ++ ["- Your default topic(s): #{ids_str}"]
        else
          lines
        end

      lines =
        if chat_id && topic_ids != [] do
          first_topic = hd(topic_ids)

          lines ++
            [
              "- To send a message to your topic: use message tool with channel=\"#{channel}\", target=\"#{chat_id}\", topicId=\"#{first_topic}\""
            ]
        else
          lines
        end

      Enum.join(lines, "\n") <> "\n"
    else
      ""
    end
  end

  # Resolve topic IDs from default_topics config
  # Supports two formats:
  # 1. Map: {"telegram:-100xxx": [144, 145]}
  # 2. List: [144, "144"]
  defp resolve_topic_ids(nil, _channel, _chat_id), do: []

  defp resolve_topic_ids(default_topics, channel, chat_id) when is_map(default_topics) do
    key = "#{channel}:#{chat_id}"

    case Map.get(default_topics, key) do
      nil -> []
      ids when is_list(ids) -> Enum.map(ids, &to_string/1)
      id -> [to_string(id)]
    end
  end

  defp resolve_topic_ids(default_topics, _channel, _chat_id) when is_list(default_topics) do
    Enum.map(default_topics, &to_string/1)
  end

  defp resolve_topic_ids(_, _channel, _chat_id), do: []

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
    case ClawdEx.Skills.Registry.skills_prompt() do
      nil -> nil
      prompt ->
        """
        ## Skills
        Skills extend your capabilities. To use a skill, read its SKILL.md with the read tool.

        #{prompt}
        """
    end
  rescue
    # Registry might not be started yet
    _ -> nil
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

  defp bootstrap_section(agent, config, is_group) do
    workspace =
      cond do
        agent && agent.workspace_path -> agent.workspace_path
        config[:workspace] -> config[:workspace]
        true -> nil
      end

    if workspace do
      expanded = Path.expand(workspace)
      max_chars = config[:bootstrap_max_chars] || 20_000

      # In group chats, skip MEMORY.md to prevent private data leakage
      files_to_load =
        if is_group do
          Enum.reject(@bootstrap_files, fn {filename, _} -> filename == "MEMORY.md" end)
        else
          @bootstrap_files
        end

      loaded_files =
        files_to_load
        |> Enum.map(fn {filename, _desc} ->
          path = Path.join(expanded, filename)

          if File.exists?(path) do
            case File.read(path) do
              {:ok, content} ->
                # Check if BOOTSTRAP.md — schedule deletion after load
                if filename == "BOOTSTRAP.md" do
                  schedule_bootstrap_delete(path)
                end

                truncated = truncate_content(content, max_chars)
                "## #{path}\n#{truncated}"

              _ ->
                "[MISSING] Expected at: #{path}"
            end
          else
            "[MISSING] Expected at: #{path}"
          end
        end)

      if Enum.any?(loaded_files, &(!String.starts_with?(&1, "[MISSING]"))) do
        privacy_note =
          if is_group do
            "\nNote: MEMORY.md is NOT loaded in group chats for privacy. Use memory_search tool if needed."
          else
            ""
          end

        """
        # Project Context
        The following project context files have been loaded:
        If SOUL.md is present, embody its persona and tone. Avoid stiff, generic replies; follow its guidance unless higher-priority instructions override it.
        #{privacy_note}
        #{Enum.join(loaded_files, "\n")}
        """
      else
        nil
      end
    else
      nil
    end
  end

  # Schedule BOOTSTRAP.md deletion (fire-and-forget, after the prompt is built)
  defp schedule_bootstrap_delete(path) do
    Task.start(fn ->
      # Small delay to ensure the prompt was fully built before deleting
      Process.sleep(5_000)

      if File.exists?(path) do
        case File.rm(path) do
          :ok ->
            Logger.info("BOOTSTRAP.md deleted after first load (ritual complete)")

          {:error, reason} ->
            Logger.warning("Failed to delete BOOTSTRAP.md: #{inspect(reason)}")
        end
      end
    end)
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
  # Inbound Context — sender/chat metadata from the channel
  # ============================================================================

  defp inbound_context_section(metadata, _agent) when metadata == %{} or metadata == nil,
    do: nil

  defp inbound_context_section(metadata, agent) do
    chat_type = metadata[:chat_type] || "private"
    channel = metadata[:channel] || "unknown"

    context = %{
      schema: "clawdex.inbound_meta.v1",
      channel: channel,
      chat_type: chat_type,
      sender_id: metadata[:sender_id],
      sender_name: metadata[:sender_name],
      sender_username: metadata[:sender_username],
      is_group: metadata[:is_group] || false,
      is_forum: metadata[:is_forum] || false,
      topic_id: metadata[:topic_id],
      group_subject: metadata[:group_subject],
      agent_id: agent && agent.id,
      agent_name: agent && agent.name
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()

    """
    ## Inbound Context (trusted metadata)
    The following JSON describes the current message context.
    ```json
    #{Jason.encode!(context, pretty: true)}
    ```
    """
  end

  # ============================================================================
  # Group Chat — behavioral guidelines
  # ============================================================================

  defp group_chat_section(metadata) do
    if metadata[:is_group] do
      group_name = metadata[:group_subject] || "this group"

      """
      ## Group Chat Context
      You are in the group chat "#{group_name}". Your replies are automatically sent to this group.
      Do not use the message tool to send to this same group — just reply normally.

      ### Group Chat Rules
      - You are a participant, not the user's voice or proxy
      - Private info stays private — do not share MEMORY.md contents
      - Respond when directly mentioned, asked a question, or can add genuine value
      - Stay silent when it's casual banter or someone already answered
      - Quality > quantity — if you wouldn't send it in a real group chat, don't send it
      """
    else
      nil
    end
  end

  # ============================================================================
  # Reply Tags
  # ============================================================================

  defp reply_tags_section do
    """
    ## Reply Tags
    To reply to a specific message, include a reply tag as the very first token:
    - `[[reply_to_current]]` — replies to the triggering message
    - `[[reply_to:<message_id>]]` — replies to a specific message by ID
    Tags are stripped before sending. Example: `[[reply_to_current]] Here's your answer.`
    """
  end

  # ============================================================================
  # Session Startup Protocol
  # ============================================================================

  defp session_startup_section(config, is_group) do
    workspace = config[:workspace]

    if workspace do
      memory_instruction =
        if is_group do
          "- Skip MEMORY.md in group chats (privacy)"
        else
          "- Read `MEMORY.md` for long-term context"
        end

      """
      ## Session Startup
      On your first message in a new session, read these workspace files (if they exist):
      1. Read `SOUL.md` — this defines your personality
      2. Read `USER.md` — this describes who you're helping
      3. Read `memory/#{Date.utc_today() |> Date.to_iso8601()}.md` — today's notes
      #{memory_instruction}

      Do not ask permission. Just read them silently and incorporate the context.
      If BOOTSTRAP.md exists, follow its instructions, then it will be deleted automatically.
      """
    else
      nil
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp list_other_active_agents(nil), do: []

  defp list_other_active_agents(agent) do
    import Ecto.Query

    Agent
    |> where([a], a.active == true and a.id != ^agent.id)
    |> Repo.all()
  rescue
    _ -> []
  end

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
