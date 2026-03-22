# Plugin System V2 — Code Review

**Reviewer:** Reviewer Agent  
**Date:** 2026-03-22  
**Commits reviewed:**  
- `4106de4` wip: Plugin System V2 — Manager rewrite, Store, Channel Registry, dynamic routing  
- `76a2255` feat: Plugin System V2 Phase 2-3 — NodeBridge, tests, CLI, docs  

**Stats:** +6191 / -1257 across 23 files

---

## 🔴 Critical — 必须修复

### C1. NodeBridge: `next_id` 整型溢出 / 无上限增长

**文件:** `lib/clawd_ex/plugins/node_bridge.ex` L441-443

```elixir
defp next_id(state) do
  {state.next_id, %{state | next_id: state.next_id + 1}}
end
```

`next_id` 是一个永远递增的整数，永远不会回绕。虽然 Elixir 使用大整数不会溢出，但 JSON 序列化到 JS 端后，当超过 `Number.MAX_SAFE_INTEGER`（2^53 - 1）时，JS 会产生精度丢失，导致请求/响应匹配失败。

长期运行的 sidecar 如果每秒发 10 个请求，约 285 万年才会出问题，所以**实际风险较低**，但设计上不够健壮。

**建议:** 使用模运算回绕，或用字符串 UUID 作为 RPC id。

---

### C2. NodeBridge: 超时 timer 与 pending request 不同步清理

**文件:** `lib/clawd_ex/plugins/node_bridge.ex` L194-201, L453

```elixir
defp schedule_timeout(rpc_id) do
  Process.send_after(self(), {:rpc_timeout, rpc_id}, @default_timeout)
end
```

当一个 RPC 请求正常返回时，`remove_pending/2` 把 id 从 pending map 移除了，**但超时 timer 没有取消**。虽然超时触发后因为在 pending 中找不到 id 而无害（`handle_info({:rpc_timeout, ...})` 中做了 nil 检查），每个请求都会遗留一个无效的 timer 消息。

**真正的问题是:** 如果 id 被回绕复用（见 C1），旧 timer 可能意外取消新请求。

**建议:** 用 `Process.send_after/3` 返回的 timer ref 存入 pending，正常返回时 `Process.cancel_timer/1`。

---

### C3. NodeBridge: Port 启动后直接设 `:ready` — 无握手确认

**文件:** `lib/clawd_ex/plugins/node_bridge.ex` L226

```elixir
port = Port.open(...)
{:ok, %{state | port: port, status: :ready, buffer: ""}}
```

Port.open 成功只表示 OS 进程启动了，并不意味 Node.js 脚本已完成初始化。在 `status: :ready` 之后立刻发送 RPC 请求，有可能 Node 进程还没执行到 `rl.on('line', ...)` 就收到数据，导致请求丢失。

**建议:** 启动后先发 `ping` 请求，收到 pong 后才设 `:ready`。或者 plugin-host 启动后主动发 `{"jsonrpc":"2.0","method":"host.ready"}` 通知。

---

### C4. plugin-host.mjs: 插件代码在主进程执行 — 无沙箱隔离

**文件:** `priv/plugin-host/plugin-host.mjs` L125-131

```javascript
const pluginModule = await import(pathToFileURL(entryPoint).href);
const plugin = pluginModule.default || pluginModule;
const pluginDef = typeof plugin === 'function' ? { register: plugin } : plugin;
if (pluginDef.register) await pluginDef.register(api);
```

所有插件共享同一个 Node.js 进程和全局作用域。恶意或有 bug 的插件可以：
- 修改全局对象 (`process.env`, `global`)
- 调用 `process.exit()` 杀掉整个 host
- 覆盖其他插件的工具函数
- 通过 `process.stdout` 直接写入，破坏 JSON-RPC 协议

**建议 (阶段性改进):**
1. 短期：用 `try/catch` 包裹 `register`/`activate`，捕获插件初始化异常
2. 中期：拦截 `process.stdout.write`，确保插件不能直接写 stdout
3. 长期：每个插件用 `worker_threads` 或 `vm.Module` 隔离

---

### C5. Manager: `install` 和 `uninstall` 不是原子操作

**文件:** `lib/clawd_ex/plugins/manager.ex` L168-194

`do_install` 流程: npm install → read plugin.json → update registry.json → install skills → update state

任何中间步骤失败，前面的步骤（npm install 的文件、registry.json 部分写入）不会回滚。

`uninstall` 流程: stop plugin → unregister channels → remove from registry → remove from state  
但 registry.json 写入失败后仍然从 state 中移除了，导致**内存与磁盘不一致**。

**建议:** 
- Install: 在临时目录操作，全部成功后原子 rename 到目标位置
- Uninstall: 先从 registry 移除并持久化，成功后才更新内存状态

---

## 🟡 Important — 应该修复

