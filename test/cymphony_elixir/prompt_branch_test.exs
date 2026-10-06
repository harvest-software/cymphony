defmodule CymphonyElixir.PromptBranchTest do
  @moduledoc """
  Without an explicit rule the agent invents a branch name per run
  (`HC-1-hello-world-static-page`), which is neither predictable nor greppable.
  """
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.PromptTemplate

  defp issue(overrides \\ %{}) do
    struct(
      %Issue{identifier: "HC-1", title: "Create a simple hello world app", state: "Open", url: "u", description: "d"},
      overrides
    )
  end

  test "defaults to the bare issue identifier" do
    assert PromptBuilder.branch_name(issue(), nil) == "HC-1"
    assert PromptBuilder.branch_name(issue(), "{{ issue.identifier }}") == "HC-1"
  end

  test "a project can use the tracker's own suggestion or any other shape" do
    linear = issue(%{branch_name: "jeremy/hc-1-hello-world"})

    assert PromptBuilder.branch_name(linear, "{{ issue.branch_name }}") == "jeremy/hc-1-hello-world"
    assert PromptBuilder.branch_name(issue(), "feature/{{ issue.identifier }}") == "feature/HC-1"
  end

  test "renders a legal git ref out of whatever the template produces" do
    assert PromptBuilder.branch_name(issue(), "{{ issue.identifier }} {{ issue.title }}") ==
             "HC-1-Create-a-simple-hello-world-app"

    assert PromptBuilder.sanitize_branch("  spaced   out  ") == "spaced-out"
    assert PromptBuilder.sanitize_branch("has:colon?and*globs[") == "hascolonandglobs"
    assert PromptBuilder.sanitize_branch("/leading/and/trailing/") == "leading/and/trailing"
    assert PromptBuilder.sanitize_branch("dots..collapse") == "dots.collapse"
    assert PromptBuilder.sanitize_branch("--edges--") == "edges"
  end

  test "falls back to the identifier rather than failing the run" do
    # An empty render, or a template referencing something that does not exist,
    # must not take the prompt down.
    assert PromptBuilder.branch_name(issue(), "") == "HC-1"
    assert PromptBuilder.branch_name(issue(), "{{ issue.nonexistent }}") == "HC-1"

    log = ExUnit.CaptureLog.capture_log(fn -> assert PromptBuilder.branch_name(issue(), "{% bad %}") == "HC-1" end)
    assert log =~ "Ignoring invalid branch_name_template"
  end

  test "the rendered prompt names the branch and nothing else" do
    {:ok, config} = Schema.parse(%{"tracker" => %{"kind" => "youtrack"}, "branch_name_template" => "{{ issue.identifier }}"})

    prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

    assert prompt =~ "Name the working branch exactly `HC-1`."
    assert prompt =~ "Do not add a description,"
    assert prompt =~ "a prefix or a suffix to it."
    assert prompt =~ "Create a fresh branch named exactly `HC-1`"
  end

  test "every commit is prefixed with the branch name" do
    {:ok, config} = Schema.parse(%{"branch_name_template" => "{{ issue.identifier }}"})

    prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

    assert prompt =~ "Prefix every commit subject with `HC-1` followed by a space"
    assert prompt =~ "`HC-1 Add OAUTH_* environment"
    # The `commit` skill has its own opinion about message shape; the prefix wins.
    assert prompt =~ "keep\n  the prefix and apply the skill's format after it"
  end

  test "the commit prefix follows branch_name_template, not the bare identifier" do
    {:ok, config} = Schema.parse(%{"branch_name_template" => "feature/{{ issue.identifier }}"})

    prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

    assert prompt =~ "Prefix every commit subject with `feature/HC-1` followed by a space"
  end

  describe "base_branch/2" do
    test "an issue with no parent uses the configured base branch" do
      {:ok, default} = Schema.parse(%{})
      {:ok, custom} = Schema.parse(%{"base_branch" => "develop"})

      assert PromptBuilder.base_branch(issue(), default) == "main"
      assert PromptBuilder.base_branch(issue(), custom) == "develop"
      assert PromptBuilder.base_branch(issue(), nil) == "main"
    end

    test "an issue with a parent branches off the parent's branch" do
      # The whole point: a sub-task of an epic must be cut from the epic's
      # branch, not from the repository default, or it builds on code its
      # siblings have already landed somewhere else.
      {:ok, config} = Schema.parse(%{"base_branch" => "main"})
      child = issue(%{identifier: "HFE-6471", parent_identifier: "HFE-6470", branch_from_parent: true})

      assert PromptBuilder.base_branch(child, config) == "HFE-6470"
    end

    test "the parent's branch goes through branch_name_template too" do
      {:ok, config} = Schema.parse(%{"branch_name_template" => "feature/{{ issue.identifier }}"})
      child = issue(%{identifier: "HFE-6471", parent_identifier: "HFE-6470", branch_from_parent: true})

      assert PromptBuilder.base_branch(child, config) == "feature/HFE-6470"
      assert PromptBuilder.branch_name(child, config.branch_name_template) == "feature/HFE-6471"
    end

    test "only one level is walked, so the chain composes rather than flattens" do
      # A grandchild targets its own parent, never the root of the tree: the
      # parent, when it runs, resolves its base by the same rule.
      {:ok, config} = Schema.parse(%{})
      grandchild = issue(%{identifier: "HFE-6489", parent_identifier: "HFE-6471", branch_from_parent: true})

      assert PromptBuilder.base_branch(grandchild, config) == "HFE-6471"
    end

    test "a blank or unusable parent falls back to the configured base" do
      {:ok, config} = Schema.parse(%{"base_branch" => "trunk"})

      assert PromptBuilder.base_branch(issue(%{parent_identifier: "   ", branch_from_parent: true}), config) == "trunk"
      assert PromptBuilder.base_branch(issue(%{parent_identifier: nil, branch_from_parent: true}), config) == "trunk"
      assert PromptBuilder.base_branch(issue(%{parent_identifier: 7, branch_from_parent: true}), config) == "trunk"
    end

    test "a parent alone is not enough: the tracker has to opt the issue in" do
      # Most trackers give every ticket a parent of some kind. Branching off all
      # of them would put unrelated work on each other's branches, so the epic
      # case is explicit: the adapter sets `branch_from_parent` from the
      # parent's container tag or the issue's own version marker.
      {:ok, config} = Schema.parse(%{"base_branch" => "master"})
      child = issue(%{identifier: "HFE-6471", parent_identifier: "HFE-6470"})

      assert PromptBuilder.base_branch(child, config) == "master"
      assert PromptBuilder.base_branch(%{child | branch_from_parent: true}, config) == "HFE-6470"
    end

    test "blocker_base_branch/2 answers from the dependency's own policy" do
      # The gate asks where the *dependency* was supposed to land. An entry with
      # no policy returns nil so the caller can fall back to the dependent's
      # base, which is what every tracker but YouTrack supplies today.
      {:ok, config} = Schema.parse(%{"branch_name_template" => "feature/{{ issue.identifier }}"})

      opted_in = %{identifier: "HFE-6471", parent_identifier: "HFE-6470", branch_from_parent: true}
      opted_out = %{identifier: "HFE-6471", parent_identifier: "HFE-6470", branch_from_parent: false}

      assert PromptBuilder.blocker_base_branch(opted_in, config) == "feature/HFE-6470"
      assert PromptBuilder.blocker_base_branch(opted_out, config) == nil
      assert PromptBuilder.blocker_base_branch(%{identifier: "HFE-6471"}, config) == nil
      assert PromptBuilder.blocker_base_branch("nonsense", config) == nil
    end

    test "a blank configured base still yields a usable ref" do
      {:ok, config} = Schema.parse(%{"base_branch" => "  "})
      assert PromptBuilder.base_branch(issue(), config) == "main"
    end
  end

  describe "the prompt's base branch" do
    test "every origin/... instruction names the issue's own base branch" do
      {:ok, config} = Schema.parse(%{"tracker" => %{"kind" => "youtrack"}})
      child = issue(%{identifier: "HFE-6471", parent_identifier: "HFE-6470", branch_from_parent: true})

      prompt = PromptBuilder.build_prompt(child, prompt_template: PromptTemplate.get(), config: config)

      # `origin/main` was hardcoded in six places, which sent every sub-task
      # of an epic to merge and branch from the wrong place.
      refute prompt =~ "origin/main"
      assert prompt =~ "Cut it from `origin/HFE-6470`"
      assert prompt =~ "merge it into"
      assert prompt =~ "Merge latest `origin/HFE-6470` into branch"
    end

    test "the review is opened against the base branch explicitly" do
      # The push skill runs `gh pr create` with no base flag, so the prompt has
      # to name the base or the forge default branch silently wins.
      {:ok, gitlab} = Schema.parse(%{"forge" => "gitlab"})
      {:ok, github} = Schema.parse(%{})
      child = issue(%{identifier: "HFE-6471", parent_identifier: "HFE-6470", branch_from_parent: true})

      gitlab_prompt = PromptBuilder.build_prompt(child, prompt_template: PromptTemplate.get(), config: gitlab)
      github_prompt = PromptBuilder.build_prompt(child, prompt_template: PromptTemplate.get(), config: github)

      assert gitlab_prompt =~ "glab ... --target-branch HFE-6470"
      assert github_prompt =~ "gh ... --base HFE-6470"
    end

    test "the prompt names the create command and verifies the target afterwards" do
      # The Branch section states the rule ~180 lines above the step where the
      # agent actually opens the review, and a repository need not ship a skill
      # that gets it right. Name the command at the point of use, then read the
      # target back — which is also the only thing that retargets a review
      # opened before the issue gained its parent.
      {:ok, gitlab} = Schema.parse(%{"forge" => "gitlab"})
      {:ok, github} = Schema.parse(%{})
      child = issue(%{identifier: "HFE-6471", parent_identifier: "HFE-6470", branch_from_parent: true})

      gitlab_prompt = PromptBuilder.build_prompt(child, prompt_template: PromptTemplate.get(), config: gitlab)
      github_prompt = PromptBuilder.build_prompt(child, prompt_template: PromptTemplate.get(), config: github)

      assert gitlab_prompt =~ "glab mr create --target-branch HFE-6470"
      assert gitlab_prompt =~ "glab mr view --json targetBranch"
      assert gitlab_prompt =~ "glab mr update --target-branch HFE-6470"
      refute gitlab_prompt =~ "baseRefName"

      assert github_prompt =~ "gh pr create --base HFE-6470"
      assert github_prompt =~ "gh pr view --json baseRefName"
      assert github_prompt =~ "gh pr edit --base HFE-6470"
      refute github_prompt =~ "targetBranch"
    end

    test "an issue with no parent still renders the repository default" do
      {:ok, config} = Schema.parse(%{"base_branch" => "main"})
      prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

      assert prompt =~ "Cut it from `origin/main`"
    end
  end
end
