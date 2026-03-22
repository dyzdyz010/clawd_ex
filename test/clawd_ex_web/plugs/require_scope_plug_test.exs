defmodule ClawdExWeb.Plugs.RequireScopePlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ClawdExWeb.Plugs.RequireScopePlug

  defp build_conn_with(method, scope) do
    conn(method, "/")
    |> assign(:auth_scope, scope)
  end

  describe "admin scope" do
    test "admin can access admin endpoints" do
      conn =
        build_conn_with(:get, :admin)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :admin))

      refute conn.halted
    end

    test "admin can POST to admin endpoints" do
      conn =
        build_conn_with(:post, :admin)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :admin))

      refute conn.halted
    end

    test "admin can access write endpoints" do
      conn =
        build_conn_with(:post, :admin)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :write))

      refute conn.halted
    end

    test "admin can access read endpoints" do
      conn =
        build_conn_with(:get, :admin)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :read))

      refute conn.halted
    end
  end

  describe "write scope" do
    test "write can POST to write endpoints" do
      conn =
        build_conn_with(:post, :write)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :write))

      refute conn.halted
    end

    test "write can GET from write endpoints" do
      conn =
        build_conn_with(:get, :write)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :write))

      refute conn.halted
    end

    test "write can DELETE from write endpoints" do
      conn =
        build_conn_with(:delete, :write)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :write))

      refute conn.halted
    end

    test "write cannot access admin endpoints" do
      conn =
        build_conn_with(:get, :write)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :admin))

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "read scope" do
    test "read can GET from read endpoints" do
      conn =
        build_conn_with(:get, :read)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :read))

      refute conn.halted
    end

    test "read cannot POST to write endpoints" do
      conn =
        build_conn_with(:post, :read)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :write))

      assert conn.halted
      assert conn.status == 403
    end

    test "read cannot access admin endpoints" do
      conn =
        build_conn_with(:get, :read)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :admin))

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "error response" do
    test "returns JSON error with scope info" do
      conn =
        build_conn_with(:post, :read)
        |> RequireScopePlug.call(RequireScopePlug.init(scope: :admin))

      assert conn.halted
      body = Jason.decode!(conn.resp_body)
      assert body["error"]["code"] == "forbidden"
      assert body["error"]["message"] =~ "Insufficient scope"
    end
  end
end
