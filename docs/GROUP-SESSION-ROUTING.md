# Group Session Routing — Topic × Agent 隔离机制

## 概述

ClawdEx 在 Telegram 群聊中实现了 **Topic × Agent** 级别的 session 隔离，每个 agent 在每个 topic 中有独立的会话上下文。消息通过 @mention 路由到指定 agent。

## Session Key 格式

| 场景 | Session Key | 示例 |
|------|------------|------|
| 私聊 | `telegram:{chat_id}` | `telegram:191578189` |
| 普通群（非论坛） | `telegram:{chat_id}:agent:{agent_id}` | `telegram:-100xxx:agent:2` |
| 论坛 Topic | `telegram:{chat_id}:topic:{topic_id}:agent:{agent_id}` | `telegram:-100xxx:topic:5:agent:3` |

## 消息路由规则

当用户在群/topic 中发消息时，按以下优先级匹配目标 agent：

1. **@mention 精确匹配** — 消息以 `@AgentName` 开头，如 `@CTO 你怎么看这个方案`
2. **名称模糊匹配** — 消息文本中包含 agent 名称（大小写不敏感、词边界匹配），如 `请 CTO 来看一下`
3. **Topic 默认 agent** — agent 配置了该 topic 为默认负责区域
4. **全局 fallback** — 用第一个 active agent（通常是 default）

## 配置 Topic 默认 Agent

在 agent 的 `config` JSON 字段中设置 `default_topics`：

```json
{
  "default_topics": {
    "telegram:-1003768565369": [5, 8, 12]
  }
}
```

含义：这个 agent 是群 `-1003768565369` 中 topic 5、8、12 的默认响应者。

**注意**：一个 topic 应该只配一个默认 agent。如果多个 agent 都配了同一个 topic，取第一个匹配的。

## Agent 协作机制

### @mention 路由（主动触发）
用户主动 @ 某个 agent，只有该 agent 响应。其他 agent 不会收到消息。

### A2A 协作（agent 间通信）
当一个 agent 需要其他 agent 参与时：
1. 被触发的 agent 通过 A2A `send` / `request` 发消息给目标 agent
2. 目标 agent 在自己的 session 中处理，回复发到同一个 topic
3. 用户看到多个 agent 在同一个 topic 里协作讨论

### 示例场景

```
[Engineering Topic]

用户: @CTO 我们要加一个新的 API endpoint
CTO:  好的，这个需要 Backend Dev 参与。
      → (A2A send to Backend Dev: "需要实现新的 API endpoint, 详情...")
Backend Dev: 收到，我来设计 API schema...
```

## 注意事项

- **私聊不受影响** — 私聊仍然是 `telegram:{chat_id}`，通过 DM pairing 解析 agent
- **每个 session 独立** — 不同 agent 的 session 互不干扰，各自有独立的消息历史和上下文
- **Always-On sessions** — AutoStarter 启动的 `agent:{name}:always_on` session 是后台 session，和群聊 session 是不同的进程
- **Token 效率** — 只有被路由到的 agent 消耗 token，不会广播给所有 agent