### I1. Store: `save/1` 不是原子写入

**文件:** `lib/clawd_ex/plugins/store.ex` L67-79

```elixir
def save(registry) do
  path = registry_path()
  path |> Path.dirname() |> File.mkdir_p!()
  content = Jason.encode!(registry, pretty: true)
  case File.write(path, content) do ...
```

直接 `File.write` 如果进程中途崩溃，会留下半写的 registry.json。

对比 CLI 中 `write_mcp_config/1` 用了 `File.write(tmp, ...) + File.rename(tmp, target)` 的原子写入模式 — **Store 应该保持一致**。

**建议:** `write → tmp file + rename` 模式。

---

### I2. Manager: `reload/0` 丢弃所有运行时状态

**文件:** `lib/clawd_ex/plugins/manager.ex` L158-165

```elixir
def handle_call(:reload, _from, _state) do
  state = load_all_plugins(%{
    plugins: %{},
    plugin_states: %{},
    tool_index: %{},
    registry: nil
  })
  {:reply, :ok, state}
end
```

Reload 创建全新 state，旧的 `plugin_states`（BEAM 插件的运行时状态）被直接丢弃，没有调用 `stop/1`。这可能导致：
- BEAM 插件的资源泄漏（打开的连接、ETS 表等）
- Node 插件在 bridge 中仍然 loaded，但 Manager 以为是新的

**建议:** reload 前先 stop 所有已加载插件，对 Node 插件调用 `unload_plugin`。

---

### I3. NodeBridge: 重启延迟没有退避上限

**文件:** `lib/clawd_ex/plugins/node_bridge.ex` L170-180

```elixir
def handle_info(:restart_port, state) do
  ...
  {:error, reason} ->
    Process.send_after(self(), :restart_port, @restart_delay * 2)
  ...
end
```

注意这里 `@restart_delay * 2` 是常量 `1000 * 2 = 2000`，并不是指数退避！每次失败都是固定 2 秒后重试。如果意图是指数退避，需要把 delay 存入 state。

如果 Node.js 彻底不可用（比如被删除），会每 2 秒无限重试，产生大量日志。

**建议:** 实现真正的指数退避 + 上限（如 max 30s），或设置最大重试次数。

---

### I4. plugin-host.mjs: 插件 tool.execute 无超时保护

**文件:** `priv/plugin-host/plugin-host.mjs` L166-178

```javascript
async function handleToolCall(params) {
  ...
  const result = await tool.execute(toolParams || {}, context || {});
  return { ok: true, data: result };
}
```

如果 `tool.execute` 永远不 resolve（无限循环、死锁），这个 handler 会永远挂起，阻塞 readline 的后续处理。因为 `rl.on('line', async ...)` 中用 `await`，所有后续请求都会排队。

Elixir 侧有 30s 超时，但 Node 侧的 promise 永远不会被回收。

**建议:** 用 `Promise.race([tool.execute(...), timeout(30000)])` 加超时。

---

### I5. NodeBridge: Port buffer 和 `{:line, max}` 的交互

**文件:** `lib/clawd_ex/plugins/node_bridge.ex` L217

```elixir
{:line, 1_048_576}  # 1MB line buffer
```

使用 `:line` 模式时，Port 会将数据按行分割。如果 JSON 消息超过 1MB（比如 tool 返回大量数据），Port 会拆分成 `{:noeol, data}` + `{:eol, data}` 多段。

代码中 `handle_port_data` 正确处理了 `{:noeol, data}` 的情况（拼接到 buffer），但 **buffer 没有大小限制**。恶意插件返回无限长的单行可导致 OOM。

**建议:** 设置 buffer 最大大小（如 10MB），超过时丢弃并返回错误。

---

### I6. Manager: `enable_plugin/1` 不重新加载 Node 插件

**文件:** `lib/clawd_ex/plugins/manager.ex` L117-124

```elixir
def handle_call({:enable_plugin, id}, _from, state) do
  ...
  updated = %{plugin | enabled: true, status: :loaded}
  state = put_in(state.plugins[id], updated)
  persist_enabled_state(state, id, true)
  {:reply, :ok, state}
end
```

对于 Node 插件，`enable` 只是翻转了内存中的 flag，但没有通过 NodeBridge 重新 `load_plugin`。如果之前 disable 时也没 unload，那 Node 侧的插件状态就是不一致的。

同样 `disable_plugin` 也没有调用 NodeBridge.unload_plugin。

**建议:** enable/disable 时对 Node 插件分别调用 `NodeBridge.load_plugin` / `NodeBridge.unload_plugin`。

---

### I7. CLI: `return/0` 未使用的私有函数

**文件:** `lib/clawd_ex/cli/plugins.ex` L571

```elixir
defp return, do: :ok
```

这个函数被 `handle_config` 中的 `return()` 调用，但使用方式诡异：

