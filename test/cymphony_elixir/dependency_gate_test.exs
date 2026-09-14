defmodule CymphonyElixir.DependencyGateTest do
  @moduledoc """
  The gate exists because "the ticket says Fixed" and "the code is on the
  branch I am about to cut from" are different claims. These tests drive it
  against a real git repository so the ancestry answers are the ones git
  actually gives, not a stub's idea of them.
  """

  use ExUnit.Case, async: false

  alias CymphonyElixir.DependencyGate

  setup do
    root = Path.join(System.tmp_dir!(), "cymphony-gate-#{System.unique_integer([:positive])}")
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

    {:ok, origin: origin, root: root}
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

  # main
  #  └── HFE-6470            the epic branch, the base every sub-task targets
  #       ├── HFE-6471       merged into the epic
  #       └── HFE-6472       published but not merged
  # A second repository for the tests that need their own, since `setup`'s is
  # shared with the surrounding assertions.
  defp build_scratch do
    root = Path.join(System.tmp_dir!(), "cymphony-gate-scratch-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin")
    File.mkdir_p!(origin)
    on_exit(fn -> File.rm_rf(root) end)
    build_origin!(origin)
    %{origin: origin}
  end

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

  # The real checker shells out to `glab`/`gh`; a suite that needed either
  # installed and authenticated would be testing the machine, not the gate.
  defp stub_forge(verdict), do: fn _mirror, _forge, _dep, _base -> verdict end

  defp start_gate!(origin, opts \\ []) do
    name = :"gate-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      DependencyGate.start_link(
        name: name,
        project_name: "gate-test-#{System.unique_integer([:positive])}",
        repo_url: origin,
        forge: Keyword.get(opts, :forge, "github"),
        forge_checker: Keyword.get(opts, :forge_checker, stub_forge(:blocked))
      )

    # The initial mirror clone is a real `git clone --mirror`, so wait for the
    # gate to report something other than "no mirror yet" before asserting.
    await_ready(pid)
    pid
  end

  defp await_ready(pid, attempts \\ 100)

  defp await_ready(_pid, 0), do: flunk("gate never finished its initial mirror sync")

  defp await_ready(pid, attempts) do
    if DependencyGate.merged?(pid, "HFE-6471", "HFE-6470") == :unknown do
      Process.sleep(50)
      await_ready(pid, attempts - 1)
    else
      :ok
    end
  end

  defp settle(pid, dep, base, attempts \\ 100)

  defp settle(_pid, _dep, _base, 0), do: flunk("verdict never settled")

  defp settle(pid, dep, base, attempts) do
    case DependencyGate.merged?(pid, dep, base) do
      :pending ->
        Process.sleep(50)
        settle(pid, dep, base, attempts - 1)

      verdict ->
        verdict
    end
  end

  test "a dependency merged into the base reads as merged", %{origin: origin} do
    pid = start_gate!(origin)
    assert settle(pid, "HFE-6471", "HFE-6470") == :merged
  end

  test "a published but unmerged dependency blocks", %{origin: origin} do
    # This is the case the tracker's state cannot see: the ticket may well say
    # Fixed while the branch is still sitting in review.
    pid = start_gate!(origin)
    assert settle(pid, "HFE-6472", "HFE-6470") == :blocked
  end

  test "a blocked verdict expires, so a dependency that lands later unblocks", %{origin: origin} do
    # The whole point of re-checking: HFE-6472 is in review now and merged in a
    # minute, and the dependent has to notice without a restart.
    Application.put_env(:cymphony_elixir, :dependency_gate_ttl_ms, 0)
    on_exit(fn -> Application.delete_env(:cymphony_elixir, :dependency_gate_ttl_ms) end)

    pid = start_gate!(origin, forge_checker: stub_forge(:blocked))
    assert settle(pid, "HFE-6472", "HFE-6470") == :blocked

    git!(origin, ["checkout", "-q", "HFE-6470"])
    git!(origin, ["merge", "--no-ff", "-m", "merge two", "HFE-6472"])
    send(pid, :scheduled_sync)

    assert eventually_merged(pid, "HFE-6472", "HFE-6470")
  end

  defp eventually_merged(pid, dep, base, attempts \\ 100)

  defp eventually_merged(_pid, _dep, _base, 0), do: flunk("verdict never became merged")

  defp eventually_merged(pid, dep, base, attempts) do
    case DependencyGate.merged?(pid, dep, base) do
      :merged ->
        true

      _ ->
        Process.sleep(50)
        eventually_merged(pid, dep, base, attempts - 1)
    end
  end

  test "a dependency with no branch on the remote is unknown, not blocked", %{origin: origin} do
    # Squash-then-delete leaves no branch, and so does a dependency that never
    # started — indistinguishable from here, so the caller's tracker-state test
    # is the right tie-breaker.
    pid = start_gate!(origin)
    assert DependencyGate.merged?(pid, "HFE-9999", "HFE-6470") == :unknown
  end

  test "an unknown base ref is unknown rather than blocking everything", %{origin: origin} do
    # A parent branch that does not exist yet is the normal state before the
    # first sub-task runs. Reporting `:blocked` there would deadlock the epic.
    pid = start_gate!(origin)
    assert DependencyGate.merged?(pid, "HFE-6471", "HFE-7000") == :unknown
  end

  test "a merged verdict is not re-derived", %{origin: origin} do
    pid = start_gate!(origin)
    assert settle(pid, "HFE-6471", "HFE-6470") == :merged

    # Merged stays merged; re-checking would spend a forge request per
    # dependency per minute for the life of the epic.
    assert DependencyGate.merged?(pid, "HFE-6471", "HFE-6470") == :merged
  end

  test "a dead gate answers unknown instead of taking the caller down" do
    # A project with no repo_url runs without a gate at all, and every call
    # site has to degrade to the pre-existing tracker-state behaviour.
    assert DependencyGate.merged?(:"never-started-#{System.unique_integer()}", "a", "b") == :unknown
  end

  test "a squash-merged dependency is settled by the forge, not by ancestry" do
    # Squashing rewrites the commits, so the dependency's tip is never an
    # ancestor of the base however thoroughly it landed. Ancestry is only the
    # fast local pre-check; the forge is the authority.
    %{origin: origin} = build_scratch()
    pid = start_gate!(origin, forge_checker: stub_forge(:merged))

    assert settle(pid, "HFE-6472", "HFE-6470") == :merged
  end

  test "an unreachable forge is unknown, so it cannot block an epic indefinitely" do
    %{origin: origin} = build_scratch()
    pid = start_gate!(origin, forge_checker: stub_forge(:unknown))

    assert settle(pid, "HFE-6472", "HFE-6470") == :unknown

    # And the cached `:unknown` keeps answering `:unknown` rather than
    # re-queueing a resolution and reporting `:pending` forever.
    assert DependencyGate.merged?(pid, "HFE-6472", "HFE-6470") == :unknown
  end

  test "a repository that cannot be cloned leaves the gate unknown" do
    {:ok, pid} =
      DependencyGate.start_link(
        name: :"gate-broken-#{System.unique_integer([:positive])}",
        project_name: "broken-#{System.unique_integer([:positive])}",
        repo_url: Path.join(System.tmp_dir!(), "definitely-not-a-repo-#{System.unique_integer([:positive])}"),
        forge: "github"
      )

    # Failing closed on infrastructure trouble would wedge a whole project
    # with nothing to show an operator why.
    assert DependencyGate.merged?(pid, "a", "b") == :unknown
  end

  describe "the forge query" do
    test "asks each forge for a merged review from this branch into that base" do
      assert {"glab", gitlab} = DependencyGate.forge_query("gitlab", "HFE-6472", "HFE-6470")
      assert "--source-branch" in gitlab
      assert "--target-branch" in gitlab
      assert "merged" in gitlab

      assert {"gh", github} = DependencyGate.forge_query("github", "HFE-6472", "HFE-6470")
      assert "--head" in github
      assert "--base" in github
      assert "merged" in github
    end

    test "reads a listing with rows as merged and an empty one as blocked" do
      # The squash case: ancestry can never see it, so an actual row from the
      # forge is the only evidence the work landed.
      assert DependencyGate.forge_verdict({"4711\n", 0}, "gh", "a", "b") == :merged
      assert DependencyGate.forge_verdict({"", 0}, "gh", "a", "b") == :blocked
      assert DependencyGate.forge_verdict({"  \n", 0}, "gh", "a", "b") == :blocked
    end

    test "an erroring or unreachable CLI is unknown, never blocked" do
      # Failing closed here would let an unavailable forge wedge an epic with
      # nothing to show an operator why.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert DependencyGate.forge_verdict({"not logged in", 1}, "gh", "a", "b") == :unknown
        end)

      assert log =~ "Forge merge check failed"
      assert DependencyGate.forge_verdict(:error, "gh", "a", "b") == :unknown
    end
  end

  test "a git call that outruns its timeout leaves the gate unknown", %{origin: origin} do
    {:ok, pid} =
      DependencyGate.start_link(
        name: :"gate-slow-#{System.unique_integer([:positive])}",
        project_name: "slow-#{System.unique_integer([:positive])}",
        repo_url: origin,
        git_timeout_ms: 1
      )

    assert DependencyGate.merged?(pid, "HFE-6471", "HFE-6470") == :unknown
  end

  test "refresh/1 re-syncs the mirror out of band", %{origin: origin} do
    pid = start_gate!(origin)
    assert DependencyGate.refresh(pid) == :ok

    # A new branch pushed after the initial sync is visible once the refresh
    # lands, which is what makes "a session just finished" worth reacting to.
    git!(origin, ["branch", "HFE-6480", "HFE-6470"])
    send(pid, :scheduled_sync)
    assert settle(pid, "HFE-6480", "HFE-6470") == :merged
  end

  test "unrelated messages do not disturb the gate", %{origin: origin} do
    pid = start_gate!(origin)

    send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    send(pid, :something_else)

    assert settle(pid, "HFE-6471", "HFE-6470") == :merged
  end

  test "mirror_path/1 keeps the mirror out of every workspace" do
    path = DependencyGate.mirror_path("My Project/x")

    assert Path.basename(path) == "My_Project_x.git"
    assert path =~ "/repos/"
  end
end
