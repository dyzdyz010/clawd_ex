defmodule ClawdExWeb.Api.ToolControllerTest do
  use ClawdExWeb.ConnCase

  describe "GET /api/v1/tools" do
    test "returns list of available tools", %{conn: conn} do
      conn = get(conn, "/api/v1/tools")
      body = json_response(conn, 200)
      assert is_list(body["data"])
      assert body["total"] > 0

      # Each tool should have name, description, parameters
      first = hd(body["data"])
      assert first["name"]
      assert first["description"]
      assert is_map(first["parameters"])
    end
  end

  describe "POST /api/v1/tools/:name/execute" do
    test "returns 404 for non-existent tool", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/tools/nonexistent_tool_xyz/execute", %{params: %{}})

      assert json_response(conn, 404)["error"]["code"] == "tool_not_found"
    end
  end
end
