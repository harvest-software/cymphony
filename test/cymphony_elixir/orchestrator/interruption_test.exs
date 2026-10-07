defmodule CymphonyElixir.Orchestrator.InterruptionTest do
  @moduledoc """
  Usage-limit parking, resumable sessions, restart durability, and manual
  issues: everything that keeps an interrupted run from being lost.
  """

  # Mutates application env (config dir, durable state, memory tracker).
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Orchestrator.{DurableState, State}

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-interruption-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    previous_dir = Application.get_env(:cymphony_elixir, :config_dir_override)
    # Never the operator's real ~/.cymphony: manual issues and queue order are
    # persisted to config.json, durable state next to it.
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)
    Application.put_env(:cymphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: Path.join(tmp, "workspaces"),
      poll_interval_ms: 600_000
    )

    on_exit(fn ->
      if previous_dir,
        do: Application.put_env(:cymphony_elixir, :config_dir_override, previous_dir),
        else: Application.delete_env(:cymphony_elixir, :config_dir_override)

      Application.put_env(:cymphony_elixir, :durable_orchestrator_state, false)
      Application.delete_env(:cymphony_elixir, :orchestrator_state_file)
      File.rm_rf(tmp)
    end)

    %{tmp: tmp}
  end

  defp issue(id, state, extra \\ []) do
    struct!(
      %Issue{id: id, identifier: id, title: "Title #{id}", description: "", state: state, url: "https://example.org/#{id}", labels: []},
      extra
    )
  end

  defp base_state(extra \\ %{}) do
    struct!(
      %State{
        config: Config.settings!(),
        token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        poll_interval_ms: 600_000,
        max_concurrent_agents: 10
      },
      extra
    )
  end

  defp running_entry(id, ref, extra \\ %{}) do
    Map.merge(
      %{
        pid: nil,
        ref: ref,
        identifier: id,
        issue: issue(id, "In Progress"),
        agent_kind: "claude",
        provider: nil,
        worker_host: nil,
        workspace_path: nil,
        retry_attempt: 0,
        failure_count: 0,
        session_id: "new",
        resume_session_id: "sess-#{id}",
        started_at: DateTime.utc_now()
      },
      extra
    )
  end

  defp down(state, _id, ref, reason) do
    {:noreply, state} = Orchestrator.handle_info({:DOWN, ref, :process, self(), reason}, state)
    cancel_timers(state)
    state
  end

  defp cancel_timers(state) do
    Enum.each(state.retry_attempts, fn {_id, retry} ->
      if is_reference(retry[:timer_ref]), do: Process.cancel_timer(retry.timer_ref)
    end)
  end

  defp in_ms(%{due_at_ms: due_at_ms}), do: due_at_ms - System.monotonic_time(:millisecond)

  defp call(state, message), do: Orchestrator.handle_call(message, {self(), make_ref()}, state)

  # Runs `fun` with its log output captured, returning its result.
  defp quietly(fun) do
    ref = make_ref()
    capture_log(fn -> send(self(), {ref, fun.()}) end)
    assert_received {^ref, result}
    result
  end

  describe "usage limits" do
    test "a refused run is parked until the reset, not counted as a failure" do
      ref = make_ref()
      resets_at = System.os_time(:second) + 600

      state =
        base_state(%{
          running: %{"MT-1" => running_entry("MT-1", ref, %{provider: "cz1", failure_count: 2})},
          claimed: MapSet.new(["MT-1"])
        })

      reason = {:shutdown, {:usage_limit, %{resets_at: resets_at, message: "m"}}}
      log = capture_log(fn -> send(self(), {:state, down(state, "MT-1", ref, reason)}) end)

      assert_received {:state, state}
      assert log =~ "Usage limit reached"

      retry = state.retry_attempts["MT-1"]
      assert retry.failures == 2
      assert retry.usage_limited_until == resets_at
      assert retry.error =~ "usage limit reached; resumes after"
      # Reset plus the one-minute grace.
      assert_in_delta in_ms(retry), 660_000, 3_000
      assert state.usage_limits == %{{"claude", "cz1"} => resets_at}
      assert %{session_id: "sess-MT-1", reason: "the agent hit its usage limit"} = state.resumable["MT-1"]
    end

    test "a limit with no usable reset time waits thirty minutes" do
      ref = make_ref()
      state = base_state(%{running: %{"MT-2" => running_entry("MT-2", ref)}, claimed: MapSet.new(["MT-2"])})

      state = quietly(fn -> down(state, "MT-2", ref, {:shutdown, {:usage_limit, %{resets_at: 1}}}) end)

      assert_in_delta in_ms(state.retry_attempts["MT-2"]), 1_860_000, 3_000
    end

    test "a retry that fires inside the window moves to the reset with its counts unchanged" do
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-3", "In Progress")])
      resets_at = System.os_time(:second) + 900
      token = make_ref()

      state =
        base_state(%{
          usage_limits: %{{"claude", nil} => resets_at},
          retry_attempts: %{
            "MT-3" => %{attempt: 4, retry_token: token, timer_ref: nil, due_at_ms: 0, identifier: "MT-3", failures: 1}
          },
          claimed: MapSet.new(["MT-3"])
        })

      {:noreply, state} = Orchestrator.handle_info({:retry_issue, "MT-3", token}, state)
      cancel_timers(state)

      retry = state.retry_attempts["MT-3"]
      assert %{attempt: 4, failures: 1, usage_limited_until: ^resets_at} = retry
      assert retry.error =~ "waiting for the usage limit to reset"
      assert_in_delta in_ms(retry), 960_000, 3_000
      assert state.running == %{}
    end

    test "an expired limit no longer holds anything back, and is not snapshotted" do
      state = base_state(%{usage_limits: %{{"claude", nil} => System.os_time(:second) - 1}})
      assert {:reply, %{usage_limits: []}, _state} = call(state, :snapshot)
    end

    test "waiting issues stay queued while every provider they could use is limited" do
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-4", "Todo")])
      {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :GateOrch))
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      resets_at = System.os_time(:second) + 600
      :sys.replace_state(pid, &%{&1 | usage_limits: %{{"claude", nil} => resets_at}})
      :ok = Orchestrator.run_poll_cycle_for_test(pid)

      snapshot = GenServer.call(pid, :snapshot)
      assert snapshot.running == []
      assert [%{identifier: "MT-4"}] = snapshot.waiting
      assert [%{agent_kind: "claude", provider: nil}] = snapshot.usage_limits
    end

    test "a completed turn on a limited provider clears its limit" do
      ref = make_ref()

      state =
        base_state(%{
          running: %{"MT-5" => running_entry("MT-5", ref, %{provider: "cz1"})},
          usage_limits: %{{"claude", "cz1"} => System.os_time(:second) + 600}
        })

      update = %{event: :turn_completed, session_id: "sess-MT-5", timestamp: DateTime.utc_now()}
      {:noreply, state} = Orchestrator.handle_info({:agent_worker_update, "MT-5", update}, state)
      assert state.usage_limits == %{}
    end
  end

  describe "resumable sessions" do
    test "the CLI's session id is recorded as soon as it is printed; the 'new' placeholder is not" do
      ref = make_ref()
      state = base_state(%{running: %{"MT-6" => running_entry("MT-6", ref, %{resume_session_id: nil})}})

      placeholder = %{event: :session_started, session_id: "new", timestamp: DateTime.utc_now()}
      {:noreply, state} = Orchestrator.handle_info({:agent_worker_update, "MT-6", placeholder}, state)
      assert state.running["MT-6"].resume_session_id == nil

      identified = %{event: :session_identified, session_id: "sess-real", timestamp: DateTime.utc_now()}
      {:noreply, state} = Orchestrator.handle_info({:agent_worker_update, "MT-6", identified}, state)
      assert state.running["MT-6"].resume_session_id == "sess-real"
    end

    test "a kill keeps the conversation for the next dispatch" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      state = base_state(%{running: %{"MT-7" => running_entry("MT-7", nil, %{pid: worker})}, claimed: MapSet.new(["MT-7"])})

      assert {:reply, :ok, state} = call(state, {:kill_issue, "MT-7"})
      refute Process.alive?(worker)
      assert %{session_id: "sess-MT-7", agent_kind: "claude", reason: "an operator stopped it from the dashboard"} = state.resumable["MT-7"]
    end

    test "a crash keeps it; a clean finish and a run of failures drop it" do
      ref = make_ref()
      crashing = base_state(%{running: %{"MT-8" => running_entry("MT-8", ref)}})
      state = quietly(fn -> down(crashing, "MT-8", ref, :boom) end)
      assert state.resumable["MT-8"].reason == "the agent exited with an error"

      # Third consecutive failure: start fresh next time.
      failing = base_state(%{running: %{"MT-8" => running_entry("MT-8", ref, %{failure_count: 2})}, resumable: state.resumable})
      state = quietly(fn -> down(failing, "MT-8", ref, :boom) end)
      refute Map.has_key?(state.resumable, "MT-8")

      finishing = base_state(%{running: %{"MT-8" => running_entry("MT-8", ref)}, resumable: %{"MT-8" => %{session_id: "old"}}})
      state = quietly(fn -> down(finishing, "MT-8", ref, :normal) end)
      refute Map.has_key?(state.resumable, "MT-8")
    end

    test "a killed run that never printed a session id keeps the older conversation" do
      worker = spawn(fn -> Process.sleep(:infinity) end)
      old = %{session_id: "sess-older", agent_kind: "claude", worker_host: nil, identifier: "MT-9", reason: "x"}

      state =
        base_state(%{
          running: %{"MT-9" => running_entry("MT-9", nil, %{pid: worker, resume_session_id: nil})},
          resumable: %{"MT-9" => old}
        })

      {:reply, :ok, state} = call(state, {:kill_issue, "MT-9"})
      assert state.resumable["MT-9"] == old
    end

    test "the next dispatch resumes it, but only for the same agent kind", %{tmp: tmp} do
      trace = Path.join(tmp, "claude.trace")
      binary = Path.join(tmp, "fake-claude")

      File.write!(binary, """
      #!/bin/sh
      printf 'RUN:%s\\n' "$*" >> "#{trace}"
      echo '{"result":"ok","session_id":"sess-after"}'
      """)

      File.chmod!(binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: Path.join(tmp, "workspaces"),
        poll_interval_ms: 600_000,
        claude_command: binary,
        max_turns: 1
      )

      # Boot paused (the persisted flag is read before the first tick) so the
      # poll loop does not dispatch these itself before the resumable records
      # are in place.
      File.write!(Path.join(tmp, "config.json"), Jason.encode!(%{"dispatch_paused" => true}))
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-10", "In Progress"), issue("MT-11", "In Progress")])
      {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :ResumeOrch))
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      :sys.replace_state(pid, fn state ->
        %{
          state
          | resumable: %{
              "MT-10" => %{session_id: "sess-before", agent_kind: "claude", worker_host: nil, identifier: "MT-10", reason: "the agent hit its usage limit"},
              "MT-11" => %{session_id: "codex-thread", agent_kind: "codex", worker_host: nil, identifier: "MT-11", reason: "x"}
            }
        }
      end)

      :ok = Orchestrator.dispatch_issue_for_test(pid, issue("MT-10", "In Progress"))
      :ok = Orchestrator.dispatch_issue_for_test(pid, issue("MT-11", "In Progress"))

      running = Map.new(GenServer.call(pid, :snapshot).running, &{&1.identifier, &1})
      assert running["MT-10"].resumed_from == "sess-before"
      assert running["MT-11"].resumed_from == nil

      wait_until(fn -> File.exists?(trace) and length(String.split(File.read!(trace), "RUN:", trim: true)) >= 2 end, 100, fn -> inspect(File.read(trace)) end)
      runs = File.read!(trace)
      assert runs =~ "--resume sess-before"
      assert runs =~ "the agent hit its usage limit"
      refute runs =~ "--resume codex-thread"
      Process.exit(pid, :normal)
    end

    test "a resumable conversation is dropped once its issue leaves the active set" do
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-12", "Done")])
      {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :PruneOrch))
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

      records = %{"MT-12" => %{session_id: "s", agent_kind: "claude"}, "MT-13" => %{session_id: "t", agent_kind: "claude"}}
      :sys.replace_state(pid, &%{&1 | resumable: records})
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-12", "In Progress", assigned_to_worker: false)])
      :ok = Orchestrator.pause(pid)
      :ok = Orchestrator.run_poll_cycle_for_test(pid)

      assert Map.keys(:sys.get_state(pid).resumable) == ["MT-12"]
    end
  end

  describe "restart durability" do
    setup %{tmp: tmp} do
      path = Path.join(tmp, "orchestrator_state.json")
      Application.put_env(:cymphony_elixir, :durable_orchestrator_state, true)
      Application.put_env(:cymphony_elixir, :orchestrator_state_file, path)
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [])
      %{path: path}
    end

    test "retries, interrupted runs, sessions and live limits come back after a restart", %{path: path} do
      now_ms = System.os_time(:millisecond)
      resets_at = System.os_time(:second) + 3_600

      :ok =
        DurableState.save(nil, %{
          retries: %{
            "MT-20" => %{
              identifier: "MT-20",
              attempt: 3,
              failures: 1,
              error: "usage limit reached",
              due_at_ms: now_ms + 120_000,
              held: false,
              usage_limited_until: resets_at
            },
            "MT-21" => %{identifier: "MT-21", attempt: 2, failures: 0, error: "x", due_at_ms: now_ms - 5_000, held: true}
          },
          running: %{
            "MT-22" => %{identifier: "MT-22", attempt: nil, failures: 1, workspace_path: "/w/MT-22", session_id: "sess-22", agent_kind: "claude"},
            "MT-23" => %{identifier: "MT-23", attempt: 2, failures: 0}
          },
          resumable: %{"MT-20" => %{identifier: "MT-20", session_id: "sess-20", agent_kind: "claude", reason: "the agent hit its usage limit"}},
          usage_limits: %{{"claude", nil} => resets_at, {"codex", nil} => System.os_time(:second) - 10}
        })

      {:ok, state} = quietly(fn -> Orchestrator.init([]) end)

      assert state.usage_limits == %{{"claude", nil} => resets_at}
      assert MapSet.equal?(state.claimed, MapSet.new(["MT-20", "MT-21", "MT-22", "MT-23"]))

      assert %{attempt: 3, failures: 1, usage_limited_until: ^resets_at} = state.retry_attempts["MT-20"]
      assert_in_delta in_ms(state.retry_attempts["MT-20"]), 120_000, 3_000

      # Held while the old daemon was paused; this one is not, so it is due now.
      refute Map.has_key?(state.retry_attempts["MT-21"], :held)
      assert in_ms(state.retry_attempts["MT-21"]) <= 0

      assert %{attempt: 1, failures: 1, error: "interrupted by a daemon restart", workspace_path: "/w/MT-22"} =
               state.retry_attempts["MT-22"]

      assert %{session_id: "sess-22", reason: "the Cymphony daemon restarted mid-run"} = state.resumable["MT-22"]
      assert state.resumable["MT-20"].session_id == "sess-20"
      refute Map.has_key?(state.resumable, "MT-23")

      token = state.retry_attempts["MT-22"].retry_token
      assert_receive {:retry_issue, "MT-22", ^token}, 1_000
      cancel_timers(state)

      # The restored state is written straight back, in its new shape.
      saved = DurableState.load(nil)
      assert saved.running == %{}
      assert Map.keys(saved.retries) |> Enum.sort() == ["MT-20", "MT-21", "MT-22", "MT-23"]
      assert File.exists?(path)
    end

    test "a held retry stays held when the restarted project is still paused", %{tmp: tmp} do
      File.write!(Path.join(tmp, "config.json"), Jason.encode!(%{"projects" => [%{"name" => "p", "dispatch_paused" => true}]}))
      :ok = DurableState.save("p", %{DurableState.empty() | retries: %{"MT-24" => %{identifier: "MT-24", attempt: 2, failures: 0, due_at_ms: 0, held: true}}})

      {:ok, state} = quietly(fn -> Orchestrator.init(project_name: "p") end)

      assert state.paused
      assert %{held: true, timer_ref: nil, attempt: 2} = state.retry_attempts["MT-24"]
    end

    test "a checkpoint writes only when something durable changed", %{path: path} do
      {:ok, state} = quietly(fn -> Orchestrator.init([]) end)
      refute File.exists?(path)

      ref = make_ref()
      state = %{state | running: %{"MT-25" => running_entry("MT-25", ref)}}
      update = %{event: :session_identified, session_id: "sess-25", timestamp: DateTime.utc_now()}
      {:noreply, state} = Orchestrator.handle_info({:agent_worker_update, "MT-25", update}, state)
      assert DurableState.load(nil).running["MT-25"].session_id == "sess-25"

      File.rm!(path)
      heartbeat = %{event: :notification, timestamp: DateTime.utc_now()}
      {:noreply, _state} = Orchestrator.handle_info({:agent_worker_update, "MT-25", heartbeat}, state)
      refute File.exists?(path)
    end
  end

  describe "manual issues" do
    test "adding moves an issue outside the active states to the first queued state" do
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-30", "Backlog")])

      assert {:reply, {:ok, added}, state} = quietly(fn -> call(base_state(), {:add_manual_issue, " MT-30 "}) end)

      assert added.state == "Todo"
      assert_received {:memory_tracker_state_update, "MT-30", "Todo"}
      assert state.manual_issue_ids == ["MT-30"]

      # Adding again is idempotent and makes no second state write.
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-30", "Todo")])
      assert {:reply, {:ok, _}, again} = quietly(fn -> call(state, {:add_manual_issue, "MT-30"}) end)
      assert again.manual_issue_ids == ["MT-30"]
      refute_received {:memory_tracker_state_update, _, _}
    end

    test "unknown, blank and finished issues are refused" do
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue("MT-31", "Done")])
      state = base_state()

      assert {:reply, {:error, :issue_not_found}, _} = call(state, {:add_manual_issue, "MT-404"})
      assert {:reply, {:error, :invalid_issue}, _} = call(state, {:add_manual_issue, "  "})
      assert {:reply, {:error, {:issue_terminal, "Done"}}, _} = call(state, {:add_manual_issue, "MT-31"})
    end

    test "a manual issue is queued even when it is not assigned to Cymphony, and pruned when finished or gone" do
      Application.put_env(:cymphony_elixir, :memory_tracker_issues, [
        issue("MT-32", "Todo", assigned_to_worker: false),
        issue("MT-33", "Todo", assigned_to_worker: false),
        issue("MT-34", "Done")
      ])

      {:ok, pid} = Orchestrator.start_link(name: Module.concat(__MODULE__, :ManualOrch))
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
      :ok = Orchestrator.pause(pid)
      :sys.replace_state(pid, &%{&1 | manual_issue_ids: ["MT-32", "MT-34", "MT-GONE"]})

      capture_log(fn -> :ok = Orchestrator.run_poll_cycle_for_test(pid) end)

      snapshot = GenServer.call(pid, :snapshot)
      assert [%{identifier: "MT-32", manual: true}] = snapshot.waiting
      assert snapshot.manual_issues == ["MT-32"]

      assert :ok = Orchestrator.remove_manual_issue(pid, "MT-32")
      assert {:error, :not_manual} = Orchestrator.remove_manual_issue(pid, "MT-32")
      assert GenServer.call(pid, :snapshot).manual_issues == []
    end
  end

  defp wait_until(fun, attempts, describe) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never became true: " <> describe.())
      true -> Process.sleep(50) && wait_until(fun, attempts - 1, describe)
    end
  end
end
