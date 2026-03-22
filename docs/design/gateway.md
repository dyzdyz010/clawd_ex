# ClawdEx Gateway 架构设计

> Status: Draft
> Author: Architect Agent
> Date: 2026-03-22

---

## 1. 概述

Gateway 是 ClawdEx 的对外服务层，职责：

1. **API 暴露** — REST + WebSocket，供外部客户端（CLI、移动端、Web UI、第三方集成）访问
2. **Node 连接管理** — 手机/平板等远程设备通过 WebSocket 配对、连接、保持心跳
3. **消息路由** — 外部请求 → 正确的 session/agent，实时事件 → 正确的客户端
4. **认证与鉴权** — Token / API Key / 设备配对密钥，分层权限

### 设计原则

- **Phoenix-native** — 不另起服务，在现有 Phoenix Endpoint 上叠加 Gateway 功能
- **WebSocket-first** — 实时操作走 Phoenix Channel，REST 做 CRUD 和外部集成
- **渐进式认证** — 开发时可跳过，生产环境强制
- **与 OpenClaw 协议兼容** — 参考 OpenClaw Gateway 的 RPC 模式，便于未来互通

---

## 2. 现有基础设施分析

### 已有的

| 模块 | 功能 | 状态 |
|---|---|---|
| `ClawdExWeb.Endpoint` | Phoenix HTTP/WS 入口，已配 LiveView socket | ✅ 可用 |
| `ClawdExWeb.Router` | Browser pipeline + API pipeline，已有 `/api/health` 和 webhook 路由 | ✅ 可用 |
| `ClawdExWeb.Plugs.BearerAuth` | 单 token 认证（`gateway_token` 配置） | ✅ 可用 |
| `ClawdExWeb.Plugs.Auth` | 多 token 认证（`auth.tokens` 列表） | ✅ 可用 |
| `ClawdEx.Nodes.Registry` | GenServer 节点注册表，管理配对/连接/断开 | ✅ 可用 |
| `ClawdEx.Nodes.Node` | 节点结构体（id/name/type/status/capabilities） | ✅ 可用 |
| `ClawdEx.Sessions.SessionManager` | DynamicSupervisor 管理 SessionWorker 进程 | ✅ 可用 |
| `ClawdEx.Tools.Gateway` | gateway 工具（restart/config CRUD/broadcast） | ✅ 可用 |
| `ClawdEx.CLI.Gateway` | CLI 的 `gateway status/restart` 命令 | ✅ 可用 |
| `Phoenix.PubSub` (`ClawdEx.PubSub`) | 已配置，gateway 工具已用于 broadcast | ✅ 可用 |

### 需要新建的

| 模块 | 功能 |
|---|---|
| `ClawdExWeb.Channels.GatewaySocket` | Gateway 专用 WebSocket 入口 |
| `ClawdExWeb.Channels.SessionChannel` | Session 实时消息通道 |
| `ClawdExWeb.Channels.NodeChannel` | Node 设备通道 |
| `ClawdExWeb.Channels.SystemChannel` | 系统事件广播通道 |
| `ClawdExWeb.Controllers.SessionController` | Session CRUD REST API |
| `ClawdExWeb.Controllers.AgentController` | Agent 管理 REST API |
| `ClawdExWeb.Controllers.ToolController` | Tool 调用 REST API |
| `ClawdExWeb.Controllers.NodeController` | Node 管理 REST API |
| `ClawdExWeb.Controllers.GatewayController` | Gateway 自身状态/配置 REST API |
| `ClawdExWeb.Plugs.NodeAuth` | 设备配对 token 认证 |
| `ClawdEx.Gateway.TokenManager` | Token 生成/校验/轮转 |

---

## 3. API 端点设计 (REST)

所有 REST 端点在 `/api/v1` 下，使用 `gateway_auth` pipeline（Bearer token）。

### 3.1 Health & Status

```
GET  /api/health                          # 公开，无需认证
GET  /api/v1/gateway/status               # Gateway 状态 + 统计
GET  /api/v1/gateway/config               # 当前配置
PATCH /api/v1/gateway/config              # 更新配置
POST /api/v1/gateway/restart              # 重启
```

