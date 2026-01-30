defmodule ClawdEx.Agent.Prompt do
  @moduledoc """
  系统提示构建器

  负责:
  - 构建基础系统提示
  - 注入工具描述
  - 注入 Bootstrap 文件 (AGENTS.md, SOUL.md, etc.)
  - 注入记忆上下文
  """

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  @base_prompt """
  You are a helpful AI assistant powered by ClawdEx.

  ## Capabilities
  You have access to various tools that allow you to:
  - Read, write, and edit files
  - Execute shell commands
  - Search the web
  - Manage memory and sessions
  - Send messages across channels

  ## Guidelines
  - Be concise and helpful
  - Use tools when needed to accomplish tasks
  - Ask for clarification when requests are ambiguous
  - Respect user privacy and security
  """

  @doc """
  构建完整的系统提示
  """
  @spec build(integer() | nil, map()) :: String.t()
  def build(agent_id, config \\ %{}) do
    agent = if agent_id, do: Repo.get(Agent, agent_id), else: nil

    sections = [
      base_section(agent),
      identity_section(agent),
      workspace_section(agent, config),
      bootstrap_section(agent, config),
      tools_section(config),
      runtime_section(config)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # ============================================================================
  # Prompt Sections
  # ============================================================================

  defp base_section(nil), do: @base_prompt
  defp base_section(%{system_prompt: nil}), do: @base_prompt
  defp base_section(%{system_prompt: ""}), do: @base_prompt
  defp base_section(%{system_prompt: prompt}), do: prompt

  defp identity_section(nil), do: nil
  defp identity_section(%{config: nil}), do: nil
  defp identity_section(%{config: config}) when is_map(config) do
    identity = config["identity"] || config[:identity]
    if identity && is_map(identity) do
      name = identity["name"] || identity[:name]
      emoji = identity["emoji"] || identity[:emoji]
      theme = identity["theme"] || identity[:theme]

      if name do
        parts = ["## Identity", "- **Name:** #{name}"]
        parts = if emoji, do: parts ++ ["- **Emoji:** #{emoji}"], else: parts
        parts = if theme, do: parts ++ ["- **Theme:** #{theme}"], else: parts
        Enum.join(parts, "\n")
      else
        nil
      end
    else
      nil
    end
  end
  defp identity_section(_), do: nil

  defp workspace_section(agent, config) do
    workspace = cond do
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
    workspace = cond do
      agent && agent.workspace_path -> agent.workspace_path
      config[:workspace] -> config[:workspace]
      true -> nil
    end

    if workspace do
      expanded = Path.expand(workspace)

      files = [
        {"AGENTS.md", "Agent configuration and guidelines"},
        {"SOUL.md", "Personality and tone"},
        {"TOOLS.md", "Tool-specific notes"},
        {"IDENTITY.md", "Identity information"},
        {"USER.md", "Information about the user"},
        {"MEMORY.md", "Long-term memory"}
      ]

      loaded_files = files
      |> Enum.map(fn {filename, _desc} ->
        path = Path.join(expanded, filename)
        if File.exists?(path) do
          case File.read(path) do
            {:ok, content} ->
              truncated = truncate_content(content, 10_000)
              "## #{filename}\n#{truncated}"
            _ -> nil
          end
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

      if loaded_files != [] do
        ["# Project Context", "The following project context files have been loaded:" | loaded_files]
        |> Enum.join("\n\n")
      else
        nil
      end
    else
      nil
    end
  end

  defp tools_section(config) do
    tools = Map.get(config, :tools, [])

    if tools != [] do
      tool_list = tools
      |> Enum.map(fn tool ->
        "- **#{tool.name}**: #{tool.description}"
      end)
      |> Enum.join("\n")

      """
      ## Available Tools
      You have access to the following tools:

      #{tool_list}

      Use tools by calling them with the appropriate parameters.
      """
    else
      nil
    end
  end

  defp runtime_section(config) do
    model = config[:model] || "unknown"
    timezone = config[:timezone] || "UTC"

    # 使用 UTC 时间，避免时区数据库问题
    now = DateTime.utc_now()
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    """
    ## Runtime
    - **Model:** #{model}
    - **Current Time:** #{now}
    - **Timezone:** #{timezone}
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
