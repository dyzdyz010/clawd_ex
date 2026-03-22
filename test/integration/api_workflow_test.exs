defmodule ClawdEx.Integration.ApiWorkflowTest do
  @moduledoc """
  Integration test for API workflows.

  Verifies:
    Create agent → Create session → Send message → View session details →
    List tools → Execute tool →
    Health check
  """
  use ClawdExWeb.ConnCase, async: false

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent
  alias ClawdEx.Sessions.{Session, SessionManager}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_name(prefix \\ "api_test"),
    do: "#{prefix}_#{:erlang.unique_integer([:positive])}"

  defp create_agent_via_db(attrs \\ %{}) do
    default = %{
      name: unique_name("agent"),
      active: true,
      workspace_path: System.tmp_dir!()
    }

    %Agent{}
    |> Agent.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  defp cleanup_session(key) do
    try do
      SessionManager.stop_session(key)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Health check
  # ---------------------------------------------------------------------------

  describe "GET /api/health" do
    test "returns health status", %{conn: conn} do
      conn = get(conn, "/api/health")
      body = json_response(conn, 200)

      assert body["status"] in ["ok", "degraded"]
      assert body["checks"] != nil
      assert body["timestamp"] != nil

      # Database check should be present
      assert Map.has_key?(body["checks"], "database")
    end

    test "health check includes database status", %{conn: conn} do
      conn = get(conn, "/api/health")
      body = json_response(conn, 200)

      db_check = body["checks"]["database"]
      assert db_check != nil
      assert db_check["status"] == "ok"
    end
  end

  # ---------------------------------------------------------------------------
  # Agent CRUD API
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/agents" do
    test "lists all agents", %{conn: conn} do
      _agent = create_agent_via_db()

      conn = get(conn, "/api/v1/agents")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["total"] >= 1

      # Each agent has required fields
      first = hd(body["data"])
      assert first["id"] != nil
      assert first["name"] != nil
      assert Map.has_key?(first, "active")
    end

    test "filters active agents", %{conn: conn} do
      _active = create_agent_via_db(%{active: true, name: unique_name("active")})
      inactive = create_agent_via_db(%{active: false, name: unique_name("inactive")})

      conn = get(conn, "/api/v1/agents?active=true")
      body = json_response(conn, 200)

      ids = Enum.map(body["data"], & &1["id"])
      refute inactive.id in ids
    end
  end

  describe "GET /api/v1/agents/:id" do
    test "returns agent details", %{conn: conn} do
      agent = create_agent_via_db()

      conn = get(conn, "/api/v1/agents/#{agent.id}")
      body = json_response(conn, 200)

      data = body["data"]
      assert data["id"] == agent.id
      assert data["name"] == agent.name
      assert data["workspace_path"] == agent.workspace_path
      assert Map.has_key?(data, "allowed_tools")
      assert Map.has_key?(data, "denied_tools")
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/999999")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/agents" do
    test "creates a new agent", %{conn: conn} do
      name = unique_name("create")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/agents", %{
          agent: %{
            name: name,
            workspace_path: System.tmp_dir!()
          }
        })

      body = json_response(conn, 201)
      assert body["data"]["name"] == name
      assert body["data"]["id"] != nil

      # Verify in DB
      agent = Repo.get(Agent, body["data"]["id"])
      assert agent != nil
      assert agent.name == name
    end

    test "creates agent with flat params (no agent wrapper)", %{conn: conn} do
      name = unique_name("flat")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/agents", %{name: name})

      body = json_response(conn, 201)
      assert body["data"]["name"] == name
    end

    test "returns validation error for missing name", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/agents", %{agent: %{workspace_path: "/tmp"}})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "validation_error"
    end
  end

  describe "PUT /api/v1/agents/:id" do
    test "updates an existing agent", %{conn: conn} do
      agent = create_agent_via_db()
      new_name = unique_name("updated")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/agents/#{agent.id}", %{agent: %{name: new_name}})

      body = json_response(conn, 200)
      assert body["data"]["name"] == new_name
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/agents/999999", %{agent: %{name: "whatever"}})

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # Session API
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/sessions" do
    test "lists active sessions", %{conn: conn} do
      conn = get(conn, "/api/v1/sessions")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert is_integer(body["total"])
    end
  end

  describe "GET /api/v1/sessions/:key" do
    test "returns session details for active session", %{conn: conn} do
      key = "api_test_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = SessionManager.start_session(session_key: key)
      on_exit(fn -> cleanup_session(key) end)

      conn = get(conn, "/api/v1/sessions/#{URI.encode(key)}")
      body = json_response(conn, 200)

      assert body["data"]["session_key"] == key
    end

    test "returns 404 for non-existent session", %{conn: conn} do
      conn = get(conn, "/api/v1/sessions/#{URI.encode("nonexistent_session_xyz")}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/sessions/:key/messages" do
    test "accepts a message for an active session", %{conn: conn} do
      key = "api_msg_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = SessionManager.start_session(session_key: key)
      on_exit(fn -> cleanup_session(key) end)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sessions/#{URI.encode(key)}/messages", %{content: "Hello API"})

      body = json_response(conn, 202)
      assert body["status"] == "accepted"
    end

    test "returns 404 for non-existent session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/sessions/#{URI.encode("nonexistent_xyz")}/messages", %{
          content: "hello"
        })

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "DELETE /api/v1/sessions/:key" do
    test "deletes an active session", %{conn: conn} do
      key = "api_del_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = SessionManager.start_session(session_key: key)

      conn = delete(conn, "/api/v1/sessions/#{URI.encode(key)}")
      body = json_response(conn, 200)
      assert body["status"] == "deleted"

      # Verify session is stopped
      assert SessionManager.find_session(key) == :not_found
    end

    test "returns 404 for non-existent session", %{conn: conn} do
      conn = delete(conn, "/api/v1/sessions/#{URI.encode("nonexistent_del_xyz")}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # Tools API
  # ---------------------------------------------------------------------------

  describe "GET /api/v1/tools" do
    test "returns list of available tools", %{conn: conn} do
      conn = get(conn, "/api/v1/tools")
      body = json_response(conn, 200)

      assert is_list(body["data"])
      assert body["total"] > 0

      # Verify tool structure
      tool = hd(body["data"])
      assert is_binary(tool["name"])
      assert is_binary(tool["description"])
      assert is_map(tool["parameters"])
    end

    test "includes core tools", %{conn: conn} do
      conn = get(conn, "/api/v1/tools")
      body = json_response(conn, 200)

      names = Enum.map(body["data"], & &1["name"])
      assert "read" in names
      assert "write" in names
      assert "exec" in names
    end
  end

  describe "POST /api/v1/tools/:name/execute" do
    test "executes the read tool on a real file", %{conn: conn} do
      # Create a temp file
      path = Path.join(System.tmp_dir!(), "api_test_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "api test content")
      on_exit(fn -> File.rm(path) end)

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/tools/read/execute", %{params: %{path: path}})

      body = json_response(conn, 200)
      assert body["tool"] == "read"
      assert body["status"] == "ok"
      assert String.contains?(to_string(body["result"]), "api test content")
    end

    test "returns 404 for non-existent tool", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/tools/nonexistent_tool_xyz/execute", %{params: %{}})

      assert json_response(conn, 404)["error"]["code"] == "tool_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # Full workflow: Create agent → session → tools → health
  # ---------------------------------------------------------------------------

  describe "full API workflow" do
    test "create agent → start session → list tools → health check", %{conn: conn} do
      # 1. Create agent via API
      agent_name = unique_name("workflow")

      conn1 =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/agents", %{agent: %{name: agent_name}})

      body1 = json_response(conn1, 201)
      agent_id = body1["data"]["id"]
      assert agent_id != nil

      # 2. Verify agent in list
      conn2 = get(conn, "/api/v1/agents")
      body2 = json_response(conn2, 200)
      agent_ids = Enum.map(body2["data"], & &1["id"])
      assert agent_id in agent_ids

      # 3. Get agent details
      conn3 = get(conn, "/api/v1/agents/#{agent_id}")
      body3 = json_response(conn3, 200)
      assert body3["data"]["name"] == agent_name

      # 4. Start a session (via SessionManager, since API doesn't have create endpoint)
      key = "workflow_#{:erlang.unique_integer([:positive])}"
      {:ok, _pid} = SessionManager.start_session(session_key: key, agent_id: agent_id)
      on_exit(fn -> cleanup_session(key) end)

      # 5. Verify session appears in sessions list
      conn4 = get(conn, "/api/v1/sessions")
      body4 = json_response(conn4, 200)
      session_keys = Enum.map(body4["data"], & &1["session_key"])
      assert key in session_keys

      # 6. Get session details
      conn5 = get(conn, "/api/v1/sessions/#{URI.encode(key)}")
      body5 = json_response(conn5, 200)
      assert body5["data"]["session_key"] == key

      # 7. List tools
      conn6 = get(conn, "/api/v1/tools")
      body6 = json_response(conn6, 200)
      assert body6["total"] > 10

      # 8. Execute a tool
      path = Path.join(System.tmp_dir!(), "workflow_test_#{:erlang.unique_integer([:positive])}.txt")
      File.write!(path, "workflow test")
      on_exit(fn -> File.rm(path) end)

      conn7 =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/tools/read/execute", %{params: %{path: path}})

      body7 = json_response(conn7, 200)
      assert body7["status"] == "ok"

      # 9. Health check
      conn8 = get(conn, "/api/health")
      body8 = json_response(conn8, 200)
      assert body8["status"] in ["ok", "degraded"]
    end
  end

  # ---------------------------------------------------------------------------
  # Edge cases
  # ---------------------------------------------------------------------------

  describe "API edge cases" do
    test "duplicate agent names return validation error", %{conn: conn} do
      name = unique_name("dup")
      create_agent_via_db(%{name: name})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/agents", %{agent: %{name: name}})

      body = json_response(conn, 422)
      assert body["error"]["code"] == "validation_error"
    end

    test "update agent with flat params works", %{conn: conn} do
      agent = create_agent_via_db()
      new_name = unique_name("flat_update")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/agents/#{agent.id}", %{name: new_name})

      body = json_response(conn, 200)
      assert body["data"]["name"] == new_name
    end
  end
end