**`GET /api/health`** 响应：
```json
{
  "status": "ok | degraded | error",
  "checks": {
    "database": { "status": "ok" },
    "node_registry": { "status": "ok", "details": "3 connected" },
    "session_manager": { "status": "ok", "details": "12 active" }
  },
  "timestamp": "2026-03-22T03:56:00Z"
}
```

**`GET /api/v1/gateway/status`** 响应：
```json
{
  "version": "0.1.0",
  "uptime_seconds": 86400,
  "port": 4000,
  "auth_enabled": true,
  "nodes": { "total": 5, "connected": 3, "pending": 1 },
  "sessions": { "active": 12, "total": 45 },
  "agents": { "total": 8, "active": 6 }
}
```

### 3.2 Sessions

```
GET    /api/v1/sessions                   # 列出活跃会话（支持分页/筛选）
POST   /api/v1/sessions                   # 创建新会话
GET    /api/v1/sessions/:id               # 获取会话详情
DELETE /api/v1/sessions/:id               # 终止会话
POST   /api/v1/sessions/:id/messages      # 发送消息到会话
GET    /api/v1/sessions/:id/messages      # 获取会话消息历史
POST   /api/v1/sessions/:id/reset         # 重置会话
```

**`POST /api/v1/sessions`** 请求体：
```json
{
  "agent": "architect",
  "channel": "api",
  "session_key": "api:user123:chat1",     // 可选，不提供则自动生成
  "metadata": {}
}
```

**`POST /api/v1/sessions/:id/messages`** 请求体：
```json
{
  "role": "user",
  "content": "Hello, world!",
  "attachments": []                        // 可选
}
```

响应（同步模式）：
```json
{
  "id": "msg_abc123",
  "role": "assistant",
  "content": "...",
  "tool_calls": [],
  "usage": { "input_tokens": 100, "output_tokens": 200 }
}
```

> **流式模式**：对于长时间运行的 LLM 调用，`POST /messages` 返回 `202 Accepted` + `session_id`，实际响应通过 WebSocket Channel 推送。客户端也可用 `Accept: text/event-stream` 请求 SSE 流式响应。

### 3.3 Agents

```
GET    /api/v1/agents                     # 列出所有 agent
POST   /api/v1/agents                     # 创建 agent
GET    /api/v1/agents/:id                 # 获取 agent 详情
PUT    /api/v1/agents/:id                 # 更新 agent
DELETE /api/v1/agents/:id                 # 删除 agent
GET    /api/v1/agents/:id/sessions        # 获取 agent 的活跃会话
```

### 3.4 Tools

```
GET    /api/v1/tools                      # 列出已注册工具
GET    /api/v1/tools/:name                # 工具详情（参数 schema）
POST   /api/v1/tools/:name/execute        # 直接调用工具（高权限）
```

### 3.5 Nodes (设备管理)

```
GET    /api/v1/nodes                      # 列出所有节点
GET    /api/v1/nodes/pending              # 列出待配对节点
GET    /api/v1/nodes/:id                  # 获取节点详情
POST   /api/v1/nodes/:id/approve          # 批准配对
POST   /api/v1/nodes/:id/reject           # 拒绝配对
DELETE /api/v1/nodes/:id                  # 移除节点
POST   /api/v1/nodes/pair                 # 生成配对码
```

### 3.6 Router 集成

```elixir
# router.ex 新增部分

scope "/api/v1", ClawdExWeb do
  pipe_through [:api, :gateway_auth]

  # Gateway
  get    "/gateway/status",        GatewayController, :status
  get    "/gateway/config",        GatewayController, :config
  patch  "/gateway/config",        GatewayController, :update_config
  post   "/gateway/restart",       GatewayController, :restart

  # Sessions
  resources "/sessions", SessionController, only: [:index, :show, :create, :delete]
  post   "/sessions/:id/messages", SessionController, :send_message
  get    "/sessions/:id/messages", SessionController, :messages
  post   "/sessions/:id/reset",   SessionController, :reset

  # Agents
  resources "/agents", AgentController, only: [:index, :show, :create, :update, :delete]
  get    "/agents/:id/sessions",   AgentController, :sessions

  # Tools
  get    "/tools",                 ToolController, :index
  get    "/tools/:name",           ToolController, :show
  post   "/tools/:name/execute",   ToolController, :execute

  # Nodes
  get    "/nodes",                 NodeController, :index
  get    "/nodes/pending",         NodeController, :pending
  get    "/nodes/:id",             NodeController, :show
  post   "/nodes/:id/approve",     NodeController, :approve
  post   "/nodes/:id/reject",      NodeController, :reject
  delete "/nodes/:id",             NodeController, :delete
  post   "/nodes/pair",            NodeController, :pair
end
```