```elixir
unless plugin do IO.puts("..."); return() end
```

这里 `return()` 的值被 `unless` 丢弃了，并不会真正 "return"。Elixir 没有 early return 语义。如果 `plugin` 为 nil，代码会打印错误消息，然后**继续执行后面的 `cond`**，导致对 nil plugin 调用方法。

**建议:** 重构为 guard clause 模式：
```elixir
defp handle_config(plugin_id, rest, opts) do
  case Manager.get_plugin(plugin_id) do
    nil -> IO.puts("✗ Plugin '#{plugin_id}' not found (V2 only).")
    plugin -> do_handle_config(plugin, plugin_id, rest, opts)
  end
end
```

---

### I8. Manager: Node 插件启动时没有通过 NodeBridge 加载

**文件:** `lib/clawd_ex/plugins/manager.ex` L258-281

`load_node_plugin_from_registry/2` 只是创建了 Plugin struct 并放入 state，但没有调用 `NodeBridge.load_plugin/2`。这意味着 Node 插件的 tools 实际上没有在 Node 侧注册。

当 `collect_all_tool_specs/1` 调用 `NodeBridge.list_tools(plugin.id)` 时，会返回空列表。

**建议:** 在 `load_node_plugin_from_registry` 中调用 `NodeBridge.load_plugin(plugin_dir, config)`。可以异步做，失败时标记插件为 error 状态。

---

## 🟢 Suggestion — 建议改进

### S1. Store: `normalize_entry` 中的 atom/string key 双重检查

**文件:** `lib/clawd_ex/plugins/store.ex` L127-142

```elixir
id: Map.get(entry, "id", Map.get(entry, :id, "")),
name: Map.get(entry, "name", Map.get(entry, :name, "")),
...
```

这种 string/atom key 双查找在每个字段重复了 12 次，非常冗长。

**建议:** 先 `Map.new(entry, fn {k, v} -> {to_string(k), v} end)` 统一转为 string key，再一次性提取。

---

### S2. plugin-host.mjs: `handlePluginLoad` 没有防止重复加载

**文件:** `priv/plugin-host/plugin-host.mjs` L115-140

如果同一个 `pluginId` 的插件被 load 两次，新的会覆盖旧的 Map entry，旧插件的 tool handlers 被丢弃但没有清理通知。

**建议:** 检查 `plugins.has(pluginId)` 并返回错误，或先自动 unload 旧的。

---

### S3. CLI: 表格宽度硬编码

**文件:** `lib/clawd_ex/cli/plugins.ex` L71-80

表格列宽固定（name=16, version=8, type=4 等），如果插件名或版本号长度超过限制会被截断加省略号。

**建议:** 考虑根据实际数据动态计算列宽，或至少增大 name 列到 24-30。

---

### S4. Manager: `install_local_plugin` 的 symlink 策略

**文件:** `lib/clawd_ex/plugins/manager.ex` L367-380

```elixir
link_target = Path.join(plugin_dir, "source")
File.rm(link_target)
File.ln_s!(source_dir, link_target)
```

在 `plugin_dir` 下创建了 `source` symlink 指向原始路径，但 `finalize_install` 用的是 `source_dir`（原始路径），不是 `link_target`。这意味着 symlink 创建了但从没被使用，也没被清理。

**建议:** 统一链接策略 — 要么 symlink 整个 plugin_dir 指向 source_dir，要么不创建 symlink。

---

### S5. Channels.Registry: 没有 unregister_all / clear 接口

测试中用了 `Registry.list() |> Enum.each(... unregister ...)` 来清理。

**建议:** 添加 `Registry.clear/0` 或 `Registry.unregister_all/0` 用于测试和 reload 场景。

---

### S6. Store: `save/1` 中 `Jason.encode!` 可能抛异常

**文件:** `lib/clawd_ex/plugins/store.ex` L71

```elixir
content = Jason.encode!(registry, pretty: true)
```

如果 registry 中含有不可 JSON 序列化的值（如 atoms、tuples），会直接 crash。

**建议:** 用 `Jason.encode(registry, pretty: true)` + `case` 处理错误，或在 put_plugin 时验证可序列化性。

---

### S7. Tools.Registry: 插件 tool 名冲突检测

**文件:** `lib/clawd_ex/tools/registry.ex` L87-115

`list_tools/1` 简单地 concat builtin + plugin_beam + plugin_node + mcp tools。如果插件注册了与内置同名的工具（如 "read"），两者都会出现在列表中，执行时 `execute/3` 会优先匹配内置工具，插件工具被静默忽略。

**建议:** 检测名称冲突并记录 warning，或允许插件覆盖内置工具（需要明确的优先级策略）。

---

### S8. NodeBridge: `terminate/1` 中的 Port.close 可以更优雅

**文件:** `lib/clawd_ex/plugins/node_bridge.ex` L197-204

