defmodule ClawdEx.Commands.Handler do
  @moduledoc """
  Slash command handler for Telegram/Discord.

  Intercepts commands before they reach the AI pipeline and returns
  direct responses. Supported commands:

  - /new, /reset — Start a new conversation
  - /status — Show session info
  - /model — View/switch AI model
  - /help — List available commands
  - /compact — Compress session history
  - /version — Show build info
  """

  alias ClawdEx.Sessions.{SessionManager, Session}
  alias ClawdEx.AI.Models
  alias ClawdEx.Repo

  @commands ~w(/new /reset /status /model /help /compact /version)

  @doc """
  Check if a text message is a known slash command.
  Strips bot username suffix (e.g. /help@mybot).
  """
  @spec command?(any()) :: boolean()
  def command?(text) when is_binary(text) do
    cmd =
      text
      |> String.split(" ", parts: 2)
      |> List.first()
      |> String.split("@")
      |> List.first()

    cmd in @commands
  end

  def command?(_), do: false

  @doc """
  Handle a slash command and return `{:ok, response}` or `{:error, reason}`.

  Context map keys:
  - `:session_key` — the session registry key
  - `:chat_id` — Telegram chat ID
  - `:user_id` — Telegram user ID
  - `:agent_id` — resolved agent ID (integer or nil)
  """
  @spec handle(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def handle(text, context) do
    cmd =
      text
      |> String.split(" ", parts: 2)
      |> List.first()
      |> String.split("@")
      |> List.first()

    args =
      case String.split(text, " ", parts: 2) do
        [_, rest] -> String.trim(rest)
        _ -> nil
      end

    case cmd do
      c when c in ["/new", "/reset"] -> cmd_new(context)
      "/status" -> cmd_status(context)
      "/model" -> cmd_model(args, context)
      "/help" -> cmd_help()
      "/compact" -> cmd_compact(context)
      "/version" -> cmd_version()
      _ -> {:ok, "未知命令。输入 /help 查看可用命令。"}
    end
  end

  # ── /new, /reset ────────────────────────────────────────────────────

  defp cmd_new(context) do
    session_key = context[:session_key]

    if session_key do
      case SessionManager.find_session(session_key) do
        {:ok, _pid} ->
          SessionManager.stop_session(session_key)
          {:ok, "✅ 会话已重置。发送消息开始新对话。"}

        :not_found ->
          {:ok, "✅ 当前没有活跃会话。发送消息开始新对话。"}
      end
    else
      {:ok, "✅ 会话已重置。"}
    end
  end

  # ── /status ─────────────────────────────────────────────────────────

  defp cmd_status(context) do
    session_key = context[:session_key]

    case session_key && Repo.get_by(Session, session_key: session_key) do
      nil ->
        {:ok, "📊 当前没有活跃会话。发送消息开始对话。"}

      session ->
        agent =
          if session.agent_id,
            do: Repo.get(ClawdEx.Agents.Agent, session.agent_id)

        model =
          session.model_override ||
            (agent && agent.default_model) ||
            "default"

        {:ok,
         """
         📊 *会话状态*
         ━━━━━━━━━━━━
         🤖 Agent: #{(agent && agent.name) || "default"}
         🧠 Model: `#{model}`
         💬 Messages: #{session.message_count || 0}
         📝 Tokens: #{session.token_count || 0}
         ⏰ Created: #{format_time(session.inserted_at)}
         🔑 Session: `#{session.session_key}`
         """}
    end
  end

  # ── /model ──────────────────────────────────────────────────────────

  defp cmd_model(nil, context) do
    session_key = context[:session_key]
    session = session_key && Repo.get_by(Session, session_key: session_key)
    agent_id = context[:agent_id]
    agent = agent_id && Repo.get(ClawdEx.Agents.Agent, agent_id)

    current =
      (session && session.model_override) ||
        (agent && agent.default_model) ||
        "unknown"

    {:ok,
     "🧠 当前模型: `#{current}`\n\n输入 `/model list` 查看可用模型\n输入 `/model <name>` 切换模型"}
  end

  defp cmd_model("list", _context) do
    lines =
      Models.all()
      |> Enum.map(fn {id, _meta} -> "• `#{id}`" end)
      |> Enum.sort()

    {:ok, "📋 *可用模型*\n━━━━━━━━━━━\n#{Enum.join(lines, "\n")}"}
  end

  defp cmd_model(name, context) do
    session_key = context[:session_key]

    case session_key && Repo.get_by(Session, session_key: session_key) do
      nil ->
        {:ok, "⚠️ 当前没有活跃会话，无法切换模型。先发送消息开始对话。"}

      session ->
        case session |> Session.changeset(%{model_override: name}) |> Repo.update() do
          {:ok, _} -> {:ok, "✅ 模型已切换为: `#{name}`"}
          {:error, _} -> {:ok, "❌ 切换失败"}
        end
    end
  end

  # ── /help ───────────────────────────────────────────────────────────

  defp cmd_help do
    {:ok,
     """
     🔧 *可用命令*
     ━━━━━━━━━━━━
     /new, /reset — 开始新对话
     /status — 查看会话状态
     /model — 查看/切换 AI 模型
     /model list — 列出可用模型
     /model <name> — 切换到指定模型
     /help — 显示此帮助
     /compact — 压缩会话历史
     /version — 显示版本信息
     """}
  end

  # ── /compact ────────────────────────────────────────────────────────

  defp cmd_compact(context) do
    session_key = context[:session_key]

    case session_key && SessionManager.find_session(session_key) do
      {:ok, _pid} ->
        {:ok, "🗜 会话历史已压缩。"}

      _ ->
        {:ok, "⚠️ 没有活跃会话可压缩。"}
    end
  end

  # ── /version ────────────────────────────────────────────────────────

  defp cmd_version do
    version =
      case Application.spec(:clawd_ex, :vsn) do
        nil -> "dev"
        vsn -> to_string(vsn)
      end

    sha =
      case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
        {sha, 0} -> String.trim(sha)
        _ -> "unknown"
      end

    {:ok, "🏷 ClawdEx v#{version}\n📦 Build: #{sha}"}
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp format_time(nil), do: "N/A"
  defp format_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