---

## 4. WebSocket 协议

### 4.1 Socket 入口

在 `ClawdExWeb.Endpoint` 中新增 Gateway 专用 socket：

```elixir
# endpoint.ex
socket "/gateway/ws", ClawdExWeb.Channels.GatewaySocket,
  websocket: [
    connect_info: [:peer_data, :x_headers],
    timeout: 60_000
  ]
```

### 4.2 Channel 拓扑

```
/gateway/ws
  ├── "session:<session_key>"     # 会话实时消息
  ├── "node:<node_id>"            # 设备通道
  ├── "system:events"             # 全局系统事件（新 session、agent 状态变更等）
  └── "admin:control"             # 管理操作（高权限）
```

### 4.3 Session Channel 协议

客户端加入 `session:<key>` 后的消息流：

#### 客户端 → 服务端

| 事件 | Payload | 说明 |
|---|---|---|
| `message` | `{ "content": "...", "role": "user", "attachments": [] }` | 发送用户消息 |
| `cancel` | `{}` | 取消当前生成 |
| `typing` | `{ "is_typing": true }` | 打字状态 |

#### 服务端 → 客户端

| 事件 | Payload | 说明 |
|---|---|---|
| `message:start` | `{ "id": "msg_xxx", "role": "assistant" }` | 开始生成 |
| `message:delta` | `{ "id": "msg_xxx", "delta": "..." }` | 流式增量文本 |
| `message:complete` | `{ "id": "msg_xxx", "content": "...", "usage": {} }` | 生成完成 |
| `message:error` | `{ "id": "msg_xxx", "error": "..." }` | 生成出错 |
| `tool_call:start` | `{ "id": "tc_xxx", "name": "read", "params": {} }` | 工具调用开始 |
| `tool_call:result` | `{ "id": "tc_xxx", "result": "..." }` | 工具调用结果 |
| `session:reset` | `{}` | 会话已重置 |
| `session:compacted` | `{ "removed_count": 5 }` | 上下文压缩 |

### 4.4 Node Channel 协议

设备加入 `node:<node_id>` 后的消息流：

#### 设备 → 服务端

| 事件 | Payload | 说明 |
|---|---|---|
| `heartbeat` | `{ "timestamp": ..., "battery": 85 }` | 心跳 + 设备状态 |
| `capability:update` | `{ "capabilities": ["camera", "tts"] }` | 能力更新 |
| `tool:result` | `{ "request_id": "...", "result": "..." }` | 工具执行结果返回 |
| `event` | `{ "type": "notification", "data": {} }` | 设备端事件 |

#### 服务端 → 设备

| 事件 | Payload | 说明 |
|---|---|---|
| `tool:execute` | `{ "request_id": "...", "name": "camera.snap", "params": {} }` | 请求设备执行工具 |
| `config:update` | `{ "config": {} }` | 推送配置变更 |
| `ping` | `{}` | 服务端主动 ping |

### 4.5 System Channel

`system:events` 广播全局事件（需认证）：

| 事件 | Payload |
|---|---|
| `session:created` | `{ "session_key": "...", "agent": "..." }` |
| `session:ended` | `{ "session_key": "..." }` |
| `node:connected` | `{ "node_id": "...", "name": "..." }` |
| `node:disconnected` | `{ "node_id": "..." }` |
| `agent:status_changed` | `{ "agent_id": "...", "status": "..." }` |
| `broadcast` | `{ "message": "..." }` |

---

## 5. 设备配对与连接管理

### 5.1 配对流程

