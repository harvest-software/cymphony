defmodule CymphonyElixir.YouTrack.Client do
  @moduledoc """
  Thin YouTrack REST client for polling candidate issues and writing back.

  Config mapping (`tracker` section of the resolved workflow settings):

    * `endpoint` — the instance root, e.g. `https://example.youtrack.cloud`.
      A trailing `/` or `/api` is tolerated and normalized away.
    * `api_key` — a YouTrack permanent token (`perm:…`), sent as a bearer token.
    * `project_slug` — the project's short name, e.g. `LLM`.
    * `assignee` — optional login; when set, only issues assigned to it are
      routed to this worker.

  Every read pages through `$top`/`$skip` and then filters the decoded issues
  by state name locally, so the search-query clause is only a narrowing hint
  (see `CymphonyElixir.YouTrack.Query`).
  """

  require Logger

  alias CymphonyElixir.Config
  alias CymphonyElixir.Linear.Issue, as: NormalizedIssue
  alias CymphonyElixir.YouTrack.BranchPolicy
  alias CymphonyElixir.YouTrack.Issue
  alias CymphonyElixir.YouTrack.Query
  alias CymphonyElixir.YouTrack.Scope

  @page_size 100
  @max_pages 50
  # Depth cap for the `scope_issue` subtree walk. YouTrack permits a link graph
  # with cycles, and a visited set already terminates those; this is the second
  # belt, against a pathologically deep tree turning one poll into 100 requests.
  @max_subtree_depth 10
  @max_query_scope_ids 200
  @request_timeout_ms 30_000
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [NormalizedIssue.t()]} | {:error, term()}
  def fetch_candidate_issues, do: fetch_candidate_issues(Config.settings!())

  @spec fetch_candidate_issues(term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(config) do
    with {:ok, tracker} <- tracker_settings(config) do
      fetch_states(tracker, tracker.active_states, tracker.assignee)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(state_names), do: fetch_issues_by_states(state_names, Config.settings!())

  @spec fetch_issues_by_states([String.t()], term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(state_names, config) when is_list(state_names) do
    states = normalized_states(state_names)

    if states == [] do
      {:ok, []}
    else
      with {:ok, tracker} <- tracker_settings(config) do
        fetch_states(tracker, states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: fetch_issue_states_by_ids(issue_ids, Config.settings!())

  @spec fetch_issue_states_by_ids([String.t()], term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, config) when is_list(issue_ids) do
    case Enum.uniq(issue_ids) do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, tracker} <- tracker_settings(config) do
          fetch_each_issue(tracker, ids)
        end
    end
  end

  @doc """
  Every id in the subtree rooted at `root_id`: the root itself plus its
  descendants, at any depth.

  Walked breadth-first, one query per level, because an issue carries only its
  *immediate* parent — and an intermediate ancestor may itself be in a
  non-active state and so absent from the polled candidate set, which is why
  the subtree cannot be reconstructed from that set alone.
  """
  @spec fetch_descendant_ids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_descendant_ids(root_id), do: fetch_descendant_ids(root_id, Config.settings!())

  @spec fetch_descendant_ids(String.t(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_descendant_ids(root_id, config) when is_binary(root_id) do
    case String.trim(root_id) do
      "" ->
        {:ok, []}

      root ->
        with {:ok, tracker} <- tracker_settings(config) do
          walk_subtree(tracker, [root], MapSet.new([root]), 0)
        end
    end
  end

  @doc """
  The tag names of each id in `issue_ids`, keyed by `idReadable`.

  One request for the whole set, requesting only `tags(name)`. Backs
  `CymphonyElixir.YouTrack.BranchPolicy`, which needs a parent's tags to decide
  whether its children branch off it, and cannot get them from the children's
  own payloads.
  """
  @spec fetch_issue_labels([String.t()], term()) :: {:ok, %{optional(String.t()) => [String.t()]}} | {:error, term()}
  def fetch_issue_labels(issue_ids, config) when is_list(issue_ids) do
    ids = normalized_states(issue_ids)

    if ids == [] do
      {:ok, %{}}
    else
      with {:ok, tracker} <- tracker_settings(config),
           {:ok, raw_issues} <- fetch_pages(tracker, Query.by_ids(ids), 0, [], "idReadable,tags(name)") do
        {:ok, Map.new(raw_issues, &{&1["idReadable"], tag_names(&1)})}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: create_comment(issue_id, body, Config.settings!())

  @spec create_comment(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, config) when is_binary(issue_id) and is_binary(body) do
    with {:ok, tracker} <- tracker_settings(config) do
      tracker
      |> post("/issues/#{URI.encode(issue_id)}/comments", %{text: body})
      |> case do
        {:ok, _body} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: update_issue_state(issue_id, state_name, Config.settings!())

  @spec update_issue_state(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, config) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, tracker} <- tracker_settings(config) do
      field = state_field(tracker)
      path = "/issues/#{URI.encode(issue_id)}"

      # Read first, so the write can name the field's real `$type`. A renamed
      # state field is often a plain enum rather than a `StateIssueCustomField`,
      # and YouTrack rejects a mismatched type.
      field_type =
        case get(tracker, path, fields: "customFields($type,name)") do
          {:ok, %{} = raw} -> Issue.custom_field_type(raw, field)
          _ -> nil
        end

      tracker
      |> post(path, state_payload(field, field_type, state_name))
      |> case do
        {:ok, _body} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Body for a state transition on `field`, using the field's own `$type`.

  Falls back to `StateIssueCustomField` when the type could not be read — that
  is YouTrack's stock state field type, so the guess is right far more often
  than it is wrong, and a mismatch fails loudly rather than silently.
  """
  @spec state_payload(String.t(), String.t() | nil, String.t()) :: map()
  def state_payload(field, field_type, state_name) do
    %{customFields: [%{name: field, "$type": field_type || "StateIssueCustomField", value: %{name: state_name}}]}
  end

  @doc """
  Normalizes a configured instance URL to its API root.

  Accepts the instance root with or without a trailing `/` or `/api`, so an
  operator pasting either shape out of the browser gets a working config.
  """
  @spec api_base(String.t()) :: String.t()
  def api_base(endpoint) when is_binary(endpoint) do
    endpoint
    |> instance_base()
    |> Kernel.<>("/api")
  end

  @doc """
  The instance root (no `/api`, no trailing slash) used to build issue URLs.
  """
  @spec instance_base(String.t()) :: String.t()
  def instance_base(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix("/api", "")
    |> String.trim_trailing("/")
  end

  defp tracker_settings(config) do
    tracker = tracker_of(config)

    cond do
      not is_binary(tracker.api_key) or tracker.api_key == "" ->
        {:error, :missing_youtrack_token}

      not is_binary(tracker.endpoint) or instance_base(tracker.endpoint) == "" ->
        {:error, :missing_youtrack_url}

      not is_binary(tracker.project_slug) or tracker.project_slug == "" ->
        {:error, :missing_youtrack_project}

      true ->
        {:ok, tracker}
    end
  end

  defp tracker_of(%{tracker: tracker}), do: tracker

  defp normalize_opts(tracker, assignee) do
    [
      assignee: assignee,
      state_field: state_field(tracker),
      version_field: Map.get(tracker, :version_field),
      merge_to_parent_version: Map.get(tracker, :merge_to_parent_version)
    ]
  end

  defp state_field(%{state_field: value}) when is_binary(value) and value != "", do: value
  defp state_field(_tracker), do: "State"

  defp fetch_states(tracker, state_names, assignee) do
    with {:ok, scope_ids} <- Scope.issue_ids(%{tracker: tracker}) do
      fetch_states(tracker, state_names, assignee, scope_ids)
    end
  end

  defp fetch_states(tracker, state_names, assignee, scope_ids) do
    states = normalized_states(state_names)
    wanted = MapSet.new(Enum.map(states, &Query.normalize_state/1))
    scope = scope_set(scope_ids)

    case fetch_pages(tracker, Query.issues(tracker.project_slug, states, query_scope_ids(scope_ids)), 0, []) do
      {:ok, raw_issues} ->
        {:ok, decode_issues(raw_issues, tracker, assignee, wanted, scope)}

      # YouTrack rejects the *whole* search when a named value is not in the
      # field's bundle ("The value \"Confirmed\" isn't used for the Stage
      # field"), so one stale state name in config blinds the poller
      # completely — 400 on every tick, nothing in the queue, and the only
      # evidence buried in daemon.log. The state clause is a narrowing
      # optimization and never a correctness boundary (the decoded issues are
      # filtered by state locally), so drop it and carry on.
      {:error, {:youtrack_api_status, 400}} ->
        Logger.warning(
          "YouTrack rejected the state-narrowed query for project #{tracker.project_slug}; " <>
            "refetching the project unfiltered. Check that #{inspect(states)} are all values of " <>
            "the #{state_field(tracker)} field (see the logged response body)."
        )

        case fetch_pages(tracker, Query.issues(tracker.project_slug, [], query_scope_ids(scope_ids)), 0, []) do
          {:ok, raw_issues} -> {:ok, decode_issues(raw_issues, tracker, assignee, wanted, scope)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp walk_subtree(_tracker, [], visited, _depth), do: {:ok, MapSet.to_list(visited)}

  defp walk_subtree(_tracker, _frontier, visited, depth) when depth >= @max_subtree_depth do
    Logger.warning("YouTrack subtree walk stopped at the #{@max_subtree_depth}-level cap; deeper sub-tasks are out of scope")

    {:ok, MapSet.to_list(visited)}
  end

  defp walk_subtree(tracker, frontier, visited, depth) do
    case fetch_child_ids(tracker, frontier) do
      {:ok, ids} ->
        next = Enum.reject(ids, &MapSet.member?(visited, &1))
        walk_subtree(tracker, next, MapSet.union(visited, MapSet.new(next)), depth + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_child_ids(tracker, parent_ids) do
    case Query.subtree(parent_ids) do
      "" ->
        {:ok, []}

      query ->
        case fetch_pages(tracker, query, 0, [], "idReadable") do
          {:ok, raw_issues} -> {:ok, Enum.flat_map(raw_issues, &readable_id/1)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp readable_id(%{"idReadable" => id}) when is_binary(id) and id != "", do: [id]
  defp readable_id(_issue), do: []

  defp tag_names(%{"tags" => tags}) when is_list(tags) do
    Enum.flat_map(tags, fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp tag_names(_issue), do: []

  defp fetch_pages(tracker, query, page, acc), do: fetch_pages(tracker, query, page, acc, Issue.fields())

  defp fetch_pages(_tracker, _query, page, acc, _fields) when page >= @max_pages do
    Logger.warning("YouTrack poll stopped at the #{@max_pages}-page cap; narrow the project's active states")
    {:ok, acc}
  end

  defp fetch_pages(tracker, query, page, acc, fields) do
    params = [
      query: query,
      fields: fields,
      "$top": @page_size,
      "$skip": page * @page_size
    ]

    case get(tracker, "/issues", params) do
      {:ok, issues} when is_list(issues) ->
        acc = acc ++ issues

        if length(issues) < @page_size do
          {:ok, acc}
        else
          fetch_pages(tracker, query, page + 1, acc, fields)
        end

      {:ok, _other} ->
        {:error, :youtrack_unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_each_issue(tracker, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      tracker
      |> get("/issues/#{URI.encode(id)}", fields: Issue.fields())
      |> collect_issue(tracker, acc)
    end)
  end

  defp collect_issue({:ok, %{} = raw}, tracker, acc) do
    opts = normalize_opts(tracker, tracker.assignee) ++ [feature_branch_parents: feature_branch_parents(tracker, [raw])]

    case Issue.normalize(raw, instance_base(tracker.endpoint), opts) do
      nil -> {:cont, {:ok, acc}}
      issue -> {:cont, {:ok, acc ++ [issue]}}
    end
  end

  defp collect_issue({:ok, _other}, _tracker, acc), do: {:cont, {:ok, acc}}

  # A running issue that has been deleted must not fail the whole reconcile
  # pass — the orchestrator reads a missing id as "no longer active", which is
  # exactly right.
  defp collect_issue({:error, {:youtrack_api_status, 404}}, _tracker, acc), do: {:cont, {:ok, acc}}
  defp collect_issue({:error, reason}, _tracker, _acc), do: {:halt, {:error, reason}}

  defp decode_issues(raw_issues, tracker, assignee, wanted, scope) do
    base = instance_base(tracker.endpoint)
    opts = normalize_opts(tracker, assignee) ++ [feature_branch_parents: feature_branch_parents(tracker, raw_issues)]

    raw_issues
    |> Enum.map(&Issue.normalize(&1, base, opts))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&(wanted_state?(&1, wanted) and in_scope?(&1, scope)))
  end

  # Whether an issue branches off its parent depends on the *parent's* tags,
  # which no child payload carries. Seed the cache with what this batch already
  # knows about itself — an epic in an active state is usually right here — and
  # let `BranchPolicy` fetch only the remainder, once, for the whole page.
  defp feature_branch_parents(tracker, raw_issues) do
    config = %{tracker: tracker}

    BranchPolicy.seed(config, Map.new(raw_issues, &{&1["idReadable"], tag_names(&1)}))
    BranchPolicy.feature_branch_parents(config, Enum.flat_map(raw_issues, &Issue.referenced_parent_ids/1))
  end

  # `nil` is "unscoped", never "nothing in scope" — the two must not collapse,
  # or a project with no `scope_issue` would poll nothing at all.
  defp scope_set([]), do: nil
  defp scope_set(ids) when is_list(ids), do: MapSet.new(ids)

  defp in_scope?(_issue, nil), do: true
  defp in_scope?(%{identifier: identifier}, scope), do: MapSet.member?(scope, identifier)

  # The `issue id:` clause is a narrowing optimization, and a very large scope
  # would make the query longer than the server will accept. Past the cap the
  # clause is dropped and the local `in_scope?/2` filter — which is the actual
  # correctness boundary — carries the whole load.
  defp query_scope_ids(ids) when length(ids) > @max_query_scope_ids, do: []
  defp query_scope_ids(ids), do: ids

  defp wanted_state?(issue, wanted) do
    MapSet.member?(wanted, Query.normalize_state(issue.state))
  end

  defp normalized_states(state_names) do
    state_names
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp get(tracker, path, params) do
    request(tracker, :get, path, params, nil)
  end

  defp post(tracker, path, payload) do
    request(tracker, :post, path, [fields: "id"], payload)
  end

  defp request(tracker, method, path, params, payload) do
    url = api_base(tracker.endpoint) <> path

    opts =
      [
        method: method,
        url: url,
        headers: headers(tracker.api_key),
        params: params,
        connect_options: [timeout: @request_timeout_ms]
      ]
      |> maybe_put_json(payload)

    case Req.request(opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, response} ->
        Logger.error("YouTrack #{method} #{path} failed status=#{response.status}#{error_context(response)}")
        {:error, {:youtrack_api_status, response.status}}

      {:error, reason} ->
        Logger.error("YouTrack #{method} #{path} failed: #{inspect(reason)}")
        {:error, {:youtrack_api_request, reason}}
    end
  end

  defp maybe_put_json(opts, nil), do: opts
  defp maybe_put_json(opts, payload), do: Keyword.put(opts, :json, payload)

  defp headers(api_key) do
    [
      {"Authorization", "Bearer " <> String.trim(api_key)},
      {"Accept", "application/json"}
    ]
  end

  defp error_context(%{body: body}) do
    " body=" <> (body |> inspect() |> String.slice(0, @max_error_body_log_bytes))
  end
end