```elixir
def terminate(_reason, state) do
  if state.port do
    try do Port.close(state.port) rescue _ -> :ok end
  end
  :ok
end
```

直接 close port 不给 Node 进程发停止信号。虽然 `rl.on('close', ...)` 会在 stdin 关闭时触发 `process.exit(0)`，但更优雅的做法是先发一个 `shutdown` RPC 通知让插件执行清理。

**建议:** `terminate` 时先发 `notify("host.shutdown", %{})` 通知，等待短暂时间（如 500ms），再 close port。

---

## ✅ Good — 值得肯定

### G1. JSON-RPC 2.0 协议设计清晰

NodeBridge ↔ plugin-host 的通信协议选用 JSON-RPC 2.0，支持请求/响应/通知三种模式，实现简洁且符合标准。`send_rpc` / `respond` / `respondError` / `notify` 四个函数职责分明。

### G2. Port crash recovery 框架完善

NodeBridge 正确处理了 `{:exit_status, code}` 和 `{:EXIT, port, reason}` 两种 Port 终止信号，fail 所有 pending 请求并触发重启。这比很多 Port-based 实现都要健壮。

### G3. Plugin 类型抽象好

`Plugin` struct 和 behaviour 设计得很干净，`:beam` 和 `:node` 两种运行时通过同一个接口暴露，Manager 内部通过 pattern match 分派。扩展新运行时类型只需加一个分支。

### G4. 双层工具发现机制

`Tools.Registry` 的优先级链 (builtin > plugin_beam > plugin_node > mcp) 设计合理，统一了四种来源的工具发现。`resolve_tool_name` 还兼容了 Claude Code 的工具名映射。

### G5. CLI 同时支持 MCP 和 V2

CLI plugins 命令无缝整合了旧的 MCP 服务器管理和新的 Plugin V2，用户不需要关心底层差异。`list`, `info`, `doctor` 都能同时展示两种类型的插件。

### G6. Store 的纯函数设计

`Store` 模块的 `put_plugin`, `remove_plugin`, `set_enabled`, `set_config` 都是纯函数（接收 registry，返回新 registry），只有 `load/save` 有副作用。这使得单元测试很干净。

### G7. 测试覆盖合理

- NodeBridge 测试覆盖了 load/unload/list/call 的正常和异常路径
- Manager 测试覆盖了 CRUD + enable/disable + reload
- Store 测试用 tmp_dir 隔离了文件系统副作用
- Channel Registry 测试覆盖了完整的 register/unregister/send/ready 生命周期

### G8. 错误处理的 catch 模式一致

Client API 函数一致使用 `catch :exit, {:noproc, _}` 和 `catch :exit, {:timeout, _}` 来优雅处理进程未启动或超时的情况，不会让调用方 crash。

---

## 测试覆盖度分析

| 模块 | 测试文件 | 覆盖情况 | 遗漏 |
|------|---------|---------|------|
| NodeBridge | ✅ node_bridge_test.exs | 核心 CRUD + 异常 | 缺少 Port crash recovery 测试、并发请求测试、buffer 拼接测试 |
| Manager | ✅ manager_test.exs | CRUD + reload + specs | 缺少 install/uninstall 测试（涉及文件系统和 npm）、Node 插件集成测试 |
| Store | ✅ store_test.exs | CRUD + roundtrip + read_plugin_json | `save/1` 的实际文件写入没有通过 `Store.save` 测试（手动 File.write） |
| Channels.Registry | ✅ registry_test.exs | 完整覆盖 | — |
| CLI.Plugins | ❌ 无测试 | — | 完全没有测试覆盖 |
| Skills.Loader | ❌ 无测试 | — | 新代码无测试 |
| Tools.Registry | ❌ 无测试 | — | 插件工具集成路径无测试 |

**关键遗漏:**
1. CLI 是用户直接面对的界面，零测试覆盖风险较高
2. NodeBridge 的 Port crash + 自动恢复是核心功能，但没有测试
3. Manager ↔ NodeBridge 的集成路径（Node 插件从安装到调用）没有端到端测试

---

## 总结

| 级别 | 数量 |
|------|------|
| 🔴 Critical | 5 |
| 🟡 Important | 8 |
| 🟢 Suggestion | 8 |
| ✅ Good | 8 |

整体设计思路清晰、架构分层合理。主要风险集中在：
1. **NodeBridge ↔ plugin-host 的可靠性**（启动握手、超时清理、buffer 安全）
2. **安装/卸载的原子性**（半成品状态的清理）
3. **Node 插件隔离**（当前零隔离，需要路线图）

建议优先处理 C3 (启动握手)、C5 (安装原子性)、I7 (CLI return bug)、I8 (Node 插件未加载) — 这四个是功能正确性问题。安全隔离 (C4) 可以作为 V2.1 的路线图项。
