defmodule CymphonyElixir.DependencyGate do
  @moduledoc """
  Answers "has this dependency actually landed on the branch we are about to
  build on?" without doing IO on the orchestrator's dispatch path.

  ## Why tracker state is not enough

  The blocker gate used to hold a queued issue only while some `blocked_by`
  entry sat in a non-terminal state. On an epic whose sub-tasks each publish a
  branch into the epic branch, "the ticket says Fixed" and "the code is on the
  branch I am cutting from" are different claims: a reviewer closes the ticket
  before the merge, a merge request sits approved but unmerged, a branch gets
  reverted. A dependent dispatched on the strength of the ticket then builds on
  code that is not there.

  ## Why git ancestry is not enough either

  Sub-task review branches are routinely squash-merged, which rewrites the
  commits: the dependency's branch tip is then *never* an ancestor of the base,
  no matter how thoroughly it landed. Ancestry is therefore the fast local
  pre-check, and the forge (`glab` / `gh`) is the authority that settles
  anything ancestry calls unmerged.

  ## Why a GenServer

  `git fetch` and a forge CLI are network calls measured in seconds. The
  orchestrator consults the gate several times per issue per tick, so the
  answer has to be a cache read. Resolution runs in a `Task` off this process
  and the call returns immediately with whatever is known:

    * `:merged`  — landed; permanent, because merged stays merged
    * `:blocked` — demonstrably not landed; re-checked after `@ttl_ms`
    * `:pending` — resolution in flight, answer next tick
    * `:unknown` — no mirror, or no such base ref; the caller falls back to
      the tracker-state test, i.e. to the behaviour that predates this module

  A git or CLI failure yields `:unknown` rather than `:blocked`. Failing closed
  on infrastructure trouble would wedge a whole project with no way for an
  operator to see why.
  """

  use GenServer

  require Logger

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.ForgeEnv

  @ttl_ms 60_000
  @fetch_interval_ms 60_000
  @git_timeout_ms 120_000
  @forge_timeout_ms 60_000

  @type verdict :: :merged | :blocked | :pending | :unknown

  defmodule State do
    @moduledoc false
    defstruct [
      :project_name,
      :repo_url,
      :forge,
      :mirror_path,
      :forge_checker,
      forge_env: %{},
      git_timeout_ms: nil,
      ready?: false,
      refs: MapSet.new(),
      verdicts: %{},
      in_flight: MapSet.new()
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Whether `dep_branch` has landed on `base_branch`, from cache only.

  Never blocks on IO: an unresolved pair is queued for resolution and answered
  `:pending`. A dead or missing gate is `:unknown`, so a project running
  without one behaves exactly as it did before.
  """
  @spec merged?(GenServer.server(), String.t(), String.t()) :: verdict()
  def merged?(server, dep_branch, base_branch)
      when is_binary(dep_branch) and is_binary(base_branch) do
    GenServer.call(server, {:merged?, dep_branch, base_branch}, 5_000)
  catch
    :exit, _reason -> :unknown
  end

  @doc """
  Requests an out-of-band `git fetch`, e.g. once a session has finished.
  """
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server), do: GenServer.cast(server, :refresh)

  @impl true
  def init(opts) do
    forge = Keyword.get(opts, :forge, "github")
    # The project's forge credential and host, under the names glab/gh read; the
    # CLI otherwise sees only the daemon's environment, which has neither.
    forge_env = ForgeEnv.cli_env(forge, Keyword.get(opts, :forge_token), Keyword.get(opts, :forge_host))

    state = %State{
      project_name: Keyword.fetch!(opts, :project_name),
      repo_url: Keyword.fetch!(opts, :repo_url),
      forge: forge,
      forge_env: forge_env,
      forge_checker: Keyword.get(opts, :forge_checker, default_forge_checker(forge_env)),
      git_timeout_ms: Keyword.get(opts, :git_timeout_ms, @git_timeout_ms),
      mirror_path: mirror_path(Keyword.fetch!(opts, :project_name))
    }

    send(self(), :sync)
    schedule_sync()
    {:ok, state}
  end

  @impl true
  def handle_call({:merged?, dep_branch, base_branch}, _from, %State{} = state) do
    cond do
      not state.ready? ->
        {:reply, :unknown, state}

      not MapSet.member?(state.refs, base_branch) ->
        {:reply, :unknown, state}

      not MapSet.member?(state.refs, dep_branch) ->
        # The dependency has no branch on the remote. That is the ordinary
        # outcome of a squash-merge with branch deletion, and it is also what a
        # dependency that never started looks like — the two are
        # indistinguishable from here, so the tracker's state is the right
        # tie-breaker and the caller applies it.
        {:reply, :unknown, state}

      true ->
        resolve_or_cached(state, dep_branch, base_branch)
    end
  end

  @impl true
  def handle_cast(:refresh, %State{} = state) do
    send(self(), :sync)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync, %State{} = state) do
    {:noreply, sync_mirror(state)}
  end

  def handle_info(:scheduled_sync, %State{} = state) do
    schedule_sync()
    {:noreply, sync_mirror(state)}
  end

  def handle_info({:verdict, key, verdict}, %State{} = state) do
    {:noreply,
     %State{
       state
       | verdicts: Map.put(state.verdicts, key, {verdict, now_ms()}),
         in_flight: MapSet.delete(state.in_flight, key)
     }}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp resolve_or_cached(%State{} = state, dep_branch, base_branch) do
    key = {dep_branch, base_branch}

    case Map.get(state.verdicts, key) do
      # Merged is permanent: a branch that landed cannot un-land, and
      # re-checking it would spend a forge request per dependency per minute
      # for the life of the epic.
      {:merged, _at} ->
        {:reply, :merged, state}

      # `:blocked` and `:unknown` both expire, and both are answered from the
      # cache while the refresh runs. Returning `:pending` for a cached
      # `:unknown` would re-queue a resolution on every tick and never let the
      # caller fall back to the tracker's state.
      {verdict, at} when verdict in [:blocked, :unknown] ->
        if fresh?(at) do
          {:reply, verdict, state}
        else
          {:reply, verdict, start_resolution(state, key)}
        end

      _ ->
        {:reply, :pending, start_resolution(state, key)}
    end
  end

  defp start_resolution(%State{} = state, key) do
    if MapSet.member?(state.in_flight, key) do
      state
    else
      {dep_branch, base_branch} = key
      owner = self()
      mirror = state.mirror_path
      forge = state.forge
      checker = state.forge_checker

      spawn(fn ->
        send(owner, {:verdict, key, resolve(mirror, forge, checker, dep_branch, base_branch)})
      end)

      %State{state | in_flight: MapSet.put(state.in_flight, key)}
    end
  end

  defp resolve(mirror, forge, checker, dep_branch, base_branch) do
    if ancestor?(mirror, dep_branch, base_branch) do
      :merged
    else
      checker.(mirror, forge, dep_branch, base_branch)
    end
  end

  defp ancestor?(mirror, dep_branch, base_branch) do
    case git(mirror, ["merge-base", "--is-ancestor", ref(dep_branch), ref(base_branch)], @git_timeout_ms) do
      {_output, 0} -> true
      _ -> false
    end
  end

  # A squash-merge rewrites the dependency's commits, so ancestry cannot see it
  # and only the forge knows. `:unknown` on any trouble reaching the CLI — an
  # unavailable forge must not be able to block an epic indefinitely.
  @doc """
  Asks the forge CLI whether `dep_branch` was merged into `base_branch`.

  Public because it is the gate's default `:forge_checker`, which tests
  replace: the real implementation shells out to `glab`/`gh`, and a suite that
  depended on either being installed and authenticated would be testing the
  operator's machine rather than the gate.
  """
  @spec forge_cli_merged?(String.t(), String.t(), String.t(), String.t(), %{String.t() => String.t()}) :: verdict()
  def forge_cli_merged?(mirror, forge, dep_branch, base_branch, env \\ %{}) do
    {cli, args} = forge_query(forge, dep_branch, base_branch)

    cli
    |> cmd(args, mirror, @forge_timeout_ms, env)
    |> forge_verdict(cli, dep_branch, base_branch)
  end

  # Checkers are called with four arguments (tests replace them), so the real
  # one closes over the forge environment rather than taking it per call.
  defp default_forge_checker(env) do
    fn mirror, forge, dep_branch, base_branch -> forge_cli_merged?(mirror, forge, dep_branch, base_branch, env) end
  end

  @doc """
  Reads a forge CLI result as a verdict.

  Separate from the shell-out so the three outcomes can be exercised without
  `glab`/`gh` installed and authenticated — a suite that needed either would
  be testing the machine rather than the gate.
  """
  @spec forge_verdict({String.t(), non_neg_integer()} | :error, String.t(), String.t(), String.t()) :: verdict()
  def forge_verdict({output, 0}, _cli, _dep_branch, _base_branch) do
    # A listing with any row means a review from this branch into this base was
    # merged; an empty one means there is none, which is the squash case's only
    # honest "no".
    if String.trim(output) == "", do: :blocked, else: :merged
  end

  def forge_verdict({output, status}, cli, dep_branch, base_branch) do
    Logger.warning("Forge merge check failed cli=#{cli} branch=#{dep_branch} base=#{base_branch} status=#{status} output=#{inspect(String.slice(output, 0, 500))}")

    :unknown
  end

  def forge_verdict(:error, _cli, _dep_branch, _base_branch), do: :unknown

  @doc """
  The forge CLI invocation that answers "was this branch merged into that one".

  The two CLIs spell the state filter differently: `glab mr list` has a `--merged`
  switch and rejects `gh`'s `--state merged` with "Unknown flag: --state".
  """
  @spec forge_query(String.t(), String.t(), String.t()) :: {String.t(), [String.t()]}
  def forge_query("gitlab", dep_branch, base_branch) do
    {"glab",
     [
       "mr",
       "list",
       "--source-branch",
       dep_branch,
       "--target-branch",
       base_branch,
       "--merged",
       "--output",
       "json"
     ]}
  end

  def forge_query(_forge, dep_branch, base_branch) do
    {"gh", ["pr", "list", "--head", dep_branch, "--base", base_branch, "--state", "merged", "--json", "number", "--jq", ".[].number"]}
  end

  defp sync_mirror(%State{} = state) do
    case ensure_mirror(state) do
      :ok ->
        case git(state.mirror_path, ["fetch", "--prune", "--quiet", "origin", "+refs/heads/*:refs/heads/*"], state.git_timeout_ms) do
          {_output, 0} ->
            %State{state | ready?: true, refs: read_refs(state.mirror_path)}

          {output, status} ->
            Logger.warning("Mirror fetch failed project=#{state.project_name} status=#{status} output=#{inspect(String.slice(output, 0, 500))}")

            state

          :error ->
            state
        end

      {:error, reason} ->
        Logger.warning("Mirror unavailable project=#{state.project_name}: #{inspect(reason)}")
        state
    end
  end

  defp ensure_mirror(%State{mirror_path: path, repo_url: repo_url, project_name: project} = state) do
    if File.dir?(Path.join(path, "objects")) do
      :ok
    else
      File.mkdir_p!(Path.dirname(path))
      Logger.info("Cloning dependency mirror project=#{project} path=#{path}")

      case cmd("git", ["clone", "--mirror", repo_url, path], File.cwd!(), state.git_timeout_ms) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:clone_failed, status, String.slice(output, 0, 500)}}
        :error -> {:error, :git_unavailable}
      end
    end
  end

  defp read_refs(mirror) do
    case git(mirror, ["for-each-ref", "--format=%(refname:short)", "refs/heads"], @git_timeout_ms) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp git(mirror, args, timeout_ms), do: cmd("git", ["-C", mirror | args], File.cwd!(), timeout_ms)

  # `env` is added to the inherited environment, overriding a same-named
  # variable, so the project's config wins over the daemon's shell.
  defp cmd(binary, args, cd, timeout_ms, env \\ %{}) do
    task =
      Task.async(fn ->
        System.cmd(binary, args, stderr_to_stdout: true, cd: cd, env: Enum.to_list(env))
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      _ ->
        Task.shutdown(task, :brutal_kill)
        Logger.warning("#{binary} timed out after #{timeout_ms}ms args=#{inspect(args)}")
        :error
    end
  rescue
    error in [ErlangError, ArgumentError] ->
      Logger.warning("#{binary} could not be run: #{Exception.message(error)}")
      :error
  end

  # A bare mirror, deliberately outside every workspace: the workspace root is
  # a cloned repo the agent commits and pushes from, and anything Cymphony
  # writes in there risks ending up in a review.
  @spec mirror_path(String.t()) :: String.t()
  def mirror_path(project_name) do
    safe = String.replace(project_name, Regex.compile!("[^a-zA-Z0-9._-]"), "_")
    Path.join([CymphonyConfig.config_dir(), "repos", safe <> ".git"])
  end

  defp ref(branch), do: "refs/heads/" <> branch

  defp schedule_sync, do: Process.send_after(self(), :scheduled_sync, @fetch_interval_ms)

  defp fresh?(at), do: now_ms() - at < ttl_ms()

  # Overridable so a test can watch a `:blocked` verdict expire and re-resolve
  # without waiting a minute for it.
  defp ttl_ms, do: Application.get_env(:cymphony_elixir, :dependency_gate_ttl_ms, @ttl_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
