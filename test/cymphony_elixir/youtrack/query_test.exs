defmodule CymphonyElixir.YouTrack.QueryTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.YouTrack.Query

  describe "issues/2" do
    test "braces the project and every state so multi-word values parse" do
      assert Query.issues("LLM", ["Todo", "In Progress"]) ==
               "project: {LLM} State: {Todo}, {In Progress}"
    end

    test "drops the state clause when no usable state is given" do
      assert Query.issues("LLM", []) == "project: {LLM}"
      assert Query.issues("LLM", ["", "   "]) == "project: {LLM}"
      assert Query.issues("LLM", [nil, 42]) == "project: {LLM}"
    end

    test "strips braces out of values so a stray one cannot end the clause early" do
      assert Query.issues("A{B}C", ["In {Progress}"]) == "project: {ABC} State: {In Progress}"
    end
  end

  describe "issues/3" do
    test "adds an id clause for the resolved scope subtree" do
      assert Query.issues("LLM", ["Todo"], ["LLM-51", "LLM-52"]) ==
               "project: {LLM} State: {Todo} issue id: {LLM-51}, {LLM-52}"
    end

    test "an empty scope means unscoped, not empty" do
      assert Query.issues("LLM", ["Todo"], []) == Query.issues("LLM", ["Todo"])
      assert Query.issues("LLM", [], []) == "project: {LLM}"
    end
  end

  describe "subtree/1" do
    test "asks for the direct children of every id in the frontier" do
      # `subtask of:` is the phrase stored on the *child* end of YouTrack's
      # Subtask link, so this reads "issues whose parent is one of these".
      assert Query.subtree(["HFE-6470"]) == "subtask of: {HFE-6470}"
      assert Query.subtree(["HFE-6471", "HFE-6472"]) == "subtask of: {HFE-6471}, {HFE-6472}"
    end

    test "an empty frontier ends the walk" do
      assert Query.subtree([]) == ""
      assert Query.subtree(["", "  "]) == ""
      assert Query.subtree([nil, 7]) == ""
    end
  end

  describe "normalize_state/1" do
    test "trims and downcases" do
      assert Query.normalize_state("  In Progress ") == "in progress"
    end

    test "treats blank and non-binary values as absent" do
      assert Query.normalize_state("   ") == nil
      assert Query.normalize_state(nil) == nil
      assert Query.normalize_state(42) == nil
    end
  end

  describe "by_ids/1" do
    test "lists every id, and asks for nothing when there are none" do
      assert Query.by_ids(["HFE-6470", "HFE-6489"]) == "issue id: {HFE-6470}, {HFE-6489}"
      assert Query.by_ids([]) == ""
      assert Query.by_ids(["  ", nil]) == ""
    end
  end
end
