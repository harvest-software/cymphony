defmodule CymphonyElixir.TrackerTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Linear.Adapter
  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.Tracker
  alias CymphonyElixir.Tracker.Memory
  alias CymphonyElixir.YouTrack.Adapter, as: YouTrackAdapter

  setup do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    todo = %Issue{id: "issue-2", identifier: "MT-2", state: "Todo"}

    Application.put_env(:cymphony_elixir, :memory_tracker_issues, [issue, todo, %{id: "ignored"}])
    Application.put_env(:cymphony_elixir, :memory_tracker_recipient, self())

    {:ok, issue: issue, todo: todo}
  end

  test "adapter/0 follows the loaded workflow tracker kind" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    assert Tracker.adapter() == Memory

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert Tracker.adapter() == Adapter

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "youtrack")
    assert Tracker.adapter() == YouTrackAdapter
  end

  test "adapter/1 follows the given config tracker kind" do
    assert Tracker.adapter(memory_config()) == Memory
    assert Tracker.adapter(linear_config()) == Adapter
    assert Tracker.adapter(youtrack_config()) == YouTrackAdapter
    assert Tracker.adapter(%Schema{}) == Adapter
  end

  test "zero-arity reads and writes delegate through the memory adapter", %{issue: issue} do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert {:ok, [^issue, _todo]} = Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = Tracker.fetch_issues_by_states([" in progress "])
    assert {:ok, [^issue]} = Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = Tracker.create_comment("issue-1", "zero-arity comment")
    assert :ok = Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "zero-arity comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}
  end

  test "fetch_descendant_ids/2 is optional and says so rather than crashing" do
    # A tracker that cannot express "children of" must not take a scoped
    # project down; the caller degrades to filtering on parent_identifier.
    assert Tracker.fetch_descendant_ids("HFE-6470", memory_config()) == {:error, :not_supported}
    assert Tracker.fetch_descendant_ids("HFE-6470", linear_config()) == {:error, :not_supported}
  end

  test "fetch_descendant_ids/2 delegates when the adapter implements it" do
    Application.put_env(:cymphony_elixir, :youtrack_client_module, __MODULE__.SubtreeStub)
    on_exit(fn -> Application.delete_env(:cymphony_elixir, :youtrack_client_module) end)

    assert Tracker.fetch_descendant_ids("HFE-6470", youtrack_config()) == {:ok, ["HFE-6470", "HFE-6471"]}
  end

  defmodule SubtreeStub do
    @moduledoc false
    def fetch_descendant_ids("HFE-6470", _config), do: {:ok, ["HFE-6470", "HFE-6471"]}
  end

  test "config-arity reads and writes delegate through the given adapter", %{issue: issue, todo: todo} do
    config = memory_config()

    assert {:ok, [^issue, ^todo]} = Tracker.fetch_candidate_issues(config)
    assert {:ok, [^todo]} = Tracker.fetch_issues_by_states(["TODO"], config)
    assert {:ok, [^issue]} = Tracker.fetch_issue_states_by_ids(["issue-1"], config)
    assert :ok = Tracker.create_comment("issue-1", "config comment", config)
    assert :ok = Tracker.update_issue_state("issue-1", "In Review", config)
    assert_receive {:memory_tracker_comment, "issue-1", "config comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "In Review"}
  end

  defp youtrack_config do
    {:ok, config} = Schema.parse(%{"tracker" => %{"kind" => "youtrack"}})
    config
  end

  defp memory_config do
    {:ok, config} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    config
  end

  defp linear_config do
    {:ok, config} =
      Schema.parse(%{
        "tracker" => %{
          "kind" => "linear",
          "api_key" => "token",
          "project_slug" => "project"
        }
      })

    config
  end
end
