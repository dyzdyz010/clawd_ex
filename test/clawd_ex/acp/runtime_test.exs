defmodule ClawdEx.ACP.RuntimeTest do
  use ExUnit.Case, async: true

  alias ClawdEx.ACP.Runtime

  # A mock module that implements the Runtime behaviour
  defmodule MockBackend do
    @behaviour Runtime

    @impl true
    def ensure_session(opts) do
      {:ok,
       %{
         session_key: opts[:session_key] || "test-session",
         backend: "mock",
         runtime_session_name: "mock-session-1",
         cwd: opts[:cwd],
         pid: self()
       }}
    end

    @impl true
    def run_turn(_handle, _prompt, _opts \\ []) do
      {:ok, []}
    end

    @impl true
    def cancel(_handle), do: :ok

    @impl true
    def close(_handle), do: :ok

    @impl true
    def get_status(_handle) do
      {:ok, %{status: "idle"}}
    end

    @impl true
    def doctor do
      {:ok, %{healthy: true, version: "1.0.0"}}
    end
  end

  describe "behaviour compliance" do
    test "MockBackend implements all callbacks" do
      assert {:ok, handle} = MockBackend.ensure_session(%{session_key: "s1", cwd: "/tmp"})
      assert handle.session_key == "s1"
      assert handle.backend == "mock"
      assert handle.cwd == "/tmp"
      assert is_pid(handle.pid)

      assert {:ok, stream} = MockBackend.run_turn(handle, "hello")
      assert is_list(stream)

      assert :ok = MockBackend.cancel(handle)
      assert :ok = MockBackend.close(handle)

      assert {:ok, status} = MockBackend.get_status(handle)
      assert status.status == "idle"

      assert {:ok, doc} = MockBackend.doctor()
      assert doc.healthy == true
    end

    test "handle has the correct shape" do
      {:ok, handle} = MockBackend.ensure_session(%{})
      assert Map.has_key?(handle, :session_key)
      assert Map.has_key?(handle, :backend)
      assert Map.has_key?(handle, :runtime_session_name)
      assert Map.has_key?(handle, :cwd)
      assert Map.has_key?(handle, :pid)
    end
  end
end
