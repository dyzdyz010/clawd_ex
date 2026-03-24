defmodule ClawdEx.ACP.RegistryTest do
  use ExUnit.Case, async: true

  alias ClawdEx.ACP.Registry

  # A mock backend module for testing
  defmodule HealthyBackend do
    @behaviour ClawdEx.ACP.Runtime

    @impl true
    def ensure_session(_opts), do: {:ok, %{session_key: "s", backend: "test", runtime_session_name: "t", cwd: nil, pid: nil}}
    @impl true
    def run_turn(_h, _p, _o \\ []), do: {:ok, []}
    @impl true
    def cancel(_h), do: :ok
    @impl true
    def close(_h), do: :ok
    @impl true
    def get_status(_h), do: {:ok, %{}}
    @impl true
    def doctor, do: {:ok, %{healthy: true}}
  end

  defmodule UnhealthyBackend do
    @behaviour ClawdEx.ACP.Runtime

    @impl true
    def ensure_session(_opts), do: {:error, :unavailable}
    @impl true
    def run_turn(_h, _p, _o \\ []), do: {:error, :unavailable}
    @impl true
    def cancel(_h), do: {:error, :unavailable}
    @impl true
    def close(_h), do: {:error, :unavailable}
    @impl true
    def get_status(_h), do: {:error, :unavailable}
    @impl true
    def doctor, do: {:error, :not_installed}
  end

  setup do
    # Start a fresh Registry for each test with a unique name
    name = :"registry_#{System.unique_integer([:positive])}"
    {:ok, pid} = Registry.start_link(name: name)
    %{server: name, pid: pid}
  end

  describe "register_backend/3" do
    test "registers a backend", %{server: server} do
      assert :ok = Registry.register_backend("cli", HealthyBackend, server: server)
    end

    test "overwrites an existing backend", %{server: server} do
      assert :ok = Registry.register_backend("cli", HealthyBackend, server: server)
      assert :ok = Registry.register_backend("cli", UnhealthyBackend, server: server)

      backends = Registry.list_backends(server: server)
      assert backends["cli"].module == UnhealthyBackend
    end
  end

  describe "unregister_backend/2" do
    test "removes a registered backend", %{server: server} do
      Registry.register_backend("cli", HealthyBackend, server: server)
      assert :ok = Registry.unregister_backend("cli", server: server)

      backends = Registry.list_backends(server: server)
      assert backends == %{}
    end

    test "returns error for unknown backend", %{server: server} do
      assert {:error, :not_found} = Registry.unregister_backend("unknown", server: server)
    end
  end

  describe "get_backend/2" do
    test "finds backend by ID", %{server: server} do
      Registry.register_backend("cli", HealthyBackend, server: server)
      assert {:ok, HealthyBackend} = Registry.get_backend("cli", server: server)
    end

    test "resolves agent ID through mapping", %{server: server} do
      Registry.register_backend("cli", HealthyBackend, server: server)
      # "claude" maps to "cli" in @agent_backend_map
      assert {:ok, HealthyBackend} = Registry.get_backend("claude", server: server)
      assert {:ok, HealthyBackend} = Registry.get_backend("codex", server: server)
      assert {:ok, HealthyBackend} = Registry.get_backend("gemini", server: server)
      assert {:ok, HealthyBackend} = Registry.get_backend("pi", server: server)
    end

    test "returns not_found for unknown agent", %{server: server} do
      assert {:error, :not_found} = Registry.get_backend("unknown", server: server)
    end
  end

  describe "list_backends/1" do
    test "returns empty map when none registered", %{server: server} do
      assert Registry.list_backends(server: server) == %{}
    end

    test "returns all registered backends", %{server: server} do
      Registry.register_backend("cli", HealthyBackend, server: server)
      Registry.register_backend("http", UnhealthyBackend, server: server)

      backends = Registry.list_backends(server: server)
      assert map_size(backends) == 2
      assert backends["cli"].module == HealthyBackend
      assert backends["http"].module == UnhealthyBackend
    end
  end

  describe "health_check/1" do
    test "checks health of all backends", %{server: server} do
      Registry.register_backend("cli", HealthyBackend, server: server)
      Registry.register_backend("http", UnhealthyBackend, server: server)

      assert {:ok, results} = Registry.health_check(server: server)
      assert results["cli"] == true
      assert results["http"] == false
    end

    test "updates backend health status after check", %{server: server} do
      Registry.register_backend("bad", UnhealthyBackend, server: server)

      # Before health check, it's assumed healthy
      backends = Registry.list_backends(server: server)
      assert backends["bad"].healthy == true

      # After health check, it's marked unhealthy
      Registry.health_check(server: server)
      backends = Registry.list_backends(server: server)
      assert backends["bad"].healthy == false
    end

    test "unhealthy backend returns error on get_backend", %{server: server} do
      Registry.register_backend("cli", UnhealthyBackend, server: server)
      Registry.health_check(server: server)

      assert {:error, :unhealthy} = Registry.get_backend("cli", server: server)
    end
  end

  describe "agent_backend_map/0" do
    test "returns the default mapping" do
      map = Registry.agent_backend_map()
      assert map["claude"] == "cli"
      assert map["codex"] == "cli"
      assert map["gemini"] == "cli"
      assert map["pi"] == "cli"
    end
  end
end
