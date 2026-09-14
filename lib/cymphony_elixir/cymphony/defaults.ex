defmodule CymphonyElixir.Cymphony.Defaults do
  @moduledoc """
  Canonical defaults applied when deriving a project's runtime config from
  `~/.cymphony/config.json`.

  Centralized here so the values live in exactly one place instead of being
  buried in string interpolation. These are the *generation* defaults for
  config.json-driven projects; `CymphonyElixir.Config.Schema` keeps its own
  field defaults for hand-authored `WORKFLOW.md` files that omit keys.
  """

  # Only literal "Todo" — matching `Config.Schema`'s default and the behavior
  # before the state names became configurable. "Rework" is an active state but
  # deliberately not a queued one: making it queued would newly gate reworked
  # issues on their blockers.
  # GitHub, for backward compatibility: every config.json written before
  # GitLab was supported describes a GitHub repository.
  @forge "github"
  @branch_name_template "{{ issue.identifier }}"
  # Branch a run is cut from when its issue has no parent. An issue with a
  # parent branches off the parent's branch instead.
  @base_branch "main"
  @queued_states ["Todo"]
  @in_progress_state "In Progress"
  @state_field "State"
  # An issue carrying this tag is a container for a feature branch, not work:
  # never dispatched, and its children branch off it.
  @feature_branch_label "Feature Branch"
  # Second, explicit opt-in for a child whose parent carries no container tag.
  @version_field "Version"
  @merge_to_parent_version "Merge to Parent Feature Branch"
  @review_state "Human Review"
  @merge_state "Merging"
  @active_states ["Todo", "In Progress", "Merging", "Rework"]
  @terminal_states ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
  @max_turns 20
  @stall_timeout_ms 300_000
  @output_format "stream-json"
  @polling_interval_ms 5000
  @workspace_root "~/.cymphony/workspaces"
  @max_concurrent_agents 10
  @agent_kind "claude"
  @claude_command "claude"
  @codex_command "codex"
  @antigravity_command "agy"
  @codex_sandbox "workspace-write"

  # `--allowedTools` for an autonomous headless run. The old value was
  # `Bash,Read,Edit`, which is narrower than the work the prompt asks for: an
  # agent told to create files, publish a branch and update its ticket was
  # granted neither `Write` nor any tracker tool. Under `-p` there is nobody to
  # approve the prompt, so those calls came back `permission_denied` and the
  # run limped on through `Bash` fallbacks — extra turns, and every turn
  # re-bills the whole prompt preamble.
  @claude_allowed_tools ["Bash", "Read", "Edit", "Write", "Glob", "Grep"]
  @claude_permission_mode "acceptEdits"

  @doc """
  Code-hosting platform a project's repository lives on (`github`/`gitlab`).
  """
  @spec forge() :: String.t()
  def forge, do: @forge

  @doc """
  Liquid template for the branch a run creates, rendered against the issue.
  """
  @spec branch_name_template() :: String.t()
  def branch_name_template, do: @branch_name_template

  @doc """
  Default base branch for an issue with no parent.
  """
  @spec base_branch() :: String.t()
  def base_branch, do: @base_branch

  @doc """
  States meaning "queued, not started" — the dispatch transition and the
  blocker gate key off these. Mirrors `Config.Schema`'s `tracker.queued_states`.
  """
  @spec queued_states() :: [String.t()]
  def queued_states, do: @queued_states

  @doc """
  State an issue is moved to when a run is dispatched.
  """
  @spec in_progress_state() :: String.t()
  def in_progress_state, do: @in_progress_state

  @doc """
  Custom field holding the workflow state (YouTrack projects rename it).
  """
  @spec state_field() :: String.t()
  def state_field, do: @state_field

  @doc """
  Tag marking an issue as a feature-branch container rather than work.
  """
  @spec feature_branch_label() :: String.t()
  def feature_branch_label, do: @feature_branch_label

  @doc """
  Custom field holding the release version.
  """
  @spec version_field() :: String.t()
  def version_field, do: @version_field

  @doc """
  Version value meaning "branch off my parent, not the configured base".
  """
  @spec merge_to_parent_version() :: String.t()
  def merge_to_parent_version, do: @merge_to_parent_version

  @doc """
  State the agent moves an issue to when it hands the change to a human.
  """
  @spec review_state() :: String.t()
  def review_state, do: @review_state

  @doc """
  State meaning "approved, go merge". Blank disables the agent-merge flow.
  """
  @spec merge_state() :: String.t()
  def merge_state, do: @merge_state

  @spec active_states() :: [String.t()]
  def active_states, do: @active_states

  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @spec max_turns() :: pos_integer()
  def max_turns, do: @max_turns

  @doc """
  Milliseconds of agent-event silence before the stall watchdog kills a session.

  Matches `Config.Schema`'s `agent.stall_timeout_ms` default so an omitted
  `config.json` key generates the same value a hand-authored `WORKFLOW.md` would
  fall back to.
  """
  @spec stall_timeout_ms() :: pos_integer()
  def stall_timeout_ms, do: @stall_timeout_ms

  @spec output_format() :: String.t()
  def output_format, do: @output_format

  @spec polling_interval_ms() :: pos_integer()
  def polling_interval_ms, do: @polling_interval_ms

  @spec workspace_root() :: String.t()
  def workspace_root, do: @workspace_root

  @spec max_concurrent_agents() :: pos_integer()
  def max_concurrent_agents, do: @max_concurrent_agents

  @spec agent_kind() :: String.t()
  def agent_kind, do: @agent_kind

  @spec claude_command() :: String.t()
  def claude_command, do: @claude_command

  @spec codex_command() :: String.t()
  def codex_command, do: @codex_command

  @spec antigravity_command() :: String.t()
  def antigravity_command, do: @antigravity_command

  @spec codex_sandbox() :: String.t()
  def codex_sandbox, do: @codex_sandbox

  @doc """
  Base `--allowedTools` list for Claude, before the tracker's own tools.

  A name the running CLI does not define is simply ignored by it, so listing a
  tool that a given Claude Code version lacks is harmless.
  """
  @spec claude_allowed_tools() :: [String.t()]
  def claude_allowed_tools, do: @claude_allowed_tools

  @doc """
  `--allowedTools` including the MCP server for `tracker_kind`.

  The agent is required by the prompt to read and update its ticket. Linear
  gets an MCP descriptor written into the workspace and YouTrack is commonly
  configured globally in the operator's own `~/.claude.json`, so in both cases
  the server exists and only the grant is missing. Naming the server without a
  tool suffix grants all of its tools; an absent server contributes nothing.
  """
  @spec claude_allowed_tools(String.t() | nil) :: [String.t()]
  def claude_allowed_tools(tracker_kind) do
    case tracker_kind do
      "linear" -> @claude_allowed_tools ++ ["mcp__linear"]
      "youtrack" -> @claude_allowed_tools ++ ["mcp__youtrack"]
      _ -> @claude_allowed_tools
    end
  end

  @doc """
  Claude `--permission-mode` for a generated project.
  """
  @spec claude_permission_mode() :: String.t()
  def claude_permission_mode, do: @claude_permission_mode
end
