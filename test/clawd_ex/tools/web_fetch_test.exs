defmodule ClawdEx.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.WebFetch

  @context %{workspace: "/tmp/test_workspace", agent_id: "test", session_id: "test-session", session_key: "test:key"}

  describe "name/0, description/0, parameters/0" do
    test "returns tool metadata" do
      assert WebFetch.name() == "web_fetch"
      assert is_binary(WebFetch.description())

      params = WebFetch.parameters()
      assert params.required == ["url"]
      assert Map.has_key?(params.properties, :url)
      assert Map.has_key?(params.properties, :extractMode)
      assert Map.has_key?(params.properties, :maxChars)
    end
  end

  describe "execute/2 - URL validation" do
    test "rejects missing/nil url with exception" do
      # URI.parse/1 raises FunctionClauseError on nil input — this is an unhandled edge case
      assert_raise FunctionClauseError, fn ->
        WebFetch.execute(%{"url" => nil}, @context)
      end
    end

    test "rejects empty string url" do
      assert {:error, msg} = WebFetch.execute(%{"url" => ""}, @context)
      # Empty string has no scheme, so fails on scheme check
      assert msg =~ "HTTP" or msg =~ "host"
    end

    test "rejects non-HTTP scheme" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "ftp://example.com"}, @context)
      assert msg =~ "HTTP"
    end

    test "rejects URL without host" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://"}, @context)
      assert msg =~ "host"
    end

    test "rejects localhost" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://localhost/test"}, @context)
      assert msg =~ "private"
    end

    test "rejects 127.0.0.1" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://127.0.0.1/test"}, @context)
      assert msg =~ "private"
    end

    test "rejects private IP ranges (192.168.x.x)" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://192.168.1.1"}, @context)
      assert msg =~ "private"
    end

    test "rejects private IP ranges (10.x.x.x)" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://10.0.0.1"}, @context)
      assert msg =~ "private"
    end

    test "rejects private IP ranges (172.16.x.x)" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://172.16.0.1"}, @context)
      assert msg =~ "private"
    end

    test "rejects .local domains" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://myhost.local/test"}, @context)
      assert msg =~ "private"
    end

    test "rejects .internal domains" do
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://service.internal/api"}, @context)
      assert msg =~ "private"
    end

    test "rejects ::1 (IPv6 loopback) as missing host" do
      # URI.parse treats "::1" in this URL form as missing host
      assert {:error, msg} = WebFetch.execute(%{"url" => "http://::1/test"}, @context)
      assert msg =~ "host" or msg =~ "private"
    end
  end

  describe "execute/2 - parameter handling" do
    test "accepts atom key params" do
      # This will fail at the HTTP request stage (not validation), proving params were parsed
      assert {:error, msg} = WebFetch.execute(%{url: "ftp://bad.com"}, @context)
      assert msg =~ "HTTP"
    end

    test "extractMode parameter is accepted" do
      params = WebFetch.parameters()
      assert params.properties[:extractMode][:enum] == ["markdown", "text"]
    end
  end
end
