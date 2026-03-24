defmodule ClawdExWeb.Helpers.SafeParse do
  @moduledoc """
  Safe parsing helpers that handle nil, empty string, and non-numeric input
  without raising exceptions.
  """

  @doc """
  Safely converts a string to integer, returning nil on invalid input.

  ## Examples

      iex> safe_to_integer("42")
      42

      iex> safe_to_integer("")
      nil

      iex> safe_to_integer(nil)
      nil

      iex> safe_to_integer("abc")
      nil

      iex> safe_to_integer(7)
      7
  """
  @spec safe_to_integer(term()) :: integer() | nil
  def safe_to_integer(value) when is_integer(value), do: value
  def safe_to_integer(nil), do: nil
  def safe_to_integer(""), do: nil

  def safe_to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  def safe_to_integer(_), do: nil
end
