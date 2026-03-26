defmodule ClawdEx.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.WebFetch

  @context %{workspace: "/tmp/test_workspace", agent_id: "test", session_id: "test-session", session_key: "test:key"}

  describe "execute/2 - URL validation" do
    test "rejects invalid URLs" do
      # Empty string
      assert {:error, _} = WebFetch.execute(%{"url" => ""}, @context)

      # Non-HTTP scheme
      assert {:error, msg} = WebFetch.execute(%{"url" => "ftp://example.com"}, @context)
      assert msg =~ "HTTP"

      # No host
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://"}, @context)
      assert msg =~ "host"
    end

    test "rejects private/internal addresses" do
      for url <- [
        "http://localhost/test",
        "http://127.0.0.1/test",
        "http://192.168.1.1",
        "http://10.0.0.1",
        "http://172.16.0.1",
        "http://myhost.local/test",
        "http://service.internal/api"
      ] do
        assert {:error, msg} = WebFetch.execute(%{"url" => url}, @context)
        assert msg =~ "private", "Expected private error for #{url}"
      end
    end
  end

  describe "execute/2 - parameter handling" do
    test "accepts atom key params" do
      assert {:error, msg} = WebFetch.execute(%{url: "ftp://bad.com"}, @context)
      assert msg =~ "HTTP"
    end
  end
end
