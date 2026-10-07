defmodule CymphonyElixir.Orchestrator.DurableStateTest do
  # Toggles application env read by every orchestrator.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Orchestrator.DurableState

  setup do
    root = Path.join(System.tmp_dir!(), "cymphony-durable-state-#{System.unique_integer([:positive])}")
    path = Path.join([root, "nested", "orchestrator_state.json"])

    Application.put_env(:cymphony_elixir, :durable_orchestrator_state, true)
    Application.put_env(:cymphony_elixir, :orchestrator_state_file, path)

    on_exit(fn ->
      Application.put_env(:cymphony_elixir, :durable_orchestrator_state, false)
      Application.delete_env(:cymphony_elixir, :orchestrator_state_file)
      File.rm_rf(root)
    end)

    %{path: path, root: root}
  end

  defp sample do
    %{
      retries: %{
        "HFE-6662" => %{
          identifier: "HFE-6662",
          attempt: 2,
          failures: 1,
          error: "usage limit reached",
          due_at_ms: 1_791_333_060_000,
          held: true,
          worker_host: nil,
          workspace_path: "/w/HFE-6662",
          usage_limited_until: 1_791_333_000
        }
      },
      running: %{
        "HFE-6660" => %{
          identifier: "HFE-6660",
          attempt: nil,
          failures: 0,
          worker_host: "box",
          workspace_path: "/w/HFE-6660",
          session_id: "c60c3754",
          agent_kind: "claude"
        }
      },
      resumable: %{
        "HFE-6662" => %{
          identifier: "HFE-6662",
          session_id: "4cc90afd",
          agent_kind: "claude",
          worker_host: nil,
          reason: "the agent hit its usage limit"
        }
      },
      usage_limits: %{{"claude", nil} => 1_791_333_000, {"claude", "cz1"} => 1_791_334_000}
    }
  end

  test "round-trips a project's state, owner-only", %{path: path} do
    assert :ok = DurableState.save("Harvest Frontend", sample())

    loaded = DurableState.load("Harvest Frontend")
    assert loaded.retries["HFE-6662"] == sample().retries["HFE-6662"]
    assert loaded.running["HFE-6660"] == sample().running["HFE-6660"]
    assert loaded.resumable == sample().resumable
    assert loaded.usage_limits == sample().usage_limits

    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "projects are independent and a legacy (nil) project has its own key" do
    assert :ok = DurableState.save("A", sample())
    assert :ok = DurableState.save(nil, %{DurableState.empty() | resumable: sample().resumable})

    assert DurableState.load("A").retries != %{}
    assert DurableState.load(nil).resumable == sample().resumable
    assert DurableState.load(nil).retries == %{}
    assert DurableState.load("B") == DurableState.empty()
  end

  test "saving an empty state removes the project instead of storing a husk", %{path: path} do
    assert :ok = DurableState.save("A", sample())
    assert :ok = DurableState.save("A", DurableState.empty())

    assert %{"projects" => projects} = path |> File.read!() |> Jason.decode!()
    assert projects == %{}
  end

  test "missing file loads empty; a corrupt file warns and loads empty", %{path: path} do
    assert DurableState.load("A") == DurableState.empty()

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not json")

    log = capture_log(fn -> assert DurableState.load("A") == DurableState.empty() end)
    assert log =~ "starting without saved retries"

    File.write!(path, ~s({"version":1}))
    assert DurableState.load("A") == DurableState.empty()

    # A corrupt file is replaced, not merged into, on the next save.
    File.write!(path, "{not json")
    assert :ok = DurableState.save("A", sample())
    assert DurableState.load("A").resumable == sample().resumable
  end

  test "entries that do not parse are dropped field by field", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "projects" => %{
          "A" => %{
            "retries" => %{
              "ok" => %{"due_at_ms" => 5, "attempt" => -1, "failures" => "x", "identifier" => ""},
              "no-due" => %{"identifier" => "X"},
              "" => %{"due_at_ms" => 1},
              "not-a-map" => 3
            },
            "running" => %{"r" => %{}},
            "resumable" => %{"no-kind" => %{"session_id" => "s"}, "no-session" => %{"agent_kind" => "claude"}},
            "usage_limits" => [%{"agent_kind" => "claude", "resets_at" => "later"}, "junk", %{"agent_kind" => "codex", "provider" => "", "resets_at" => 9}]
          },
          "B" => "not a map",
          "C" => %{"retries" => [], "running" => nil, "resumable" => 1, "usage_limits" => %{}}
        }
      })
    )

    loaded = DurableState.load("A")

    assert loaded.retries == %{
             "ok" => %{
               identifier: nil,
               attempt: 1,
               failures: 0,
               error: nil,
               due_at_ms: 5,
               held: false,
               worker_host: nil,
               workspace_path: nil,
               usage_limited_until: nil
             }
           }

    assert %{"r" => %{attempt: nil, failures: 0, session_id: nil}} = loaded.running
    assert loaded.resumable == %{}
    assert loaded.usage_limits == %{{"codex", nil} => 9}
    assert DurableState.load("B") == DurableState.empty()
    assert DurableState.load("C") == DurableState.empty()
  end

  test "a write failure is reported and leaves no staged file behind", %{root: root} do
    # The target path is an existing directory, so the final rename fails.
    blocked = Path.join(root, "blocked.json")
    File.mkdir_p!(Path.join(blocked, "occupied"))
    Application.put_env(:cymphony_elixir, :orchestrator_state_file, blocked)

    assert {:error, _reason} = DurableState.save("A", sample())
    assert root |> File.ls!() |> Enum.filter(&String.contains?(&1, ".tmp-")) == []
  end

  test "disabled: nothing is read or written", %{path: path} do
    Application.put_env(:cymphony_elixir, :durable_orchestrator_state, false)

    assert :ok = DurableState.save("A", sample())
    refute File.exists?(path)
    assert DurableState.load("A") == DurableState.empty()
    refute DurableState.enabled?()
  end

  test "defaults to the config dir" do
    Application.delete_env(:cymphony_elixir, :orchestrator_state_file)
    assert DurableState.path() == Path.join(CymphonyConfig.config_dir(), "orchestrator_state.json")
  end
end
