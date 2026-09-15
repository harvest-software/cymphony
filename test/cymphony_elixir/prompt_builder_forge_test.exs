defmodule CymphonyElixir.PromptBuilderForgeTest do
  @moduledoc """
  The default prompt is one document for both forges: everything that differs
  (CLI binary, what a change proposal is called, the review-reading commands)
  is a Liquid variable. A GitLab project must never be told to run `gh`.
  """
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.PromptTemplate

  defp issue do
    %Issue{
      identifier: "DEMO-1",
      title: "Forge vocabulary",
      description: "n/a",
      state: "In Progress",
      url: "https://example.org/issue/DEMO-1",
      labels: []
    }
  end

  defp render(forge) do
    PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), forge: forge)
  end

  test "renders GitHub vocabulary by default" do
    prompt = render(nil)

    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "(`gh pr view --comments`)"
    assert prompt =~ "(`gh api repos/<owner>/<repo>/pulls/<pr>/comments`)"
    assert prompt =~ "please fix merge conflicts on PR"
    assert prompt =~ "GitHub is **not** a valid blocker"
    assert prompt =~ "an attached pull request (PR)"
    refute prompt =~ "glab"
    refute prompt =~ "merge request"
  end

  test "renders GitLab vocabulary for a gitlab project" do
    prompt = render("gitlab")

    assert prompt =~ "Do not call `glab mr merge` directly"
    assert prompt =~ "(`glab mr view --comments`)"
    assert prompt =~ "please fix merge conflicts on MR"
    assert prompt =~ "GitLab is **not** a valid blocker"
    assert prompt =~ "MR feedback sweep protocol"
    assert prompt =~ "an attached merge request (MR)"
    # The whole point: no GitHub CLI invocation survives anywhere.
    refute prompt =~ "gh pr"
    refute prompt =~ "gh api"
    refute prompt =~ "GitHub"
  end

  test "a GitLab merge request is opened squashed, and an existing one is fixed" do
    # Squash is a property of the MR, not a merge-time choice, so it has to be
    # set when the MR is opened — and an MR opened by an earlier run predates
    # the rule, which is what the read-back is for.
    prompt = render("gitlab")

    assert prompt =~ "glab mr create --target-branch main --squash-before-merge"
    assert prompt =~ "glab mr view --json squash"
    assert prompt =~ "glab mr update --squash-before-merge"
  end

  test "GitHub renders no squash instruction at all" do
    # There is no PR-level squash attribute on GitHub; it is chosen at merge
    # time (`gh pr merge --squash`), so the whole block drops out.
    prompt = render(nil)

    refute prompt =~ "squash"
    refute prompt =~ "Squash"
  end

  test "squash_merge: false drops the squash instructions without disabling anything else" do
    # `false` means "leave the project's own default alone", not "tell the agent
    # to turn squashing off" — so the prompt simply says nothing about it.
    {:ok, config} = Schema.parse(%{"forge" => "gitlab", "squash_merge" => false})

    prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

    refute prompt =~ "squash"
    assert prompt =~ "glab mr create --target-branch main"
    assert PromptBuilder.forge_variables("gitlab", false)["review_squash_flag"] == nil
  end

  test "only an explicit false turns squashing off" do
    # `LenientBoolean` leaves an uncastable value as nil, which must keep the
    # default: the other direction lands every sub-task as a string of commits.
    {:ok, default} = Schema.parse(%{"forge" => "gitlab"})
    {:ok, typo} = Schema.parse(%{"forge" => "gitlab", "squash_merge" => "yes"})
    {:ok, spelled} = Schema.parse(%{"forge" => "gitlab", "squash_merge" => "false"})

    assert default.squash_merge == true
    assert typo.squash_merge == nil
    assert spelled.squash_merge == false

    for config <- [default, typo] do
      assert PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config) =~
               "--squash-before-merge"
    end

    refute PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: spelled) =~ "squash"
  end

  test "takes the forge from the resolved workflow config when no override is given" do
    {:ok, config} = Schema.parse(%{"forge" => "gitlab"})

    prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

    assert prompt =~ "`glab mr merge`"
    refute prompt =~ "gh pr"
  end

  test "an unknown forge falls back to GitHub rather than rendering a broken CLI" do
    assert PromptBuilder.forge_variables("bitbucket")["cli"] == "gh"
    assert PromptBuilder.forge_variables(nil)["cli"] == "gh"
    assert PromptBuilder.forge_variables("gitlab")["cli"] == "glab"
  end

  test "a hand-authored prompt that never mentions a forge still renders" do
    # `strict_variables: true` means the variable must always be supplied, even
    # for a template that does not read it.
    assert PromptBuilder.build_prompt(issue(), prompt_template: "Ticket {{ issue.identifier }}") ==
             "Ticket DEMO-1"
  end
end
