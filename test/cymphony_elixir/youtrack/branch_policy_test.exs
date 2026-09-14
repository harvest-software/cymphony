defmodule CymphonyElixir.YouTrack.BranchPolicyTest do
  @moduledoc """
  Whether a sub-task cuts its branch from its parent depends on the *parent's*
  tags, and no child payload carries them. This is the lookup that fills that
  gap, and the things worth testing are the ones that keep it off the hot path:
  one batched request for a whole page, a cache that survives the next poll, and
  a failure that degrades to "not a container" instead of taking the tick down.

  Driven against a real HTTP server for the same reason `ScopeTest` is — the
  interesting behaviour lives between the query string and the cached answer.
  """

  use ExUnit.Case, async: false

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.YouTrack.{BranchPolicy, Client}

  defmodule Stub do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      query = conn.query_params["query"] || ""
      send(owner(), {:query, query})

      case :persistent_term.get({__MODULE__, :status}, 200) do
        200 ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, JSON.encode!(:persistent_term.get({__MODULE__, :issues}, [])))

        status ->
          Plug.Conn.send_resp(conn, status, "nope")
      end
    end

    defp owner, do: :persistent_term.get({__MODULE__, :owner})
  end

  setup do
    :persistent_term.put({Stub, :owner}, self())
    {:ok, pid} = Bandit.start_link(plug: Stub, port: 0, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(pid)

    previous = Application.get_env(:cymphony_elixir, :branch_policy_cache_ttl_ms)

    on_exit(fn ->
      :persistent_term.erase({Stub, :owner})
      :persistent_term.erase({Stub, :issues})
      :persistent_term.erase({Stub, :status})

      if previous,
        do: Application.put_env(:cymphony_elixir, :branch_policy_cache_ttl_ms, previous),
        else: Application.delete_env(:cymphony_elixir, :branch_policy_cache_ttl_ms)
    end)

    {:ok, port: port}
  end

  defp stub!(issues), do: :persistent_term.put({Stub, :issues}, issues)

  defp tagged(id, tags), do: %{"idReadable" => id, "tags" => Enum.map(tags, &%{"name" => &1})}

  # A fresh endpoint per test keys the cache separately, so tests never share
  # entries and none of them has to erase the others' keys.
  defp config(port, overrides \\ %{}) do
    {:ok, parsed} =
      Schema.parse(%{
        "tracker" =>
          Map.merge(
            %{
              "kind" => "youtrack",
              "api_key" => "perm:t",
              "endpoint" => "http://127.0.0.1:#{port}/#{System.unique_integer([:positive])}",
              "project_slug" => "HFE"
            },
            overrides
          )
      })

    parsed
  end

  test "resolves a whole page of parents in one request", %{port: port} do
    stub!([tagged("HFE-6470", ["Feature Branch"]), tagged("HFE-6489", ["Backend"])])

    parents = BranchPolicy.feature_branch_parents(config(port), ["HFE-6470", "HFE-6489"])

    assert parents == ["hfe-6470"]

    assert_receive {:query, query}
    assert query =~ "HFE-6470"
    assert query =~ "HFE-6489"
    refute_receive {:query, _}, 50
  end

  test "an already-cached parent is never refetched", %{port: port} do
    config = config(port)
    stub!([tagged("HFE-6470", ["Feature Branch"])])

    assert BranchPolicy.feature_branch_parents(config, ["HFE-6470"]) == ["hfe-6470"]
    assert_receive {:query, _}

    assert BranchPolicy.feature_branch_parents(config, ["HFE-6470"]) == ["hfe-6470"]
    refute_receive {:query, _}, 50
  end

  test "seeded labels answer without any request at all", %{port: port} do
    # The poll batch usually contains the epic itself, so its tags are already
    # in hand — paying for a request to re-read them would be pure waste.
    config = config(port)
    BranchPolicy.seed(config, %{"HFE-6470" => ["Feature Branch"], "HFE-6471" => []})

    parents = BranchPolicy.feature_branch_parents(config, ["HFE-6470", "HFE-6471"])

    assert parents == ["hfe-6470"]
    refute_receive {:query, _}, 50
  end

  test "the cache expires and re-resolves", %{port: port} do
    Application.put_env(:cymphony_elixir, :branch_policy_cache_ttl_ms, 1)
    config = config(port)
    stub!([tagged("HFE-6470", ["Feature Branch"])])

    BranchPolicy.feature_branch_parents(config, ["HFE-6470"])
    assert_receive {:query, _}

    Process.sleep(10)
    assert BranchPolicy.feature_branch_parents(config, ["HFE-6470"]) == ["hfe-6470"]
    assert_receive {:query, _}
  end

  test "invalidate/2 forces the next read to re-resolve", %{port: port} do
    config = config(port)
    stub!([tagged("HFE-6470", ["Feature Branch"])])

    BranchPolicy.feature_branch_parents(config, ["HFE-6470"])
    assert_receive {:query, _}

    assert BranchPolicy.invalidate(config, "HFE-6470") == :ok
    BranchPolicy.feature_branch_parents(config, ["HFE-6470"])
    assert_receive {:query, _}
  end

  test "a failed lookup is not a container, and does not raise", %{port: port} do
    # Degrading to the configured base branch is the conservative direction: a
    # human sees the wrong base on the merge request, whereas the opposite
    # error silently retargets work onto a branch it was never meant to touch.
    :persistent_term.put({Stub, :status}, 500)

    assert BranchPolicy.feature_branch_parents(config(port), ["HFE-6470"]) == []
    assert_receive {:query, _}
  end

  test "a blank label switches the rule off entirely", %{port: port} do
    config = config(port, %{"feature_branch_label" => "  "})
    stub!([tagged("HFE-6470", ["Feature Branch"])])

    assert BranchPolicy.feature_branch_parents(config, ["HFE-6470"]) == []
    refute_receive {:query, _}, 50
  end

  test "the label is configurable and matched case-insensitively", %{port: port} do
    config = config(port, %{"feature_branch_label" => "  EPIC  "})
    stub!([tagged("HFE-6470", ["epic"])])

    assert BranchPolicy.feature_branch_parents(config, ["HFE-6470"]) == ["hfe-6470"]
  end

  test "label/1 defaults when the config says nothing" do
    assert BranchPolicy.label(%{}) == "Feature Branch"
    assert BranchPolicy.label(%{tracker: %{}}) == "Feature Branch"
    assert BranchPolicy.label(%{tracker: %{feature_branch_label: "Epic"}}) == "Epic"
    assert BranchPolicy.label(%{tracker: %{feature_branch_label: ""}}) == nil
  end

  test "a config with no endpoint still caches, keyed on the empty string" do
    # `Config.settings!/0` is not always shaped like a tracker config, and the
    # lookup must not raise on the way to answering from the cache.
    assert BranchPolicy.seed(%{}, %{"HFE-6470" => ["Feature Branch"]}) == :ok
    assert BranchPolicy.feature_branch_parents(%{}, ["HFE-6470"]) == ["hfe-6470"]
    assert BranchPolicy.invalidate(%{}, "HFE-6470") == :ok
  end

  test "seed/2 ignores entries that are not an id and a list of labels" do
    # `Map.new/2` over a raw page yields whatever the payload had, including a
    # missing `idReadable`.
    assert BranchPolicy.seed(%{}, %{nil => ["Feature Branch"], "HFE-1" => nil, 7 => []}) == :ok
  end

  test "nothing to resolve means no request", %{port: port} do
    assert BranchPolicy.feature_branch_parents(config(port), []) == []
    assert BranchPolicy.feature_branch_parents(config(port), [nil, 7]) == []
    refute_receive {:query, _}, 50
  end

  test "fetch_issue_labels/2 keys tag names by readable id", %{port: port} do
    stub!([tagged("HFE-6470", ["Feature Branch", "API"]), %{"idReadable" => "HFE-6471"}])

    assert Client.fetch_issue_labels(["HFE-6470", "HFE-6471"], config(port)) ==
             {:ok, %{"HFE-6470" => ["Feature Branch", "API"], "HFE-6471" => []}}

    assert Client.fetch_issue_labels([], config(port)) == {:ok, %{}}
    assert Client.fetch_issue_labels(["  "], config(port)) == {:ok, %{}}
  end
end