```
┌──────────┐                    ┌──────────────┐                    ┌──────────┐
│  Device   │                    │   Gateway     │                    │  Admin   │
└────┬─────┘                    └──────┬───────┘                    └────┬─────┘
     │                                  │                                 │
     │  1. POST /api/v1/nodes/pair     │                                 │
     │  (or scan QR from web UI)       │                                 │
     │ ────────────────────────────────>│                                 │
     │                                  │                                 │
     │  2. { pair_code, pair_token,    │                                 │
     │       expires_at }              │                                 │
     │ <────────────────────────────────│                                 │
     │                                  │                                 │
     │  3. WS connect /gateway/ws      │                                 │
     │     + pair_token in params      │                                 │
     │ ────────────────────────────────>│                                 │
     │                                  │  4. PubSub: node:pending        │
     │                                  │ ───────────────────────────────>│
     │                                  │                                 │
     │                                  │  5. POST /nodes/:id/approve     │
     │                                  │ <───────────────────────────────│
     │                                  │                                 │
     │  6. { status: "paired",         │                                 │
     │       node_token: "..." }       │                                 │
     │ <────────────────────────────────│                                 │
     │                                  │                                 │
     │  7. Join "node:<id>" channel    │                                 │
     │     with node_token             │                                 │
     │ ────────────────────────────────>│                                 │
```

### 5.2 Token 体系

| Token 类型 | 用途 | 有效期 | 存储 |
|---|---|---|---|
| **Gateway Token** | REST API 认证（管理员） | 持久 / 手动轮转 | 配置文件 |
| **API Key** | 第三方集成认证 | 持久 / 可吊销 | 数据库 |
| **Pair Token** | 设备配对过程中的临时凭证 | 5 分钟 | 内存 (ETS) |
| **Node Token** | 已配对设备的长期连接凭证 | 30 天 / 可刷新 | 数据库 |
| **Session Token** | 会话级别的临时凭证（可选） | 随会话生命周期 | 内存 |

### 5.3 连接保活

```elixir
# Node Channel 心跳策略
- 设备每 30s 发送 heartbeat
- 服务端 90s 无心跳 → 标记 disconnected
- 服务端 300s 无心跳 → 从活跃列表移除（不删除配对关系）
- Phoenix Channel 自带 transport-level heartbeat（默认 30s）作为底层保活
```

---

## 6. 认证方案

### 6.1 分层认证

```
                    ┌─────────────────────┐
                    │   No Auth (Public)   │
                    │   - GET /api/health  │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │  Gateway Auth        │
                    │  (Bearer Token)      │
                    │  - All /api/v1/*     │
                    │  - WS /gateway/ws    │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │  Node Auth           │
                    │  (Node Token)        │
                    │  - node:* channels   │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │  Admin Auth          │
                    │  (Elevated scope)    │
                    │  - tool execution    │
                    │  - config changes    │
                    │  - admin:control     │
                    └─────────────────────┘
```

### 6.2 WebSocket 认证

Socket 连接时通过 `connect/3` 验证：

```elixir
defmodule ClawdExWeb.Channels.GatewaySocket do
  use Phoenix.Socket

  channel "session:*", ClawdExWeb.Channels.SessionChannel
  channel "node:*",    ClawdExWeb.Channels.NodeChannel
  channel "system:*",  ClawdExWeb.Channels.SystemChannel
  channel "admin:*",   ClawdExWeb.Channels.AdminChannel

  @impl true
  def connect(%{"token" => token} = params, socket, _connect_info) do
    case ClawdEx.Gateway.TokenManager.verify(token) do
      {:ok, %{type: :gateway, scopes: scopes}} ->
        {:ok, assign(socket, :auth, %{type: :gateway, scopes: scopes})}

      {:ok, %{type: :node, node_id: node_id}} ->
        {:ok, assign(socket, :auth, %{type: :node, node_id: node_id})}

      {:ok, %{type: :pair, pair_id: pair_id}} ->
        {:ok, assign(socket, :auth, %{type: :pair, pair_id: pair_id})}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket) do
    case socket.assigns.auth do
      %{type: :node, node_id: id} -> "node:#{id}"
      %{type: :gateway}           -> nil   # 允许多连接
      _                            -> nil
    end
  end
end
```

