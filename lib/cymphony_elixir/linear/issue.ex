defmodule CymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :parent_identifier,
    :version,
    branch_from_parent: false,
    blocked_by: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @typedoc """
  One entry of `blocked_by`: the blocking issue's ids, its workflow state, and
  enough of its own branching policy for the dependency gate to work out where
  that issue was supposed to land.

  `parent_identifier`/`branch_from_parent` mirror the same two fields on the
  issue struct. The gate asks "has this dependency merged into *its own* base
  branch?" rather than into the dependent's, so that a dependency which landed
  on the epic branch unblocks a dependent that cuts from somewhere else instead
  of deadlocking it forever. An adapter that cannot supply them leaves
  `parent_identifier` `nil` and `branch_from_parent` `false`, and the gate falls
  back to the dependent's base branch.

  A bare map rather than a struct because every adapter builds it from a
  different payload and nothing outside the gate reads more than `:identifier`
  and `:state`.
  """
  @type blocker :: %{
          id: String.t() | nil,
          identifier: String.t() | nil,
          state: String.t() | nil,
          parent_identifier: String.t() | nil,
          branch_from_parent: boolean()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          parent_identifier: String.t() | nil,
          version: String.t() | nil,
          branch_from_parent: boolean(),
          blocked_by: [blocker()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
