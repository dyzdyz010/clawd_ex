# ClawdEx 下一阶段功能设计

> 三大核心特性：多阶段输出、任务管理器、A2A 通信

## 1. 多阶段输出 (Progressive Output)

### 现状分析
当前 Agent Loop 已有 PubSub 广播机制：
- `broadcast_segment` — 工具调用前的文本段
- `broadcast_chunk` — 流式 token
- `broadcast_tools_done` — 工具执行结果

但问题是：
1. 渠道层（Telegram）用 `SessionWorker.send_message` **同步等待**整个 run 完成
2. 中间段虽然广播了，但 Telegram 的 `receive_loop` 处理不够灵活
3. Agent 无法主动说"这部分结果先给用户看"

### 设计方案

#### 1.1 OutputManager — 输出管道

```elixir
defmodule ClawdEx.Agent.OutputManager do
  @moduledoc """
  管理 Agent 运行期间的渐进式输出。
  
  每个 run 对应一个 OutputManager 进程，收集 Agent 的输出段，
  根据策略（立即/批量/延迟）推送到渠道。
  """
  use GenServer

  defstruct [
    :run_id,
    :session_id,
    :channel_pid,      # 渠道的回调进程
    :delivery_mode,    # :immediate | :batched | :final_only
    segments: [],       # 已收集的输出段
    delivered: [],      # 已投递的段
    flush_timer: nil
  ]
end
```

#### 1.2 Agent Loop 改造 — 显式 flush

在 Agent Loop 的 `inferring` → `executing_tools` 转换中，自动 flush 当前文本段：

```elixir
# 当 AI 返回文本 + tool_calls 时
def inferring(:info, {:ai_done, response}, data) do
  if response[:tool_calls] && length(response[:tool_calls]) > 0 do
    content = response[:content] || ""
    
    # ✨ 新增：通过 OutputManager 立即推送中间段
    if content != "" do
      OutputManager.deliver_segment(data.run_id, content, %{
        type: :intermediate,
        tool_calls_pending: length(response[:tool_calls])
      })
    end
    
    # 继续工具执行...
  end
end
```

#### 1.3 渠道层改造 — 异步接收

```elixir
# Telegram 不再同步等待，改为订阅 OutputManager 事件
def handle_message(message) do
  # 启动 session
  SessionWorker.send_message_async(session_key, message.content)
  
  # 订阅输出事件
  Phoenix.PubSub.subscribe(ClawdEx.PubSub, "output:#{session_id}")
  
  # 输出段到达时立即发送
  receive do
    {:output_segment, content, meta} ->
      send_message(chat_id, content)
      
    {:output_complete, final_content} ->
      send_message(chat_id, final_content)
  end
end
```

### 实现要点
- [ ] `ClawdEx.Agent.OutputManager` GenServer
- [ ] Agent Loop 在每次工具调用前自动 flush
- [ ] Agent Loop 在多轮工具调用间发送进度摘要
- [ ] Telegram/Discord 渠道改为纯异步模式
- [ ] WebChat LiveView 实时显示每个输出段
- [ ] 支持 `NO_REPLY` / `HEARTBEAT_OK` 等静默标记

---

## 2. 任务管理器 (Task Manager)

### 需求分析
OpenClaw 的 Agent 在执行中被打断（超时、crash、重启）后，任务就丢了。
我们需要一个持久化的任务队列：
- 任务有生命周期：`pending → assigned → running → completed/failed/paused`
- 系统定期检查 `running` 状态的任务，如果 agent session 已死，自动恢复
- 支持优先级、依赖关系、超时策略
- Web UI 可视化任务看板

### 数据模型

```elixir
# Migration: create_tasks
defmodule ClawdEx.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title, :string, null: false
      add :description, :text
      add :status, :string, default: "pending"  
      # pending | assigned | running | paused | completed | failed | cancelled
      add :priority, :integer, default: 5  # 1=最高, 10=最低
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :session_id, references(:sessions, on_delete: :nilify_all)
      add :parent_task_id, references(:tasks, on_delete: :nilify_all)  # 子任务
      add :metadata, :map, default: %{}
      # 任务上下文：agent 需要的信息
      add :context, :map, default: %{}
      # 执行结果
      add :result, :map, default: %{}
      # 重试相关
      add :max_retries, :integer, default: 3
      add :retry_count, :integer, default: 0
      add :timeout_seconds, :integer, default: 600
      # 调度
      add :scheduled_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :last_heartbeat_at, :utc_datetime  # agent 定期心跳
      
      timestamps()
    end

    create index(:tasks, [:status])
    create index(:tasks, [:agent_id])
    create index(:tasks, [:parent_task_id])
    create index(:tasks, [:priority, :inserted_at])
  end
end
```

### TaskManager 进程

