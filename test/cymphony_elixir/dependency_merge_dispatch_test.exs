defmodule CymphonyElixir.DependencyMergeDispatchTest do
  @moduledoc """
  The dispatch gate, end to end: tracker state and git agreeing, and — the
  point of the whole exercise — tracker state and git *disagreeing*.

  The old rule held a queued issue only while a dependency's ticket was
  non-terminal. On an epic whose sub-tasks each land a branch into the epic
  branch that is the wrong question: a reviewer closes the ticket before the
  merge, an approved merge request sits unmerged, a branch is reverted. The
  dependent is then dispatched onto code that is not on the branch it is about
  to cut from.
  """

  use CymphonyElixir.TestSupport

  alias CymphonyElixir.{DependencyGate, ProjectSupervisor, PromptBuilder}
  alias CymphonyElixir.Orchestrator.State

  setup do
    root = Path.join(System.tmp_dir!(), "cymphony-merge-gate-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin")
    config_dir = Path.join(root, "config")
    File.mkdir_p!(origin)
    File.mkdir_p!(config_dir)

    previous = Application.get_env(:cymphony_elixir, :config_dir_override)
    Application.put_env(:cymphony_elixir, :config_dir_override, config_dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:cymphony_elixir, :config_dir_override, previous),
        else: Application.delete_env(:cymphony_elixir, :config_dir_override)

      File.rm_rf(root)
    end)

    build_origin!(origin)
    project = "merge-gate-#{System.unique_integer([:positive])}"

    {:ok, origin: origin, project: project}
  end

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    output
  end

  defp commit!(repo, file, message) do
    File.write!(Path.join(repo, file), message)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", message])
  end

  # HFE-6470 is the epic branch every sub-task targets. HFE-6471 has landed on
  # it; HFE-6472 is published and has not.
  defp build_origin!(origin) do
    git!(origin, ["init", "-b", "main", "--quiet"])
    git!(origin, ["config", "user.email", "test@example.com"])
    git!(origin, ["config", "user.name", "test"])
    commit!(origin, "README", "root")

    git!(origin, ["checkout", "-q", "-b", "HFE-6470"])
    commit!(origin, "epic", "epic base")

    git!(origin, ["checkout", "-q", "-b", "HFE-6471"])
    commit!(origin, "one", "sub-task one")

    git!(origin, ["checkout", "-q", "HFE-6470"])
    git!(origin, ["merge", "--no-ff", "-m", "merge one", "HFE-6471"])

    git!(origin, ["checkout", "-q", "-b", "HFE-6472"])
    commit!(origin, "two", "sub-task two")

    git!(origin, ["checkout", "-q", "HFE-6470"])
  end

  defp start_gate!(project, origin) do
    {:ok, pid} =
      DependencyGate.start_link(
        name: ProjectSupervisor.via_tuple(project, :dependency_gate),
        project_name: project,
        repo_url: origin,
        forge: "github",
        forge_checker: fn _mirror, _forge, _dep, _base -> :blocked end
      )

    await_mirror(pid)
    pid
  end

  defp await_mirror(pid, attempts \\ 100)

  defp await_mirror(_pid, 0), do: flunk("gate never finished its initial mirror sync")

  defp await_mirror(pid, attempts) do
    if DependencyGate.merged?(pid, "HFE-6471", "HFE-6470") == :unknown do
      Process.sleep(50)
      await_mirror(pid, attempts - 1)
    else
      :ok
    end
  end

  # The gate answers `:pending` on first sight of a pair and resolves off the
  # process, so give it the tick the orchestrator would give it.
  defp await_verdict(pid, dep, base, attempts \\ 100)

  defp await_verdict(_pid, _dep, _base, 0), do: flunk("verdict never settled")

  defp await_verdict(pid, dep, base, attempts) do
    case DependencyGate.merged?(pid, dep, base) do
      :pending ->
        Process.sleep(50)
        await_verdict(pid, dep, base, attempts - 1)

      verdict ->
        verdict
    end
  end

  defp seed_state(project) do
    settings = Config.settings!()

    %State{
      config: settings,
      project_name: project,
      max_concurrent_agents: settings.agent.max_concurrent_agents,
      running: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      recent_completed: [],
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp issue(blockers) do
    %Issue{
      id: "iss-#{System.unique_integer([:positive])}",
      identifier: "HFE-6473",
      title: "Dependent sub-task",
      description: "n/a",
      state: "Todo",
      parent_identifier: "HFE-6470",
      branch_from_parent: true,
      blocked_by: blockers,
      url: "https://example.org/HFE-6473"
    }
  end

  test "a dependency is gated on its own base, not on the dependent's", %{project: project, origin: origin} do
    # HFE-6471 landed on the epic branch, so it is done with. A dependent that
    # cuts from `main` instead would, under the old reading, ask "is HFE-6471
    # on main?" — it is not, and never will be until the whole epic lands, so
    # the ticket would be blocked forever. Asking where the *dependency* was
    # supposed to land is what avoids that.
    start_gate!(project, origin)

    landed = %{
      id: "b1",
      identifier: "HFE-6471",
      state: "In Progress",
      parent_identifier: "HFE-6470",
      branch_from_parent: true
    }

    dependent = %{issue([landed]) | parent_identifier: nil, branch_from_parent: false}

    assert PromptBuilder.base_branch(dependent, Config.settings!()) != "HFE-6470"
    assert eventually_dispatchable?(dependent, project)
  end

  test "a dependency with no policy of its own falls back to the dependent's base", %{project: project, origin: origin} do
    # Every tracker but YouTrack supplies no policy on a blocker entry, so this
    # is the path that must keep behaving exactly as it did before.
    pid = start_gate!(project, origin)
    assert await_verdict(pid, "HFE-6472", "HFE-6470") == :blocked

    bare = %{id: "b1", identifier: "HFE-6472", state: "Done"}
    refute Orchestrator.should_dispatch_issue_for_test(issue([bare]), seed_state(project))
  end

  defp eventually_dispatchable?(issue, project, attempts \\ 100)

  defp eventually_dispatchable?(_issue, _project, 0), do: false

  defp eventually_dispatchable?(issue, project, attempts) do
    if Orchestrator.should_dispatch_issue_for_test(issue, seed_state(project)) do
      true
    else
      Process.sleep(50)
      eventually_dispatchable?(issue, project, attempts - 1)
    end
  end

  test "a Done dependency whose branch has not landed still blocks", %{project: project, origin: origin} do
    # The headline change. Before, "Done" was the whole answer and this
    # dispatched onto an epic branch missing HFE-6472's work entirely.
    pid = start_gate!(project, origin)
    assert await_verdict(pid, "HFE-6472", "HFE-6470") == :blocked

    dependent = issue([%{id: "b1", identifier: "HFE-6472", state: "Done"}])
    refute Orchestrator.should_dispatch_issue_for_test(dependent, seed_state(project))
  end

  test "a dependency that has landed unblocks even while its ticket is open", %{project: project, origin: origin} do
    # The mirror image: merge into the base is the stronger claim in both
    # directions, so a ticket nobody closed does not hold up work that is
    # demonstrably already on the branch.
    pid = start_gate!(project, origin)
    assert await_verdict(pid, "HFE-6471", "HFE-6470") == :merged

    dependent = issue([%{id: "b1", identifier: "HFE-6471", state: "In Progress"}])
    assert Orchestrator.should_dispatch_issue_for_test(dependent, seed_state(project))
  end

  test "a dependency with no branch falls back to its tracker state", %{project: project, origin: origin} do
    # Squash-then-delete and never-started look identical from the mirror, so
    # the ticket is the right tie-breaker.
    start_gate!(project, origin)

    done = issue([%{id: "b1", identifier: "HFE-9999", state: "Done"}])
    assert Orchestrator.should_dispatch_issue_for_test(done, seed_state(project))

    open = issue([%{id: "b1", identifier: "HFE-9999", state: "In Progress"}])
    refute Orchestrator.should_dispatch_issue_for_test(open, seed_state(project))
  end

  test "a project with no gate behaves exactly as it did before", %{project: project} do
    # Legacy WORKFLOW.md mode and any project without repo_url runs without a
    # gate, and must not change behaviour at all.
    state = seed_state(project)

    assert Orchestrator.should_dispatch_issue_for_test(issue([%{id: "b", identifier: "X-1", state: "Done"}]), state)
    refute Orchestrator.should_dispatch_issue_for_test(issue([%{id: "b", identifier: "X-1", state: "Todo"}]), state)
  end

  test "an issue already in progress is not gated on its dependencies", %{project: project, origin: origin} do
    # The rule applies while the issue is queued only, so an in-flight worker
    # can finish what it started.
    start_gate!(project, origin)

    running = %{issue([%{id: "b1", identifier: "HFE-6472", state: "Done"}]) | state: "In Progress"}
    assert Orchestrator.should_dispatch_issue_for_test(running, seed_state(project))
  end
end
