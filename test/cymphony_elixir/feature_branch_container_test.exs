defmodule CymphonyElixir.FeatureBranchContainerTest do
  @moduledoc """
  An issue tagged `tracker.feature_branch_label` holds the branch its children
  merge into. It has no change of its own to make, so it is never dispatched —
  an agent sent at it would invent something to do on the branch every sub-task
  is about to cut from.
  """

  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Orchestrator.State

  defp state(overrides \\ %{}) do
    {:ok, settings} = Schema.parse(%{"tracker" => Map.merge(%{"active_states" => ["Todo"]}, overrides)})

    %State{
      config: settings,
      project_name: "container-#{System.unique_integer([:positive])}",
      max_concurrent_agents: 5,
      running: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      recent_completed: [],
      token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end

  defp issue(labels) do
    %Issue{
      id: "HFE-6470",
      identifier: "HFE-6470",
      title: "OAuth 2.1 authorization server",
      description: "epic",
      state: "Todo",
      labels: labels,
      blocked_by: [],
      url: "https://example.org/HFE-6470"
    }
  end

  test "a tagged issue is never dispatched" do
    refute Orchestrator.should_dispatch_issue_for_test(issue(["Feature Branch"]), state())
    assert Orchestrator.should_dispatch_issue_for_test(issue([]), state())
  end

  test "the tag matches regardless of case and surrounding space" do
    # YouTrack hands back tag names verbatim while the Linear adapter downcases
    # them, so an exact match would work on one tracker and not the other.
    refute Orchestrator.should_dispatch_issue_for_test(issue(["  feature branch "]), state())
    refute Orchestrator.should_dispatch_issue_for_test(issue(["FEATURE BRANCH"]), state())
  end

  test "an unrelated tag changes nothing" do
    assert Orchestrator.should_dispatch_issue_for_test(issue(["API", "Backend"]), state())
  end

  test "the label is configurable" do
    epics = state(%{"feature_branch_label" => "Epic"})

    refute Orchestrator.should_dispatch_issue_for_test(issue(["Epic"]), epics)
    assert Orchestrator.should_dispatch_issue_for_test(issue(["Feature Branch"]), epics)
  end

  test "a blank label switches the rule off" do
    off = state(%{"feature_branch_label" => ""})

    assert Orchestrator.should_dispatch_issue_for_test(issue(["Feature Branch"]), off)
  end

  test "an issue with no labels at all is unaffected" do
    assert Orchestrator.should_dispatch_issue_for_test(%{issue([]) | labels: nil}, state())
  end
end