### 6.3 Channel 级权限检查

```elixir
# SessionChannel - join 时检查
def join("session:" <> session_key, _params, socket) do
  case socket.assigns.auth do
    %{type: :gateway} ->
      # Gateway token 可访问所有 session
      {:ok, assign(socket, :session_key, session_key)}

    %{type: :node, node_id: _} ->
      # Node 只能访问自己关联的 session
      :error

    _ ->
      :error
  end
end
```

---

## 7. 与 Phoenix Endpoint 的集成

### 7.1 架构层次

```
┌──────────────────────────────────────────────────────┐
│                 ClawdExWeb.Endpoint                    │
│                                                        │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────┐   │
│  │ /live     │  │ /api/*   │  │ /gateway/ws       │   │
│  │ LiveView  │  │ REST     │  │ Phoenix Channels  │   │
│  │ Socket    │  │ Router   │  │ (Gateway Socket)  │   │
│  └────┬─────┘  └────┬─────┘  └────────┬──────────┘   │
│       │              │                  │               │
│       └──────────────┼──────────────────┘               │
│                      │                                   │
│              ClawdExWeb.Router                           │
│                      │                                   │
│    ┌─────────────────┼─────────────────┐                │
│    │                 │                 │                 │
│  :browser        :api_auth      :gateway_auth          │
│  pipeline        pipeline        pipeline               │
│                                                          │
└──────────────────────────────────────────────────────────┘
                       │
          ┌────────────┼────────────┐
          │            │            │
   SessionManager  Nodes.Registry  PubSub
```

### 7.2 关键决策

1. **单 Endpoint** — 不启动第二个 HTTP 服务器，所有流量走同一个 port（默认 4000）
   - 优点：简单，运维成本低，Phoenix 已有完善的 HTTP/WS 支持
   - 如需独立端口（安全隔离），可后续通过第二个 Endpoint 实现

2. **独立 Socket** — Gateway WebSocket 不复用 LiveView socket
   - `/live` → LiveView（浏览器 UI，cookie session 认证）
   - `/gateway/ws` → Gateway channels（API 客户端 / 设备，token 认证）

3. **PubSub 桥接** — LiveView 和 Gateway Channel 通过 PubSub 共享事件
   - LiveView 页面订阅 `session:*` 可实时显示 API session 的状态
   - Gateway broadcast → PubSub → LiveView update

4. **版本化 API** — `/api/v1/` 前缀，便于未来不破坏兼容性地升级

---

## 8. 消息路由

### 8.1 入站路由（外部 → Agent）

```
REST POST /sessions/:id/messages
    │
    ▼
SessionController.send_message/2
    │
    ├── 查找 session_key → SessionManager.find_session/1
    │
    ├── 不存在 → 404 或自动创建
    │
    ├── 存在 → SessionWorker.handle_message/2
    │       │
    │       ├── LLM 调用 (流式)
    │       │     │
    │       │     ├── PubSub.broadcast("session:<key>", {:delta, ...})
    │       │     │     │
    │       │     │     └── SessionChannel → 客户端 (message:delta)
    │       │     │
    │       │     └── 完成 → PubSub.broadcast("session:<key>", {:complete, ...})
    │       │
    │       └── 工具调用
    │             │
    │             ├── 本地工具 → 直接执行
    │             │
    │             └── Node 工具 → PubSub → NodeChannel → 设备
    │                   │
    │                   └── 设备返回结果 → 继续 LLM 循环
    │
    └── REST 响应（同步: 完整结果 / 异步: 202 + session_id）
```

### 8.2 出站路由（Agent → 外部）

```
Agent 需要发送消息到外部 channel (Telegram/Discord/etc)
    │
    ▼
Message Tool → Plugin System → Channel Plugin → 外部服务
    │
    同时
    │
    ▼
PubSub.broadcast("session:<key>", {:outbound, ...})
    │
    └── SessionChannel → 已订阅的 WebSocket 客户端
```

---

## 9. 错误处理与可靠性

### 9.1 错误响应格式

所有 REST API 错误统一格式：