```elixir
defmodule ClawdEx.Tasks.Manager do
  @moduledoc """
  任务管理器 — 定期检查任务状态，处理超时/恢复
  
  职责：
  1. 定期扫描 running 状态的任务，检测 session 是否存活
  2. 对于 session 已死的 running 任务，标记为 pending 等待重新调度
  3. 分配 pending 任务给空闲的 agent
  4. 处理任务超时
  5. 管理任务依赖关系
  """
  use GenServer
  
  @check_interval_ms 30_000  # 每 30 秒检查一次

  def init(_) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check_tasks, state) do
    check_running_tasks()
    check_timed_out_tasks()
    assign_pending_tasks()
    schedule_check()
    {:noreply, state}
  end

  # 检查 running 任务的 session 是否存活
  defp check_running_tasks do
    running_tasks = Repo.all(from t in Task, where: t.status == "running")
    
    for task <- running_tasks do
      case SessionManager.find_session(task.session_key) do
        {:ok, _pid} ->
          # Session 存活，检查心跳是否过期
          if heartbeat_expired?(task) do
            Logger.warning("Task #{task.id} heartbeat expired, marking stale")
            mark_task_stale(task)
          end
          
        :not_found ->
          # Session 已死，恢复任务
          Logger.info("Task #{task.id} session dead, re-queuing")
          requeue_task(task)
      end
    end
  end
end
```

### 任务心跳机制

Agent Loop 在执行任务时定期发送心跳：

```elixir
# Agent Loop 中
defp execute_tool(tool_call, data) do
  # 更新任务心跳
  if data.current_task_id do
    Tasks.Manager.heartbeat(data.current_task_id)
  end
  
  # 执行工具...
end
```

### 任务工具 — Agent 可创建/管理任务

```elixir
defmodule ClawdEx.Tools.TaskTool do
  @moduledoc "task 工具 — 让 Agent 可以创建和管理任务"
  
  # agent 可以：
  # - task_create: 创建新任务（包括子任务）
  # - task_list: 查看任务列表
  # - task_update: 更新任务状态
  # - task_delegate: 委派任务给其他 agent
end
```

### 实现要点
- [ ] `tasks` 数据库表 + Ecto Schema
- [ ] `ClawdEx.Tasks.Manager` GenServer (定期检查)
- [ ] `ClawdEx.Tasks.Task` Schema + CRUD
- [ ] Agent Loop 集成：心跳 + 任务上下文
- [ ] `task` 工具：create/list/update/delegate
- [ ] Web UI：任务看板页面
- [ ] 任务恢复逻辑：session 死亡 → 重新排队

---

## 3. A2A 通信 (Agent-to-Agent Communication)

### 需求分析
多个 Agent 之间需要：
1. **请求/响应** — Agent A 问 Agent B 一个问题，等待回复
2. **通知** — Agent A 告诉 Agent B 某件事发生了（fire-and-forget）
3. **委托** — Agent A 把一个任务委托给 Agent B
4. **发现** — Agent 能查到有哪些其他 Agent、它们擅长什么
5. **对话** — 两个 Agent 之间的多轮对话

### 架构设计

```
┌──────────────┐     A2A Bus (PubSub)     ┌──────────────┐
│   Agent A    │ ◄──────────────────────► │   Agent B    │
│  (session)   │                           │  (session)   │
└──────┬───────┘                           └──────┬───────┘
       │                                          │
       ▼                                          ▼
┌──────────────┐                           ┌──────────────┐
│  A2A Mailbox │                           │  A2A Mailbox │
│  (GenServer) │                           │  (GenServer) │
└──────────────┘                           └──────────────┘
       │                                          │
       └──────────────┬───────────────────────────┘
                      ▼
              ┌──────────────┐
              │  A2A Router  │
              │  (Registry)  │
              └──────────────┘
```

#### 3.1 A2A 消息协议

```elixir
defmodule ClawdEx.A2A.Message do
  @moduledoc """
  Agent 间通信消息格式
  """
  
  @type t :: %__MODULE__{
    id: String.t(),
    from: String.t(),         # source agent_id
    to: String.t(),           # target agent_id
    type: :request | :response | :notification | :delegation,
    content: String.t(),
    metadata: map(),
    reply_to: String.t() | nil,  # 关联的请求 ID
    timestamp: DateTime.t(),
    ttl: integer()            # 超时秒数
  }

  defstruct [:id, :from, :to, :type, :content, :metadata, :reply_to, :timestamp, :ttl]
end
```

#### 3.2 A2A Router — 消息路由

