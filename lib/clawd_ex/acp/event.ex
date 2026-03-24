defmodule ClawdEx.ACP.Event do
  @moduledoc """
  Normalized event struct for ACP agent output.

  All backends parse their agent-specific output into these events,
  giving consumers a uniform stream to work with.

  ## Event Types

  - `:text_delta`  — incremental text chunk from the agent
  - `:status`      — session status change
  - `:tool_call`   — agent invoked a tool
  - `:done`        — turn is complete
  - `:error`       — something went wrong
  """

  @type event_type :: :text_delta | :status | :tool_call | :done | :error

  @type t :: %__MODULE__{
          type: event_type(),
          text: String.t() | nil,
          stream: String.t() | nil,
          tag: String.t() | nil,
          stop_reason: String.t() | nil,
          code: String.t() | nil,
          retryable: boolean() | nil,
          tool_call_id: String.t() | nil,
          tool_status: String.t() | nil,
          tool_title: String.t() | nil
        }

  @enforce_keys [:type]
  defstruct [
    :type,
    :text,
    :stream,
    :tag,
    :stop_reason,
    :code,
    :retryable,
    :tool_call_id,
    :tool_status,
    :tool_title
  ]

  @doc "Create a text delta event."
  @spec text_delta(String.t(), keyword()) :: t()
  def text_delta(text, opts \\ []) do
    %__MODULE__{
      type: :text_delta,
      text: text,
      stream: Keyword.get(opts, :stream, "output"),
      tag: Keyword.get(opts, :tag)
    }
  end

  @doc "Create a status event."
  @spec status(String.t(), keyword()) :: t()
  def status(text, opts \\ []) do
    %__MODULE__{
      type: :status,
      text: text,
      tag: Keyword.get(opts, :tag)
    }
  end

  @doc "Create a tool call event."
  @spec tool_call(String.t(), keyword()) :: t()
  def tool_call(tool_call_id, opts \\ []) do
    %__MODULE__{
      type: :tool_call,
      tool_call_id: tool_call_id,
      tool_status: Keyword.get(opts, :tool_status),
      tool_title: Keyword.get(opts, :tool_title),
      text: Keyword.get(opts, :text)
    }
  end

  @doc "Create a done event."
  @spec done(keyword()) :: t()
  def done(opts \\ []) do
    %__MODULE__{
      type: :done,
      stop_reason: Keyword.get(opts, :stop_reason),
      text: Keyword.get(opts, :text)
    }
  end

  @doc "Create an error event."
  @spec error(String.t(), keyword()) :: t()
  def error(code, opts \\ []) do
    %__MODULE__{
      type: :error,
      code: code,
      text: Keyword.get(opts, :text),
      retryable: Keyword.get(opts, :retryable, false)
    }
  end
end
