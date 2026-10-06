defmodule CymphonyElixir.PromptTestingTest do
  @moduledoc """
  Runs logged on harvest_frontend spent most of their tokens on tests: whole
  integration directories swept repeatedly, every suite run twice for a
  stash-based baseline, suites rerun just to grep the output differently, and
  background runs whose wait ended the turn and started a fresh one. The
  prompt asks for tests close to the change and one broad run near the end.
  """
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.PromptTemplate

  defp prompt(config_attrs \\ %{}) do
    {:ok, config} = Schema.parse(config_attrs)

    issue = %Issue{identifier: "HC-1", title: "t", state: "Open", url: "u", description: "d"}
    PromptBuilder.build_prompt(issue, prompt_template: PromptTemplate.get(), config: config)
  end

  test "asks for targeted tests while iterating and one broad run near the end" do
    prompt = prompt(%{"base_branch" => "HFE-6470"})

    assert prompt =~ "## Testing"
    assert prompt =~ "Test close to the change while you work, and do one broad run near the end."
    assert prompt =~ "after the last code change and the merge of\n  `origin/HFE-6470`, run the broad suite once"
    assert prompt =~ "Never repeat the whole broad run."
    assert prompt =~ "then do the one broad test run"
  end

  test "the pre-push gate is the targeted tests, not the broad suite" do
    prompt = prompt()

    assert prompt =~ "Before every `git push` attempt, run the targeted tests"
    assert prompt =~ "Do not run the broad suite here."
    refute prompt =~ "run the required validation for your scope"
    refute prompt =~ "and rerun checks."
  end

  test "rules out the patterns that burned tokens" do
    prompt = prompt()

    # A full-suite baseline doubles every run.
    assert prompt =~ "rerun only that test against the base"
    assert prompt =~ "Do not rerun a whole suite to collect a baseline."
    # Re-running to re-filter output.
    assert prompt =~ "Never rerun a suite just to view its output\n  another way."
    # Ending the turn to wait resumes the whole context immediately.
    assert prompt =~ "Never start a test run in the background and end your turn to\n  wait for it."
  end

  test "the workpad records the broad run and confirmed pre-existing failures" do
    prompt = prompt()

    assert prompt =~ "- [ ] broad run (once, before review): `<command>`"
    assert prompt =~ "- pre-existing failures: <test, and how it was confirmed against the base>"
    assert prompt =~ "with any pre-existing failures recorded in the workpad"
  end
end
