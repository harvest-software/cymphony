defmodule CymphonyElixir.YouTrack.ScopeTest do
  @moduledoc """
  `scope_issue` restricts a run to one issue and everything under it.

  Driven against a real HTTP server rather than a stubbed client, because the
  parts worth testing are the ones between the query string and the decoded
  issue: the breadth-first walk, its cycle and depth guards, and the local
  membership filter that is the actual correctness boundary.
  """

  use ExUnit.Case, async: false

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.YouTrack.{Client, Scope}

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

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, JSON.encode!(reply(query)))
    end

    defp owner, do: :persistent_term.get({__MODULE__, :owner})

    defp reply(query) do
      case :persistent_term.get({__MODULE__, :replies}) |> Enum.find(fn {match, _} -> query =~ match end) do
        {_match, issues} -> issues
        nil -> []
      end
    end
  end

  setup do
    :persistent_term.put({Stub, :owner}, self())
    {:ok, pid} = Bandit.start_link(plug: Stub, port: 0, startup_log: false)
    {:ok, {_addr, port}} = ThousandIsland.listener_info(pid)

    on_exit(fn ->
      :persistent_term.erase({Stub, :owner})
      :persistent_term.erase({Stub, :replies})
    end)

    {:ok, port: port}
  end

  defp stub!(replies), do: :persistent_term.put({Stub, :replies}, replies)

  defp config(port, scope) do
    {:ok, parsed} =
      Schema.parse(%{
        "tracker" => %{
          "kind" => "youtrack",
          "api_key" => "perm:t",
          "endpoint" => "http://127.0.0.1:#{port}",
          "project_slug" => "HFE",
          "scope_issue" => scope,
          "active_states" => ["Open"]
        }
      })

    # The subtree is cached per {endpoint, root}, and each test gets its own
    # port, so no test can read another's cached answer.
    parsed
  end

  defp child(id, parent) do
    %{
      "idReadable" => id,
      "summary" => id,
      "customFields" => [%{"name" => "State", "value" => %{"name" => "Open"}}],
      "links" => [
        %{
          "direction" => "INWARD",
          "linkType" => %{"name" => "Subtask", "sourceToTarget" => "parent for", "targetToSource" => "subtask of"},
          "issues" => [%{"idReadable" => parent, "customFields" => []}]
        }
      ]
    }
  end

  test "walks the subtree breadth-first, one level per request", %{port: port} do
    stub!([
      {"subtask of: {HFE-6470}", [%{"idReadable" => "HFE-6471"}, %{"idReadable" => "HFE-6472"}]},
      {"subtask of: {HFE-6471}, {HFE-6472}", [%{"idReadable" => "HFE-6489"}]},
      {"subtask of: {HFE-6489}", []}
    ])

    assert {:ok, ids} = Client.fetch_descendant_ids("HFE-6470", config(port, "HFE-6470"))

    # The root is in scope too, so one flag covers "this epic" and "just this
    # ticket" alike.
    assert Enum.sort(ids) == ["HFE-6470", "HFE-6471", "HFE-6472", "HFE-6489"]
  end

  test "a link cycle terminates instead of walking forever", %{port: port} do
    # YouTrack will happily let someone link a grandchild back to the root.
    stub!([
      {"subtask of: {HFE-6470}", [%{"idReadable" => "HFE-6471"}]},
      {"subtask of: {HFE-6471}", [%{"idReadable" => "HFE-6470"}, %{"idReadable" => "HFE-6472"}]},
      {"subtask of: {HFE-6472}", [%{"idReadable" => "HFE-6471"}]}
    ])

    assert {:ok, ids} = Client.fetch_descendant_ids("HFE-6470", config(port, "HFE-6470"))
    assert Enum.sort(ids) == ["HFE-6470", "HFE-6471", "HFE-6472"]
  end

  test "an unscoped project resolves to the empty set, meaning no filtering", %{port: port} do
    stub!([])

    assert Scope.issue_ids(config(port, nil)) == {:ok, []}
    assert Scope.issue_ids(config(port, "   ")) == {:ok, []}
    refute_received {:query, _}
  end

  test "an out-of-scope issue the server returned anyway is dropped locally", %{port: port} do
    # The `issue id:` clause is a narrowing optimization; the local membership
    # filter is what actually guarantees an out-of-scope issue never reaches a
    # dispatch.
    stub!([
      {"subtask of: {HFE-6470}", [%{"idReadable" => "HFE-6471"}]},
      {"subtask of: {HFE-6471}", []},
      {"project: {HFE}", [child("HFE-6471", "HFE-6470"), child("HFE-9999", "SOMETHING-ELSE")]}
    ])

    assert {:ok, issues} = Client.fetch_candidate_issues(config(port, "HFE-6470"))
    assert Enum.map(issues, & &1.identifier) == ["HFE-6471"]
  end

  test "the subtree is resolved once and served from cache after that", %{port: port} do
    # Resolving costs one request per level of the tree; the poll runs every
    # few seconds and a subtree changes on the order of days.
    stub!([{"subtask of: {HFE-6470}", []}])
    config = config(port, "HFE-6470")

    assert {:ok, ids} = Scope.issue_ids(config)
    assert_received {:query, _}

    assert Scope.issue_ids(config) == {:ok, ids}
    refute_received {:query, _}

    # And `invalidate/2` is how a caller forces a re-resolution.
    assert Scope.invalidate(config, "HFE-6470") == :ok
    assert {:ok, ^ids} = Scope.issue_ids(config)
    assert_received {:query, _}
  end

  test "the cache expires so a new sub-task is picked up", %{port: port} do
    Application.put_env(:cymphony_elixir, :scope_cache_ttl_ms, 0)
    on_exit(fn -> Application.delete_env(:cymphony_elixir, :scope_cache_ttl_ms) end)

    stub!([{"subtask of: {HFE-6470}", []}])
    config = config(port, "HFE-6470")

    assert {:ok, _} = Scope.issue_ids(config)
    assert_received {:query, _}
    assert {:ok, _} = Scope.issue_ids(config)
    assert_received {:query, _}
  end

  test "a config with no endpoint still has a usable cache key" do
    assert Scope.invalidate(%{tracker: %{}}, "HFE-1") == :ok
  end

  test "a resolution failure is neither cached nor swallowed" do
    # Falling back to an unscoped poll would dispatch agents across the whole
    # board, which is the exact opposite of what scoping asked for.
    {:ok, config} =
      Schema.parse(%{
        "tracker" => %{"kind" => "youtrack", "api_key" => "perm:t", "project_slug" => "HFE", "scope_issue" => "HFE-1"}
      })

    log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = Scope.issue_ids(config) end)
    assert log =~ "Could not resolve scope subtree"
  end

  test "scope_issue/1 reads only a usable string" do
    assert Scope.scope_issue(%{tracker: %{scope_issue: "  HFE-1 "}}) == "HFE-1"
    assert Scope.scope_issue(%{tracker: %{scope_issue: "   "}}) == nil
    assert Scope.scope_issue(%{tracker: %{scope_issue: nil}}) == nil
    assert Scope.scope_issue(%{tracker: %{}}) == nil
    assert Scope.scope_issue(%{}) == nil
  end

  test "an empty root id is unscoped rather than an empty scope", %{port: port} do
    assert Client.fetch_descendant_ids("   ", config(port, "HFE-6470")) == {:ok, []}
  end

  test "the poll query carries the project, state and scope clauses", %{port: port} do
    stub!([
      {"subtask of: {HFE-6470}", []},
      {"project: {HFE}", []}
    ])

    assert {:ok, []} = Client.fetch_candidate_issues(config(port, "HFE-6470"))

    assert_received {:query, "subtask of: {HFE-6470}"}
    assert_received {:query, poll_query}
    assert poll_query =~ "project: {HFE}"
    assert poll_query =~ "State: {Open}"
    assert poll_query =~ "issue id: {HFE-6470}"
  end
end
