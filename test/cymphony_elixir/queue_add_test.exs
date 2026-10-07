defmodule CymphonyElixir.QueueAddTest do
  # async: false — mutates :config_dir_override, Endpoint, and ProjectRegistry.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.ProjectSupervisor
  alias CymphonyElixirWeb.Control

  @endpoint CymphonyElixirWeb.Endpoint

  # Answers the two manual-issue calls the way the real orchestrator does,
  # keyed by the issue id it is asked about.
  defmodule AddOrch do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :recipient), name: Keyword.fetch!(opts, :name))

    @impl true
    def init(recipient), do: {:ok, recipient}

    @impl true
    def handle_call({:add_manual_issue, "CRASH"}, _from, _recipient), do: exit(:boom)

    def handle_call({:add_manual_issue, key} = msg, _from, recipient) do
      send(recipient, {:orch, msg})

      reply =
        case key do
          "HFE-1" -> {:ok, %Issue{id: "HFE-1", identifier: "HFE-1", state: "Todo", title: "Do the thing"}}
          "GONE" -> {:error, :issue_not_found}
          "DONE" -> {:error, {:issue_terminal, "Done"}}
          "STUCK" -> {:error, {:state_update_failed, :forbidden}}
          _ -> {:error, :weird}
        end

      {:reply, reply, recipient}
    end

    def handle_call({:remove_manual_issue, "HFE-1"} = msg, _from, recipient) do
      send(recipient, {:orch, msg})
      {:reply, :ok, recipient}
    end

    def handle_call({:remove_manual_issue, _key}, _from, recipient), do: {:reply, {:error, :not_manual}, recipient}
  end

  setup do
    endpoint_config = Application.get_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, [])
    tmp = Path.join(System.tmp_dir!(), "cymphony-queue-add-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)
      Application.put_env(:cymphony_elixir, CymphonyElixirWeb.Endpoint, endpoint_config)
      File.rm_rf!(tmp)
    end)

    %{endpoint_config: endpoint_config}
  end

  defp start_endpoint!(endpoint_config, overrides \\ []) do
    Application.put_env(
      :cymphony_elixir,
      CymphonyElixirWeb.Endpoint,
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)
    )

    start_supervised!({CymphonyElixirWeb.Endpoint, []})
  end

  defp start_orch!(name, role \\ :orchestrator) do
    start_supervised!(%{
      id: {:add_orch, name, role},
      start: {AddOrch, :start_link, [[name: ProjectSupervisor.via_tuple(name, role), recipient: self()]]}
    })
  end

  describe "POST /api/v1/queue-add" do
    setup %{endpoint_config: endpoint_config} do
      start_endpoint!(endpoint_config)
      start_orch!("hfe")
      :ok
    end

    test "queues the issue and answers with what the tracker said" do
      conn = post(build_conn(), "/api/v1/queue-add?project=hfe", %{"issue" => " HFE-1 "})

      assert json_response(conn, 202) == %{
               "issue" => "HFE-1",
               "issue_id" => "HFE-1",
               "state" => "Todo",
               "title" => "Do the thing",
               "project" => "hfe"
             }

      assert_receive {:orch, {:add_manual_issue, "HFE-1"}}
    end

    test "each refusal has its own error code" do
      for {issue, code} <- [
            {"GONE", "issue_not_found"},
            {"DONE", "issue_terminal"},
            {"STUCK", "state_update_failed"},
            {"OTHER", "queue_add_failed"}
          ] do
        body = json_response(post(build_conn(), "/api/v1/queue-add?project=hfe", %{"issue" => issue}), 422)
        assert body["error"]["code"] == code, "#{issue} -> #{inspect(body)}"
      end

      assert json_response(post(build_conn(), "/api/v1/queue-add?project=ghost", %{"issue" => "HFE-1"}), 422)["error"]["code"] ==
               "project_not_found"
    end

    test "project and issue are both required" do
      for {path, body} <- [
            {"/api/v1/queue-add", %{"issue" => "HFE-1"}},
            {"/api/v1/queue-add?project=hfe", %{}},
            {"/api/v1/queue-add?project=hfe", %{"issue" => "  "}},
            {"/api/v1/queue-add?project=hfe", %{"issue" => 7}}
          ] do
        assert json_response(post(build_conn(), path, body), 422)["error"]["code"] == "invalid_queue_add"
      end
    end

    test "queue-remove drops a hand-added issue, and says when it was not one" do
      assert json_response(post(build_conn(), "/api/v1/queue-remove?project=hfe", %{"issue" => "HFE-1"}), 202) ==
               %{"issue" => "HFE-1", "removed" => true, "project" => "hfe"}

      assert_receive {:orch, {:remove_manual_issue, "HFE-1"}}

      assert json_response(post(build_conn(), "/api/v1/queue-remove?project=hfe", %{"issue" => "HFE-2"}), 422)["error"]["code"] ==
               "not_manual"

      assert json_response(post(build_conn(), "/api/v1/queue-remove?project=hfe", %{}), 422)["error"]["code"] ==
               "invalid_queue_remove"
    end

    test "other methods are 405, not an issue lookup" do
      assert json_response(get(build_conn(), "/api/v1/queue-add"), 405)["error"]["code"] == "method_not_allowed"
      assert json_response(get(build_conn(), "/api/v1/queue-remove"), 405)["error"]["code"] == "method_not_allowed"
    end
  end

  describe "Control" do
    test "an orchestrator that dies mid-call is reported as unavailable", %{endpoint_config: endpoint_config} do
      start_endpoint!(endpoint_config)
      start_orch!("hfe")

      ExUnit.CaptureLog.capture_log(fn ->
        assert Control.add_manual_issue("hfe", "CRASH") == {:error, :unavailable}
      end)
    end

    test "with no project orchestrators, the legacy orchestrator answers for any name", %{endpoint_config: endpoint_config} do
      legacy = start_orch!("legacy", :workflow_store)
      start_endpoint!(endpoint_config, orchestrator: legacy)

      assert {:ok, %Issue{identifier: "HFE-1"}} = Control.add_manual_issue("whatever", "HFE-1")
      assert :ok = Control.remove_manual_issue("whatever", "HFE-1")
    end

    test "with no orchestrator at all, the project is not found" do
      assert Control.add_manual_issue("ghost", "HFE-1") == {:error, :not_found}
      assert Control.remove_manual_issue("ghost", "HFE-1") == {:error, :not_found}
    end
  end
end
