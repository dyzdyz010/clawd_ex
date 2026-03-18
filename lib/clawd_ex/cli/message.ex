defmodule ClawdEx.CLI.Message do
  @moduledoc """
  CLI message command - send messages through channels.

  Usage:
    clawd_ex message send <target> <message> [--channel telegram|discord]
  """

  alias ClawdEx.Channels.{Telegram, Discord}

  def run(args, opts \\ [])

  def run(["send", target | rest], opts) do
    if opts[:help] do
      print_send_help()
    else
      message = Enum.join(rest, " ")

      if message == "" do
        IO.puts("Error: message text is required.\n")
        print_send_help()
      else
        send_message(target, message, opts)
      end
    end
  end

  def run(["send" | _rest], _opts) do
    IO.puts("Error: target and message are required.\n")
    print_send_help()
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown message subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # message send
  # ---------------------------------------------------------------------------

  defp send_message(target, message, opts) do
    channel = opts[:channel] || detect_channel(target)

    IO.puts("Sending message via #{channel}...")
    IO.puts("  Target:  #{target}")
    IO.puts("  Message: #{truncate(message, 60)}")
    IO.puts("")

    result =
      case channel do
        "telegram" -> send_telegram(target, message)
        "discord" -> send_discord(target, message)
        other -> {:error, "Unknown channel: #{other}. Supported: telegram, discord"}
      end

    case result do
      :ok ->
        IO.puts("✓ Message sent successfully.")

      {:ok, _} ->
        IO.puts("✓ Message sent successfully.")

      {:error, reason} ->
        IO.puts("✗ Failed to send message: #{inspect(reason)}")
    end
  end

  defp send_telegram(target, message) do
    try do
      Telegram.send_message(target, message, [])
    catch
      :exit, reason -> {:error, {:telegram_not_running, reason}}
    end
  end

  defp send_discord(target, message) do
    try do
      Discord.send_message(target, message)
    catch
      :exit, reason -> {:error, {:discord_not_running, reason}}
    end
  end

  defp detect_channel(target) do
    cond do
      # Telegram chat IDs are typically negative numbers or numeric
      String.match?(target, ~r/^-?\d+$/) -> "telegram"
      # Discord channel IDs are large positive numbers (snowflakes)
      String.match?(target, ~r/^\d{17,20}$/) -> "discord"
      # Default to telegram
      true -> "telegram"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 1) <> "…"
    else
      str
    end
  end

  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------

  defp print_help do
    IO.puts("""
    Usage: clawd_ex message <subcommand> [options]

    Subcommands:
      send <target> <message>    Send a message to a channel

    Options:
      --help                     Show this help message
    """)
  end

  defp print_send_help do
    IO.puts("""
    Usage: clawd_ex message send <target> <message> [options]

    Send a message through a channel (Telegram or Discord).
    Target is typically a chat/channel ID.

    Examples:
      clawd_ex message send -1001234567890 "Hello world"
      clawd_ex message send -1001234567890 "Deploy complete" --channel telegram
      clawd_ex message send 987654321098765432 "Status update" --channel discord

    Options:
      --channel CHANNEL    Channel to use (telegram, discord). Auto-detected if omitted.
      --help               Show this help message
    """)
  end
end
