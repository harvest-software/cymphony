defmodule CymphonyElixir.WorkspaceRunHookLockTest do
  @moduledoc """
  `after_run` used to live only in `AgentRunner`'s `after` block, which does not
  run when the orchestrator kills the task. So a hook that stopped a dev stack
  never ran when an issue moved to review. `run_after_run_hook_detached/4` is
  the orchestrator's replacement. It must never let a restart's `before_run`
  overtake the killed attempt's `after_run`.
  """
  use CymphonyElixir.TestSupport

  setup do
    root = Path.join(System.tmp_dir!(), "cymphony-run-hook-lock-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "HC-1")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, order: Path.join(root, "order")}
  end

  defp wait_for_lines(path, count, deadline \\ 5_000) do
    lines = if File.exists?(path), do: path |> File.read!() |> String.split("\n", trim: true), else: []

    cond do
      length(lines) >= count ->
        lines

      deadline <= 0 ->
        flunk("timed out waiting for #{count} lines in #{path}, got #{inspect(lines)}")

      true ->
        Process.sleep(20)
        wait_for_lines(path, count, deadline - 20)
    end
  end

  test "is a no-op without an after_run hook", %{root: root, workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

    assert :ok = Workspace.run_after_run_hook_detached(workspace, "HC-1")
  end

  test "runs the hook in the workspace, with the issue in its environment", %{root: root, workspace: workspace, order: order} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_run: "echo \"after $(basename \"$PWD\") $CYMPHONY_ISSUE\" >> #{order}"
    )

    issue = %Issue{id: "id-1", identifier: "HC-1", title: "t", state: "Review"}
    assert :ok = Workspace.run_after_run_hook_detached(workspace, issue)

    assert wait_for_lines(order, 1) == ["after HC-1 HC-1"]
  end

  test "a before_run started right after waits for the killed attempt's after_run", %{root: root, workspace: workspace, order: order} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_run: "sleep 0.4; echo after >> #{order}",
      hook_before_run: "echo before >> #{order}"
    )

    assert :ok = Workspace.run_after_run_hook_detached(workspace, "HC-1")
    # A restart dispatches the next attempt straight away. Without the lock its
    # before_run would finish first and the slow after_run would undo it.
    assert :ok = Workspace.run_before_run_hook(workspace, "HC-1")

    assert wait_for_lines(order, 2) == ["after", "before"]
  end

  test "hooks for different workspaces do not wait on each other", %{root: root, workspace: workspace, order: order} do
    other = Path.join(root, "HC-2")
    File.mkdir_p!(other)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_after_run: "sleep 0.4; echo \"after $(basename \"$PWD\")\" >> #{order}",
      hook_before_run: "echo \"before $(basename \"$PWD\")\" >> #{order}"
    )

    assert :ok = Workspace.run_after_run_hook_detached(workspace, "HC-1")
    assert :ok = Workspace.run_before_run_hook(other, "HC-2")

    assert wait_for_lines(order, 2) == ["before HC-2", "after HC-1"]
  end

  test "gives up waiting for the lock but still runs the hook", %{root: root, workspace: workspace, order: order} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_before_run: "sleep 0.5; echo before >> #{order}",
      hook_after_run: "echo after >> #{order}"
    )

    test_pid = self()

    spawn(fn ->
      send(test_pid, :before_run_started)
      Workspace.run_before_run_hook(workspace, "HC-1")
    end)

    assert_receive :before_run_started
    Process.sleep(50)

    log =
      capture_log(fn ->
        assert :timeout = Workspace.run_after_run_hook_detached(workspace, "HC-1", nil, lock_wait_ms: 50)
      end)

    refute log =~ "error"
    assert wait_for_lines(order, 2) == ["before", "after"]
  end

  test "a lock held by a killed process is released", %{root: root, workspace: workspace, order: order} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: root,
      hook_before_run: "sleep 5",
      hook_after_run: "echo after >> #{order}"
    )

    holder = spawn(fn -> Workspace.run_before_run_hook(workspace, "HC-1") end)
    Process.sleep(100)
    Process.exit(holder, :kill)

    assert :ok = Workspace.run_after_run_hook_detached(workspace, "HC-1", nil, lock_wait_ms: 2_000)
    assert wait_for_lines(order, 1) == ["after"]
  end
end
