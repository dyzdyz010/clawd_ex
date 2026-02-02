import Ecto.Query
alias ClawdEx.Repo
alias ClawdEx.Agents.Agent

agent = Repo.one(from a in Agent, where: a.name == "default")
IO.puts "Default agent model: #{agent.default_model}"
