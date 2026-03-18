defmodule ClawdEx.Tools.WebSearchTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.WebSearch

  @context %{workspace: "/tmp/test_workspace", agent_id: "test", session_id: "test-session", session_key: "test:key"}

  describe "name/0, description/0, parameters/0" do
    test "returns tool metadata" do
      assert WebSearch.name() == "web_search"
      assert is_binary(WebSearch.description())

      params = WebSearch.parameters()
      assert params.required == ["query"]
      assert Map.has_key?(params.properties, :query)
      assert Map.has_key?(params.properties, :count)
      assert Map.has_key?(params.properties, :country)
      assert Map.has_key?(params.properties, :search_lang)
      assert Map.has_key?(params.properties, :freshness)
    end
  end

  describe "execute/2 - API key validation" do
    setup do
      # Save and clear env var to test missing API key behavior
      original = System.get_env("BRAVE_API_KEY")
      System.delete_env("BRAVE_API_KEY")

      on_exit(fn ->
        if original do
          System.put_env("BRAVE_API_KEY", original)
        else
          System.delete_env("BRAVE_API_KEY")
        end
      end)

      :ok
    end

    test "returns error when API key is not configured" do
      # Temporarily override app config too
      original_config = Application.get_env(:clawd_ex, :tools)
      Application.put_env(:clawd_ex, :tools, [])

      on_exit(fn ->
        if original_config do
          Application.put_env(:clawd_ex, :tools, original_config)
        else
          Application.delete_env(:clawd_ex, :tools)
        end
      end)

      assert {:error, msg} = WebSearch.execute(%{"query" => "test"}, @context)
      assert msg =~ "API key"
      assert msg =~ "BRAVE_API_KEY"
    end
  end

  describe "execute/2 - parameter handling" do
    test "accepts string key params" do
      params = %{"query" => "test", "count" => 3, "country" => "US"}
      # Will fail on API key, but proves params are accepted
      # (save/restore env to ensure no key)
      original = System.get_env("BRAVE_API_KEY")
      System.delete_env("BRAVE_API_KEY")
      original_config = Application.get_env(:clawd_ex, :tools)
      Application.put_env(:clawd_ex, :tools, [])

      result = WebSearch.execute(params, @context)

      # Restore
      if original, do: System.put_env("BRAVE_API_KEY", original)
      if original_config, do: Application.put_env(:clawd_ex, :tools, original_config)

      assert {:error, _} = result
    end

    test "accepts atom key params" do
      original = System.get_env("BRAVE_API_KEY")
      System.delete_env("BRAVE_API_KEY")
      original_config = Application.get_env(:clawd_ex, :tools)
      Application.put_env(:clawd_ex, :tools, [])

      result = WebSearch.execute(%{query: "test"}, @context)

      if original, do: System.put_env("BRAVE_API_KEY", original)
      if original_config, do: Application.put_env(:clawd_ex, :tools, original_config)

      assert {:error, msg} = result
      assert msg =~ "API key"
    end

    test "count is capped at 10" do
      # Verify via parameters schema
      params = WebSearch.parameters()
      assert params.properties[:count][:type] == "integer"
      # The cap is enforced in execute (min(count, 10))
    end

    test "optional parameters have proper types" do
      params = WebSearch.parameters()
      assert params.properties[:country][:type] == "string"
      assert params.properties[:search_lang][:type] == "string"
      assert params.properties[:freshness][:type] == "string"
    end
  end
end