```elixir
defmodule ClawdEx.A2A.Router do
  @moduledoc """
  A2A 消息路由器 — 负责：
  1. Agent 注册与发现
  2. 消息路由与投递
  3. 请求/响应匹配
  4. 超时处理
  """
  use GenServer

  # Agent 注册
  def register(agent_id, capabilities \\ []) do
    GenServer.call(__MODULE__, {:register, agent_id, capabilities})
  end

  # 发送消息（异步）
  def send_message(from, to, content, opts \\ []) do
    GenServer.cast(__MODULE__, {:send, from, to, content, opts})
  end

  # 请求/响应（同步等待）
  def request(from, to, content, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:request, from, to, content, opts}, timeout)
  end

  # 发现 — 列出所有可用 Agent
  def discover(opts \\ []) do
    GenServer.call(__MODULE__, {:discover, opts})
  end
end
```

#### 3.3 A2A Mailbox — Agent 收件箱

```elixir
defmodule ClawdEx.A2A.Mailbox do
  @moduledoc """
  每个 Agent 的收件箱 — 缓存未处理的 A2A 消息
  
  当 Agent 正忙时，消息排队等待。
  Agent Loop 在 idle 状态时检查收件箱。
  """
  use GenServer

  defstruct [
    :agent_id,
    inbox: :queue.new(),      # 待处理消息队列
    pending_replies: %{}      # 等待回复的请求 {msg_id => from_pid}
  ]
end
```

#### 3.4 Agent Loop 集成

```elixir
# Agent Loop idle 状态检查 A2A 收件箱
def idle(:enter, _old_state, data) do
  # 检查 A2A 收件箱
  case A2A.Mailbox.peek(data.agent_id) do
    {:ok, message} ->
      # 有 A2A 消息，作为新的 run 处理
      handle_a2a_message(message, data)
    :empty ->
      :keep_state_and_data
  end
end
```

#### 3.5 A2A 工具 — Agent 可调用

```elixir
defmodule ClawdEx.Tools.A2A do
  @moduledoc """
  a2a 工具 — 让 Agent 能发现和与其他 Agent 通信
  
  actions:
  - discover: 列出可用 Agent 及其能力
  - send: 发送通知给另一个 Agent
  - request: 请求另一个 Agent 做某事（同步等待响应）
  - delegate: 委托任务给另一个 Agent（通过 TaskManager）
  """
end
```

#### 3.6 数据库持久化 — A2A 消息日志

```sql
CREATE TABLE a2a_messages (
  id BIGSERIAL PRIMARY KEY,
  message_id VARCHAR(64) NOT NULL UNIQUE,
  from_agent_id BIGINT REFERENCES agents(id),
  to_agent_id BIGINT REFERENCES agents(id),
  type VARCHAR(20) NOT NULL,  -- request/response/notification/delegation
  content TEXT,
  metadata JSONB DEFAULT '{}',
  reply_to VARCHAR(64),       -- 关联的请求 message_id
  status VARCHAR(20) DEFAULT 'pending',  -- pending/delivered/processed/failed
  created_at TIMESTAMPTZ DEFAULT NOW(),
  processed_at TIMESTAMPTZ
);
```

### 实现要点
- [ ] `a2a_messages` 数据库表
- [ ] `ClawdEx.A2A.Message` Schema
- [ ] `ClawdEx.A2A.Router` GenServer
- [ ] `ClawdEx.A2A.Mailbox` — per-agent 收件箱
- [ ] `ClawdEx.Tools.A2A` — a2a 工具
- [ ] Agent Loop 集成：idle 时检查收件箱
- [ ] Agent 能力注册（capabilities）
- [ ] 请求/响应匹配 + 超时
- [ ] Web UI：A2A 消息监控

---

## 实现优先级

### Phase 1: 多阶段输出 (1-2 天)
这是最基础的改进，直接提升用户体验。

### Phase 2: 任务管理器 (2-3 天)
有了多阶段输出后，任务管理器可以在执行过程中报告进度。

### Phase 3: A2A 通信 (2-3 天)
任务管理器 + A2A = Agent 可以委托子任务给其他 Agent。

### 总计：约 6-8 天工作量

---

## 文件清单（新增）

```
lib/clawd_ex/
├── agent/
│   └── output_manager.ex      # 多阶段输出管理
├── tasks/
│   ├── task.ex                 # Task Schema
│   ├── manager.ex              # 任务管理器 GenServer
│   └── supervisor.ex           # 任务系统 Supervisor
├── a2a/
│   ├── message.ex              # A2A 消息 Schema
│   ├── router.ex               # A2A 路由器
│   ├── mailbox.ex              # Agent 收件箱
│   └── supervisor.ex           # A2A 系统 Supervisor
├── tools/
│   ├── task_tool.ex            # task 工具
│   └── a2a.ex                  # a2a 工具

priv/repo/migrations/
├── XXXXXX_create_tasks.exs
└── XXXXXX_create_a2a_messages.exs

lib/clawd_ex_web/live/
├── tasks_live.ex               # 任务看板
└── a2a_live.ex                 # A2A 消息监控
```
