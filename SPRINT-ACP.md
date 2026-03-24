# Sprint ACP — Agent Communication Protocol Runtime

## 概要
ACP 是 OpenClaw 的核心能力之一：让 ClawdEx 能够驱动外部 AI coding agents（Claude Code、Codex、Pi、Gemini CLI 等）作为子代理。

## ACP 架构

```
用户请求 → sessions_spawn(runtime: "acp", agentId: "codex")
  → ACP Runtime Manager 查找已注册的 backend
  → backend.ensureSession() 启动外部 CLI 进程
  → backend.runTurn(text) 发送消息，流式接收响应
  → 响应流式推送到父会话/渠道
```

## 核心组件

### 1. ACP Runtime Protocol (已有类型定义)
```
AcpRuntime interface:
  - ensureSession(input) → handle
  - runTurn(handle, text) → AsyncStream<AcpRuntimeEvent>  
  - cancel(handle) → void
  - close(handle) → void
  - getStatus(handle) → status
  - doctor() → health report
```

### 2. ACP Runtime Registry
管理多个 ACP backend（acpx、direct CLI 等），按优先级选择健康的 backend。

### 3. acpx Backend
通过 `acpx` CLI 驱动外部 agent：
- 启动 Claude Code / Codex / Pi / Gemini 进程
- 通过 stdin/stdout JSON lines 通信
- 管理进程生命周期

### 4. sessions_spawn runtime="acp" 支持
扩展现有 sessions_spawn，当 runtime="acp" 时路由到 ACP Runtime。

---

## 实现任务

### Wave 1: ACP Core (Backend #1)

#### Task 1.1: ACP Runtime Behaviour
`lib/clawd_ex/acp/runtime.ex`
```elixir
defmodule ClawdEx.ACP.Runtime do
  @callback ensure_session(map()) :: {:ok, handle()} | {:error, term()}
  @callback run_turn(handle(), String.t(), keyword()) :: {:ok, stream()} | {:error, term()}
  @callback cancel(handle()) :: :ok
  @callback close(handle()) :: :ok
  @callback get_status(handle()) :: {:ok, map()} | {:error, term()}
  @callback doctor() :: {:ok, map()} | {:error, term()}
end
```

#### Task 1.2: ACP Runtime Registry
`lib/clawd_ex/acp/registry.ex`
- GenServer，管理已注册的 ACP backend
- register_backend(id, module, opts)
- get_backend(agent_id) — 按 agent_id 映射到 backend
- list_backends() — 列出所有可用 backend
- health_check() — 检查所有 backend 健康状态

#### Task 1.3: ACP Event Types
`lib/clawd_ex/acp/event.ex`
```elixir
# 事件类型，对应 OpenClaw 的 AcpRuntimeEvent
defmodule ClawdEx.ACP.Event do
  @type t :: text_delta() | status() | tool_call() | done() | error()
  
  defstruct [:type, :text, :stream, :tag, :stop_reason, :code, :retryable]
end
```

### Wave 2: CLI Agent Backend (Backend #2)

#### Task 2.1: CLI Process Manager
`lib/clawd_ex/acp/backends/cli.ex`
- 通过 Port/System.cmd 启动外部 CLI (claude, codex, pi, gemini)
- stdin/stdout 通信
- JSON lines 事件解析
- 进程生命周期管理（start, stop, restart）

#### Task 2.2: Agent 命令映射
```elixir
@agent_commands %{
  "claude" => {"claude", ["--print", "--output-format", "stream-json"]},
  "codex" => {"codex", ["--full-auto"]},
  "pi" => {"pi", ["--json"]},
  "gemini" => {"gemini", []}
}
```
- 自动检测哪些 CLI 可用（which）
- 自动选择 permission mode

#### Task 2.3: 流式事件解析
解析外部 CLI 的 JSON lines 输出为 ACP Event：
- Claude Code: `{"type":"assistant","content":...}`
- Codex: `{"type":"message","content":...}`
- 统一转换为 ClawdEx.ACP.Event

### Wave 3: sessions_spawn ACP 集成 (Backend #3)

#### Task 3.1: 扩展 sessions_spawn
修改 `lib/clawd_ex/tools/sessions_spawn.ex`：
- 新增 `runtime` 参数 ("subagent" | "acp")
- runtime="acp" 时路由到 ACP Runtime
- 其余参数保持兼容（task, label, agentId, mode, thread, streamTo）

#### Task 3.2: ACP Session 管理
`lib/clawd_ex/acp/session.ex`
- GenServer per ACP session
- 管理外部进程生命周期
- 消息队列（external agent 一次只能处理一条）
- 超时处理
- crash 恢复

#### Task 3.3: ACP → 渠道集成
- ACP 流式事件转发到 Telegram/Discord/WebChat
- tool_call 事件显示工具调用进度
- done 事件触发完成通知
- error 事件触发错误通知

### Wave 4: 测试 + 管理 (QA + Frontend)

#### Task 4.1: ACP Doctor
`mix clawd_ex.acp.doctor` — 检查哪些 CLI agent 可用

#### Task 4.2: ACP 管理 UI
- `/acp` LiveView 页面
- 列出活跃 ACP sessions
- 查看 session 详情（事件流）
- 手动关闭/取消

#### Task 4.3: 测试
- ACP Runtime behaviour 测试
- CLI backend mock 测试
- sessions_spawn runtime="acp" 集成测试
- 事件流解析测试
