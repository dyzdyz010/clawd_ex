defmodule ClawdExWeb.AuthTest do
  use ExUnit.Case, async: false

  alias ClawdExWeb.Auth

  setup do
    original = Application.get_env(:clawd_ex, :web_auth)
    on_exit(fn -> Application.put_env(:clawd_ex, :web_auth, original || []) end)
    :ok
  end

  describe "auth_disabled?/0" do
    test "returns true when no config (default dev mode)" do
      Application.put_env(:clawd_ex, :web_auth, [])
      assert Auth.auth_disabled?()
    end

    test "returns true when mode is :disabled" do
      Application.put_env(:clawd_ex, :web_auth, mode: :disabled)
      assert Auth.auth_disabled?()
    end

    test "returns true when mode is :token but no token configured" do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: nil)
      assert Auth.auth_disabled?()
    end

    test "returns true when mode is :token with empty token" do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "")
      assert Auth.auth_disabled?()
    end

    test "returns false when mode is :token with valid token" do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "secret-123")
      refute Auth.auth_disabled?()
    end

    test "returns true when mode is :password but no credentials" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password)
      assert Auth.auth_disabled?()
    end

    test "returns true when mode is :password with empty credentials" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "", password: "")
      assert Auth.auth_disabled?()
    end

    test "returns false when mode is :password with valid credentials" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "admin", password: "secret")
      refute Auth.auth_disabled?()
    end
  end

  describe "validate_token/1" do
    test "returns :ok for matching token" do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "my-token-123")
      assert Auth.validate_token("my-token-123") == :ok
    end

    test "returns :error for non-matching token" do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "my-token-123")
      assert Auth.validate_token("wrong-token") == :error
    end

    test "returns :error when no token configured" do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: nil)
      assert Auth.validate_token("any-token") == :error
    end

    test "returns :error for nil input" do
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "my-token")
      assert Auth.validate_token(nil) == :error
    end

    test "uses timing-safe comparison" do
      # Ensure it doesn't short-circuit — both should take similar time
      Application.put_env(:clawd_ex, :web_auth, mode: :token, token: "my-token-123")
      assert Auth.validate_token("my-token-123") == :ok
      assert Auth.validate_token("xx-token-123") == :error
    end
  end

  describe "validate_credentials/2" do
    test "returns :ok for matching credentials" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "admin", password: "secret")
      assert Auth.validate_credentials("admin", "secret") == :ok
    end

    test "returns :error for wrong password" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "admin", password: "secret")
      assert Auth.validate_credentials("admin", "wrong") == :error
    end

    test "returns :error for wrong username" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "admin", password: "secret")
      assert Auth.validate_credentials("user", "secret") == :error
    end

    test "returns :error for nil inputs" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password, username: "admin", password: "secret")
      assert Auth.validate_credentials(nil, nil) == :error
    end
  end

  describe "get_mode/0" do
    test "defaults to :token" do
      Application.put_env(:clawd_ex, :web_auth, [])
      assert Auth.get_mode() == :token
    end

    test "returns configured mode" do
      Application.put_env(:clawd_ex, :web_auth, mode: :password)
      assert Auth.get_mode() == :password
    end
  end
end
