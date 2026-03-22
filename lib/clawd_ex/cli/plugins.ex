defmodule ClawdEx.CLI.Plugins do
  @moduledoc """
  CLI plugins command - manage MCP servers and Plugin V2 plugins.
  """

  alias ClawdEx.MCP.{ServerManager, Connection}
  alias ClawdEx.Plugins.{Manager, Store}

  @mcp_config_file Path.expand("~/.clawd/mcp_servers.json")
  @extensions_dir Path.expand("~/.clawd/extensions")
  @bridge_script Path.expand("~/.clawd/bridge/mcp-bridge.js")

  # ===========================================================================
  # Dispatch
  # ===========================================================================

  def run(args, opts \\ [])
  def run(["list" | _], opts), do: if(opts[:help], do: print_help("list"), else: list_plugins(opts))
  def run(["install", spec | _], opts), do: if(opts[:help], do: print_help("install"), else: install_plugin(spec, opts))
  def run(["install" | _], _), do: IO.puts("Usage: clawd plugins install <spec>")
  def run(["uninstall", name | _], opts), do: if(opts[:help], do: print_help("uninstall"), else: uninstall_plugin(name, opts))
  def run(["uninstall" | _], _), do: IO.puts("Usage: clawd plugins uninstall <name>")
  def run(["enable", name | _], _), do: enable_plugin(name)
  def run(["enable" | _], _), do: IO.puts("Usage: clawd plugins enable <name>")
  def run(["disable", name | _], _), do: disable_plugin(name)
  def run(["disable" | _], _), do: IO.puts("Usage: clawd plugins disable <name>")
  def run(["update" | rest], opts), do: (if rest == [], do: update_all_plugins(opts), else: update_plugin(hd(rest), opts))
  def run(["info", name | _], opts), do: if(opts[:help], do: print_help("info"), else: show_plugin_info(name, opts))
  def run(["info" | _], _), do: IO.puts("Usage: clawd plugins info <name>")
  def run(["config", id | rest], opts), do: if(opts[:help], do: print_help("config"), else: handle_config(id, rest, opts))
  def run(["config" | _], _), do: IO.puts("Usage: clawd plugins config <plugin_id> [key] [value]")
  def run(["doctor" | rest], opts), do: (if rest == [], do: run_system_diagnostics(opts), else: run_plugin_diagnostics(hd(rest), opts))
  def run(["--help" | _], _), do: print_help()
  def run([], _), do: print_help()
  def run([sub | _], _), do: (IO.puts("Unknown subcommand: #{sub}"); print_help())

  # ===========================================================================
  # list — unified MCP + Plugin V2
  # ===========================================================================

  defp list_plugins(opts) do
    all = list_mcp_servers() ++ list_v2_plugins()
    all = all |> maybe_filter(:type, opts[:type]) |> maybe_filter(:status, opts[:status])

    if opts[:format] == "json" do
      IO.puts(Jason.encode!(%{plugins: all, total: length(all)}, pretty: true))
    else
      output_unified_table(all)
    end
  end

  defp list_mcp_servers do
    case load_mcp_config() do
      nil -> []
      config ->
        Enum.map(config["servers"] || [], fn srv ->
          status = get_mcp_status(srv["id"])
          tools = get_mcp_tool_count(srv["id"])
          %{name: srv["name"] || srv["id"], id: srv["id"],
            version: get_in(srv, ["source", "version"]) || "—",
            type: "mcp", status: format_status(status),
            capabilities: "tools(#{tools})", enabled: srv["enabled"]}
        end)
    end
  end

  defp list_v2_plugins do
    Manager.list_plugins()
    |> Enum.map(fn p ->
      %{name: p.name || p.id, id: p.id, version: p.version || "—",
        type: to_string(p.plugin_type),
        status: format_v2_status(p.status, p.enabled),
        capabilities: format_caps(p.capabilities), enabled: p.enabled}
    end)
  end

  defp maybe_filter(rows, _field, nil), do: rows
  defp maybe_filter(rows, field, val), do: Enum.filter(rows, &(Map.get(&1, field) == val))

  defp output_unified_table([]) do
    IO.puts("No plugins found. Run 'clawd plugins install <spec>' to install one.")
  end

  defp output_unified_table(rows) do
    enabled = Enum.count(rows, & &1.enabled)
    IO.puts("Plugins (#{length(rows)} total)\n")
    IO.puts("┌──────────────────┬──────────┬──────┬─────────┬──────────────────────────┐")
    IO.puts("│ Name             │ Version  │ Type │ Status  │ Capabilities             │")
    IO.puts("├──────────────────┼──────────┼──────┼─────────┼──────────────────────────┤")
    rows |> Enum.sort_by(& &1.name) |> Enum.each(fn r ->
      IO.puts("│ #{pad(r.name, 16)} │ #{pad(r.version, 8)} │ #{pad(r.type, 4)} │ #{pad(r.status, 7)} │ #{pad(r.capabilities, 24)} │")
    end)
    IO.puts("└──────────────────┴──────────┴──────┴─────────┴──────────────────────────┘")
    IO.puts("  #{enabled} enabled, #{length(rows) - enabled} disabled")
  end

  defp format_caps(caps) when is_list(caps), do: caps |> Enum.map(&to_string/1) |> Enum.join(", ")
  defp format_caps(_), do: "—"

  defp format_v2_status(:loaded, true), do: "loaded"
  defp format_v2_status(:loaded, false), do: "disabled"
  defp format_v2_status(:disabled, _), do: "disabled"
  defp format_v2_status(:error, _), do: "error"
  defp format_v2_status(s, _), do: to_string(s)

  # ===========================================================================
  # install — detect MCP vs V2
  # ===========================================================================

  defp install_plugin(spec, opts) do
    if opts[:mcp], do: install_mcp_server(spec, opts), else: install_v2_plugin(spec)
  end

  defp install_v2_plugin(spec) do
    IO.puts("Installing plugin: #{spec}...")
    case Manager.install(spec) do
      {:ok, plugin} ->
        IO.puts("✓ Installed: #{plugin.id} v#{plugin.version} (#{plugin.plugin_type})")
        IO.puts("  Capabilities: #{format_caps(plugin.capabilities)}")
      {:error, reason} ->
        IO.puts("✗ Failed: #{inspect(reason)}")
    end
  end

  defp install_mcp_server(spec, opts) do
    IO.puts("Installing MCP server: #{spec}...")
    with :ok <- check_node(),
         :ok <- File.mkdir_p(@extensions_dir),
         :ok <- npm_install(spec),
         {:ok, info} <- discover_mcp_plugin(spec),
         {:ok, cfg} <- gen_mcp_config(info, spec, opts),
         :ok <- save_mcp_server(cfg),
         :ok <- start_mcp_server(cfg) do
      tools = get_mcp_tool_count(cfg["id"])
      IO.puts("✓ Installed: #{cfg["id"]} (#{tools} tools)")
    else
      {:error, reason} -> IO.puts("✗ Failed: #{reason}")
    end
  end

  defp check_node do
    case System.cmd("node", ["--version"]) do
      {_, 0} -> :ok
      _ -> {:error, "Node.js not found"}
    end
  end

  defp npm_install(spec) do
    {output, code} = System.cmd("npm", ["install", spec], cd: @extensions_dir, stderr_to_stdout: true)
    if code == 0, do: :ok, else: {:error, "npm failed: #{String.trim(output)}"}
  end

  defp discover_mcp_plugin(spec) do
    pkg_dir = if String.starts_with?(spec, "./") or String.starts_with?(spec, "/") do
      spec
    else
      pkg = spec |> String.split("@") |> case do
        ["", scope, name | _] -> "@#{scope}/#{String.split(name, "@") |> List.first()}"
        [name | _] -> name
      end
      Path.join([@extensions_dir, "node_modules", pkg])
    end

    cond do
      File.exists?(Path.join(pkg_dir, "openclaw.plugin.json")) ->
        with {:ok, c} <- File.read(Path.join(pkg_dir, "openclaw.plugin.json")),
             {:ok, d} <- Jason.decode(c), do: {:ok, Map.put(d, "package_dir", pkg_dir)}
      File.exists?(Path.join(pkg_dir, "package.json")) ->
        with {:ok, c} <- File.read(Path.join(pkg_dir, "package.json")),
             {:ok, d} <- Jason.decode(c) do
          case d["openclaw"] do
            nil -> {:error, "No openclaw config in package.json"}
            cfg -> {:ok, Map.put(cfg, "package_dir", pkg_dir)}
          end
        end
      true ->
        {:error, "Package not found: #{pkg_dir}"}
    end
  end

  defp gen_mcp_config(info, spec, opts) do
    id = opts[:id] || (spec |> String.split("/") |> List.last() |> String.split("@") |> List.first()
         |> String.replace(~r/[^a-zA-Z0-9_-]/, "-") |> String.downcase())
    env = opts |> Keyword.get_values(:env) |> Enum.reduce(%{}, fn p, a ->
      case String.split(p, "=", parts: 2) do
        [k, v] -> Map.put(a, k, v)
        _ -> a
      end
    end)
    {:ok, %{"id" => id, "name" => opts[:name] || info["name"] || id, "enabled" => true,
            "transport" => "stdio", "command" => "node",
            "args" => [@bridge_script, "--plugin", info["package_dir"]],
            "env" => env, "timeout_ms" => opts[:timeout] || 30_000, "auto_restart" => true,
            "source" => %{"type" => "openclaw-plugin", "spec" => spec,
                          "version" => info["version"] || "unknown",
                          "installed_at" => DateTime.utc_now() |> DateTime.to_iso8601()}}}
  end

  defp save_mcp_server(cfg) do
    config = load_mcp_config() || %{"version" => 1, "servers" => []}
    if Enum.any?(config["servers"], &(&1["id"] == cfg["id"])) do
      {:error, "Server ID '#{cfg["id"]}' already exists"}
    else
      write_mcp_config(Map.put(config, "servers", config["servers"] ++ [cfg]))
    end
  end

  defp start_mcp_server(cfg) do
    try do
      fmt = %{command: cfg["command"], args: cfg["args"] || [],
              env: cfg["env"] |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)}
      case ServerManager.start_server(cfg["id"], fmt) do
        {:ok, _} -> Process.sleep(1000); :ok
        {:error, r} -> {:error, "Start failed: #{inspect(r)}"}
      end
    catch
      :exit, _ -> {:error, "Server manager not running"}
    end
  end

  # ===========================================================================
  # uninstall — V2 + MCP
  # ===========================================================================

  defp uninstall_plugin(name, opts) do
    v2 = Manager.get_plugin(name)
    mcp = find_mcp_server(name)
    cond do
      v2 != nil -> uninstall_v2(v2, opts)
      mcp != nil -> uninstall_mcp(mcp, opts)
      true -> IO.puts("✗ Plugin '#{name}' not found.")
    end
  end

  defp uninstall_v2(plugin, opts) do
    if !opts[:force] && !confirm("Uninstall '#{plugin.name}'?"), do: throw(:abort)
    IO.puts("Uninstalling #{plugin.name}...")
    case Manager.uninstall(plugin.id) do
      :ok ->
        unless opts[:keep_files] do
          dir = Path.join(Store.plugins_dir(), plugin.id)
          if File.dir?(dir), do: File.rm_rf(dir)
        end
        IO.puts("✓ Uninstalled.")
      {:error, r} -> IO.puts("✗ Failed: #{inspect(r)}")
    end
  catch
    :abort -> IO.puts("Aborted.")
  end

  defp uninstall_mcp(server, opts) do
    if !opts[:force] && !confirm("Uninstall MCP '#{server["name"]}'?"), do: throw(:abort)
    IO.puts("Uninstalling MCP server #{server["name"]}...")
    try do ServerManager.stop_server(server["id"]) catch :exit, _ -> :ok end
    config = load_mcp_config()
    updated = Enum.reject(config["servers"], &(&1["id"] == server["id"]))
    write_mcp_config(Map.put(config, "servers", updated))
    unless opts[:keep_files] do
      src = server["source"] || %{}
      if src["type"] == "openclaw-plugin" && src["spec"] do
        pkg = Path.join([@extensions_dir, "node_modules", src["spec"]])
        if File.dir?(pkg), do: File.rm_rf(pkg)
      end
    end
    IO.puts("✓ Uninstalled.")
  catch
    :abort -> IO.puts("Aborted.")
  end

  defp confirm(msg) do
    IO.puts("#{msg} [y/N] ")
    IO.gets("") |> String.trim() |> String.downcase() |> Kernel.in(["y", "yes"])
  end

  # ===========================================================================
  # enable / disable
  # ===========================================================================

  defp enable_plugin(name), do: toggle(name, true, "enabled")
  defp disable_plugin(name), do: toggle(name, false, "disabled")

  defp toggle(name, enabled, action) do
    v2 = Manager.get_plugin(name)
    mcp = find_mcp_server(name)
    cond do
      v2 != nil ->
        case if(enabled, do: Manager.enable_plugin(name), else: Manager.disable_plugin(name)) do
          :ok -> IO.puts("✓ Plugin '#{v2.name}' #{action}.")
          {:error, :not_found} -> IO.puts("✗ Not found.")
        end
      mcp != nil ->
        toggle_mcp(mcp, enabled, action)
      true ->
        IO.puts("✗ Plugin '#{name}' not found.")
    end
  end

  defp toggle_mcp(server, enabled, action) do
    config = load_mcp_config()
    updated = Map.put(server, "enabled", enabled)
    servers = Enum.map(config["servers"], fn s -> if s["id"] == server["id"], do: updated, else: s end)
    write_mcp_config(Map.put(config, "servers", servers))
    try do
      if enabled do
        fmt = %{command: updated["command"], args: updated["args"] || [],
                env: (updated["env"] || %{}) |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)}
        ServerManager.start_server(updated["id"], fmt)
      else
        ServerManager.stop_server(updated["id"])
      end
    catch
      :exit, _ -> :ok
    end
    IO.puts("✓ MCP '#{server["name"]}' #{action}.")
  end

  # ===========================================================================
  # update (stub)
  # ===========================================================================

  defp update_plugin(_name, _opts), do: IO.puts("Plugin update not yet implemented.")
  defp update_all_plugins(_opts), do: IO.puts("Plugin update not yet implemented.")

  # ===========================================================================
  # info — V2 + MCP
  # ===========================================================================

  defp show_plugin_info(name, opts) do
    v2 = Manager.get_plugin(name)
    mcp = find_mcp_server(name)
    cond do
      v2 != nil -> if opts[:format] == "json", do: info_v2_json(v2), else: info_v2_table(v2)
      mcp != nil -> if opts[:format] == "json", do: info_mcp_json(mcp), else: info_mcp_table(mcp)
      true -> IO.puts("✗ Plugin '#{name}' not found.")
    end
  end

  defp info_v2_table(p) do
    IO.puts("Plugin: #{p.name}\n─────────────────────────────────────")
    IO.puts("  ID:           #{p.id}")
    IO.puts("  Version:      #{p.version || "—"}")
    IO.puts("  Type:         #{p.plugin_type}")
    IO.puts("  Status:       #{format_v2_status(p.status, p.enabled)}")
    IO.puts("  Enabled:      #{if p.enabled, do: "✓", else: "✗"}")
    IO.puts("  Capabilities: #{format_caps(p.capabilities)}")
    if p.path, do: IO.puts("  Path:         #{p.path}")
    if p.description && p.description != "", do: IO.puts("  Description:  #{p.description}")
    if p.config && map_size(p.config) > 0 do
      IO.puts("\n  Config:")
      Enum.each(p.config, fn {k, v} -> IO.puts("    #{k}: #{mask(k, v)}") end)
    end
    # Tools
    if :tools in p.capabilities do
      IO.puts("\n  Tools:")
      try do
        Manager.get_tool_specs()
        |> Enum.filter(&(Map.get(&1, :plugin_id) == p.id))
        |> Enum.each(fn t -> IO.puts("    • #{Map.get(t, :name)}") end)
      catch :exit, _ -> IO.puts("    (manager not running)")
      end
    end
    # Channels
    if :channels in p.capabilities do
      IO.puts("\n  Channels:")
      try do
        Manager.get_channels()
        |> Enum.filter(&(Map.get(&1, :plugin_id) == p.id))
        |> Enum.each(fn ch -> IO.puts("    • #{Map.get(ch, :id)}") end)
      catch :exit, _ -> IO.puts("    (manager not running)")
      end
    end
    if p.error, do: IO.puts("\n  Error: #{p.error}")
  end

  defp info_v2_json(p) do
    tools = try do
      Manager.get_tool_specs() |> Enum.filter(&(Map.get(&1, :plugin_id) == p.id))
      |> Enum.map(&%{name: Map.get(&1, :name), description: Map.get(&1, :description, "")})
    catch :exit, _ -> [] end
    channels = try do
      Manager.get_channels() |> Enum.filter(&(Map.get(&1, :plugin_id) == p.id))
      |> Enum.map(&Map.get(&1, :id))
    catch :exit, _ -> [] end
    IO.puts(Jason.encode!(%{id: p.id, name: p.name, version: p.version, type: p.plugin_type,
      status: p.status, enabled: p.enabled, description: p.description, path: p.path,
      capabilities: p.capabilities, config_keys: Map.keys(p.config || %{}),
      tools: tools, channels: channels, error: p.error}, pretty: true))
  end

  defp info_mcp_table(s) do
    status = get_mcp_status(s["id"])
    tools = get_mcp_tool_count(s["id"])
    IO.puts("MCP Server: #{s["name"] || s["id"]}\n─────────────────────────────────────")
    IO.puts("  ID:        #{s["id"]}")
    IO.puts("  Status:    #{format_status(status)}")
    IO.puts("  Enabled:   #{if s["enabled"], do: "✓", else: "✗"}")
    IO.puts("  Command:   #{s["command"]} #{Enum.join(s["args"] || [], " ")}")
    IO.puts("  Timeout:   #{s["timeout_ms"] || 30_000}ms")
    if src = s["source"] do
      IO.puts("  Source:    #{src["type"] || "?"}")
      if src["version"], do: IO.puts("  Version:   #{src["version"]}")
    end
    if env = s["env"], do: (unless Enum.empty?(env) do
      IO.puts("\n  Env: #{Map.keys(env) |> Enum.join(", ")}") end)
    if tools > 0 do
      IO.puts("\n  Tools (#{tools}):")
      try do
        case ServerManager.get_connection(s["id"]) do
          {:ok, pid} ->
            case Connection.list_tools(pid) do
              {:ok, list} -> list |> Enum.take(10) |> Enum.each(fn t ->
                IO.puts("    • #{t["name"] || Map.get(t, :name)}") end)
                if length(list) > 10, do: IO.puts("    ... +#{length(list) - 10} more")
              _ -> :ok
            end
          _ -> IO.puts("    (not running)")
        end
      catch :exit, _ -> IO.puts("    (not running)")
      end
    end
  end

  defp info_mcp_json(s) do
    status = get_mcp_status(s["id"])
    tools_count = get_mcp_tool_count(s["id"])
    tools = try do
      case ServerManager.get_connection(s["id"]) do
        {:ok, pid} -> case Connection.list_tools(pid) do
          {:ok, l} -> Enum.map(l, fn t -> %{name: t["name"] || Map.get(t, :name)} end)
          _ -> [] end
        _ -> [] end
    catch :exit, _ -> [] end
    IO.puts(Jason.encode!(%{id: s["id"], name: s["name"], type: "mcp", status: status,
      enabled: s["enabled"], source: s["source"] || %{}, env_keys: Map.keys(s["env"] || %{}),
      tools: %{count: tools_count, list: tools}}, pretty: true))
  end

  # ===========================================================================
  # config — Plugin V2 only
  # ===========================================================================

  defp handle_config(plugin_id, rest, opts) do
    case Manager.get_plugin(plugin_id) do
      nil ->
        IO.puts("✗ Plugin '#{plugin_id}' not found (V2 only).")

      plugin ->
        cond do
          opts[:show] || rest == [] -> show_config(plugin)
          length(rest) == 1 -> show_config_key(plugin, hd(rest))
          length(rest) >= 2 -> set_config(plugin_id, hd(rest), Enum.drop(rest, 1) |> Enum.join(" "))
        end
    end
  end

  defp show_config(plugin) do
    cfg = plugin.config || %{}
    if map_size(cfg) == 0, do: IO.puts("No config for '#{plugin.name}'."),
    else: (IO.puts("Config (#{plugin.name}):"); Enum.each(cfg, fn {k, v} -> IO.puts("  #{k}: #{mask(k, v)}") end))
  end

  defp show_config_key(plugin, key) do
    case Map.get(plugin.config || %{}, key) do
      nil -> IO.puts("Key '#{key}' not set.")
      v -> IO.puts("#{key}: #{mask(key, v)}")
    end
  end

  defp set_config(plugin_id, key, value) do
    case Store.load() do
      {:ok, registry} ->
        entry = Store.get_plugin(registry, plugin_id)
        if entry do
          cfg = Map.put(Map.get(entry, :config, %{}), key, value)
          registry = Store.set_config(registry, plugin_id, cfg)
          case Store.save(registry) do
            :ok ->
              try do Manager.reload() catch :exit, _ -> :ok end
              IO.puts("✓ #{key} = #{mask(key, value)}")
            {:error, r} -> IO.puts("✗ Save failed: #{inspect(r)}")
          end
        else
          IO.puts("✗ Not in registry.")
        end
      {:error, r} -> IO.puts("✗ Registry error: #{inspect(r)}")
    end
  end

  defp mask(key, value) do
    secrets = ~w(token secret key password api_key apiKey app_secret)
    kl = String.downcase(to_string(key))
    if Enum.any?(secrets, &String.contains?(kl, &1)) do
      s = to_string(value)
      if String.length(s) > 6, do: String.slice(s, 0, 3) <> "***" <> String.slice(s, -3, 3), else: "***"
    else
      to_string(value)
    end
  end

  # ===========================================================================
  # doctor
  # ===========================================================================

  defp run_system_diagnostics(_opts) do
    IO.puts("Plugin System Diagnostics\n")
    issues = []
    # Prerequisites
    IO.puts("Prerequisites:")
    issues = case System.cmd("node", ["--version"]) do
      {v, 0} -> IO.puts("  ✓ Node.js #{String.trim(v)}"); issues
      _ -> IO.puts("  ✗ Node.js not found"); ["Node.js missing" | issues]
    end
    issues = if File.exists?(@bridge_script), do: (IO.puts("  ✓ MCP bridge"); issues),
             else: (IO.puts("  ✗ MCP bridge missing"); ["Bridge missing" | issues])
    # MCP config
    IO.puts("\nMCP Config:")
    issues = case load_mcp_config() do
      nil -> if File.exists?(@mcp_config_file),
             do: (IO.puts("  ✗ Invalid JSON"); ["Bad MCP config" | issues]),
             else: (IO.puts("  — No config (OK)"); issues)
      c -> IO.puts("  ✓ #{length(c["servers"] || [])} server(s)"); issues
    end
    # V2 Registry
    IO.puts("\nV2 Registry:")
    issues = case Store.load() do
      {:ok, r} -> IO.puts("  ✓ #{map_size(r.plugins)} plugin(s)"); issues
      {:error, r} -> IO.puts("  ✗ #{inspect(r)}"); ["Registry error" | issues]
    end
    # Plugin status
    IO.puts("\nPlugins:")
    issues = check_all_mcp(issues)
    issues = check_all_v2(issues)
    # Summary
    IO.puts("")
    if issues == [], do: IO.puts("✓ All checks passed."),
    else: (IO.puts("Issues (#{length(issues)}):"); issues |> Enum.reverse() |> Enum.with_index(1)
           |> Enum.each(fn {i, n} -> IO.puts("  #{n}. #{i}") end))
  end

  defp run_plugin_diagnostics(name, _opts) do
    v2 = Manager.get_plugin(name)
    mcp = find_mcp_server(name)
    cond do
      v2 != nil ->
        IO.puts("Diagnostics: #{v2.name} (#{v2.plugin_type})")
        IO.puts("  Status: #{format_v2_status(v2.status, v2.enabled)}")
        if v2.path, do: IO.puts("  Path:   #{v2.path} #{if File.dir?(v2.path), do: "✓", else: "✗"}")
        if v2.error, do: IO.puts("  Error:  #{v2.error}"), else: IO.puts("  Health: ✓")
      mcp != nil ->
        status = get_mcp_status(mcp["id"])
        IO.puts("Diagnostics: #{mcp["name"]} (mcp)")
        IO.puts("  Status: #{format_status(status)}, Tools: #{get_mcp_tool_count(mcp["id"])}")
        if mcp["enabled"] && status != :running, do: IO.puts("  ✗ Enabled but not running!"),
        else: IO.puts("  Health: ✓")
      true ->
        IO.puts("✗ Plugin '#{name}' not found.")
    end
  end

  defp check_all_mcp(issues) do
    case load_mcp_config() do
      nil -> issues
      config -> Enum.reduce(config["servers"] || [], issues, fn s, acc ->
        name = s["name"] || s["id"]
        status = get_mcp_status(s["id"])
        case {status, s["enabled"]} do
          {:running, _} -> IO.puts("  ✓ [mcp] #{name} — running"); acc
          {:stopped, true} -> IO.puts("  ✗ [mcp] #{name} — stopped"); ["MCP '#{name}' stopped" | acc]
          {:stopped, _} -> IO.puts("  — [mcp] #{name} — disabled"); acc
          _ -> IO.puts("  ? [mcp] #{name}"); acc
        end
      end)
    end
  end

  defp check_all_v2(issues) do
    Manager.list_plugins() |> Enum.reduce(issues, fn p, acc ->
      label = "[#{p.plugin_type}] #{p.name}"
      case {p.status, p.enabled} do
        {:loaded, true} -> IO.puts("  ✓ #{label} — loaded"); acc
        {:error, _} -> IO.puts("  ✗ #{label} — error"); ["'#{p.name}' error" | acc]
        _ -> IO.puts("  — #{label} — disabled"); acc
      end
    end)
  end

  # ===========================================================================
  # MCP helpers
  # ===========================================================================

  defp load_mcp_config do
    if File.exists?(@mcp_config_file) do
      with {:ok, c} <- File.read(@mcp_config_file), {:ok, d} <- Jason.decode(c), do: d
    end
  end

  defp write_mcp_config(config) do
    File.mkdir_p(Path.dirname(@mcp_config_file))
    tmp = @mcp_config_file <> ".tmp"
    with :ok <- File.write(tmp, Jason.encode!(config, pretty: true)),
         :ok <- File.rename(tmp, @mcp_config_file), do: :ok
  end

  defp find_mcp_server(name) do
    case load_mcp_config() do
      nil -> nil
      config -> Enum.find(config["servers"] || [], fn s -> s["id"] == name or s["name"] == name end)
    end
  end

  defp get_mcp_status(id) do
    try do
      case ServerManager.get_connection(id) do
        {:ok, pid} -> case Connection.status(pid) do {:ok, %{status: s}} -> s; _ -> :unknown end
        {:error, _} -> :stopped
      end
    catch :exit, _ -> :unknown
    end
  end

  defp get_mcp_tool_count(id) do
    try do
      case ServerManager.get_connection(id) do
        {:ok, pid} -> case Connection.list_tools(pid) do {:ok, t} -> length(t); _ -> 0 end
        {:error, _} -> 0
      end
    rescue _ -> 0
    catch :exit, _ -> 0
    end
  end

  defp format_status(:running), do: "running"
  defp format_status(:stopped), do: "stopped"
  defp format_status(:error), do: "error"
  defp format_status(_), do: "unknown"

  # ===========================================================================
  # Formatting
  # ===========================================================================

  defp pad(str, len) when is_binary(str) do
    if String.length(str) > len,
      do: String.slice(str, 0, len - 1) <> "…",
      else: String.pad_trailing(str, len)
  end
  defp pad(nil, len), do: String.pad_trailing("—", len)

  # ===========================================================================
  # Help
  # ===========================================================================

  defp print_help(sub \\ nil)
  defp print_help(nil) do
    IO.puts("""
    Usage: clawd plugins <subcommand> [options]

    Subcommands:
      list       List all plugins (MCP + V2)
      install    Install a plugin (--mcp for MCP servers)
      uninstall  Remove a plugin (--keep-files, --force)
      enable     Enable a plugin
      disable    Disable a plugin
      update     Update plugins (stub)
      info       Show plugin details (--format json)
      config     View/set Plugin V2 config
      doctor     Run diagnostics

    Examples:
      clawd plugins list --type beam
      clawd plugins install @scope/my-plugin
      clawd plugins config feishu app_id lark-xxx
      clawd plugins uninstall feishu --keep-files
    """)
  end
  defp print_help("list"), do: IO.puts("Usage: clawd plugins list [--format json] [--type TYPE] [--status STATUS]")
  defp print_help("install"), do: IO.puts("Usage: clawd plugins install <spec> [--mcp] [--id ID] [--name NAME] [--env K=V]")
  defp print_help("uninstall"), do: IO.puts("Usage: clawd plugins uninstall <name> [--keep-files] [--force]")
  defp print_help("info"), do: IO.puts("Usage: clawd plugins info <name> [--format json]")
  defp print_help("config"), do: IO.puts("Usage: clawd plugins config <id> [key] [value] [--show]")
  defp print_help(_), do: print_help()
end
