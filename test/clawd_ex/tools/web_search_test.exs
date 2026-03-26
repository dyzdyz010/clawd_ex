defmodule ClawdEx.Tools.WebSearchTest do
  use ExUnit.Case, async: true

  alias ClawdEx.Tools.WebSearch

  @context %{workspace: "/tmp/test_workspace", agent_id: "test", session_id: "test-session", session_key: "test:key"}

  describe "execute/2 - API key validation" do
    setup do
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
    test "accepts both string and atom key params" do
      original = System.get_env("BRAVE_API_KEY")
      System.delete_env("BRAVE_API_KEY")
      original_config = Application.get_env(:clawd_ex, :tools)
      Application.put_env(:clawd_ex, :tools, [])

      assert {:error, _} = WebSearch.execute(%{"query" => "test", "count" => 3}, @context)
      assert {:error, msg} = WebSearch.execute(%{query: "test"}, @context)
      assert msg =~ "API key"

      if original, do: System.put_env("BRAVE_API_KEY", original)
      if original_config, do: Application.put_env(:clawd_ex, :tools, original_config)
    end
  end
end
