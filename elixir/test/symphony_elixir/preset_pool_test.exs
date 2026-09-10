defmodule SymphonyElixir.PresetPoolTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.Schema.Workspace, as: WorkspaceConfig
  alias SymphonyElixir.PresetPool

  setup do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "pool")
    env = Path.join(root, "apa-02")
    File.mkdir_p!(Path.join(env, "dev"))
    File.mkdir_p!(Path.join(env, ".environment"))
    for name <- ["runtime.env", "repositories.json", "provisioned.json"], do: File.write!(Path.join(env, ".environment/#{name}"), "{}")
    File.write!(Path.join(env, "keep"), "preserve")

    File.write!(Path.join(env, "dev/job.sh"), """
    #!/bin/sh
    echo "$1" >> .environment/calls
    test ! -f .environment/fail || exit 1
    phase=ready
    test "$1" != cleanup || phase=released
    printf '{"job_id":"%s","phase":"%s"}' "$2" "$phase" > .environment/job.json
    """)

    File.chmod!(Path.join(env, "dev/job.sh"), 0o755)
    configure(root, ["apa-02"])
    {:ok, root: root, env: env}
  end

  test "reserves exclusively, resumes and releases without deleting", %{env: env} do
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    assert {:error, :preset_pool_full} = PresetPool.reserve(issue("2"))
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    assert :ok = Workspace.run_before_run_hook(env, issue("1"))
    assert {:ok, []} = Workspace.remove_recorded(env, nil)
    assert File.read!(Path.join(env, "keep")) == "preserve"
    assert {:ok, ^env} = PresetPool.reserve(issue("2"))
  end

  test "removed environment retains its assignment and cleanup failures", %{root: root, env: env} do
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    assert :ok = Workspace.run_before_run_hook(env, issue("1"))
    configure(root, [])
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    File.write!(Path.join(env, ".environment/fail"), "")
    assert {:error, _, _} = Workspace.remove(env)
    assert {:error, :preset_pool_full} = PresetPool.reserve(issue("2"))
    File.rm!(Path.join(env, ".environment/fail"))
    assert {:ok, []} = Workspace.remove(env)
    assert File.exists?(env)
  end

  test "manual occupancy and path escapes are never adopted", %{root: root, env: env} do
    File.write!(Path.join(env, ".environment/job.json"), ~s({"job_id":"manual","phase":"ready"}))
    assert {:error, :preset_pool_full} = PresetPool.reserve(issue("1"))
    assert {:error, _, _} = Workspace.remove_recorded(env, nil)
    assert File.exists?(env)
    configure(root, ["../outside"])
    refute WorkspaceConfig.changeset(%WorkspaceConfig{}, %{"environments" => ["../outside"]}).valid?
  end

  test "concurrent reservations only grant one owner", %{env: env} do
    results = 1..5 |> Task.async_stream(fn n -> PresetPool.reserve(issue(to_string(n))) end) |> Enum.map(fn {:ok, r} -> r end)
    assert Enum.count(results, &(&1 == {:ok, env})) == 1
  end

  test "restart reloads durable ownership and legacy hooks cannot destroy presets", %{root: root, env: env} do
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    assert :ok = Workspace.run_before_run_hook(env, issue("1"))
    WorkflowStore.force_reload()
    assert {:ok, ^env} = Workspace.create_for_issue(issue("1"))
    assert {:error, :preset_pool_full} = Workspace.create_for_issue(issue("2"))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_run: "rm keep",
      hook_before_remove: "rm keep"
    )

    assert :ok = Workspace.run_after_run_hook(env, issue("1"))
    assert {:ok, []} = Workspace.remove_recorded(env, nil)
    assert File.exists?(Path.join(env, "keep"))
  end

  test "cancellation before prepare releases only the reservation", %{env: env} do
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    assert :ok = PresetPool.release_issue(issue("1"))
    assert File.exists?(env)
    refute File.exists?(Path.join(env, ".environment/calls"))
    assert {:ok, ^env} = PresetPool.reserve(issue("2"))
  end

  test "failed preparation retains ownership and can retry", %{env: env} do
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    File.write!(Path.join(env, ".environment/fail"), "")
    assert {:error, _} = Workspace.run_before_run_hook(env, issue("1"))
    assert {:error, :preset_pool_full} = PresetPool.reserve(issue("2"))
    File.rm!(Path.join(env, ".environment/fail"))
    assert :ok = Workspace.run_before_run_hook(env, issue("1"))
    assert :ok = Workspace.remove_issue_workspaces(issue("1"))
    refute PresetPool.assigned?(issue("1"))
  end

  test "symlinked and incomplete environments fail before allocation", %{root: root, env: env} do
    File.rename!(env, env <> "-real")
    File.ln_s!(env <> "-real", env)
    assert {:error, _} = PresetPool.reserve(issue("1"))
    File.rm!(env)
    File.rename!(env <> "-real", env)
    File.rm!(Path.join(env, ".environment/provisioned.json"))
    assert {:error, _} = PresetPool.reserve(issue("1"))
    assert PresetPool.records() == %{}
    configure(root, [])
    assert {:error, :preset_pool_full} = PresetPool.reserve(issue("1"))
  end

  test "polling waits without agents and retries terminal cleanup", %{root: root, env: env} do
    configure(root, ["apa-02"], tracker_kind: "memory", codex_command: "false")
    owner = %Issue{id: "1", identifier: "GT-1", state: "Review", title: "owner", dispatchable: true}
    waiter = %Issue{id: "2", identifier: "GT-2", state: "Todo", title: "waiting", dispatchable: true}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [owner, waiter])
    assert {:ok, ^env} = PresetPool.reserve(owner)
    assert :ok = Workspace.run_before_run_hook(env, owner)
    supervisor = start_supervised!({Task.Supervisor, []})
    server = start_supervised!({Orchestrator, name: __MODULE__.PoolOrchestrator, task_supervisor: supervisor})
    send(server, :run_poll_cycle)
    assert Orchestrator.snapshot(__MODULE__.PoolOrchestrator, 5_000).running == []
    assert Task.Supervisor.children(supervisor) == []
    refute PresetPool.assigned?(waiter)
    File.write!(Path.join(env, ".environment/fail"), "")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{owner | state: "Done"}, waiter])
    send(server, :run_poll_cycle)
    assert [%{"phase" => "cleanup_failed"}] = Orchestrator.snapshot(__MODULE__.PoolOrchestrator, 5_000).preset_environments
    refute PresetPool.assigned?(waiter)
    File.rm!(Path.join(env, ".environment/fail"))
    send(server, :run_poll_cycle)
    _snapshot = Orchestrator.snapshot(__MODULE__.PoolOrchestrator, 5_000)
    refute PresetPool.assigned?(owner)
    assert PresetPool.assigned?(waiter)
    assert File.read!(Path.join(env, "keep")) == "preserve"
  end

  test "malformed ledger and job state fail closed", %{env: env} do
    ledger = Path.join(Path.dirname(Workflow.workflow_file_path()), ".symphony-preset-pool.json")
    File.mkdir!(ledger)
    assert_raise File.Error, fn -> PresetPool.records() end
    assert {:error, _} = PresetPool.reserve(issue("1"))
    assert {:error, _, _} = PresetPool.release(env)
    File.rmdir!(ledger)
    File.mkdir!(Path.join(env, ".environment/job.json"))
    assert {:error, :preset_pool_full} = PresetPool.reserve(issue("1"))
    File.rmdir!(Path.join(env, ".environment/job.json"))
    assert {:error, :preset_assignment_mismatch} = PresetPool.prepare(env, issue("1"))
    assert :ok = PresetPool.release_issue(issue("missing"))
  end

  test "scope changes, unsupported remote mode and disabled pools are rejected", %{root: root, env: env} do
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    configure(root, ["apa-02"], tracker_project_slug: "different")
    assert {:error, :preset_tracker_scope_changed} = PresetPool.reserve(issue("2"))
    assert {:error, :preset_tracker_scope_changed, _} = PresetPool.release(env)
    configure(root, ["apa-02"])
    assert :ok = PresetPool.prepare(env, issue("1"))
    assert {:ok, []} = PresetPool.release(env)
    configure(root, ["apa-02"], worker_ssh_hosts: ["remote"])
    assert {:error, :preset_pool_requires_local_worker} = PresetPool.reserve(issue("2"))
    assert {:error, :preset_pool_requires_local_worker} = Workspace.create_for_issue(issue("2"), "remote")
    assert {:error, :preset_pool_requires_local_worker, _} = Workspace.remove(env, "remote")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    assert {:error, :preset_pool_disabled} = PresetPool.reserve("GT-2")
    assert {:ok, path} = Workspace.create_for_issue(nil)
    assert path == Path.join(root, "issue")
  end

  test "command timeout, false success and missing prerequisites retain ownership", %{root: root, env: env} do
    assert {:ok, ^env} = PresetPool.reserve(issue("1"))
    File.write!(Path.join(env, "dev/job.sh"), "#!/bin/sh\nexit 0\n")
    assert {:error, :preset_job_state_mismatch} = PresetPool.prepare(env, issue("1"))
    configure(root, ["apa-02"], hook_timeout_ms: 1)
    File.write!(Path.join(env, "dev/job.sh"), "#!/bin/sh\nsleep 0.2\n")
    assert {:error, {:preset_job_timeout, "prepare"}} = PresetPool.prepare(env, issue("1"))
    File.rm!(Path.join(env, ".environment/provisioned.json"))
    assert {:error, _} = PresetPool.prepare(env, issue("1"))
    assert {:error, _} = PresetPool.reserve(issue("1"))
  end

  test "review drains a preset worker without releasing its environment", %{root: root, env: env} do
    configure(root, ["apa-02"], tracker_kind: "memory", tracker_active_states: ["symphony/in-progress"], tracker_parked_states: ["symphony/human-review"])
    owner = %Issue{id: "43", identifier: "GT-43", title: "Review handoff", state: "symphony/in-progress", dispatchable: true}
    assert {:ok, ^env} = PresetPool.reserve(owner)
    assert :ok = PresetPool.prepare(env, owner)

    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    state = %Orchestrator.State{
      running: %{owner.id => %{pid: pid, ref: nil, identifier: owner.identifier, issue: owner, started_at: DateTime.utc_now(), workspace_path: env}},
      claimed: MapSet.new([owner.id])
    }

    parked = %{owner | state: "symphony/human-review", dispatchable: false}
    updated = Orchestrator.reconcile_issue_states_for_test([parked], state)
    assert Process.alive?(pid)
    assert is_integer(updated.running[owner.id].drain_deadline_ms)
    assert PresetPool.assigned?(owner)
    assert {:error, :preset_pool_full} = PresetPool.reserve(issue("other"))
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:ok, []} = PresetPool.release(env)
    assert File.exists?(Path.join(env, "keep"))
  end

  defp issue(id), do: %{id: id, identifier: "GT-#{id}"}

  defp configure(root, names, options \\ []) do
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(options, :workspace_root, root))
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "workspace:\n", "workspace:\n  mode: preset\n  environments: #{Jason.encode!(names)}\n"))
    WorkflowStore.force_reload()
  end
end
