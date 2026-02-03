# 模拟通过 AI 对话创建定时器的完整闭环测试

alias ClawdEx.Tools.Cron
alias ClawdEx.Automation.CronJob
alias ClawdEx.Repo

IO.puts("=== ClawdEx Cron E2E 测试 ===\n")

# 1. 模拟 Agent Context
context = %{agent: %{id: "e2e-test-agent"}}
IO.puts("✓ Agent Context: #{context.agent.id}")

# 2. 创建定时任务 (模拟 AI 调用 cron tool)
IO.puts("\n📝 步骤 1: 通过 Cron 工具创建定时任务...")

params = %{
  "action" => "add",
  "job" => %{
    "name" => "E2E 测试定时器",
    "schedule" => "*/5 * * * *",
    "text" => "这是通过 E2E 测试创建的定时任务",
    "enabled" => true
  }
}

case Cron.execute(params, context) do
  {:ok, result} ->
    IO.puts("✅ 定时任务创建成功!")
    IO.puts("   ID: #{result.job.id}")
    IO.puts("   名称: #{result.job.name}")
    IO.puts("   调度: #{result.job.schedule}")
    IO.puts("   启用: #{result.job.enabled}")

    job_id = result.job.id

    # 3. 验证任务已存储
    IO.puts("\n📋 步骤 2: 验证任务列表...")
    {:ok, list_result} = Cron.execute(%{"action" => "list"}, context)
    IO.puts("✅ 当前任务数: #{length(list_result.jobs)}")

    # 4. 获取状态
    IO.puts("\n📊 步骤 3: 获取调度器状态...")
    {:ok, status} = Cron.execute(%{"action" => "status"}, context)
    IO.puts("✅ 总任务数: #{status.total_jobs}")
    IO.puts("   启用任务: #{status.enabled_jobs}")

    if status.next_run do
      IO.puts("   下次运行: #{status.next_run.name}")
    end

    # 5. 手动触发执行
    IO.puts("\n🚀 步骤 4: 手动触发任务执行...")
    {:ok, run_result} = Cron.execute(%{"action" => "run", "jobId" => job_id}, context)
    IO.puts("✅ 任务触发: #{run_result.triggered}")
    IO.puts("   消息: #{run_result.message}")

    # 6. 清理测试任务
    IO.puts("\n🧹 步骤 5: 清理测试任务...")
    {:ok, _} = Cron.execute(%{"action" => "remove", "jobId" => job_id}, context)
    IO.puts("✅ 测试任务已删除")

    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("🎉 ClawdEx Cron E2E 测试全部通过!")
    IO.puts(String.duplicate("=", 50))

  {:error, reason} ->
    IO.puts("❌ 创建失败: #{inspect(reason)}")
end
