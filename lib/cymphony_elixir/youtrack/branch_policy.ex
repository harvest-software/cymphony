defmodule CymphonyElixir.YouTrack.BranchPolicy do
  @moduledoc """
  Answers "is this issue a feature-branch container?" for a set of parent ids.

  A sub-task branches off its direct parent when that parent carries the
  `tracker.feature_branch_label` tag (`Feature Branch` by default). The decision
  therefore needs the *parent's* tags — and an issue payload never carries them,
  only its own.

  Deepening the poll's field selection to fetch them would grow every response
  for a value that changes on the order of days, so the answer is cached here
  instead, in `:persistent_term` like `CymphonyElixir.YouTrack.Scope`. Unknown
  ids are resolved in **one** batched request per poll at most, and the poll's
  own issues seed the cache for free through `seed/2` — an epic in an active
  state is usually in the batch already.

  A resolution failure is logged and treated as "not a container". That is the
  conservative direction: the sub-task targets the configured base branch, which
  a human sees on the merge request, whereas the opposite error would silently
  retarget work onto a branch it was never meant to touch.
  """

  alias CymphonyElixir.YouTrack.Client
  alias CymphonyElixir.YouTrack.Query

  require Logger

  @ttl_ms 60_000
  @default_label "Feature Branch"

  @doc """
  The subset of `ids` that are feature-branch containers, normalized for
  comparison (trimmed and downcased, via `Query.normalize_state/1`).

  Always succeeds: ids that cannot be resolved are simply absent.
  """
  @spec feature_branch_parents(term(), [String.t()]) :: [String.t()]
  def feature_branch_parents(config, ids) when is_list(ids) do
    case label(config) do
      nil -> []
      label -> resolve_parents(config, Enum.uniq(Enum.filter(ids, &is_binary/1)), label)
    end
  end

  @doc """
  Records the labels of issues already in hand, so they are never refetched.
  """
  @spec seed(term(), %{optional(String.t()) => [String.t()]}) :: :ok
  def seed(config, labels_by_id) when is_map(labels_by_id) do
    Enum.each(labels_by_id, fn {id, labels} -> cache_put(config, id, labels) end)
  end

  @doc """
  The configured container label, or `nil` when the feature is switched off.
  """
  @spec label(term()) :: String.t() | nil
  def label(%{tracker: %{feature_branch_label: value}}) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def label(%{tracker: %{}}), do: @default_label
  def label(_config), do: @default_label

  @doc """
  Drops the cached labels for `id`, so the next read re-resolves them.
  """
  @spec invalidate(term(), String.t()) :: :ok
  def invalidate(config, id) when is_binary(id) do
    :persistent_term.erase(key(config, id))
    :ok
  end

  defp resolve_parents(config, ids, label) do
    {known, unknown} = Enum.split_with(ids, &cached?(config, &1))

    fetched =
      case unknown do
        [] -> %{}
        _ -> fetch_labels(config, unknown)
      end

    seed(config, fetched)

    known
    |> Enum.concat(Map.keys(fetched))
    |> Enum.filter(&container?(config, &1, label))
    |> Enum.map(&Query.normalize_state/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp fetch_labels(config, ids) do
    case Client.fetch_issue_labels(ids, config) do
      {:ok, labels_by_id} ->
        labels_by_id

      {:error, reason} ->
        Logger.warning("Could not resolve feature-branch tags for #{inspect(ids)}: #{inspect(reason)}")
        %{}
    end
  end

  defp container?(config, id, label) do
    wanted = Query.normalize_state(label)

    config
    |> cached_labels(id)
    |> List.wrap()
    |> Enum.any?(&(Query.normalize_state(&1) == wanted))
  end

  defp cached?(config, id), do: cached_labels(config, id) != nil

  defp cached_labels(config, id) do
    case :persistent_term.get(key(config, id), nil) do
      {labels, cached_at} when is_list(labels) -> if fresh?(cached_at), do: labels, else: nil
      _ -> nil
    end
  end

  defp cache_put(config, id, labels) when is_binary(id) and is_list(labels) do
    :persistent_term.put(key(config, id), {labels, System.monotonic_time(:millisecond)})
    :ok
  end

  defp cache_put(_config, _id, _labels), do: :ok

  defp fresh?(cached_at), do: System.monotonic_time(:millisecond) - cached_at < ttl_ms()

  # Overridable so a test can watch the cache expire without waiting a minute.
  defp ttl_ms, do: Application.get_env(:cymphony_elixir, :branch_policy_cache_ttl_ms, @ttl_ms)

  defp key(config, id), do: {__MODULE__, endpoint(config), id}

  defp endpoint(%{tracker: %{endpoint: endpoint}}) when is_binary(endpoint), do: endpoint
  defp endpoint(_config), do: ""
end
