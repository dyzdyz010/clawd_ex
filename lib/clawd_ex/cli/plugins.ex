defmodule ClawdEx.CLI.Plugins do
  @moduledoc """
  CLI plugins command - manage MCP servers and OpenClaw plugins.

  Usage:
    clawd_ex plugins list [--format json] [--status STATUS] [--source TYPE]
    clawd_ex plugins install <spec> [--id ID] [--name NAME] [--env KEY=VALUE]
    clawd_ex plugins uninstall <name> [--keep-package] [--force]
    clawd_ex plugins enable <name>
    clawd_ex plugins disable <name>
    clawd_ex plugins update [name] [--dry-run] [--check-only]
    clawd_ex plugins info <name> [--format json]
    clawd_ex plugins doctor [name] [--fix] [--verbose]
  """

  alias ClawdEx.MCP.{ServerManager, Connection}

  @config_file Path.expand("~/.clawd/mcp_servers.json")
  @extensions_dir Path.expand("~/.clawd/extensions")
  @bridge_script Path.expand("~/.clawd/bridge/mcp-bridge.js")

  def run(args, opts \\ [])

  def run(["list" | _rest], opts) do
    if opts[:help] do
      print_list_help()
    else
      list_plugins(opts)
    end
  end

  def run(["install", spec | _rest], opts) do
    if opts[:help] do
      print_install_help()
    else
      install_plugin(spec, opts)
    end
  end

  def run(["install" | _], _opts) do
    IO.puts("Usage: clawd_ex plugins install <spec>\n")
    IO.puts("Provide a package specifier (npm package, local path, or git repo).")
  end

  def run(["uninstall", name | _rest], opts) do
    if opts[:help] do
      print_uninstall_help()
    else
      uninstall_plugin(name, opts)
    end
  end

  def run(["uninstall" | _], _opts) do
    IO.puts("Usage: clawd_ex plugins uninstall <name>\n")
    IO.puts("Provide a plugin name or ID to uninstall.")
  end

  def run(["enable", name | _rest], opts) do
    if opts[:help] do
      print_enable_help()
    else
      enable_plugin(name)
    end
  end

  def run(["enable" | _], _opts) do
    IO.puts("Usage: clawd_ex plugins enable <name>\n")
    IO.puts("Provide a plugin name or ID to enable.")
  end

  def run(["disable", name | _rest], opts) do
    if opts[:help] do
      print_disable_help()
    else
      disable_plugin(name)
    end
  end

  def run(["disable" | _], _opts) do
    IO.puts("Usage: clawd_ex plugins disable <name>\n")
    IO.puts("Provide a plugin name or ID to disable.")
  end

  def run(["update" | rest], opts) do
    if opts[:help] do
      print_update_help()
    else
      case rest do
        [name | _] -> update_plugin(name, opts)
        [] -> update_all_plugins(opts)
      end
    end
  end

  def run(["info", name | _rest], opts) do
    if opts[:help] do
      print_info_help()
    else
      show_plugin_info(name, opts)
    end
  end

  def run(["info" | _], _opts) do
    IO.puts("Usage: clawd_ex plugins info <name>\n")
    IO.puts("Provide a plugin name or ID to show details.")
  end

  def run(["doctor" | rest], opts) do
    if opts[:help] do
      print_doctor_help()
    else
      case rest do
        [name | _] -> run_plugin_diagnostics(name, opts)
        [] -> run_system_diagnostics(opts)
      end
    end
  end

  def run(["--help" | _], _opts), do: print_help()
  def run([], _opts), do: print_help()

  def run([subcmd | _], _opts) do
    IO.puts("Unknown plugins subcommand: #{subcmd}\n")
    print_help()
  end

  # ---------------------------------------------------------------------------
  # plugins list
  # ---------------------------------------------------------------------------

  defp list_plugins(opts) do
    config = load_config()

    if config == nil do
      IO.puts("No plugin configuration found.")
      IO.puts("Run 'clawd_ex plugins doctor' to set up the plugin system.")
      :ok
    else
      servers = config["servers"] || []
      servers = apply_filters(servers, opts)

      if opts[:format] == "json" do
        output_json(servers)
      else
        output_table(servers)
      end
    end
  end

  defp apply_filters(servers, opts) do
    servers
    |> filter_by_status(opts[:status])
    |> filter_by_source(opts[:source])
  end

  defp filter_by_status(servers, nil), do: servers
  defp filter_by_status(servers, status) do
    Enum.filter(servers, fn server ->
      server_status = get_server_status(server["id"])
      to_string(server_status) == status
    end)
  end

  defp filter_by_source(servers, nil), do: servers
  defp filter_by_source(servers, source_type) do
    Enum.filter(servers, fn server ->
      source = server["source"] || %{}
      source["type"] == source_type
    end)
  end

  defp output_table(servers) do
    if Enum.empty?(servers) do
      IO.puts("No plugins found.")
    else

    enabled_count = Enum.count(servers, & &1["enabled"])
    
    IO.puts("Plugins (#{length(servers)} total)\n")

    IO.puts(
      "┌────────────┬──────────┬─────────┬─────────┬────────────────────────────────┐"
    )
    IO.puts(
      "│ Name       │ ID       │ Status  │ Tools   │ Source                         │"
    )
    IO.puts(
      "├────────────┼──────────┼─────────┼─────────┼────────────────────────────────┤"
    )

    servers
    |> Enum.sort_by(& &1["name"])
    |> Enum.each(fn server ->
      name = truncate(server["name"] || server["id"], 10)
      id = truncate(server["id"], 8)
      status = format_status(get_server_status(server["id"]))
      tools = format_tool_count(get_tool_count(server["id"]))
      source = format_source(server)

      IO.puts(
        "│ #{String.pad_trailing(name, 10)} │ #{String.pad_trailing(id, 8)} │ #{String.pad_trailing(status, 7)} │ #{String.pad_trailing(tools, 7)} │ #{String.pad_trailing(source, 30)} │"
      )
    end)

    IO.puts(
      "└────────────┴──────────┴─────────┴─────────┴────────────────────────────────┘"
    )

    IO.puts("\n  #{enabled_count} enabled, #{length(servers) - enabled_count} disabled")
    end
  end

  defp output_json(servers) do
    plugin_data = Enum.map(servers, fn server ->
      %{
        id: server["id"],
        name: server["name"] || server["id"],
        enabled: server["enabled"],
        status: get_server_status(server["id"]),
        tools: get_tool_count(server["id"]),
        source: server["source"] || %{},
        path: get_plugin_path(server)
      }
    end)

    enabled_count = Enum.count(plugin_data, & &1.enabled)
    running_count = Enum.count(plugin_data, &(&1.status == :running))

    result = %{
      plugins: plugin_data,
      total: length(plugin_data),
      enabled: enabled_count,
      running: running_count
    }

    IO.puts(Jason.encode!(result, pretty: true))
  end

  defp get_server_status(id) do
    try do
      case ServerManager.get_connection(id) do
        {:ok, conn_pid} ->
          case Connection.status(conn_pid) do
            {:ok, %{status: status}} -> status
            _ -> :unknown
          end
        {:error, _} -> :stopped
      end
    catch
      :exit, _ -> :unknown
    end
  end

  defp get_tool_count(id) do
    try do
      case ServerManager.get_connection(id) do
        {:ok, conn_pid} ->
          case Connection.list_tools(conn_pid) do
            {:ok, tools} -> length(tools)
            _ -> 0
          end
        {:error, _} -> 0
      end
    catch
      :exit, _ -> 0
    rescue
      _ -> 0
    end
  end

  defp format_status(:running), do: "running"
  defp format_status(:stopped), do: "stopped"
  defp format_status(:error), do: "error"
  defp format_status(_), do: "unknown"

  defp format_tool_count(0), do: "—"
  defp format_tool_count(count), do: to_string(count)

  defp format_source(server) do
    source = server["source"] || %{}
    
    case source["type"] do
      "openclaw-plugin" ->
        path = get_plugin_path(server)
        if path, do: Path.relative_to_cwd(path), else: "openclaw-plugin"
      
      "mcp-server" ->
        server["command"] || "mcp-server"
        
      "local" ->
        "local"
        
      _ ->
        server["command"] || "unknown"
    end
    |> truncate(28)
  end

  defp get_plugin_path(server) do
    source = server["source"] || %{}
    
    case source["type"] do
      "openclaw-plugin" ->
        spec = source["spec"]
        if spec && String.starts_with?(spec, "@") do
          Path.join([@extensions_dir, "node_modules", spec])
        end
        
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # plugins install
  # ---------------------------------------------------------------------------

  defp install_plugin(spec, opts) do
    IO.puts("Installing #{spec}...")

    with :ok <- check_prerequisites(),
         :ok <- prepare_extensions_dir(),
         :ok <- install_package(spec),
         {:ok, plugin_info} <- discover_plugin(spec),
         {:ok, server_config} <- generate_server_config(plugin_info, spec, opts),
         :ok <- update_config_file(server_config),
         :ok <- validate_and_start(server_config) do
      
      IO.puts("✓ Plugin installed successfully!\n")
      print_install_success(server_config)
    else
      {:error, reason} ->
        IO.puts("✗ Installation failed: #{reason}")
        System.halt(1)
    end
  end

  defp check_prerequisites do
    case System.cmd("node", ["--version"]) do
      {_, 0} -> :ok
      _ -> {:error, "Node.js not found. Please install Node.js first."}
    end
  end

  defp prepare_extensions_dir do
    File.mkdir_p(@extensions_dir)
  end

  defp install_package(spec) do
    IO.puts("  Downloading package...")
    
    {output, exit_code} = System.cmd("npm", ["install", spec], 
      cd: @extensions_dir,
      stderr_to_stdout: true
    )
    
    case exit_code do
      0 -> :ok
      _ -> {:error, "npm install failed: #{String.trim(output)}"}
    end
  end

  defp discover_plugin(spec) do
    IO.puts("  Discovering plugin entry...")
    
    # For npm packages, look in node_modules
    # For local paths, look directly
    package_dir = if String.starts_with?(spec, "./") or String.starts_with?(spec, "/") do
      spec
    else
      # Extract package name from spec (@scope/package@version -> @scope/package)
      package_name = spec |> String.split("@") |> case do
        ["", scope, name | _] -> "@#{scope}/#{name}"  # scoped package
        [name | _] -> name  # unscoped package
      end
      Path.join([@extensions_dir, "node_modules", package_name])
    end
    
    package_json_path = Path.join(package_dir, "package.json")
    plugin_json_path = Path.join(package_dir, "openclaw.plugin.json")
    
    cond do
      File.exists?(plugin_json_path) ->
        # Dedicated plugin config file
        {:ok, content} = File.read(plugin_json_path)
        {:ok, config} = Jason.decode(content)
        {:ok, Map.put(config, "package_dir", package_dir)}
        
      File.exists?(package_json_path) ->
        # Check package.json for openclaw field
        {:ok, content} = File.read(package_json_path)
        {:ok, package} = Jason.decode(content)
        
        case package["openclaw"] do
          nil -> {:error, "No openclaw configuration found in package"}
          config -> {:ok, Map.put(config, "package_dir", package_dir)}
        end
        
      true ->
        {:error, "Package directory not found: #{package_dir}"}
    end
  end

  defp generate_server_config(plugin_info, spec, opts) do
    id = opts[:id] || generate_id_from_spec(spec)
    name = opts[:name] || plugin_info["name"] || id
    
    base_config = %{
      "id" => id,
      "name" => name,
      "enabled" => true,
      "transport" => "stdio",
      "command" => "node",
      "args" => [
        @bridge_script,
        "--plugin",
        plugin_info["package_dir"]
      ],
      "env" => build_env_vars(opts),
      "timeout_ms" => opts[:timeout] || 30000,
      "auto_restart" => true,
      "source" => %{
        "type" => "openclaw-plugin",
        "spec" => spec,
        "version" => plugin_info["version"] || "unknown",
        "installed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
    
    {:ok, base_config}
  end

  defp generate_id_from_spec(spec) do
    spec
    |> String.split("/")
    |> List.last()
    |> String.split("@")
    |> List.first()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.downcase()
  end

  defp build_env_vars(opts) do
    env_pairs = Keyword.get_values(opts, :env)
    
    Enum.reduce(env_pairs, %{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp update_config_file(server_config) do
    IO.puts("  Updating configuration...")
    
    config = load_config() || %{"version" => 1, "servers" => []}
    
    # Check for duplicate IDs
    existing_ids = config["servers"] |> Enum.map(& &1["id"]) |> MapSet.new()
    
    if MapSet.member?(existing_ids, server_config["id"]) do
      {:error, "Plugin ID '#{server_config["id"]}' already exists"}
    else
      updated_config = Map.put(config, "servers", config["servers"] ++ [server_config])
      write_config(updated_config)
    end
  end

  defp validate_and_start(server_config) do
    IO.puts("  Starting server...")
    
    try do
      # Start the server directly with ServerManager
      server_map_config = convert_config_to_server_format(server_config)
      case ServerManager.start_server(server_config["id"], server_map_config) do
        {:ok, _pid} -> 
          # Give it a moment to start
          Process.sleep(1000)
          case get_server_status(server_config["id"]) do
            :running -> :ok
            status -> {:error, "Server started but status is #{status}"}
          end
        {:error, reason} -> 
          {:error, "Failed to start server: #{inspect(reason)}"}
      end
    catch
      :exit, _ -> {:error, "Server manager not running"}
    end
  end

  defp print_install_success(server_config) do
    tool_count = get_tool_count(server_config["id"])
    
    if tool_count > 0 do
      IO.puts("Available tools: #{tool_count}")
    end
    
    IO.puts("""
    Configuration:
      • Server ID: #{server_config["id"]}
      • Config file: ~/.clawd/mcp_servers.json
    
    Next steps:
      1. Edit ~/.clawd/mcp_servers.json to configure API credentials
      2. Run 'clawd_ex plugins doctor #{server_config["id"]}' to test connection
    """)
  end

  # ---------------------------------------------------------------------------
  # plugins uninstall
  # ---------------------------------------------------------------------------

  defp uninstall_plugin(name, opts) do
    config = load_config()
    
    case find_server_by_name_or_id(config, name) do
      nil ->
        IO.puts("✗ Plugin '#{name}' not found.")
        System.halt(1)
        
      server ->
        unless opts[:force] do
          IO.puts("Are you sure you want to uninstall '#{server["name"]}'? [y/N] ")
          response = IO.gets("") |> String.trim() |> String.downcase()
          
          unless response in ["y", "yes"] do
            IO.puts("Aborted.")
            :aborted
          end
        end
        
        uninstall_server(server, opts)
    end
  end

  defp uninstall_server(server, opts) do
    IO.puts("Uninstalling #{server["name"]}...")
    
    # Stop server
    IO.puts("  Stopping server...")
    try do
      ServerManager.stop_server(server["id"])
    catch
      :exit, _ -> :ok
    end
    
    # Remove from config
    IO.puts("  Removing configuration...")
    config = load_config()
    updated_servers = Enum.reject(config["servers"], &(&1["id"] == server["id"]))
    updated_config = Map.put(config, "servers", updated_servers)
    write_config(updated_config)
    
    # Remove package unless --keep-package
    unless opts[:keep_package] do
      if package_path = get_plugin_path(server) do
        IO.puts("  Removing package...")
        File.rm_rf(package_path)
      end
    end
    
    IO.puts("✓ Plugin uninstalled successfully.")
  end

  # ---------------------------------------------------------------------------
  # plugins enable/disable
  # ---------------------------------------------------------------------------

  defp enable_plugin(name) do
    modify_plugin_status(name, true, "enabled")
  end

  defp disable_plugin(name) do
    modify_plugin_status(name, false, "disabled")
  end

  defp modify_plugin_status(name, enabled, action) do
    config = load_config()
    
    case find_server_by_name_or_id(config, name) do
      nil ->
        IO.puts("✗ Plugin '#{name}' not found.")
        System.halt(1)
        
      server ->
        updated_server = Map.put(server, "enabled", enabled)
        updated_servers = Enum.map(config["servers"], fn s ->
          if s["id"] == server["id"], do: updated_server, else: s
        end)
        
        updated_config = Map.put(config, "servers", updated_servers)
        write_config(updated_config)
        
        # Apply changes by stopping/starting the server
        try do
          if enabled do
            # Enable: start the server
            server_map_config = convert_config_to_server_format(updated_server)
            case ServerManager.start_server(updated_server["id"], server_map_config) do
              {:ok, _pid} -> 
                IO.puts("✓ Plugin '#{server["name"]}' #{action} and started.")
              {:error, :already_started} ->
                IO.puts("✓ Plugin '#{server["name"]}' #{action} (already running).")
              {:error, reason} ->
                IO.puts("✓ Plugin '#{server["name"]}' #{action} but failed to start: #{inspect(reason)}")
            end
          else
            # Disable: stop the server
            case ServerManager.stop_server(updated_server["id"]) do
              :ok -> IO.puts("✓ Plugin '#{server["name"]}' #{action} and stopped.")
              {:error, :not_found} -> IO.puts("✓ Plugin '#{server["name"]}' #{action} (already stopped).")
              {:error, reason} -> IO.puts("✓ Plugin '#{server["name"]}' #{action} but failed to stop: #{inspect(reason)}")
            end
          end
        catch
          :exit, _ ->
            IO.puts("✓ Plugin #{action} in config. Restart ClawdEx to apply changes.")
        end
    end
  end

  # ---------------------------------------------------------------------------
  # plugins update
  # ---------------------------------------------------------------------------

  defp update_plugin(name, opts) do
    IO.puts("Update single plugin not yet implemented.")
    IO.puts("Use 'clawd_ex plugins update' to update all plugins.")
  end

  defp update_all_plugins(opts) do
    IO.puts("Update all plugins not yet implemented.")
    IO.puts("This feature will check for newer versions and update packages.")
  end

  # ---------------------------------------------------------------------------
  # plugins info
  # ---------------------------------------------------------------------------

  defp show_plugin_info(name, opts) do
    config = load_config()
    
    case find_server_by_name_or_id(config, name) do
      nil ->
        IO.puts("✗ Plugin '#{name}' not found.")
        IO.puts("Use 'clawd_ex plugins list' to see available plugins.")
        
      server ->
        if opts[:format] == "json" do
          output_plugin_info_json(server)
        else
          output_plugin_info_table(server)
        end
    end
  end

  defp output_plugin_info_table(server) do
    name = server["name"] || server["id"]
    status = get_server_status(server["id"])
    tool_count = get_tool_count(server["id"])
    
    IO.puts("""
    Plugin: #{name}
    ┌─────────────────────────────────────────────────────────────────────────────────┐
    │  #{String.pad_trailing(name, 75)}│
    └─────────────────────────────────────────────────────────────────────────────────┘

      ID:           #{server["id"]}
      Name:         #{server["name"] || server["id"]}
      Status:       #{format_status(status)}#{if status == :running, do: " (active)", else: ""}
      Enabled:      #{if server["enabled"], do: "✓", else: "✗"}
      Transport:    #{server["transport"]}
      Command:      #{server["command"]} #{Enum.join(server["args"] || [], " ")}
      Timeout:      #{server["timeout_ms"] || 30000}ms
      Auto-restart: #{if server["auto_restart"], do: "✓", else: "✗"}
    """)
    
    # Source info
    if source = server["source"] do
      IO.puts("      Source:       #{source["type"] || "unknown"}")
      if source["spec"], do: IO.puts("      Package:      #{source["spec"]}")
      if source["version"], do: IO.puts("      Version:      #{source["version"]}")
      if source["installed_at"], do: IO.puts("      Installed:    #{source["installed_at"]}")
    end
    
    # Environment
    if env = server["env"] do
      unless Enum.empty?(env) do
        IO.puts("\n      Environment:")
        Enum.each(env, fn {key, _value} ->
          IO.puts("        #{key}: ***")
        end)
      end
    end
    
    # Tools
    if tool_count > 0 do
      IO.puts("\n      Available Tools (#{tool_count}):")
      try do
        case ServerManager.get_connection(server["id"]) do
          {:ok, conn_pid} ->
            case Connection.list_tools(conn_pid) do
              {:ok, tools} ->
                Enum.each(Enum.take(tools, 10), fn tool ->
                  name = tool["name"] || tool.name
                  desc = tool["description"] || tool.description
                  IO.puts("        • #{name}#{if desc, do: " - #{desc}", else: ""}")
                end)
                
                if length(tools) > 10 do
                  IO.puts("        ... and #{length(tools) - 10} more")
                end
              _ ->
                IO.puts("        (Unable to query tools)")
            end
          {:error, _} ->
            IO.puts("        (Server not running)")
        end
      catch
        :exit, _ ->
          IO.puts("        (Unable to query tools - server not running)")
      end
    else
      IO.puts("\n      Tools: None available")
    end
  end

  defp output_plugin_info_json(server) do
    status = get_server_status(server["id"])
    tool_count = get_tool_count(server["id"])
    
    tools = try do
      case ServerManager.get_connection(server["id"]) do
        {:ok, conn_pid} ->
          case Connection.list_tools(conn_pid) do
            {:ok, tool_list} ->
              Enum.map(tool_list, fn tool ->
                name = tool["name"] || tool.name
                desc = tool["description"] || tool.description
                %{name: name, description: desc}
              end)
            _ -> []
          end
        {:error, _} -> []
      end
    catch
      :exit, _ -> []
    end
    
    info = %{
      id: server["id"],
      name: server["name"] || server["id"],
      enabled: server["enabled"],
      status: status,
      transport: server["transport"],
      command: server["command"],
      args: server["args"] || [],
      timeout_ms: server["timeout_ms"] || 30000,
      auto_restart: server["auto_restart"],
      source: server["source"] || %{},
      env_keys: Map.keys(server["env"] || %{}),
      tools: %{
        count: tool_count,
        list: tools
      }
    }
    
    IO.puts(Jason.encode!(info, pretty: true))
  end

  # ---------------------------------------------------------------------------
  # plugins doctor
  # ---------------------------------------------------------------------------

  defp run_system_diagnostics(opts) do
    IO.puts("ClawdEx Plugin System Diagnostics")
    IO.puts("┌─────────────────────────────────────────────────────────────────────────────────┐")
    IO.puts("│                                 System Health                                  │")
    IO.puts("└─────────────────────────────────────────────────────────────────────────────────┘\n")
    
    issues = []
    
    # Check prerequisites
    IO.puts("Prerequisites:")
    issues = check_node_js(issues, opts)
    issues = check_bridge_script(issues, opts)
    issues = check_extensions_dir(issues, opts)
    
    IO.puts("")
    
    # Check configuration
    IO.puts("Configuration:")
    issues = check_config_file(issues, opts)
    
    IO.puts("")
    
    # Check plugins
    issues = check_all_plugins(issues, opts)
    
    # Summary
    IO.puts("")
    if Enum.empty?(issues) do
      IO.puts("✓ All checks passed. Plugin system is healthy.")
    else
      IO.puts("Issues Found:")
      Enum.with_index(issues, 1) |> Enum.each(fn {issue, idx} ->
        IO.puts("  #{idx}. #{issue}")
      end)
      
      IO.puts("\nOverall Status: #{length(issues)} issue(s) detected")
    end
  end

  defp run_plugin_diagnostics(name, opts) do
    config = load_config()
    
    case find_server_by_name_or_id(config, name) do
      nil ->
        IO.puts("✗ Plugin '#{name}' not found.")
        
      server ->
        IO.puts("Plugin Diagnostics: #{server["name"]}")
        IO.puts("┌─────────────────────────────────────────────────────────────────────────────────┐")
        IO.puts("│  #{String.pad_trailing(server["name"], 75)}│")
        IO.puts("└─────────────────────────────────────────────────────────────────────────────────┘\n")
        
        diagnose_single_plugin(server, opts)
    end
  end

  defp check_node_js(issues, _opts) do
    case System.cmd("node", ["--version"]) do
      {version, 0} ->
        version = String.trim(version)
        IO.puts("  ✓ Node.js #{version} found")
        issues
        
      _ ->
        IO.puts("  ✗ Node.js not found")
        ["Node.js not installed or not in PATH" | issues]
    end
  end

  defp check_bridge_script(issues, _opts) do
    if File.exists?(@bridge_script) do
      IO.puts("  ✓ MCP bridge available at #{Path.relative_to_cwd(@bridge_script)}")
      issues
    else
      IO.puts("  ✗ MCP bridge not found")
      ["MCP bridge script missing: #{@bridge_script}" | issues]
    end
  end

  defp check_extensions_dir(issues, _opts) do
    if File.exists?(@extensions_dir) and File.dir?(@extensions_dir) do
      case File.stat(@extensions_dir) do
        {:ok, %{access: access}} when access in [:read_write, :write] ->
          IO.puts("  ✓ Extensions directory exists and writable")
          issues
          
        {:ok, _} ->
          IO.puts("  ✗ Extensions directory not writable")
          ["Extensions directory not writable: #{@extensions_dir}" | issues]
          
        {:error, _} ->
          IO.puts("  ✗ Cannot access extensions directory")
          ["Cannot access extensions directory: #{@extensions_dir}" | issues]
      end
    else
      IO.puts("  ✗ Extensions directory missing")
      ["Extensions directory missing: #{@extensions_dir}" | issues]
    end
  end

  defp check_config_file(issues, _opts) do
    if File.exists?(@config_file) do
      case load_config() do
        nil ->
          IO.puts("  ✗ Config file invalid JSON")
          ["Invalid JSON in config file: #{@config_file}" | issues]
          
        config ->
          servers = config["servers"] || []
          ids = Enum.map(servers, & &1["id"])
          
          if length(ids) == length(Enum.uniq(ids)) do
            IO.puts("  ✓ Config file syntax valid, all server IDs unique")
            issues
          else
            IO.puts("  ✗ Duplicate server IDs found")
            ["Duplicate server IDs in config file" | issues]
          end
      end
    else
      IO.puts("  ✓ No config file (will be created on first install)")
      issues
    end
  end

  defp check_all_plugins(issues, _opts) do
    config = load_config()
    
    cond do
      config == nil ->
        IO.puts("Plugins: No configuration found")
        issues
      
      Enum.empty?(config["servers"] || []) ->
        IO.puts("Plugins: No plugins installed")
        issues
      
      true ->
        servers = config["servers"] || []
        IO.puts("Plugins (#{length(servers)} total):")
    
        Enum.reduce(servers, issues, fn server, acc ->
          check_single_plugin(server, acc)
        end)
    end
  end

  defp check_single_plugin(server, issues) do
    name = server["name"] || server["id"]
    status = get_server_status(server["id"])
    
    case status do
      :running ->
        tool_count = get_tool_count(server["id"])
        IO.puts("  ✓ #{name} - running, #{tool_count} tools available")
        issues
        
      :stopped ->
        if server["enabled"] do
          IO.puts("  ✗ #{name} - stopped (should be running)")
          ["Plugin '#{name}' is enabled but not running" | issues]
        else
          IO.puts("  — #{name} - disabled")
          issues
        end
        
      :error ->
        IO.puts("  ✗ #{name} - error state")
        ["Plugin '#{name}' is in error state" | issues]
        
      _ ->
        IO.puts("  ? #{name} - unknown status")
        ["Plugin '#{name}' has unknown status" | issues]
    end
  end

  defp diagnose_single_plugin(server, _opts) do
    # Detailed diagnostics for a single plugin
    # This would include more specific checks
    IO.puts("Detailed plugin diagnostics not yet implemented.")
    IO.puts("Use 'clawd_ex plugins info #{server["id"]}' for basic information.")
  end

  # ---------------------------------------------------------------------------
  # Utility functions
  # ---------------------------------------------------------------------------

  defp load_config do
    if File.exists?(@config_file) do
      case File.read(@config_file) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, config} -> config
            {:error, reason} -> 
              IO.puts("Error parsing config file: #{inspect(reason)}")
              nil
          end
        {:error, reason} -> 
          IO.puts("Error reading config file: #{inspect(reason)}")
          nil
      end
    else
      nil
    end
  end

  defp write_config(config) do
    # Ensure config directory exists
    config_dir = Path.dirname(@config_file)
    File.mkdir_p(config_dir)
    
    # Write config atomically
    content = Jason.encode!(config, pretty: true)
    temp_file = @config_file <> ".tmp"
    
    case File.write(temp_file, content) do
      :ok ->
        case File.rename(temp_file, @config_file) do
          :ok -> :ok
          {:error, reason} -> {:error, "Failed to update config: #{reason}"}
        end
        
      {:error, reason} ->
        {:error, "Failed to write config: #{reason}"}
    end
  end

  defp find_server_by_name_or_id(config, name) do
    servers = config["servers"] || []
    
    Enum.find(servers, fn server ->
      server["id"] == name or server["name"] == name
    end)
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 1) <> "…"
    else
      str
    end
  end

  defp truncate(nil, _max), do: "—"

  defp convert_config_to_server_format(server_config) do
    %{
      command: server_config["command"],
      args: server_config["args"] || [],
      env: convert_env_to_list(server_config["env"] || %{})
    }
  end

  defp convert_env_to_list(env_map) when is_map(env_map) do
    Enum.map(env_map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
  defp convert_env_to_list(env_list) when is_list(env_list), do: env_list
  defp convert_env_to_list(_), do: []

  # ---------------------------------------------------------------------------
  # Help functions
  # ---------------------------------------------------------------------------

  defp print_help do
    IO.puts("""
    Usage: clawd_ex plugins <subcommand> [options]

    Subcommands:
      list       List installed plugins and their status
      install    Install a plugin from npm, local path, or git
      uninstall  Remove a plugin and its configuration
      enable     Enable a disabled plugin
      disable    Disable an enabled plugin
      update     Update plugins to latest versions
      info       Show detailed information about a plugin
      doctor     Run health checks and diagnostics

    Options:
      --help  Show this help message

    Examples:
      clawd_ex plugins list --format json
      clawd_ex plugins install @larksuiteoapi/feishu-openclaw-plugin
      clawd_ex plugins info feishu
      clawd_ex plugins doctor
    """)
  end

  # Individual help functions would go here...
  # (print_list_help, print_install_help, etc.)
  # For brevity, just showing the main help structure

  defp print_list_help, do: IO.puts("plugins list help - TBD")
  defp print_install_help, do: IO.puts("plugins install help - TBD")
  defp print_uninstall_help, do: IO.puts("plugins uninstall help - TBD")
  defp print_enable_help, do: IO.puts("plugins enable help - TBD")
  defp print_disable_help, do: IO.puts("plugins disable help - TBD")
  defp print_update_help, do: IO.puts("plugins update help - TBD")
  defp print_info_help, do: IO.puts("plugins info help - TBD")
  defp print_doctor_help, do: IO.puts("plugins doctor help - TBD")
end