defmodule CymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  require Logger

  alias CymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(CymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    prompt_template = Keyword.get(opts, :prompt_template)
    config = Keyword.get(opts, :config)

    template =
      if prompt_template do
        prompt_template
      else
        if config do
          config_prompt_template(config)
        else
          Workflow.current()
          |> prompt_template!()
        end
      end
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "forge" => forge_variables(Keyword.get(opts, :forge) || forge_kind(config), squash_merge?(config)),
        "branch_name" => branch_name(issue, branch_template(config)),
        "base_branch" => base_branch(issue, config),
        "workflow" => workflow_variables(config),
        "tracker" => tracker_variables(config)
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  @doc """
  Prompt variables describing a code-hosting platform.

  The default prompt is one document for both forges, so everything that
  differs between them — the CLI binary, what a change proposal is called, and
  the three review-reading commands — is a variable rather than a second copy
  of the template. Rendering runs with `strict_variables: true`, so this map is
  always supplied, including for a hand-authored prompt that never reads it.

  `squash?` is `config.squash_merge`. It only has a meaning on GitLab, where
  squash is an attribute of the merge request and so has to be set when the MR
  is opened; GitHub picks it at merge time (`gh pr merge --squash`) and has
  nothing to set, so the three squash variables are `nil` there either way and
  the template's `{% if forge.review_squash_flag %}` blocks drop out entirely.
  """
  @spec forge_variables(String.t() | nil) :: map()
  def forge_variables(kind), do: forge_variables(kind, true)

  @doc """
  `forge_variables/1` with squashing decided by `config.squash_merge`.
  """
  @spec forge_variables(String.t() | nil, boolean()) :: map()
  def forge_variables("gitlab", squash?) do
    %{
      "name" => "GitLab",
      "cli" => "glab",
      "review" => "merge request",
      "review_abbr" => "MR",
      "merge_command" => "glab mr merge",
      "review_base_flag" => "--target-branch",
      "review_open_command" => "mr create",
      "review_target_command" => "glab mr view --json targetBranch",
      "review_retarget_command" => "glab mr update --target-branch",
      "review_squash_flag" => squash_variable(squash?, "--squash-before-merge"),
      "review_squash_check_command" => squash_variable(squash?, "glab mr view --json squash"),
      "review_squash_command" => squash_variable(squash?, "glab mr update --squash-before-merge"),
      "comments_command" => "glab mr view --comments",
      "inline_comments_command" => "glab api projects/:id/merge_requests/<mr>/notes",
      "reviews_command" => "glab mr view --json reviewers,approvalsRequired"
    }
  end

  def forge_variables(_kind, _squash?) do
    %{
      "name" => "GitHub",
      "cli" => "gh",
      "review" => "pull request",
      "review_abbr" => "PR",
      "merge_command" => "gh pr merge",
      "review_base_flag" => "--base",
      "review_open_command" => "pr create",
      "review_target_command" => "gh pr view --json baseRefName",
      "review_retarget_command" => "gh pr edit --base",
      "review_squash_flag" => nil,
      "review_squash_check_command" => nil,
      "review_squash_command" => nil,
      "comments_command" => "gh pr view --comments",
      "inline_comments_command" => "gh api repos/<owner>/<repo>/pulls/<pr>/comments",
      "reviews_command" => "gh pr view --json reviews"
    }
  end

  defp forge_kind(%{forge: forge}) when is_binary(forge), do: forge
  defp forge_kind(_config), do: nil

  # Only an explicit `false` turns squashing off. A `LenientBoolean` that could
  # not cast the operator's value leaves `nil` here, which must keep the
  # default: the failure mode of the other direction is every sub-task landing
  # on its parent as a string of commits, silently.
  defp squash_merge?(%{squash_merge: false}), do: false
  defp squash_merge?(_config), do: true

  # A blank string is truthy in Liquid, so an unset variable has to be `nil`.
  defp squash_variable(true, value), do: value
  defp squash_variable(_squash?, _value), do: nil

  defp branch_template(%{branch_name_template: template}) when is_binary(template) and template != "",
    do: template

  defp branch_template(_config), do: "{{ issue.identifier }}"

  defp configured_base_branch(%{base_branch: base}) when is_binary(base) do
    case sanitize_branch(base) do
      "" -> "main"
      name -> name
    end
  end

  defp configured_base_branch(_config), do: "main"

  defp parent_identifier(issue) do
    case Map.get(issue, :parent_identifier) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  # A template is operator-authored and rendered per issue; a typo in it must
  # degrade to the identifier rather than raise out of the whole prompt build.
  defp render_branch(template, issue) do
    template
    |> Solid.parse!()
    |> Solid.render!(%{"issue" => issue |> Map.from_struct() |> to_solid_map()}, @render_opts)
    |> IO.iodata_to_binary()
  rescue
    error ->
      Logger.warning("Ignoring invalid branch_name_template #{inspect(template)}: #{Exception.message(error)}")

      ""
  end

  @doc """
  Branch name for this run: `template` rendered against the issue.

  Without an explicit name in the prompt the agent invents one per run
  (`HC-1-hello-world-static-page`), which is unpredictable and awkward to
  grep for. The default template is the bare identifier; a project that wants
  the tracker's own suggestion can use `{{ issue.branch_name }}` (Linear
  populates it), and anything else Liquid can express works too.

  The result is sanitized into a legal git ref and falls back to the
  identifier when the template renders blank or fails — a bad template must
  not take the run down.
  """
  @spec branch_name(term(), String.t() | nil) :: String.t()
  def branch_name(issue, template) do
    identifier = to_string(Map.get(issue, :identifier) || Map.get(issue, :id) || "")

    case sanitize_branch(render_branch(template, issue)) do
      "" -> sanitize_branch(identifier)
      name -> name
    end
  end

  @doc """
  Branch this run is cut from, and the branch its review targets.

  An issue branches off **its direct parent's branch** — the parent's
  identifier put through the same `branch_name_template` — when the tracker
  said it should: `issue.branch_from_parent`, which the adapter sets from the
  parent's container tag or the issue's own version marker. Only one level is
  walked: the chain composes because each parent, when it runs, resolves its own
  base by the same rule.

  Having a parent is **not** on its own enough. Most trackers give every ticket
  a parent of some kind, and branching off all of them would put unrelated work
  on each other's branches; the opt-in is what makes the epic case explicit.

  Otherwise the answer is `config.base_branch` (default `main`), which is what
  the prompt's `origin/{{ base_branch }}` renders to for ordinary standalone
  issues.
  """
  @spec base_branch(term(), term()) :: String.t()
  def base_branch(issue, config) do
    with true <- branch_from_parent?(issue),
         parent when is_binary(parent) <- parent_identifier(issue) do
      branch_name(issue_for(parent), branch_template(config))
    else
      _ -> configured_base_branch(config)
    end
  end

  @doc """
  Base branch for a `blocked_by` entry, from its own parent and policy.

  The dependency gate asks whether a dependency landed where *it* was supposed
  to land, not whether it is present on the branch the dependent happens to cut
  from — otherwise a dependency merged into an epic branch blocks a sibling that
  branches from the repository default, permanently. An entry that carries no
  policy (any tracker that does not supply one) returns `nil`, and the caller
  falls back to the dependent's base.
  """
  @spec blocker_base_branch(term(), term()) :: String.t() | nil
  def blocker_base_branch(blocker, config) do
    with true <- branch_from_parent?(blocker),
         parent when is_binary(parent) <- parent_identifier(blocker) do
      branch_name(issue_for(parent), branch_template(config))
    else
      _ -> nil
    end
  end

  defp branch_from_parent?(issue) when is_map(issue), do: Map.get(issue, :branch_from_parent, false) == true
  defp branch_from_parent?(_issue), do: false

  @doc """
  A bare `Issue` struct carrying only `identifier`.

  `branch_name/2` renders the template through `Map.from_struct/1`, so a plain
  map cannot stand in for an issue: the render raises, is rescued, and quietly
  degrades to the identifier — which silently drops the `feature/` in a
  template like `feature/{{ issue.identifier }}`.
  """
  @spec issue_for(String.t()) :: CymphonyElixir.Linear.Issue.t()
  def issue_for(identifier) when is_binary(identifier) do
    %CymphonyElixir.Linear.Issue{id: identifier, identifier: identifier}
  end

  @doc """
  Coerces `value` into something git will accept as a branch name.

  Whitespace becomes `-`; the characters git forbids in a ref (`~^:?*[\\` and
  control bytes) are dropped, as are the leading/trailing `.`, `-` and `/` and
  the `..` sequence that `git check-ref-format` rejects.
  """
  @spec sanitize_branch(String.t()) :: String.t()
  def sanitize_branch(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(Regex.compile!("\\s+"), "-")
    |> String.replace(Regex.compile!("[~^:?*\\[\\\\\\x00-\\x1f\\x7f]"), "")
    |> String.replace(Regex.compile!("\\.{2,}"), ".")
    |> String.replace(Regex.compile!("-{2,}"), "-")
    |> String.replace(Regex.compile!("/{2,}"), "/")
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> String.trim("-")
    |> String.trim(".")
  end

  @doc """
  Prompt variables describing the project's workflow states.

  The status map the agent routes on is the *tracker's* vocabulary, so it is
  rendered from config rather than hardcoded: a YouTrack project whose states
  are `Open`/`In Progress`/`Review and Testing` must not be told to move
  tickets to Linear's `Todo` and `Human Review`. `merge_state` is blank for a
  workflow where humans merge, and the template drops the whole land/merge
  protocol when it is.
  """
  @spec workflow_variables(term()) :: map()
  def workflow_variables(%{tracker: tracker}) do
    active = state_list(tracker.active_states, ["Todo", "In Progress"])

    %{
      "queued_states" => state_list(tracker.queued_states, ["Todo"]),
      "in_progress_state" => present(tracker.in_progress_state, "In Progress"),
      "review_state" => present(tracker.review_state, "Human Review"),
      # `nil`, not `""`: Liquid treats an empty string as truthy, so a blank
      # merge state has to become nil or `{% if workflow.merge_state %}` keeps
      # the whole land/merge protocol and renders it with an empty state name.
      "merge_state" => blank_to_nil(tracker.merge_state),
      "active_states" => active,
      "other_active_states" => other_active_states(active, tracker),
      "terminal_states" => state_list(tracker.terminal_states, ["Done"])
    }
  end

  def workflow_variables(_config) do
    %{
      "queued_states" => ["Todo"],
      "in_progress_state" => "In Progress",
      "review_state" => "Human Review",
      "merge_state" => "Merging",
      "active_states" => ["Todo", "In Progress"],
      "other_active_states" => [],
      "terminal_states" => ["Done"]
    }
  end

  @doc """
  Prompt variables describing the issue tracker.

  `access` tells the agent how to reach the tracker: Linear projects get an MCP
  server written into the workspace, while a YouTrack project gets `$YOUTRACK_*`
  in its environment and talks to the REST API directly.
  """
  @spec tracker_variables(term()) :: map()
  def tracker_variables(%{tracker: %{kind: "youtrack"}}) do
    %{
      "name" => "YouTrack",
      "access" =>
        "the YouTrack REST API at `$YOUTRACK_URL/api`, authenticated with " <>
          "`Authorization: Bearer $YOUTRACK_TOKEN` (both are in your environment; " <>
          "`$YOUTRACK_PROJECT` is the project short name)"
    }
  end

  def tracker_variables(_config) do
    %{
      "name" => "Linear",
      "access" => "a configured Linear MCP server or the injected `linear_graphql` tool"
    }
  end

  # Active states the status map does not already describe (Linear's `Rework`
  # is the motivating case). Without this the prompt tells the agent that a
  # state Cymphony actively dispatches on is "out of scope: stop".
  defp other_active_states(active, tracker) do
    covered =
      [tracker.in_progress_state, tracker.review_state, tracker.merge_state | tracker.queued_states || []]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    Enum.reject(active, &MapSet.member?(covered, normalize_state(&1)))
  end

  defp normalize_state(value), do: value |> String.trim() |> String.downcase()

  defp state_list(states, default) do
    case states do
      [_ | _] = list -> Enum.filter(list, &(is_binary(&1) and String.trim(&1) != ""))
      _ -> default
    end
  end

  defp present(value, _default) when is_binary(value), do: value
  defp present(_value, default), do: default

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp config_prompt_template(_config) do
    # Config.Schema does not store the prompt template; it must be passed via opts.
    # Fall back to the global workflow prompt for backward compatibility.
    Config.workflow_prompt()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