```json
{
  "error": {
    "code": "session_not_found",
    "message": "Session abc123 does not exist",
    "details": {}
  }
}
```

HTTP 状态码映射：

| 状态码 | 含义 |
|---|---|
| 400 | 请求参数无效 |
| 401 | 未认证 |
| 403 | 权限不足 |
| 404 | 资源不存在 |
| 409 | 冲突（如 session 已存在） |
| 429 | 速率限制 |
| 500 | 内部错误 |
| 503 | 服务不可用 |

### 9.2 速率限制

```elixir
# 基于 token 的速率限制（使用 ETS 计数器）
# 默认限制：
#   - REST API: 100 req/min per token
#   - WebSocket messages: 60 msg/min per connection
#   - Tool execution: 30 req/min per token
```

### 9.3 WebSocket 重连

- 客户端断连后自动重连（客户端实现，建议指数退避）
- 重连后服务端推送 `session:sync` 事件，包含缺失的消息
- Node 设备断连后保持 paired 状态，重连后自动恢复

---

## 10. 实现计划

### Phase 1: Core REST API（优先级 P0）

> 目标：让外部客户端可以通过 REST API 与 agent 交互

**新增模块：**

| 文件 | 说明 |
|---|---|
| `lib/clawd_ex_web/controllers/gateway_controller.ex` | Gateway 状态/配置 |
| `lib/clawd_ex_web/controllers/session_controller.ex` | Session CRUD + 消息发送 |
| `lib/clawd_ex_web/controllers/agent_controller.ex` | Agent 管理 |
| `lib/clawd_ex_web/controllers/node_controller.ex` | Node 管理 |
| `lib/clawd_ex_web/controllers/tool_controller.ex` | Tool 列表/调用 |
| `lib/clawd_ex_web/controllers/fallback_controller.ex` | 统一错误处理 |

**修改模块：**
- `router.ex` — 新增 `/api/v1/*` 路由

**工作量估计：** 3-4 天

---

### Phase 2: WebSocket Channels（优先级 P0）

> 目标：实时消息推送，客户端无需轮询

**新增模块：**

| 文件 | 说明 |
|---|---|
| `lib/clawd_ex_web/channels/gateway_socket.ex` | Socket 入口 + 认证 |
| `lib/clawd_ex_web/channels/session_channel.ex` | Session 实时消息 |
| `lib/clawd_ex_web/channels/system_channel.ex` | 系统事件广播 |

**修改模块：**
- `endpoint.ex` — 新增 `/gateway/ws` socket
- `SessionWorker` — 在处理消息时广播 PubSub 事件

**工作量估计：** 2-3 天

---

### Phase 3: Node Channel + 设备配对（优先级 P1）

> 目标：手机/平板可以配对并通过 WebSocket 连接

**新增模块：**

| 文件 | 说明 |
|---|---|
| `lib/clawd_ex_web/channels/node_channel.ex` | 设备通道 |
| `lib/clawd_ex/gateway/token_manager.ex` | Token 生成/校验 |
| `lib/clawd_ex/gateway/pair_server.ex` | 配对状态管理 (GenServer) |
| `lib/clawd_ex_web/plugs/node_auth.ex` | 设备 token 认证 plug |

**修改模块：**
- `Nodes.Registry` — 添加 pair_token 字段和过期逻辑
- `Nodes.Node` — 添加 `node_token` 字段

**工作量估计：** 3-4 天

---

### Phase 4: 认证增强（优先级 P1）

> 目标：生产级认证体系

**新增模块：**

| 文件 | 说明 |
|---|---|
| `lib/clawd_ex/gateway/api_key.ex` | API Key schema + CRUD |
| `lib/clawd_ex/gateway/scope.ex` | 权限 scope 定义 |
| `lib/clawd_ex_web/plugs/rate_limiter.ex` | 速率限制 plug |
| `lib/clawd_ex_web/plugs/scope_check.ex` | scope 权限检查 plug |

**数据库迁移：**
- `api_keys` 表（token, scopes, created_at, expires_at, revoked）
- `node_tokens` 表（node_id, token, expires_at）

**工作量估计：** 2-3 天

---

