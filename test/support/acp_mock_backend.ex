defmodule ClawdEx.ACP.MockBackend do
  @moduledoc """
  Mock ACP backend for testing. Implements ClawdEx.ACP.Runtime behaviour.
  """
  @behaviour ClawdEx.ACP.Runtime

  alias ClawdEx.ACP.Event

  @impl true
  def ensure_session(opts) do
    {:ok, %{
      session_key: opts.session_key,
      backend: "mock",
      runtime_session_name: "mock-#{opts.session_key}",
      cwd: opts[:cwd],
      pid: self()
    }}
  end

  @impl true
  def run_turn(_handle, text, _opts \\ []) do
    events = [
      Event.text_delta("Mock response to: #{text}"),
      Event.done(stop_reason: "end_turn", text: "Mock response to: #{text}")
    ]

    {:ok, events}
  end

  @impl true
  def cancel(_handle), do: :ok

  @impl true
  def close(_handle), do: :ok

  @impl true
  def get_status(handle) do
    {:ok, %{session_key: handle.session_key, status: :idle}}
  end

  @impl true
  def doctor do
    {:ok, %{status: "healthy", backend: "mock"}}
  end
end

defmodule ClawdEx.ACP.SlowMockBackend do
  @moduledoc "Slow mock backend for timeout testing."
  @behaviour ClawdEx.ACP.Runtime

  alias ClawdEx.ACP.Event

  @impl true
  def ensure_session(opts) do
    {:ok, %{
      session_key: opts.session_key,
      backend: "slow_mock",
      runtime_session_name: "slow-#{opts.session_key}",
      cwd: nil,
      pid: self()
    }}
  end

  @impl true
  def run_turn(_handle, _text, _opts \\ []) do
    Process.sleep(5_000)
    {:ok, [Event.done()]}
  end

  @impl true
  def cancel(_handle), do: :ok
  @impl true
  def close(_handle), do: :ok
  @impl true
  def get_status(handle), do: {:ok, %{session_key: handle.session_key, status: :idle}}
  @impl true
  def doctor, do: {:ok, %{status: "healthy"}}
end

defmodule ClawdEx.ACP.FailingMockBackend do
  @moduledoc "Failing mock backend for error testing."
  @behaviour ClawdEx.ACP.Runtime

  @impl true
  def ensure_session(_opts), do: {:error, :connection_refused}
  @impl true
  def run_turn(_handle, _text, _opts \\ []), do: {:error, :not_connected}
  @impl true
  def cancel(_handle), do: :ok
  @impl true
  def close(_handle), do: :ok
  @impl true
  def get_status(_handle), do: {:error, :not_connected}
  @impl true
  def doctor, do: {:error, "backend unavailable"}
end
