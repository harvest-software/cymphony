defmodule CymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias CymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_comment(String.t(), String.t(), term()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @doc """
  Every issue id in the subtree rooted at the given id, the root included.

  Optional: a tracker that cannot express "children of" answers
  `{:error, :not_supported}` and the caller falls back to filtering the polled
  candidates by their `parent_identifier` chain, which reaches only ancestors
  that are themselves active.
  """
  @callback fetch_descendant_ids(String.t(), term()) :: {:ok, [String.t()]} | {:error, term()}

  @optional_callbacks fetch_descendant_ids: 2

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_candidate_issues(Config.Schema.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(config) when is_struct(config, Config.Schema) do
    adapter(config).fetch_candidate_issues(config)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_states([String.t()], Config.Schema.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, config) when is_struct(config, Config.Schema) do
    adapter(config).fetch_issues_by_states(states, config)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_states_by_ids([String.t()], Config.Schema.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, config) when is_struct(config, Config.Schema) do
    adapter(config).fetch_issue_states_by_ids(issue_ids, config)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec create_comment(String.t(), String.t(), Config.Schema.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, config) when is_struct(config, Config.Schema) do
    adapter(config).create_comment(issue_id, body, config)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec update_issue_state(String.t(), String.t(), Config.Schema.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, config) when is_struct(config, Config.Schema) do
    adapter(config).update_issue_state(issue_id, state_name, config)
  end

  @spec fetch_descendant_ids(String.t(), Config.Schema.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_descendant_ids(root_id, config) when is_struct(config, Config.Schema) do
    module = adapter(config)

    # `apply/3` rather than a static call: the callback is optional, so most
    # adapters legitimately do not export it and a direct call would be a
    # compile-time warning on every one of them.
    Code.ensure_loaded(module)

    if function_exported?(module, :fetch_descendant_ids, 2) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(module, :fetch_descendant_ids, [root_id, config])
    else
      {:error, :not_supported}
    end
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> CymphonyElixir.Tracker.Memory
      "youtrack" -> CymphonyElixir.YouTrack.Adapter
      _ -> CymphonyElixir.Linear.Adapter
    end
  end

  @spec adapter(Config.Schema.t()) :: module()
  def adapter(config) do
    case config.tracker.kind do
      "memory" -> CymphonyElixir.Tracker.Memory
      "youtrack" -> CymphonyElixir.YouTrack.Adapter
      _ -> CymphonyElixir.Linear.Adapter
    end
  end
end
