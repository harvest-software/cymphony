defmodule CymphonyElixir.Orchestrator.DurableState do
  @moduledoc """
  The part of an orchestrator's state that must survive a daemon restart.

  The retry queue, held retries, the sessions an interrupted run could resume,
  and the usage limits a provider is waiting out all used to live only in the
  Orchestrator process. A restart — `cymphony restart`, an upgrade, a crash, a
  laptop going to sleep — silently dropped every one of them: a run parked on
  its usage limit or held by a pause simply vanished, and its conversation was
  never resumed.

  Kept in `~/.cymphony/orchestrator_state.json`, keyed by project name, rather
  than in `config.json`: this is volatile runtime state, rewritten on every
  dispatch and retry, and `config.json` is the operator's file.

  Shape of one project's entry (decoded):

      %{
        retries: %{issue_id => %{identifier, attempt, failures, error, due_at_ms,
                                 held, worker_host, workspace_path, usage_limited_until}},
        running: %{issue_id => %{identifier, attempt, failures, worker_host,
                                 workspace_path, session_id, agent_kind}},
        resumable: %{issue_id => %{identifier, session_id, agent_kind, worker_host, reason}},
        usage_limits: %{{agent_kind, provider | nil} => resets_at_unix_seconds}
      }

  `due_at_ms` is wall-clock milliseconds: a monotonic deadline means nothing
  to the next VM.

  Everything read back is validated field by field; an entry that does not
  parse is dropped, never allowed to crash `Orchestrator.init/1` — a corrupt
  state file must not take the project down with it.
  """

  require Logger

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig

  @file_name "orchestrator_state.json"
  @file_mode 0o600
  @legacy_key "__default__"

  @type project_state :: %{
          retries: %{String.t() => map()},
          running: %{String.t() => map()},
          resumable: %{String.t() => map()},
          usage_limits: %{{String.t(), String.t() | nil} => integer()}
        }

  @spec empty() :: project_state()
  def empty, do: %{retries: %{}, running: %{}, resumable: %{}, usage_limits: %{}}

  @doc """
  Whether durable state is read and written at all. Off under `mix test` (see
  `config/config.exs`): every test orchestrator would otherwise share one file
  and restore each other's retries.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:cymphony_elixir, :durable_orchestrator_state, true) == true

  @spec path() :: String.t()
  def path do
    case Application.get_env(:cymphony_elixir, :orchestrator_state_file) do
      path when is_binary(path) -> path
      _ -> Path.join(CymphonyConfig.config_dir(), @file_name)
    end
  end

  @spec load(String.t() | nil) :: project_state()
  def load(project_name) do
    if enabled?() do
      case read_file() do
        {:ok, %{"projects" => %{} = projects}} -> decode_project(Map.get(projects, key(project_name)))
        {:ok, _other} -> empty()
        {:error, :enoent} -> empty()
        {:error, reason} -> warn_unreadable(reason)
      end
    else
      empty()
    end
  end

  @spec save(String.t() | nil, project_state()) :: :ok | {:error, term()}
  def save(project_name, %{} = state) do
    if enabled?() do
      :global.trans({{__MODULE__, :write}, self()}, fn -> write_project(key(project_name), encode_project(state)) end)
    else
      :ok
    end
  end

  defp write_project(project_key, encoded) do
    projects =
      case read_file() do
        {:ok, %{"projects" => %{} = projects}} -> projects
        _ -> %{}
      end

    empty? = encoded == encode_project(empty())

    cond do
      # Nothing to record and nothing recorded: no file to create or rewrite.
      empty? and not Map.has_key?(projects, project_key) -> :ok
      empty? -> write_projects(Map.delete(projects, project_key))
      true -> write_projects(Map.put(projects, project_key, encoded))
    end
  end

  defp write_projects(projects) do
    with :ok <- File.mkdir_p(Path.dirname(path())),
         {:ok, json} <- Jason.encode(%{"version" => 1, "projects" => projects}, pretty: true) do
      write_atomically(path(), json)
    end
  end

  defp read_file do
    with {:ok, body} <- File.read(path()) do
      Jason.decode(body)
    end
  end

  defp warn_unreadable(reason) do
    Logger.warning("Could not read #{path()} (#{inspect(reason)}); starting without saved retries or resumable sessions")
    empty()
  end

  defp write_atomically(path, json) do
    staged = "#{path}.tmp-#{:erlang.unique_integer([:positive])}"

    with :ok <- File.write(staged, ""),
         :ok <- File.chmod(staged, @file_mode),
         :ok <- File.write(staged, json),
         :ok <- File.rename(staged, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(staged)
        {:error, reason}
    end
  end

  defp key(project_name) when is_binary(project_name) and project_name != "", do: project_name
  defp key(_project_name), do: @legacy_key

  ## Encoding

  defp encode_project(state) do
    %{
      "retries" => encode_map(Map.get(state, :retries, %{}), &encode_retry/1),
      "running" => encode_map(Map.get(state, :running, %{}), &encode_running/1),
      "resumable" => encode_map(Map.get(state, :resumable, %{}), &encode_resumable/1),
      "usage_limits" =>
        state
        |> Map.get(:usage_limits, %{})
        |> Enum.map(fn {{kind, provider}, resets_at} ->
          %{"agent_kind" => kind, "provider" => provider, "resets_at" => resets_at}
        end)
        |> Enum.sort_by(&{&1["agent_kind"], &1["provider"] || ""})
    }
  end

  defp encode_map(entries, encoder) do
    Map.new(entries, fn {issue_id, entry} -> {issue_id, encoder.(entry)} end)
  end

  defp encode_retry(entry) do
    pick(entry, [
      :identifier,
      :attempt,
      :failures,
      :error,
      :due_at_ms,
      :held,
      :worker_host,
      :workspace_path,
      :usage_limited_until
    ])
  end

  defp encode_running(entry) do
    pick(entry, [:identifier, :attempt, :failures, :worker_host, :workspace_path, :session_id, :agent_kind])
  end

  defp encode_resumable(entry) do
    pick(entry, [:identifier, :session_id, :agent_kind, :worker_host, :reason])
  end

  defp pick(entry, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case Map.get(entry, key) do
        nil -> acc
        value -> Map.put(acc, Atom.to_string(key), value)
      end
    end)
  end

  ## Decoding

  defp decode_project(%{} = raw) do
    %{
      retries: decode_map(raw["retries"], &decode_retry/1),
      running: decode_map(raw["running"], &decode_running/1),
      resumable: decode_map(raw["resumable"], &decode_resumable/1),
      usage_limits: decode_usage_limits(raw["usage_limits"])
    }
  end

  defp decode_project(_raw), do: empty()

  defp decode_map(%{} = raw, decoder) do
    Enum.reduce(raw, %{}, fn
      {issue_id, %{} = entry}, acc when is_binary(issue_id) and issue_id != "" ->
        case decoder.(entry) do
          nil -> acc
          decoded -> Map.put(acc, issue_id, decoded)
        end

      _entry, acc ->
        acc
    end)
  end

  defp decode_map(_raw, _decoder), do: %{}

  defp decode_retry(%{"due_at_ms" => due_at_ms} = raw) when is_integer(due_at_ms) do
    %{
      identifier: string(raw["identifier"]),
      attempt: positive_int(raw["attempt"]) || 1,
      failures: non_negative_int(raw["failures"]) || 0,
      error: string(raw["error"]),
      due_at_ms: due_at_ms,
      held: raw["held"] == true,
      worker_host: string(raw["worker_host"]),
      workspace_path: string(raw["workspace_path"]),
      usage_limited_until: positive_int(raw["usage_limited_until"])
    }
  end

  defp decode_retry(_raw), do: nil

  defp decode_running(raw) do
    %{
      identifier: string(raw["identifier"]),
      attempt: positive_int(raw["attempt"]),
      failures: non_negative_int(raw["failures"]) || 0,
      worker_host: string(raw["worker_host"]),
      workspace_path: string(raw["workspace_path"]),
      session_id: string(raw["session_id"]),
      agent_kind: string(raw["agent_kind"])
    }
  end

  defp decode_resumable(raw) do
    with session_id when is_binary(session_id) <- string(raw["session_id"]),
         agent_kind when is_binary(agent_kind) <- string(raw["agent_kind"]) do
      %{
        identifier: string(raw["identifier"]),
        session_id: session_id,
        agent_kind: agent_kind,
        worker_host: string(raw["worker_host"]),
        reason: string(raw["reason"])
      }
    else
      _ -> nil
    end
  end

  defp decode_usage_limits(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn
      %{"agent_kind" => kind, "resets_at" => resets_at} = entry, acc
      when is_binary(kind) and is_integer(resets_at) ->
        Map.put(acc, {kind, string(entry["provider"])}, resets_at)

      _entry, acc ->
        acc
    end)
  end

  defp decode_usage_limits(_entries), do: %{}

  defp string(value) when is_binary(value) and value != "", do: value
  defp string(_value), do: nil

  defp positive_int(value) when is_integer(value) and value > 0, do: value
  defp positive_int(_value), do: nil

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(_value), do: nil
end
