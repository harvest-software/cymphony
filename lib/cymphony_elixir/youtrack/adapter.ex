defmodule CymphonyElixir.YouTrack.Adapter do
  @moduledoc """
  YouTrack-backed tracker adapter.

  Pure delegation to `CymphonyElixir.YouTrack.Client`, indirected through
  `:youtrack_client_module` so tests can substitute a stub — the same shape
  `CymphonyElixir.Linear.Adapter` uses for its client.
  """

  @behaviour CymphonyElixir.Tracker

  alias CymphonyElixir.YouTrack.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_candidate_issues(term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(config), do: client_module().fetch_candidate_issues(config)

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_states([String.t()], term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, config), do: client_module().fetch_issues_by_states(states, config)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec fetch_issue_states_by_ids([String.t()], term()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, config), do: client_module().fetch_issue_states_by_ids(issue_ids, config)

  @spec fetch_descendant_ids(String.t(), term()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_descendant_ids(root_id, config), do: client_module().fetch_descendant_ids(root_id, config)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body), do: client_module().create_comment(issue_id, body)

  @spec create_comment(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, config), do: client_module().create_comment(issue_id, body, config)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: client_module().update_issue_state(issue_id, state_name)

  @spec update_issue_state(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, config),
    do: client_module().update_issue_state(issue_id, state_name, config)

  defp client_module do
    Application.get_env(:cymphony_elixir, :youtrack_client_module, Client)
  end
end
