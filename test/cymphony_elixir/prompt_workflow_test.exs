defmodule CymphonyElixir.PromptWorkflowTest do
  @moduledoc """
  The prompt's status map is the *tracker's* vocabulary, not Linear's.

  A YouTrack project whose states are `Open`/`In Progress`/`Review and Testing`
  must be routed on those names, and a workflow where humans merge must not
  carry the land/merge protocol at all.
  """
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.PromptTemplate

  @youtrack %{
    "forge" => "gitlab",
    "tracker" => %{
      "kind" => "youtrack",
      "queued_states" => ["Open", "Confirmed", "Reopened"],
      "in_progress_state" => "In Progress",
      "review_state" => "Review and Testing",
      "merge_state" => "",
      "active_states" => ["Open", "Confirmed", "Reopened", "In Progress"],
      "terminal_states" => ["Fixed", "Verified", "Done"]
    }
  }

  @linear %{
    "tracker" => %{
      "active_states" => ["Todo", "In Progress", "Merging", "Rework"],
      "terminal_states" => ["Closed", "Done"]
    }
  }

  defp render(attrs) do
    {:ok, config} = Schema.parse(attrs)

    issue = %Issue{identifier: "MYSQL-1", title: "t", description: "d", state: "Open", url: "u", labels: []}

    PromptBuilder.build_prompt(issue, prompt_template: PromptTemplate.get(), config: config)
  end

  describe "a YouTrack workflow where humans merge" do
    test "routes on the project's own state names" do
      prompt = render(@youtrack)

      for state <- ["Open", "Confirmed", "Reopened", "In Progress", "Review and Testing", "Fixed", "Verified"] do
        assert prompt =~ "`#{state}`", "expected the status map to mention #{state}"
      end

      refute prompt =~ "`Todo`"
      refute prompt =~ "`Human Review`"
      refute prompt =~ "`Backlog`"
    end

    test "drops the land/merge protocol entirely" do
      prompt = render(@youtrack)

      refute prompt =~ "SKILL.md"
      refute prompt =~ "land` skill"
      refute prompt =~ "glab mr merge"
      # An empty merge state must not render as an empty backtick pair, which
      # is what a plain `{{ }}` would produce (Liquid treats "" as truthy, so
      # the variable has to be nil).
      refute prompt =~ "issue to ``"
      refute prompt =~ "`` ->"
      assert prompt =~ "Merging is a human's job in this workflow"
    end

    test "tells the agent how to reach YouTrack instead of assuming a Linear MCP" do
      prompt = render(@youtrack)

      assert prompt =~ "## Prerequisite: YouTrack access"
      assert prompt =~ "$YOUTRACK_URL/api"
      assert prompt =~ "Authorization: Bearer $YOUTRACK_TOKEN"
      refute prompt =~ "Linear"
    end
  end

  describe "the Linear + GitHub default is unchanged" do
    test "keeps its own status map, the merge state and the land protocol" do
      prompt = render(@linear)

      assert prompt =~ "`Todo` -> queued"
      assert prompt =~ "`Human Review` -> PR is attached"
      assert prompt =~ "`Merging` -> approved by human"
      assert prompt =~ ".claude/skills/land/SKILL.md"
      assert prompt =~ "gh pr merge"
      assert prompt =~ "## Prerequisite: Linear access"
    end

    test "still lists an active state the status map does not otherwise describe" do
      # `Rework` is dispatched on, so the prompt must not file it under
      # "out of scope: stop".
      assert render(@linear) =~ "`Rework` -> active work state"
    end
  end

  describe "workflow_variables/1" do
    test "blanks the merge state to nil so the Liquid conditional can fire" do
      {:ok, config} = Schema.parse(@youtrack)
      vars = PromptBuilder.workflow_variables(config)

      assert vars["merge_state"] == nil
      assert vars["review_state"] == "Review and Testing"
      assert vars["queued_states"] == ["Open", "Confirmed", "Reopened"]
      assert vars["other_active_states"] == []
    end

    test "excludes queued, in-progress, review and merge states from the leftovers" do
      {:ok, config} = Schema.parse(@linear)

      assert PromptBuilder.workflow_variables(config)["other_active_states"] == ["Rework"]
    end

    test "falls back to Linear's shape when there is no config" do
      vars = PromptBuilder.workflow_variables(nil)

      assert vars["queued_states"] == ["Todo"]
      assert vars["in_progress_state"] == "In Progress"
      assert vars["review_state"] == "Human Review"
      assert vars["merge_state"] == "Merging"
      assert vars["other_active_states"] == []
    end

    test "ignores blank and non-string states" do
      {:ok, config} =
        Schema.parse(%{"tracker" => %{"queued_states" => ["  ", "Open"], "active_states" => ["Open"]}})

      assert PromptBuilder.workflow_variables(config)["queued_states"] == ["Open"]

      empty = %Schema{tracker: %Schema.Tracker{queued_states: [], active_states: [], terminal_states: []}}
      vars = PromptBuilder.workflow_variables(empty)

      assert vars["queued_states"] == ["Todo"]
      assert vars["terminal_states"] == ["Done"]
      assert vars["in_progress_state"] == "In Progress"
    end

    test "a nil state falls back rather than rendering an empty name" do
      # A hand-authored WORKFLOW.md can null these out; the prompt must still
      # name a state, and a nil merge state must stay nil for the conditional.
      nils = %Schema{
        tracker: %Schema.Tracker{
          queued_states: ["Open"],
          active_states: ["Open"],
          terminal_states: ["Done"],
          in_progress_state: nil,
          review_state: nil,
          merge_state: nil
        }
      }

      vars = PromptBuilder.workflow_variables(nils)

      assert vars["in_progress_state"] == "In Progress"
      assert vars["review_state"] == "Human Review"
      assert vars["merge_state"] == nil
    end
  end

  describe "tracker_variables/1" do
    test "describes how to reach each tracker" do
      {:ok, youtrack} = Schema.parse(%{"tracker" => %{"kind" => "youtrack"}})
      assert PromptBuilder.tracker_variables(youtrack)["name"] == "YouTrack"
      assert PromptBuilder.tracker_variables(youtrack)["access"] =~ "$YOUTRACK_TOKEN"

      {:ok, linear} = Schema.parse(%{"tracker" => %{"kind" => "linear"}})
      assert PromptBuilder.tracker_variables(linear)["name"] == "Linear"
      assert PromptBuilder.tracker_variables(linear)["access"] =~ "MCP"
      assert PromptBuilder.tracker_variables(nil)["name"] == "Linear"
    end
  end

  describe "ignored comment authors (UAT-15)" do
    defp with_ignored(attrs, logins), do: put_in(attrs, ["tracker", "ignored_comment_authors"], logins)

    test "the rule names the ignored login and is keyed on the author, not the heading" do
      prompt = render(with_ignored(@youtrack, ["software.uat"]))

      assert prompt =~ "Ignore every comment written by `software.uat`, whatever its heading or content"
      assert prompt =~ "Decide by the comment's author login"
      assert prompt =~ "author(login)"
      # Inverse: a human comment, even one with the bot's heading, still counts.
      assert prompt =~ "A comment by anyone else is a normal comment, even when it starts with the same heading."
      # The existing human-comment intake is still there beside it.
      assert prompt =~ "Identify new actionable human comments"
    end

    test "several logins are listed" do
      prompt = render(with_ignored(@youtrack, ["software.uat", "ci.bot"]))

      assert prompt =~ "written by `software.uat`, `ci.bot`, whatever"
    end

    test "with no ignored authors the rule is absent" do
      for attrs <- [@youtrack, with_ignored(@youtrack, []), @linear] do
        prompt = render(attrs)

        refute prompt =~ "Ignore every comment written by"
        refute prompt =~ "author(login)"
      end
    end

    test "the YouTrack field hint does not leak into a Linear prompt" do
      prompt = render(with_ignored(@linear, ["software.uat"]))

      assert prompt =~ "Ignore every comment written by `software.uat`"
      refute prompt =~ "author(login)"
    end
  end
end
