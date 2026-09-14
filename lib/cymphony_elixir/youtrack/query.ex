defmodule CymphonyElixir.YouTrack.Query do
  @moduledoc """
  Builds YouTrack search-query strings for the tracker adapter.

  YouTrack has no structured filter object like Linear's GraphQL `filter:`
  argument — the API takes a single `query` string in its own search syntax.
  Values containing spaces must be brace-wrapped (`State: {In Progress}`) and
  several values for one field are comma-separated
  (`State: {Todo}, {In Progress}`).

  The state clause is a *narrowing* filter only: the client still filters the
  decoded issues by state name, so a project whose workflow spells a state
  differently can never leak a non-active issue into a dispatch.
  """

  @doc """
  Query for every issue of `project_slug` whose State is one of `state_names`.

  An empty (or fully blank) state list yields the project clause alone.
  """
  @spec issues(String.t(), [String.t()]) :: String.t()
  def issues(project_slug, state_names) when is_binary(project_slug) and is_list(state_names) do
    ["project: #{brace(project_slug)}" | state_clause(state_names)]
    |> Enum.join(" ")
  end

  @doc """
  Query for every issue of `project_slug` whose State is one of `state_names`,
  narrowed to `scope_ids`.

  `scope_ids` is the resolved subtree (root plus descendants) of a project's
  `scope_issue`. YouTrack has no "id in (...)" operator, so membership is
  expressed as an `issue id:` clause listing every id. Like the state clause
  this is a *narrowing* filter only — `Client.decode_issues/4` still checks
  membership locally, so a query-syntax surprise cannot leak an out-of-scope
  issue into a dispatch.

  An empty `scope_ids` means "no scope configured" and yields `issues/2`.
  """
  @spec issues(String.t(), [String.t()], [String.t()]) :: String.t()
  def issues(project_slug, state_names, scope_ids)
      when is_binary(project_slug) and is_list(state_names) and is_list(scope_ids) do
    [issues(project_slug, state_names) | id_clause(scope_ids)]
    |> Enum.join(" ")
  end

  @doc """
  Query matching exactly the issues named in `ids`.

  `""` for an empty list, which the caller treats as "ask for nothing".
  """
  @spec by_ids([String.t()]) :: String.t()
  def by_ids(ids) when is_list(ids) do
    case id_clause(ids) do
      [] -> ""
      [clause] -> clause
    end
  end

  @doc """
  Query for the direct children of every id in `parent_ids`.

  One level of the breadth-first subtree walk. `subtask of: {HFE-6470}` reads
  "issues whose parent is HFE-6470" — the phrase is the one stored on the
  *child* end of YouTrack's Subtask link.

  Returns `""` for an empty frontier, which the caller treats as "stop".
  """
  @spec subtree([String.t()]) :: String.t()
  def subtree(parent_ids) when is_list(parent_ids) do
    case Enum.flat_map(parent_ids, &sanitized_value/1) do
      [] -> ""
      values -> "subtask of: " <> Enum.map_join(values, ", ", &brace/1)
    end
  end

  @doc """
  Normalizes a state name for comparison: trimmed and downcased.
  """
  @spec normalize_state(term()) :: String.t() | nil
  def normalize_state(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  def normalize_state(_value), do: nil

  defp id_clause(ids) do
    case Enum.flat_map(ids, &sanitized_value/1) do
      [] -> []
      values -> ["issue id: " <> Enum.map_join(values, ", ", &brace/1)]
    end
  end

  defp state_clause(state_names) do
    case Enum.flat_map(state_names, &sanitized_value/1) do
      [] -> []
      values -> ["State: " <> Enum.map_join(values, ", ", &brace/1)]
    end
  end

  defp sanitized_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp sanitized_value(_value), do: []

  # Braces are the only escaping YouTrack search syntax offers, so a value
  # that carries its own braces would terminate the clause early. Dropping
  # them keeps the query parseable; the client-side state filter is what
  # actually guarantees correctness.
  defp brace(value) do
    "{" <> String.replace(value, Regex.compile!("[{}]"), "") <> "}"
  end
end
