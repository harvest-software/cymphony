defmodule CymphonyElixir.Cymphony.ConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CymphonyElixir.Config
  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.Defaults
  alias CymphonyElixir.Cymphony.WorkflowGenerator
  alias CymphonyElixir.Workflow

  describe "normalize/1" do
    test "keeps a non-empty projects list as-is" do
      config = %{"projects" => [%{"name" => "alpha"}], "extra" => 1}
      assert CymphonyConfig.normalize(config) == config
    end

    test "keeps a config that already has a projects key even when the list is empty" do
      config = %{"projects" => []}
      assert CymphonyConfig.normalize(config) == config
    end

    test "wraps a flat config using linear_project_slug as the project name" do
      config = %{"linear_project_slug" => "farm", "linear_api_key" => "k"}

      assert CymphonyConfig.normalize(config) == %{
               "projects" => [
                 %{
                   "linear_project_slug" => "farm",
                   "linear_api_key" => "k",
                   "name" => "farm"
                 }
               ]
             }
    end

    test "wraps a flat config with name default when slug is missing" do
      assert CymphonyConfig.normalize(%{"workspace_root" => "/tmp"}) == %{
               "projects" => [%{"workspace_root" => "/tmp", "name" => "default"}]
             }
    end
  end

  describe "projects/1" do
    test "returns the projects list from a normalized config" do
      projects = [%{"name" => "alpha"}, %{"name" => "beta"}]
      assert CymphonyConfig.projects(%{"projects" => projects}) == projects
    end

    test "returns an empty list when projects is absent or not a list" do
      assert CymphonyConfig.projects(%{}) == []
      assert CymphonyConfig.projects(%{"projects" => "oops"}) == []
      assert CymphonyConfig.projects(%{"projects" => %{}}) == []
      assert CymphonyConfig.projects("not a map") == []
    end
  end

  describe "find_project/2" do
    @config %{"projects" => [%{"name" => "alpha", "agent" => "claude"}, %{"name" => "beta"}]}

    test "returns the matching project by name" do
      assert {:ok, %{"name" => "alpha", "agent" => "claude"}} =
               CymphonyConfig.find_project(@config, "alpha")
    end

    test "returns :project_not_found when no project matches" do
      assert CymphonyConfig.find_project(@config, "ghost") == {:error, :project_not_found}
      assert CymphonyConfig.find_project(%{}, "alpha") == {:error, :project_not_found}
    end
  end

  describe "parse_providers_csv/1" do
    test "parses, trims, and drops empty segments" do
      assert CymphonyConfig.parse_providers_csv("cv1, cz2,,ck1 ,") == {:ok, ["cv1", "cz2", "ck1"]}
    end

    test "returns :empty for a blank string" do
      assert CymphonyConfig.parse_providers_csv("") == {:error, :empty}
      assert CymphonyConfig.parse_providers_csv(" , , ") == {:error, :empty}
    end

    test "returns :empty for non-binary values" do
      assert CymphonyConfig.parse_providers_csv(nil) == {:error, :empty}
      assert CymphonyConfig.parse_providers_csv(123) == {:error, :empty}
      assert CymphonyConfig.parse_providers_csv(["cv1"]) == {:error, :empty}
    end
  end

  describe "to_schema_map/1" do
    test "builds a Schema-parseable map with generation defaults applied" do
      map = CymphonyConfig.to_schema_map(%{"linear_api_key" => "k", "linear_project_slug" => "slug"})

      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.kind == "linear"
      assert parsed.tracker.api_key == "k"
      assert parsed.tracker.project_slug == "slug"
      assert parsed.tracker.active_states == ["Todo", "In Progress", "Merging", "Rework"]
      assert parsed.tracker.terminal_states == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
      assert parsed.polling.interval_ms == 5000
      assert parsed.agent.max_concurrent_agents == 10
      assert parsed.agent.max_turns == 20
      assert parsed.agent.stall_timeout_ms == 300_000
      assert parsed.claude.command == "claude"
      assert parsed.claude.output_format == "stream-json"
      assert map["antigravity"]["command"] == "agy"
      assert map["antigravity"]["output_format"] == "stream-json"
      assert map["antigravity"]["skip_permissions"] == true
    end

    test "keeps the Linear shape when no tracker_kind is named" do
      map = CymphonyConfig.to_schema_map(%{"linear_api_key" => "k", "linear_project_slug" => "slug"})

      assert map["tracker"]["kind"] == "linear"
      refute Map.has_key?(map["tracker"], "endpoint")
      refute Map.has_key?(map["tracker"], "assignee")
      refute Map.has_key?(map, "server")
    end

    test "generates a YouTrack tracker section" do
      map =
        CymphonyConfig.to_schema_map(%{
          "tracker_kind" => "youtrack",
          "tracker_endpoint" => "  https://example.youtrack.cloud  ",
          "tracker_api_key" => "perm:token",
          "tracker_project_slug" => "LLM",
          "tracker_assignee" => "jeremy"
        })

      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.kind == "youtrack"
      assert parsed.tracker.endpoint == "https://example.youtrack.cloud"
      assert parsed.tracker.api_key == "perm:token"
      assert parsed.tracker.project_slug == "LLM"
      assert parsed.tracker.assignee == "jeremy"
      assert Config.validate!(parsed) == :ok
    end

    test "tracker_api_key and tracker_project_slug fall back to the linear_* keys" do
      map =
        CymphonyConfig.to_schema_map(%{
          "tracker_kind" => "youtrack",
          "tracker_endpoint" => "https://example.youtrack.cloud",
          "linear_api_key" => "perm:legacy",
          "linear_project_slug" => "LEG",
          "tracker_api_key" => "",
          "tracker_project_slug" => nil
        })

      assert map["tracker"]["api_key"] == "perm:legacy"
      assert map["tracker"]["project_slug"] == "LEG"
    end

    test "an unknown tracker_kind falls back to linear and warns" do
      log =
        capture_log(fn ->
          assert CymphonyConfig.to_schema_map(%{"tracker_kind" => "jira"})["tracker"]["kind"] == "linear"
        end)

      assert log =~ "Ignoring unknown tracker_kind"
      assert CymphonyConfig.to_schema_map(%{"tracker_kind" => 7})["tracker"]["kind"] == "linear"
    end

    test "a project can name the state that means queued and the one dispatch moves to" do
      map =
        CymphonyConfig.to_schema_map(%{
          "queued_states" => ["Open", "Submitted"],
          "in_progress_state" => "  In Progress  "
        })

      assert map["tracker"]["queued_states"] == ["Open", "Submitted"]
      assert map["tracker"]["in_progress_state"] == "In Progress"
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.queued_states == ["Open", "Submitted"]
      assert parsed.tracker.in_progress_state == "In Progress"
    end

    test "forge credentials come from config and support $VAR indirection" do
      map =
        CymphonyConfig.to_schema_map(%{
          "forge" => "gitlab",
          "forge_token" => "  glpat-literal  ",
          "forge_host" => "gitlab.example.com"
        })

      assert map["forge_token"] == "glpat-literal"
      assert map["forge_host"] == "gitlab.example.com"
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.forge_token == "glpat-literal"
      assert parsed.forge_host == "gitlab.example.com"

      # Absent keys stay absent, so the runner's inherited environment wins.
      plain = CymphonyConfig.to_schema_map(%{})
      refute Map.has_key?(plain, "forge_token")
      refute Map.has_key?(plain, "forge_host")
      assert {:ok, %Schema{forge_token: nil, forge_host: nil}} = Schema.parse(plain)
    end

    test "a project can name the custom field holding the workflow state" do
      # YouTrack keeps the state in a custom field and projects rename it
      # ("Stage" is common). Reading the wrong name yields state: nil, which
      # never matches an active state and so silently never dispatches.
      map = CymphonyConfig.to_schema_map(%{"state_field" => "  Stage  "})

      assert map["tracker"]["state_field"] == "Stage"
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.state_field == "Stage"

      assert CymphonyConfig.to_schema_map(%{})["tracker"]["state_field"] == "State"
      assert CymphonyConfig.to_schema_map(%{"state_field" => 7})["tracker"]["state_field"] == "State"
    end

    test "a project can name its review and merge states" do
      map =
        CymphonyConfig.to_schema_map(%{
          "review_state" => "  Review and Testing  ",
          "merge_state" => ""
        })

      assert map["tracker"]["review_state"] == "Review and Testing"
      # Empty is meaningful: humans merge, and the prompt drops the land flow.
      assert map["tracker"]["merge_state"] == ""
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.review_state == "Review and Testing"
      assert parsed.tracker.merge_state == ""
    end

    test "review and merge states default to Linear's names" do
      default = CymphonyConfig.to_schema_map(%{})

      assert default["tracker"]["review_state"] == "Human Review"
      assert default["tracker"]["merge_state"] == "Merging"
      assert CymphonyConfig.to_schema_map(%{"review_state" => 7})["tracker"]["review_state"] == "Human Review"
    end

    test "queued state defaults stay Linear-shaped, and an empty in_progress_state disables the transition" do
      default = CymphonyConfig.to_schema_map(%{})

      assert default["tracker"]["queued_states"] == ["Todo"]
      assert default["tracker"]["in_progress_state"] == "In Progress"
      assert CymphonyConfig.to_schema_map(%{"in_progress_state" => 7})["tracker"]["in_progress_state"] == "In Progress"

      # An explicit empty string is meaningful: no such state in the workflow.
      assert CymphonyConfig.to_schema_map(%{"in_progress_state" => ""})["tracker"]["in_progress_state"] == ""
    end

    test "a project can name its own active and terminal states" do
      map =
        CymphonyConfig.to_schema_map(%{
          "active_states" => ["Open", " In Progress ", "In Progress", ""],
          "terminal_states" => ["Fixed", "Verified"]
        })

      assert map["tracker"]["active_states"] == ["Open", "In Progress"]
      assert map["tracker"]["terminal_states"] == ["Fixed", "Verified"]
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.tracker.active_states == ["Open", "In Progress"]
    end

    test "an invalid state list warns and keeps the default" do
      # A mistyped list either polls nothing or treats finished work as
      # running, so it must never reach the front matter silently.
      for bad <- ["Open", ["Open", 1], [], ["   "], %{"a" => "b"}, 7] do
        log =
          capture_log(fn ->
            map = CymphonyConfig.to_schema_map(%{"active_states" => bad})
            assert map["tracker"]["active_states"] == ["Todo", "In Progress", "Merging", "Rework"]
          end)

        assert log =~ "Ignoring invalid active_states"
      end

      default = CymphonyConfig.to_schema_map(%{})
      assert default["tracker"]["active_states"] == ["Todo", "In Progress", "Merging", "Rework"]
      assert default["tracker"]["terminal_states"] == ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
    end

    test "only an explicit false disables claude bare mode" do
      # `--bare` skips keychain reads, so a Claude Code account (as opposed to
      # an API key) cannot authenticate under it.
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{})["claude"], "bare_mode")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"claude_bare_mode" => true})["claude"], "bare_mode")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"claude_bare_mode" => "false"})["claude"], "bare_mode")

      map = CymphonyConfig.to_schema_map(%{"claude_bare_mode" => false})

      assert map["claude"]["bare_mode"] == false
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      refute parsed.claude.bare_mode
      assert Schema.parse(CymphonyConfig.to_schema_map(%{})) |> elem(1) |> then(& &1.claude.bare_mode)
    end

    test "only an explicit false disables the status TUI" do
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{}), "observability")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"status_dashboard_enabled" => true}), "observability")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"status_dashboard_enabled" => "false"}), "observability")

      map = CymphonyConfig.to_schema_map(%{"status_dashboard_enabled" => false})

      assert map["observability"] == %{"dashboard_enabled" => false}
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      refute parsed.observability.dashboard_enabled
    end

    test "emits a server section only when a host or port is configured" do
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"server_host" => "  "}), "server")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"server_port" => "4000"}), "server")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"server_port" => -1}), "server")

      map = CymphonyConfig.to_schema_map(%{"server_host" => "0.0.0.0", "server_port" => 4000})

      assert map["server"] == %{"host" => "0.0.0.0", "port" => 4000}
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.server.host == "0.0.0.0"
      assert parsed.server.port == 4000
    end

    test "explicit values override defaults" do
      map =
        CymphonyConfig.to_schema_map(%{
          "polling_interval_ms" => 1234,
          "max_concurrent_agents" => 7,
          "stall_timeout_ms" => 1_800_000,
          "workspace_root" => "/custom/root"
        })

      assert map["polling"]["interval_ms"] == 1234
      assert map["agent"]["max_concurrent_agents"] == 7
      assert map["agent"]["stall_timeout_ms"] == 1_800_000
      assert map["workspace"]["root"] == "/custom/root"
      assert {:ok, %Schema{} = parsed} = Schema.parse(map)
      assert parsed.agent.stall_timeout_ms == 1_800_000
    end

    test "only a positive integer stall_timeout_ms overrides the default" do
      # A typo must not silently disable the watchdog (<= 0 turns it off) or
      # generate front matter that fails Schema.parse/1.
      for bad <- [0, -1, "600000", 600_000.0, nil, true, %{}] do
        map = CymphonyConfig.to_schema_map(%{"stall_timeout_ms" => bad})
        assert map["agent"]["stall_timeout_ms"] == 300_000
      end

      assert CymphonyConfig.to_schema_map(%{})["agent"]["stall_timeout_ms"] == 300_000
      assert CymphonyConfig.to_schema_map(%{"stall_timeout_ms" => 1})["agent"]["stall_timeout_ms"] == 1
    end

    test "provider list sets providers + head; single provider sets provider; none omits both" do
      list_map = CymphonyConfig.to_schema_map(%{"providers" => ["cv1", "cz2"]})
      assert list_map["claude"]["providers"] == ["cv1", "cz2"]
      assert list_map["claude"]["provider"] == "cv1"

      single_map = CymphonyConfig.to_schema_map(%{"provider" => "ck1"})
      assert single_map["claude"]["provider"] == "ck1"
      refute Map.has_key?(single_map["claude"], "providers")

      none_map = CymphonyConfig.to_schema_map(%{})
      refute Map.has_key?(none_map["claude"], "provider")
      refute Map.has_key?(none_map["claude"], "providers")
    end

    test "empty provider values fall through and omit both keys" do
      empty_list = CymphonyConfig.to_schema_map(%{"providers" => [], "provider" => ""})
      refute Map.has_key?(empty_list["claude"], "provider")
      refute Map.has_key?(empty_list["claude"], "providers")

      non_list = CymphonyConfig.to_schema_map(%{"providers" => "cv1", "provider" => nil})
      refute Map.has_key?(non_list["claude"], "provider")
      refute Map.has_key?(non_list["claude"], "providers")
    end

    test "github_repo_url adds an after_create clone hook; absence omits hooks" do
      with_repo = CymphonyConfig.to_schema_map(%{"github_repo_url" => "git@github.com:me/repo.git"})
      assert with_repo["hooks"]["after_create"] =~ "git clone --depth 1 https://github.com/me/repo.git"

      refute Map.has_key?(CymphonyConfig.to_schema_map(%{}), "hooks")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"github_repo_url" => ""}), "hooks")
      refute Map.has_key?(CymphonyConfig.to_schema_map(%{"github_repo_url" => 1}), "hooks")
    end

    test "a repo URL that is not an scp-style git@ remote is cloned verbatim" do
      https = CymphonyConfig.to_schema_map(%{"github_repo_url" => "  https://github.com/me/repo.git  "})
      assert https["hooks"]["after_create"] =~ "git clone --depth 1 https://github.com/me/repo.git ."
      refute https["hooks"]["after_create"] =~ "  https://"

      ssh_url = CymphonyConfig.to_schema_map(%{"repo_url" => "ssh://git@gitlab.example.com/group/repo.git"})
      assert ssh_url["hooks"]["after_create"] =~ "git clone --depth 1 ssh://git@gitlab.example.com/group/repo.git"
    end

    test "the scp-style rewrite is host-agnostic, so GitLab clones over HTTPS too" do
      # An SSH remote in a container has no key; HTTPS picks up the gh/glab
      # credential helper. Nested groups are a GitLab shape the old
      # github.com-only regex could not express.
      for {remote, https} <- [
            {"git@gitlab.com:me/repo.git", "https://gitlab.com/me/repo.git"},
            {"git@gitlab.example.com:group/subgroup/repo.git", "https://gitlab.example.com/group/subgroup/repo.git"},
            {"git@gitlab.com:me/repo", "https://gitlab.com/me/repo.git"}
          ] do
        assert CymphonyConfig.https_clone_url(remote) == https
        assert CymphonyConfig.to_schema_map(%{"repo_url" => remote})["hooks"]["after_create"] =~ https
      end
    end

    test "rewrite_ssh_remote: false clones the remote exactly as written" do
      # Running as the invoker (rootless podman mounts ~/.ssh and the agent
      # socket) makes an SSH remote workable, and forcing HTTPS would demand a
      # token the operator may not have.
      ssh = %{"repo_url" => "git@gitlab.example.com:group/sub/repo.git", "rewrite_ssh_remote" => false}

      assert CymphonyConfig.to_schema_map(ssh)["hooks"]["after_create"] =~
               "git clone --depth 1 git@gitlab.example.com:group/sub/repo.git ."

      refute CymphonyConfig.to_schema_map(ssh)["hooks"]["after_create"] =~ "https://"

      # Only an explicit false opts out.
      for keep <- [true, "false", nil, 0] do
        map = CymphonyConfig.to_schema_map(Map.put(ssh, "rewrite_ssh_remote", keep))
        assert map["hooks"]["after_create"] =~ "https://gitlab.example.com/group/sub/repo.git"
      end
    end

    test "repo_url wins over the legacy github_repo_url key" do
      assert CymphonyConfig.repo_url(%{"repo_url" => " https://gitlab.com/a/b.git "}) == "https://gitlab.com/a/b.git"
      assert CymphonyConfig.repo_url(%{"github_repo_url" => "https://github.com/a/b.git"}) == "https://github.com/a/b.git"

      both = %{"repo_url" => "https://gitlab.com/a/b.git", "github_repo_url" => "https://github.com/a/b.git"}
      assert CymphonyConfig.repo_url(both) == "https://gitlab.com/a/b.git"

      assert CymphonyConfig.repo_url(%{"repo_url" => "  ", "github_repo_url" => "https://github.com/a/b.git"}) ==
               "https://github.com/a/b.git"

      assert CymphonyConfig.repo_url(%{}) == ""
      assert CymphonyConfig.repo_url(%{"repo_url" => 1}) == ""
    end

    test "project_slug/1 prefers the tracker key and falls back to the Linear one" do
      assert CymphonyConfig.project_slug(%{"tracker_project_slug" => " DEMO "}) == "DEMO"
      assert CymphonyConfig.project_slug(%{"linear_project_slug" => "lin"}) == "lin"
      assert CymphonyConfig.project_slug(%{"tracker_project_slug" => "yt", "linear_project_slug" => "lin"}) == "yt"
      assert CymphonyConfig.project_slug(%{"tracker_project_slug" => "  ", "linear_project_slug" => "lin"}) == "lin"
      assert CymphonyConfig.project_slug(%{}) == ""
      assert CymphonyConfig.project_slug(%{"tracker_project_slug" => 1}) == ""
    end

    test "forge defaults to github and only a known value overrides it" do
      assert CymphonyConfig.to_schema_map(%{})["forge"] == "github"
      assert CymphonyConfig.to_schema_map(%{"forge" => " GitLab "})["forge"] == "gitlab"
      assert {:ok, %Schema{forge: "gitlab"}} = Schema.parse(CymphonyConfig.to_schema_map(%{"forge" => "gitlab"}))

      for bad <- ["bitbucket", "", 7, nil] do
        log = capture_log(fn -> assert CymphonyConfig.to_schema_map(%{"forge" => bad})["forge"] == "github" end)
        if bad != nil, do: assert(log =~ "Ignoring unknown forge")
      end
    end
  end

  describe "to_schema_map/1 agent shape" do
    test "maps agent/model/effort project keys and routes providers to the active kind section" do
      config = %{
        "name" => "P",
        "agent" => "codex",
        "model" => "gpt-5.2-codex",
        "effort" => "high",
        "providers" => ["oa1", "oa2"]
      }

      schema_map = CymphonyConfig.to_schema_map(config)

      assert schema_map["agent"]["kind"] == "codex"
      assert schema_map["agent"]["model"] == "gpt-5.2-codex"
      assert schema_map["agent"]["effort"] == "high"
      assert schema_map["codex"]["providers"] == ["oa1", "oa2"]
      assert schema_map["codex"]["provider"] == "oa1"
      refute Map.has_key?(schema_map["claude"], "providers")
      refute Map.has_key?(schema_map["claude"], "approval_policy")
    end

    test "defaults to claude kind and routes providers to claude section" do
      schema_map = CymphonyConfig.to_schema_map(%{"provider" => "cz"})
      assert schema_map["agent"]["kind"] == "claude"
      assert schema_map["claude"]["provider"] == "cz"
      assert schema_map["claude"]["command"] == "claude"
      assert schema_map["codex"]["command"] == "codex"
      assert schema_map["antigravity"]["command"] == "agy"
      refute Map.has_key?(schema_map["codex"], "provider")
      refute Map.has_key?(schema_map["antigravity"], "provider")
    end

    test "unknown agent kind falls back to claude" do
      schema_map = CymphonyConfig.to_schema_map(%{"agent" => "gemini"})
      assert schema_map["agent"]["kind"] == "claude"
    end

    test "routes providers onto the antigravity section when that kind is active" do
      schema_map =
        CymphonyConfig.to_schema_map(%{
          "agent" => "antigravity",
          "providers" => ["g1", "g2"]
        })

      assert schema_map["agent"]["kind"] == "antigravity"
      assert schema_map["antigravity"]["command"] == "agy"
      assert schema_map["antigravity"]["output_format"] == "stream-json"
      assert schema_map["antigravity"]["skip_permissions"] == true
      assert schema_map["antigravity"]["providers"] == ["g1", "g2"]
      assert schema_map["antigravity"]["provider"] == "g1"
      refute Map.has_key?(schema_map["claude"], "providers")
      refute Map.has_key?(schema_map["claude"], "provider")
      refute Map.has_key?(schema_map["codex"], "providers")
      refute Map.has_key?(schema_map["codex"], "provider")
    end
  end

  describe "to_schema_map/1 extra_args" do
    test "a map keyed by kind emits only the active kind's list" do
      config = %{
        "agent" => "antigravity",
        "extra_args" => %{"antigravity" => ["--new-project"], "codex" => ["--full-auto"]}
      }

      schema_map = CymphonyConfig.to_schema_map(config)

      assert schema_map["antigravity"]["extra_args"] == ["--new-project"]
      refute Map.has_key?(schema_map["codex"], "extra_args")
      refute Map.has_key?(schema_map["claude"], "extra_args")
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.antigravity.extra_args == ["--new-project"]
      assert parsed.codex.extra_args == nil
    end

    test "switching the active kind switches which list is emitted" do
      config = %{
        "agent" => "codex",
        "extra_args" => %{"antigravity" => ["--new-project"], "codex" => ["--full-auto"]}
      }

      schema_map = CymphonyConfig.to_schema_map(config)

      # A project pinned to codex must never inherit the antigravity flags.
      assert schema_map["codex"]["extra_args"] == ["--full-auto"]
      refute Map.has_key?(schema_map["antigravity"], "extra_args")
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.codex.extra_args == ["--full-auto"]
      assert parsed.antigravity.extra_args == nil
    end

    test "a map with no entry for the active kind emits nothing and stays quiet" do
      config = %{"agent" => "claude", "extra_args" => %{"codex" => ["--full-auto"]}}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          schema_map = CymphonyConfig.to_schema_map(config)
          refute Map.has_key?(schema_map["claude"], "extra_args")
        end)

      refute log =~ "Ignoring invalid extra_args"
    end

    test "a bare list is the convenience form and applies to the active kind" do
      claude_map = CymphonyConfig.to_schema_map(%{"extra_args" => ["--add-dir", "/srv/x"]})
      assert claude_map["claude"]["extra_args"] == ["--add-dir", "/srv/x"]
      refute Map.has_key?(claude_map["codex"], "extra_args")

      agy_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "extra_args" => ["--yolo"]})
      assert agy_map["antigravity"]["extra_args"] == ["--yolo"]
      assert {:ok, %Schema{} = parsed} = Schema.parse(agy_map)
      assert parsed.antigravity.extra_args == ["--yolo"]
    end

    test "only lists of strings are honored; anything else is ignored with a warning" do
      # Mirrors stall_timeout_ms: a typo in a hand-edited key must not produce
      # front matter that fails Schema.parse/1 and takes the project down.
      for bad <- ["--new-project", 1, true, ["--ok", 2], [nil], %{"antigravity" => "--x"}] do
        log =
          ExUnit.CaptureLog.capture_log(fn ->
            schema_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "extra_args" => bad})
            refute Map.has_key?(schema_map["antigravity"], "extra_args")
          end)

        assert log =~ "Ignoring invalid extra_args"
      end
    end

    test "a missing key and an empty list emit nothing without warning" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refute Map.has_key?(CymphonyConfig.to_schema_map(%{})["claude"], "extra_args")
          refute Map.has_key?(CymphonyConfig.to_schema_map(%{"extra_args" => []})["claude"], "extra_args")

          refute Map.has_key?(
                   CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "extra_args" => %{"antigravity" => []}})[
                     "antigravity"
                   ],
                   "extra_args"
                 )
        end)

      refute log =~ "Ignoring invalid extra_args"
    end
  end

  describe "to_schema_map/1 new_project" do
    test "the default is omitted so the adapter keeps --new-project on" do
      schema_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity"})
      refute Map.has_key?(schema_map["antigravity"], "new_project")
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.antigravity.new_project == true
    end

    test "only an explicit false reaches the front matter" do
      schema_map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "new_project" => false})
      assert schema_map["antigravity"]["new_project"] == false
      assert {:ok, %Schema{} = parsed} = Schema.parse(schema_map)
      assert parsed.antigravity.new_project == false

      for truthy <- [true, "false", 0, nil] do
        map = CymphonyConfig.to_schema_map(%{"agent" => "antigravity", "new_project" => truthy})
        refute Map.has_key?(map["antigravity"], "new_project")
      end
    end
  end

  describe "generated WORKFLOW.md front matter round-trips safely" do
    test "values with YAML metacharacters survive generation and parsing" do
      # The old hand-built-YAML path would corrupt these (`:`, `#`, quotes);
      # JSON front matter round-trips them losslessly.
      config = %{
        "linear_api_key" => "lin_api_3:foo#bar \"quoted\"",
        "linear_project_slug" => "team/sub: project # hash",
        "workspace_root" => "/tmp/weird: path #1",
        "model" => "model: 'single' \"double\" #tag"
      }

      {:ok, path} = WorkflowGenerator.write_temp(config)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{config: parsed_map}} = Workflow.load(path)
      assert parsed_map["tracker"]["api_key"] == "lin_api_3:foo#bar \"quoted\""
      assert parsed_map["tracker"]["project_slug"] == "team/sub: project # hash"
      assert parsed_map["workspace"]["root"] == "/tmp/weird: path #1"
      assert parsed_map["agent"]["model"] == "model: 'single' \"double\" #tag"

      assert {:ok, %Schema{}} = Schema.parse(parsed_map)
    end

    test "a project's stall_timeout_ms reaches the parsed agent settings" do
      {:ok, path} =
        WorkflowGenerator.write_temp(%{
          "name" => "Slow",
          "linear_project_slug" => "slow",
          "stall_timeout_ms" => 1_800_000
        })

      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{config: parsed_map}} = Workflow.load(path)
      assert {:ok, %Schema{} = settings} = Schema.parse(parsed_map)
      assert settings.agent.stall_timeout_ms == 1_800_000
    end
  end

  describe "to_schema_map/1 allowed_tools" do
    # An autonomous run has nobody to approve a permission prompt, so a tool
    # the prompt requires but the grant omits comes back `permission_denied`
    # and the agent works around it with shell — costing turns, and every turn
    # re-bills the whole prompt preamble.
    test "grants the tracker's MCP server alongside the file and shell tools" do
      youtrack = CymphonyConfig.to_schema_map(%{"tracker_kind" => "youtrack"})
      linear = CymphonyConfig.to_schema_map(%{"tracker_kind" => "linear"})

      assert youtrack["claude"]["allowed_tools"] ==
               "Bash,Read,Edit,Write,Glob,Grep,mcp__youtrack"

      assert linear["claude"]["allowed_tools"] == "Bash,Read,Edit,Write,Glob,Grep,mcp__linear"
    end

    test "grants Write, which the old Bash,Read,Edit default withheld" do
      map = CymphonyConfig.to_schema_map(%{})

      assert map["claude"]["allowed_tools"] =~ "Write"
      assert map["claude"]["permission_mode"] == "acceptEdits"
    end

    test "an unrecognized tracker_kind still resolves to linear's grant" do
      # tracker_kind/1 warns and falls back to "linear", so the grant follows
      # the tracker that will actually be polled.
      map = CymphonyConfig.to_schema_map(%{"tracker_kind" => "memory"})

      assert map["claude"]["allowed_tools"] == "Bash,Read,Edit,Write,Glob,Grep,mcp__linear"
    end

    test "Defaults.claude_allowed_tools/1 adds no MCP grant for a tracker without one" do
      assert Defaults.claude_allowed_tools(nil) == Defaults.claude_allowed_tools()
      assert Defaults.claude_allowed_tools("memory") == Defaults.claude_allowed_tools()
      refute Enum.any?(Defaults.claude_allowed_tools("memory"), &String.starts_with?(&1, "mcp__"))
    end

    test "an operator override wins, as a list or a comma-separated string" do
      list = CymphonyConfig.to_schema_map(%{"allowed_tools" => ["Bash", "mcp__jira"]})
      string = CymphonyConfig.to_schema_map(%{"allowed_tools" => "Bash,mcp__jira"})

      assert list["claude"]["allowed_tools"] == "Bash,mcp__jira"
      assert string["claude"]["allowed_tools"] == "Bash,mcp__jira"
    end

    test "a malformed override falls back to the default rather than emitting junk" do
      for bad <- [42, %{"a" => 1}, ["Bash", 7], ""] do
        map = CymphonyConfig.to_schema_map(%{"allowed_tools" => bad, "tracker_kind" => "youtrack"})

        assert map["claude"]["allowed_tools"] ==
                 "Bash,Read,Edit,Write,Glob,Grep,mcp__youtrack"
      end
    end

    test "permission_mode is overridable and survives a round trip through Schema" do
      map = CymphonyConfig.to_schema_map(%{"permission_mode" => "bypassPermissions"})

      assert map["claude"]["permission_mode"] == "bypassPermissions"
      assert {:ok, %Schema{} = settings} = Schema.parse(map)
      assert settings.claude.permission_mode == "bypassPermissions"
      assert settings.claude.allowed_tools =~ "Write"
    end

    test "a malformed permission_mode falls back instead of failing Schema.parse/1" do
      map = CymphonyConfig.to_schema_map(%{"permission_mode" => 7})

      assert map["claude"]["permission_mode"] == "acceptEdits"
      assert {:ok, %Schema{}} = Schema.parse(map)
    end
  end
end
