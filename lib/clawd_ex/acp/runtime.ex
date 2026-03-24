defmodule ClawdEx.ACP.Runtime do
  @moduledoc """
  Behaviour for ACP runtime backends.

  Each backend (CLI, HTTP, etc.) implements this behaviour to drive
  external AI coding agents (Claude Code, Codex, Gemini CLI) as sub-agents.
  """

  @type handle :: %{
          session_key: String.t(),
          backend: String.t(),
          runtime_session_name: String.t(),
          cwd: String.t() | nil,
          pid: pid() | nil
        }

  @doc "Ensure a session exists (create or resume). Returns a handle for subsequent calls."
  @callback ensure_session(map()) :: {:ok, handle()} | {:error, term()}

  @doc "Run a turn in the session. Returns a stream of ACP.Event structs."
  @callback run_turn(handle(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}

  @doc "Cancel an in-progress turn."
  @callback cancel(handle()) :: :ok | {:error, term()}

  @doc "Close and clean up a session."
  @callback close(handle()) :: :ok | {:error, term()}

  @doc "Get the current status of a session."
  @callback get_status(handle()) :: {:ok, map()} | {:error, term()}

  @doc "Run a health/diagnostic check on the backend itself."
  @callback doctor() :: {:ok, map()} | {:error, term()}
end
