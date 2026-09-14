defmodule CymphonyElixir.YouTrack.Scope do
  @moduledoc """
  Resolves and caches a project's `tracker.scope_issue` subtree.

  A scoped project polls only the named issue and its descendants, at any
  depth. Resolving that set costs one request per level of the tree, which is
  far too much to repeat on every poll tick (`polling.interval_ms` defaults to
  5s), and a subtree changes on the order of days — so the resolved id list is
  cached for `@ttl_ms`.

  The cache lives in `:persistent_term`, like `ShellProvider`'s: reads are what
  the hot path does and they are free there, while the write happens at most
  once per TTL per project.

  A resolution failure is **not** cached and **not** swallowed. Falling back to
  an unscoped poll would dispatch agents across the whole board, which is the
  exact opposite of what scoping was asked to do, so the error propagates and
  the poll retries on the next tick.
  """

  alias CymphonyElixir.YouTrack.Client

  require Logger

  @ttl_ms 60_000

  @doc """
  The ids in scope for `config`, or `[]` when the project has no `scope_issue`.

  `[]` means "unscoped" — every caller treats an empty list as "no filtering",
  never as "nothing is in scope".
  """
  @spec issue_ids(term()) :: {:ok, [String.t()]} | {:error, term()}
  def issue_ids(config) do
    case scope_issue(config) do
      nil -> {:ok, []}
      root -> cached_or_resolve(config, root)
    end
  end

  @doc """
  The configured scope root, or `nil` when the project is unscoped.
  """
  @spec scope_issue(term()) :: String.t() | nil
  def scope_issue(%{tracker: %{scope_issue: value}}) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def scope_issue(_config), do: nil

  @doc """
  Drops the cached subtree for `root`, so the next read re-resolves it.
  """
  @spec invalidate(term(), String.t()) :: :ok
  def invalidate(config, root) when is_binary(root) do
    :persistent_term.erase(key(config, root))
    :ok
  end

  defp cached_or_resolve(config, root) do
    case :persistent_term.get(key(config, root), nil) do
      {ids, cached_at} when is_list(ids) ->
        if fresh?(cached_at), do: {:ok, ids}, else: resolve(config, root)

      _ ->
        resolve(config, root)
    end
  end

  defp resolve(config, root) do
    case Client.fetch_descendant_ids(root, config) do
      {:ok, ids} ->
        Logger.info("Resolved scope subtree root=#{root} issues=#{length(ids)}")
        :persistent_term.put(key(config, root), {ids, System.monotonic_time(:millisecond)})
        {:ok, ids}

      {:error, reason} ->
        Logger.warning("Could not resolve scope subtree root=#{root}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fresh?(cached_at), do: System.monotonic_time(:millisecond) - cached_at < ttl_ms()

  # Overridable so a test can watch the cache expire without waiting a minute.
  defp ttl_ms, do: Application.get_env(:cymphony_elixir, :scope_cache_ttl_ms, @ttl_ms)

  defp key(config, root), do: {__MODULE__, endpoint(config), root}

  defp endpoint(%{tracker: %{endpoint: endpoint}}) when is_binary(endpoint), do: endpoint
  defp endpoint(_config), do: ""
end
