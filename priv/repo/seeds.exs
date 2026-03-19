# Script for populating the database with seed data.
#
# Run with: mix run priv/repo/seeds.exs
#
# Creates:
# - Default agent with a sensible configuration

alias ClawdEx.Repo
alias ClawdEx.Agents.Agent

# Create default agent if it doesn't exist
case Repo.get_by(Agent, name: "default") do
  nil ->
    %Agent{}
    |> Agent.changeset(%{
      name: "default",
      system_prompt: """
      You are a helpful AI assistant running on ClawdEx.
      You have access to tools for file operations, web search, code execution, and more.
      Be concise and helpful. Use tools when they would help answer the question better.
      """,
      active: true
    })
    |> Repo.insert!()

    IO.puts("✅ Created default agent")

  _agent ->
    IO.puts("ℹ️  Default agent already exists, skipping")
end
