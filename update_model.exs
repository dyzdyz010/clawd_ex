import Ecto.Query
alias ClawdEx.Repo
alias ClawdEx.Agents.Agent

# 更新所有 agent 的模型名称
{count, _} = Repo.update_all(
  from(a in Agent, where: a.default_model == "anthropic/claude-sonnet-4"),
  set: [default_model: "anthropic/claude-sonnet-4-20250514"]
)

IO.puts "更新了 #{count} 个 agent"

# 验证
agent = Repo.one(from a in Agent, where: a.name == "default")
IO.puts "Default agent 新模型: #{agent.default_model}"
