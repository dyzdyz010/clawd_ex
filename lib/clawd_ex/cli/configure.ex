defmodule ClawdEx.CLI.Configure do
  @moduledoc """
  CLI configure command - interactive configuration wizard.
  """

  @env_file ".env"

  def run(_opts \\ []) do
    IO.puts("""
    ┌─────────────────────────────────────────┐
    │       ClawdEx Configuration Wizard      │
    └─────────────────────────────────────────┘

    This wizard will help you configure ClawdEx.
    Press Enter to keep current values, or type new ones.
    """)

    current_env = load_env()

    # Database
    IO.puts("\n--- Database Configuration ---")

    database_url =
      prompt(
        "DATABASE_URL",
        Map.get(current_env, "DATABASE_URL", "postgresql://localhost/clawd_ex_dev")
      )

    # AI Providers
    IO.puts("\n--- AI Provider Configuration ---")
    IO.puts("(API keys are optional, leave blank to skip)")

    anthropic_key = prompt_secret("ANTHROPIC_API_KEY", Map.get(current_env, "ANTHROPIC_API_KEY"))
    openai_key = prompt_secret("OPENAI_API_KEY", Map.get(current_env, "OPENAI_API_KEY"))
    google_key = prompt_secret("GOOGLE_API_KEY", Map.get(current_env, "GOOGLE_API_KEY"))

    # Server
    IO.puts("\n--- Server Configuration ---")
    port = prompt("PORT", Map.get(current_env, "PORT", "4000"))
    host = prompt("HOST", Map.get(current_env, "HOST", "localhost"))

    # Build env map
    env = %{
      "DATABASE_URL" => database_url,
      "PORT" => port,
      "HOST" => host
    }

    env =
      if anthropic_key && anthropic_key != "",
        do: Map.put(env, "ANTHROPIC_API_KEY", anthropic_key),
        else: env

    env =
      if openai_key && openai_key != "", do: Map.put(env, "OPENAI_API_KEY", openai_key), else: env

    env =
      if google_key && google_key != "", do: Map.put(env, "GOOGLE_API_KEY", google_key), else: env

    # Save
    IO.puts("\n--- Summary ---")
    IO.puts("Configuration will be saved to #{@env_file}")
    IO.puts("")

    env
    |> Enum.each(fn {key, value} ->
      display_value = if String.contains?(key, "KEY"), do: mask(value), else: value
      IO.puts("  #{key}=#{display_value}")
    end)

    IO.puts("")

    case IO.gets("Save configuration? [Y/n] ") |> String.trim() |> String.downcase() do
      "" -> save_env(env)
      "y" -> save_env(env)
      "yes" -> save_env(env)
      _ -> IO.puts("Configuration cancelled.")
    end
  end

  defp prompt(name, default) do
    display_default = if String.contains?(name, "KEY"), do: mask(default), else: default
    prompt_text = "#{name} [#{display_default}]: "

    case IO.gets(prompt_text) |> String.trim() do
      "" -> default
      value -> value
    end
  end

  defp prompt_secret(name, default) do
    if default && default != "" do
      IO.puts("#{name}: [configured, press Enter to keep]")

      case IO.gets("> ") |> String.trim() do
        "" -> default
        value -> value
      end
    else
      IO.puts("#{name}: ")
      IO.gets("> ") |> String.trim()
    end
  end

  defp mask(nil), do: ""
  defp mask(""), do: ""

  defp mask(value) when byte_size(value) <= 8 do
    String.duplicate("*", byte_size(value))
  end

  defp mask(value) do
    String.slice(value, 0, 4) <> "****" <> String.slice(value, -4, 4)
  end

  defp load_env do
    case File.read(@env_file) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.filter(&(String.trim(&1) != "" && !String.starts_with?(&1, "#")))
        |> Enum.map(fn line ->
          case String.split(line, "=", parts: 2) do
            [key, value] -> {String.trim(key), String.trim(value)}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.into(%{})

      {:error, _} ->
        %{}
    end
  end

  defp save_env(env) do
    content =
      env
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
      |> Enum.join("\n")

    case File.write(@env_file, content <> "\n") do
      :ok ->
        IO.puts("\n✓ Configuration saved to #{@env_file}")
        IO.puts("  Restart the application to apply changes.")

      {:error, reason} ->
        IO.puts("\n✗ Failed to save: #{inspect(reason)}")
    end
  end
end