### Phase 5: SSE + 流式支持（优先级 P2）

> 目标：REST 客户端也能获取流式响应（不依赖 WebSocket）

**新增模块：**

| 文件 | 说明 |
|---|---|
| `lib/clawd_ex_web/controllers/stream_controller.ex` | SSE 端点 |
| `lib/clawd_ex_web/plugs/sse.ex` | SSE 连接管理 |

**路由：**
```
GET /api/v1/sessions/:id/stream    # SSE 流（Accept: text/event-stream）
```

**工作量估计：** 1-2 天

---

### Phase 6: Admin Channel + 高级管理（优先级 P2）

> 目标：通过 WebSocket 实时管理 ClawdEx

**新增模块：**

| 文件 | 说明 |
|---|---|
| `lib/clawd_ex_web/channels/admin_channel.ex` | 管理通道 |

**功能：**
- 实时日志推送
- 远程配置变更
- Agent 热加载
- 系统监控面板数据源

**工作量估计：** 2 天

---

### 总体时间线

```
Phase 1 (Core REST)         ████████░░░░░░░░░░░░  Week 1
Phase 2 (WebSocket)         ░░░░░░████████░░░░░░  Week 1-2
Phase 3 (Node + Pair)       ░░░░░░░░░░████████░░  Week 2
Phase 4 (Auth)              ░░░░░░░░░░░░░░██████  Week 2-3
Phase 5 (SSE)               ░░░░░░░░░░░░░░░░░███  Week 3
Phase 6 (Admin)             ░░░░░░░░░░░░░░░░░░██  Week 3
```

**Phase 1+2 是 MVP**，完成后即可通过 REST + WebSocket 与 ClawdEx 交互。

---

## 附录 A: 与 OpenClaw Gateway 的对比

| 功能 | OpenClaw | ClawdEx |
|---|---|---|
| 传输 | 独立 WebSocket 服务 (port 18789) | Phoenix Endpoint 内嵌 (port 4000) |
| 协议 | 自定义 JSON-RPC over WS | Phoenix Channel 协议 |
| 认证 | Token / Password | Bearer Token + Node Token + API Key |
| 设备发现 | Bonjour mDNS | 计划 Phase 后期支持 |
| 锁机制 | TCP bind 独占 | Phoenix Endpoint 自带 |
| REST | 无（纯 WS） | 完整 REST + WS 双栈 |
| SSE | 无 | Phase 5 支持 |

### 设计差异说明

OpenClaw 的 Gateway 是独立的 WebSocket 进程，使用自定义 JSON-RPC 协议。ClawdEx 选择基于 Phoenix Channel 构建，原因：

1. **Phoenix Channel 已经是生产级 WebSocket 框架** — 自带 heartbeat、reconnect、multiplexing、presence
2. **REST 是刚需** — 第三方集成（Zapier、Make、自定义脚本）更倾向 REST
3. **OTP 优势** — GenServer + DynamicSupervisor + PubSub 天然适合实时系统
4. **统一入口** — 一个端口同时服务 Web UI、REST API、WebSocket，部署简单

---

## 附录 B: 配置示例

```elixir
# config/runtime.exs

config :clawd_ex, ClawdExWeb.Endpoint,
  http: [port: System.get_env("PORT") || 4000],
  server: true

config :clawd_ex, :gateway_token,
  System.get_env("CLAWD_GATEWAY_TOKEN") || "dev-token"

config :clawd_ex, :auth,
  enabled: System.get_env("AUTH_ENABLED", "false") == "true",
  tokens: String.split(System.get_env("AUTH_TOKENS", ""), ",")

config :clawd_ex, :gateway,
  pair_token_ttl: 300,           # 配对码有效期（秒）
  node_token_ttl: 2_592_000,     # 节点 token 有效期（秒，30天）
  heartbeat_interval: 30_000,    # 心跳间隔（毫秒）
  heartbeat_timeout: 90_000,     # 心跳超时（毫秒）
  rate_limit: %{
    rest: {100, :minute},        # REST API 速率限制
    ws: {60, :minute},           # WebSocket 消息速率限制
    tools: {30, :minute}         # 工具调用速率限制
  }
```
