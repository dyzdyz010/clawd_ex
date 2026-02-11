defmodule ClawdEx.Skills.Gate do
  @moduledoc """
  Gating logic for skills based on metadata requirements.

  Checks whether a skill's prerequisites are met:
  - `requires.bins` - all listed binaries must exist on PATH
  - `requires.anyBins` - at least one listed binary must exist on PATH
  - `requires.env` - all listed environment variables must be set
  - `requires.config` - all listed config keys must be set
  - `os` - current OS must match
  """

  alias ClawdEx.Skills.Skill

  @doc """
  Check if a skill passes all gating requirements.
  Returns `true` if the skill should be enabled, `false` otherwise.
  """
  @spec eligible?(Skill.t()) :: boolean()
  def eligible?(%Skill{metadata: metadata}) do
    requires = get_in_metadata(metadata, ["openclaw", "requires"]) || %{}
    os_filter = get_in_metadata(metadata, ["openclaw", "os"])

    check_os(os_filter) &&
      check_bins(Map.get(requires, "bins")) &&
      check_any_bins(Map.get(requires, "anyBins")) &&
      check_env(Map.get(requires, "env")) &&
      check_config(Map.get(requires, "config"))
  end

  @doc """
  返回 skill 每个 requirement 的详细满足状态。
  """
  @spec detailed_status(Skill.t()) :: map()
  def detailed_status(%Skill{metadata: metadata}) do
    requires = get_in_metadata(metadata, ["openclaw", "requires"]) || %{}
    os_filter = get_in_metadata(metadata, ["openclaw", "os"])

    bins = Map.get(requires, "bins")
    any_bins = Map.get(requires, "anyBins")
    env = Map.get(requires, "env")
    config = Map.get(requires, "config")

    %{
      os: %{required: os_filter, met: check_os(os_filter)},
      bins: %{
        required: bins,
        met: check_bins(bins),
        details: if(bins, do: Enum.map(bins, fn b -> {b, binary_exists?(b)} end), else: [])
      },
      any_bins: %{
        required: any_bins,
        met: check_any_bins(any_bins),
        details: if(any_bins, do: Enum.map(any_bins, fn b -> {b, binary_exists?(b)} end), else: [])
      },
      env: %{
        required: env,
        met: check_env(env),
        details: if(env, do: Enum.map(env, fn v -> {v, System.get_env(v) != nil} end), else: [])
      },
      config: %{required: config, met: check_config(config)}
    }
  end

  @doc """
  Filter a list of skills, returning only eligible ones.
  """
  @spec filter_eligible([Skill.t()]) :: [Skill.t()]
  def filter_eligible(skills) do
    Enum.filter(skills, &eligible?/1)
  end

  # OS check
  defp check_os(nil), do: true

  defp check_os(os_list) when is_list(os_list) do
    current_os() in os_list
  end

  defp check_os(os) when is_binary(os), do: current_os() == os

  defp current_os do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "win32"
      _ -> "unknown"
    end
  end

  # All bins must exist
  defp check_bins(nil), do: true
  defp check_bins(bins) when is_list(bins), do: Enum.all?(bins, &binary_exists?/1)

  # At least one bin must exist
  defp check_any_bins(nil), do: true
  defp check_any_bins(bins) when is_list(bins), do: Enum.any?(bins, &binary_exists?/1)

  # All env vars must be set
  defp check_env(nil), do: true

  defp check_env(vars) when is_list(vars) do
    Enum.all?(vars, fn var ->
      System.get_env(var) != nil
    end)
  end

  # All config keys must be present
  defp check_config(nil), do: true

  defp check_config(keys) when is_list(keys) do
    Enum.all?(keys, fn key ->
      Application.get_env(:clawd_ex, String.to_atom(key)) != nil
    end)
  end

  @doc false
  def binary_exists?(name) do
    System.find_executable(name) != nil
  end

  # Safe nested map access
  defp get_in_metadata(metadata, keys) when is_map(metadata) do
    get_in(metadata, keys)
  end

  defp get_in_metadata(_, _), do: nil
end
