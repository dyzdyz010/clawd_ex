defmodule ClawdExWeb.Api.AgentControllerTest do
  use ClawdExWeb.ConnCase

  alias ClawdEx.Repo
  alias ClawdEx.Agents.Agent

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "content-type", "application/json")}
  end

  describe "GET /api/v1/agents" do
    test "returns empty list when no agents", %{conn: conn} do
      conn = get(conn, "/api/v1/agents")
      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert is_integer(body["total"])
    end

    test "returns agents list", %{conn: conn} do
      {:ok, _agent} = %Agent{} |> Agent.changeset(%{name: "test-agent"}) |> Repo.insert()

      conn = get(conn, "/api/v1/agents")
      body = json_response(conn, 200)
      assert length(body["data"]) >= 1
      assert Enum.any?(body["data"], fn a -> a["name"] == "test-agent" end)
    end

    test "filters by active status", %{conn: conn} do
      {:ok, _active} = %Agent{} |> Agent.changeset(%{name: "active-agent", active: true}) |> Repo.insert()
      {:ok, _inactive} = %Agent{} |> Agent.changeset(%{name: "inactive-agent", active: false}) |> Repo.insert()

      conn_active = get(conn, "/api/v1/agents?active=true")
      active_body = json_response(conn_active, 200)
      assert Enum.all?(active_body["data"], fn a -> a["active"] == true end)

      conn_inactive = get(conn, "/api/v1/agents?active=false")
      inactive_body = json_response(conn_inactive, 200)
      assert Enum.all?(inactive_body["data"], fn a -> a["active"] == false end)
    end
  end

  describe "GET /api/v1/agents/:id" do
    test "returns agent details", %{conn: conn} do
      {:ok, agent} = %Agent{} |> Agent.changeset(%{name: "detail-agent"}) |> Repo.insert()

      conn = get(conn, "/api/v1/agents/#{agent.id}")
      body = json_response(conn, 200)
      assert body["data"]["name"] == "detail-agent"
      assert body["data"]["id"] == agent.id
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, "/api/v1/agents/999999")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "POST /api/v1/agents" do
    test "creates a new agent", %{conn: conn} do
      conn = post(conn, "/api/v1/agents", %{agent: %{name: "new-api-agent"}})
      body = json_response(conn, 201)
      assert body["data"]["name"] == "new-api-agent"
      assert body["data"]["id"]
    end

    test "creates agent with flat params", %{conn: conn} do
      conn = post(conn, "/api/v1/agents", %{name: "flat-agent"})
      body = json_response(conn, 201)
      assert body["data"]["name"] == "flat-agent"
    end

    test "returns validation error for missing name", %{conn: conn} do
      conn = post(conn, "/api/v1/agents", %{agent: %{}})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "validation_error"
    end
  end

  describe "PUT /api/v1/agents/:id" do
    test "updates an existing agent", %{conn: conn} do
      {:ok, agent} = %Agent{} |> Agent.changeset(%{name: "before-update"}) |> Repo.insert()

      conn = put(conn, "/api/v1/agents/#{agent.id}", %{agent: %{name: "after-update"}})
      body = json_response(conn, 200)
      assert body["data"]["name"] == "after-update"
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = put(conn, "/api/v1/agents/999999", %{agent: %{name: "nope"}})
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end
end
