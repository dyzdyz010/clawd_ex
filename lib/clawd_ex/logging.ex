defmodule ClawdEx.Logging do
  @moduledoc """
  Runtime log level control and file handler setup.

  Uses OTP's built-in `:logger_std_h` for file output with rotation.
  The file handler writes to `$CLAWD_LOG_DIR/clawd_ex.log` (default: `~/.clawd/logs/`).
  """

  require Logger

  @valid_levels [:debug, :info, :warning, :error]
  @handler_id :clawd_file_handler

  # ---------------------------------------------------------------------------
  # File handler setup
  # ---------------------------------------------------------------------------

  @doc """
  Adds an OTP file handler that writes to the configured log directory.

  Called from `ClawdEx.Application.start/2`.
  """
  def setup_file_handler do
    log_dir = log_dir()
    File.mkdir_p!(log_dir)

    log_file = Path.join(log_dir, "clawd_ex.log")

    handler_config = %{
      config: %{
        file: String.to_charlist(log_file),
        max_no_bytes: 10_485_760,
        max_no_files: 5
      },
      formatter:
        {:logger_formatter,
         %{
           template: [:time, " [", :level, "] ", :msg, "\n"],
           single_line: true
         }}
    }

    case :logger.add_handler(@handler_id, :logger_std_h, handler_config) do
      :ok ->
        Logger.info("File logger started: #{log_file}")
        {:ok, log_file}

      {:error, {:already_exist, _}} ->
        {:ok, log_file}

      {:error, reason} = err ->
        Logger.warning("Failed to add file handler: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Removes the file handler. Useful for tests.
  """
  def remove_file_handler do
    :logger.remove_handler(@handler_id)
  end

  @doc """
  Returns the current log file path.
  """
  def log_file do
    Path.join(log_dir(), "clawd_ex.log")
  end

  @doc """
  Returns the configured log directory.
  """
  def log_dir do
    Application.get_env(:clawd_ex, :log_dir) ||
      System.get_env("CLAWD_LOG_DIR") ||
      Path.expand("~/.clawd/logs")
  end

  # ---------------------------------------------------------------------------
  # Dynamic level control
  # ---------------------------------------------------------------------------

  @doc """
  Sets the global Logger level at runtime.

  ## Examples

      iex> ClawdEx.Logging.set_level(:info)
      :ok

      iex> ClawdEx.Logging.set_level(:nope)
      {:error, :invalid_level}
  """
  def set_level(level) when level in @valid_levels do
    Logger.configure(level: level)
    :ok
  end

  def set_level(_level), do: {:error, :invalid_level}

  @doc """
  Returns the current Logger level.
  """
  def get_level do
    Logger.level()
  end

  @doc """
  Returns the list of valid log levels.
  """
  def valid_levels, do: @valid_levels
end
