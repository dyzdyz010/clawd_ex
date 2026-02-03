defmodule ClawdExWeb.SessionComponents do
  @moduledoc false
  use ClawdExWeb, :html

  embed_templates "session_components/*"

  def format_datetime(nil), do: "-"

  def format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  def message_bg(:user), do: "bg-blue-900/30"
  def message_bg(:assistant), do: "bg-gray-700"
  def message_bg(:system), do: "bg-gray-800 border border-gray-600"
  def message_bg(:tool), do: "bg-purple-900/30"
  def message_bg(_), do: "bg-gray-700"
end
