defmodule CymphonyElixir.YouTrack.AdapterTest do
  use ExUnit.Case, async: false

  alias CymphonyElixir.YouTrack.Adapter

  defmodule StubClient do
    @moduledoc false

    def fetch_candidate_issues, do: record({:fetch_candidate_issues})
    def fetch_candidate_issues(config), do: record({:fetch_candidate_issues, config})
    def fetch_issues_by_states(states), do: record({:fetch_issues_by_states, states})
    def fetch_issues_by_states(states, config), do: record({:fetch_issues_by_states, states, config})
    def fetch_issue_states_by_ids(ids), do: record({:fetch_issue_states_by_ids, ids})
    def fetch_issue_states_by_ids(ids, config), do: record({:fetch_issue_states_by_ids, ids, config})
    def fetch_descendant_ids(root, config), do: record({:fetch_descendant_ids, root, config})
    def create_comment(id, body), do: record({:create_comment, id, body})
    def create_comment(id, body, config), do: record({:create_comment, id, body, config})
    def update_issue_state(id, state), do: record({:update_issue_state, id, state})
    def update_issue_state(id, state, config), do: record({:update_issue_state, id, state, config})

    defp record(call) do
      send(Application.get_env(:cymphony_elixir, :youtrack_stub_recipient), call)
      {:ok, call}
    end
  end

  setup do
    Application.put_env(:cymphony_elixir, :youtrack_client_module, StubClient)
    Application.put_env(:cymphony_elixir, :youtrack_stub_recipient, self())

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :youtrack_client_module)
      Application.delete_env(:cymphony_elixir, :youtrack_stub_recipient)
    end)

    :ok
  end

  test "implements the tracker behaviour" do
    assert CymphonyElixir.Tracker in Adapter.__info__(:attributes)[:behaviour]
  end

  test "every read and write delegates to the configured client module" do
    config = %{tracker: %{kind: "youtrack"}}

    assert {:ok, _} = Adapter.fetch_candidate_issues()
    assert {:ok, _} = Adapter.fetch_candidate_issues(config)
    assert {:ok, _} = Adapter.fetch_issues_by_states(["Todo"])
    assert {:ok, _} = Adapter.fetch_issues_by_states(["Todo"], config)
    assert {:ok, _} = Adapter.fetch_issue_states_by_ids(["LLM-1"])
    assert {:ok, _} = Adapter.fetch_issue_states_by_ids(["LLM-1"], config)
    assert {:ok, _} = Adapter.fetch_descendant_ids("HFE-6470", config)
    assert {:ok, _} = Adapter.create_comment("LLM-1", "hi")
    assert {:ok, _} = Adapter.create_comment("LLM-1", "hi", config)
    assert {:ok, _} = Adapter.update_issue_state("LLM-1", "Done")
    assert {:ok, _} = Adapter.update_issue_state("LLM-1", "Done", config)

    assert_received {:fetch_candidate_issues}
    assert_received {:fetch_candidate_issues, ^config}
    assert_received {:fetch_issues_by_states, ["Todo"]}
    assert_received {:fetch_issues_by_states, ["Todo"], ^config}
    assert_received {:fetch_descendant_ids, "HFE-6470", ^config}
    assert_received {:fetch_issue_states_by_ids, ["LLM-1"]}
    assert_received {:fetch_issue_states_by_ids, ["LLM-1"], ^config}
    assert_received {:create_comment, "LLM-1", "hi"}
    assert_received {:create_comment, "LLM-1", "hi", ^config}
    assert_received {:update_issue_state, "LLM-1", "Done"}
    assert_received {:update_issue_state, "LLM-1", "Done", ^config}
  end

  test "defaults to the real client when nothing is configured" do
    Application.delete_env(:cymphony_elixir, :youtrack_client_module)

    assert {:error, _reason} = Adapter.fetch_candidate_issues(%{tracker: %{api_key: nil}})
  end
end
