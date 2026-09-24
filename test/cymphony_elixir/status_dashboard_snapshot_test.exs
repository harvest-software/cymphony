defmodule CymphonyElixir.StatusDashboardSnapshotTest do
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.TestSupport.Snapshot

  @terminal_columns 115

  test "snapshot fixture: idle dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: idle dashboard with observability url" do
    previous_port_override = Application.get_env(:cymphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:cymphony_elixir, :server_port_override)
      else
        Application.put_env(:cymphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    Application.put_env(:cymphony_elixir, :server_port_override, 4000)

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    Snapshot.assert_dashboard_snapshot!("idle_with_dashboard_url", render_snapshot(snapshot_data, 0.0))
  end

  test "snapshot fixture: super busy dashboard" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-101",
             total_tokens: 120_450,
             runtime_seconds: 785,
             turn_count: 11,
             last_agent_event: "turn_completed",
             last_agent_message: turn_completed_message("completed")
           }),
           running_entry(%{
             identifier: "MT-102",
             session_id: "thread-abcdef1234567890",
             agent_os_pid: "5252",
             total_tokens: 89_200,
             runtime_seconds: 412,
             turn_count: 4,
             last_agent_event: "claude/event/task_started",
             last_agent_message: exec_command_message("mix test --cover")
           })
         ],
         retrying: [],
         token_totals: %{
           input_tokens: 250_000,
           output_tokens: 18_500,
           total_tokens: 268_500,
           seconds_running: 4_321
         },
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 12_345, limit: 20_000, reset_in_seconds: 30},
           secondary: %{remaining: 45, limit: 60, reset_in_seconds: 12},
           credits: %{has_credits: true, balance: 9_876.5}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("super_busy", render_snapshot(snapshot_data, 1_842.7))
  end

  test "snapshot fixture: backoff queue pressure" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-638",
             state: "retrying",
             total_tokens: 14_200,
             runtime_seconds: 1_225,
             turn_count: 7,
             last_agent_event: :notification,
             last_agent_message: agent_message_delta("waiting on rate-limit backoff window")
           })
         ],
         retrying: [
           retry_entry(%{
             identifier: "MT-450",
             attempt: 4,
             due_in_ms: 1_250,
             error: "rate limit exhausted"
           }),
           retry_entry(%{
             identifier: "MT-451",
             attempt: 2,
             due_in_ms: 3_900,
             error: "retrying after API timeout with jitter"
           }),
           retry_entry(%{
             identifier: "MT-452",
             attempt: 6,
             due_in_ms: 8_100,
             error: "worker crashed\nrestarting cleanly"
           }),
           retry_entry(%{
             identifier: "MT-453",
             attempt: 1,
             due_in_ms: 11_000,
             error: "fourth queued retry should also render after removing the top-three limit"
           })
         ],
         token_totals: %{input_tokens: 18_000, output_tokens: 2_200, total_tokens: 20_200, seconds_running: 2_700},
         rate_limits: %{
           limit_id: "gpt-5",
           primary: %{remaining: 0, limit: 20_000, reset_in_seconds: 95},
           secondary: %{remaining: 0, limit: 60, reset_in_seconds: 45},
           credits: %{has_credits: false}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("backoff_queue", render_snapshot(snapshot_data, 15.4))
  end

  test "backoff queue row escapes escaped newline sequences" do
    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [
           retry_entry(%{
             identifier: "MT-980",
             attempt: 1,
             due_in_ms: 1_500,
             error: "error with \\nnewline"
           })
         ],
         token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)
    backoff_lines = rendered |> String.split("\n") |> Enum.filter(&String.contains?(&1, "MT-980"))

    assert length(backoff_lines) == 1

    [backoff_line] = backoff_lines

    assert backoff_line =~ "error=error with newline"
    refute backoff_line =~ "\\n"
  end

  test "snapshot fixture: unlimited credits variant" do
    snapshot_data =
      {:ok,
       %{
         running: [
           running_entry(%{
             identifier: "MT-777",
             state: "running",
             total_tokens: 3_200,
             runtime_seconds: 75,
             turn_count: 7,
             last_agent_event: "claude/event/token_count",
             last_agent_message: token_usage_message(90, 12, 102)
           })
         ],
         retrying: [],
         token_totals: %{input_tokens: 90, output_tokens: 12, total_tokens: 102, seconds_running: 75},
         rate_limits: %{
           limit_id: "priority-tier",
           primary: %{remaining: 100, limit: 100, reset_in_seconds: 1},
           secondary: %{remaining: 500, limit: 500, reset_in_seconds: 1},
           credits: %{unlimited: true}
         }
       }}

    Snapshot.assert_dashboard_snapshot!("credits_unlimited", render_snapshot(snapshot_data, 42.0))
  end

  test "snapshot fixtures ignore leftover HTTP bound port and registered projects" do
    previous_port_override = Application.get_env(:cymphony_elixir, :server_port_override)
    Application.delete_env(:cymphony_elixir, :server_port_override)

    on_exit(fn ->
      if is_nil(previous_port_override) do
        Application.delete_env(:cymphony_elixir, :server_port_override)
      else
        Application.put_env(:cymphony_elixir, :server_port_override, previous_port_override)
      end
    end)

    case HttpServer.start_link(port: 0) do
      {:ok, pid} ->
        on_exit(fn ->
          if Process.alive?(pid), do: Process.exit(pid, :shutdown)
        end)

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, _reason} ->
        :ok
    end

    snapshot_data =
      {:ok,
       %{
         running: [],
         retrying: [],
         token_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}

    rendered = render_snapshot(snapshot_data, 0.0)
    refute rendered =~ "Dashboard:"
    refute rendered =~ "Projects:"
    assert rendered =~ "https://linear.app/project/project/issues"

    Snapshot.assert_dashboard_snapshot!("idle", rendered)
  end

  defp render_snapshot(snapshot_data, tps) do
    StatusDashboard.format_snapshot_content_for_test(snapshot_data, tps, @terminal_columns)
  end

  defp running_entry(overrides) do
    Map.merge(
      %{
        identifier: "MT-000",
        state: "running",
        session_id: "thread-1234567890",
        agent_os_pid: "4242",
        total_tokens: 0,
        runtime_seconds: 0,
        turn_count: 1,
        last_agent_event: :notification,
        last_agent_message: turn_started_message()
      },
      overrides
    )
  end

  defp retry_entry(overrides) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "MT-000",
        attempt: 1,
        due_in_ms: 1_000,
        error: "retry scheduled"
      },
      overrides
    )
  end

  defp turn_started_message do
    %{
      event: :notification,
      message: %{
        "method" => "turn/started",
        "params" => %{"turn" => %{"id" => "turn-1"}}
      }
    }
  end

  defp turn_completed_message(status) do
    %{
      event: :notification,
      message: %{
        "method" => "turn/completed",
        "params" => %{"turn" => %{"status" => status}}
      }
    }
  end

  defp exec_command_message(command) do
    %{
      event: :notification,
      message: %{
        "method" => "claude/event/exec_command_begin",
        "params" => %{"msg" => %{"command" => command}}
      }
    }
  end

  defp agent_message_delta(delta) do
    %{
      event: :notification,
      message: %{
        "method" => "claude/event/agent_message_delta",
        "params" => %{"msg" => %{"payload" => %{"delta" => delta}}}
      }
    }
  end

  defp token_usage_message(input_tokens, output_tokens, total_tokens) do
    %{
      event: :notification,
      message: %{
        "method" => "thread/tokenUsage/updated",
        "params" => %{
          "tokenUsage" => %{
            "total" => %{
              "inputTokens" => input_tokens,
              "outputTokens" => output_tokens,
              "totalTokens" => total_tokens
            }
          }
        }
      }
    }
  end

  describe "codex JSONL event humanization" do
    test "thread.started / turn lifecycle / agent_message / usage" do
      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"type" => "thread.started", "thread_id" => "t-12345678"}
             }) =~ "thread started"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"type" => "turn.started"}
             }) == "turn started"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{
                 "type" => "item.completed",
                 "item" => %{"id" => "item_0", "type" => "agent_message", "text" => "did the thing"}
               }
             }) =~ "did the thing"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{
                 "type" => "item.started",
                 "item" => %{"id" => "item_1", "type" => "command_execution", "command" => "mix test"}
               }
             }) =~ "mix test"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{
                 "type" => "turn.completed",
                 "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
               }
             }) =~ "turn completed"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"type" => "turn.failed", "error" => %{"message" => "boom"}}
             }) =~ "boom"
    end
  end

  describe "claude stream-json event humanization" do
    defp claude_event(payload), do: StatusDashboard.humanize_agent_message(%{event: :stream_event, message: payload})

    defp assistant(blocks), do: %{"type" => "assistant", "session_id" => "s-1", "message" => %{"content" => blocks}}

    test "a Skill call names the skill instead of rendering as a bare type" do
      humanized =
        claude_event(
          assistant([
            %{"type" => "tool_use", "name" => "Skill", "input" => %{"skill" => "harvest-frontend-stack:harvest-frontend-stack"}}
          ])
        )

      assert humanized == "Skill: harvest-frontend-stack:harvest-frontend-stack"
    end

    test "tool calls show their most telling argument" do
      assert claude_event(
               assistant([
                 %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "mix test", "description" => "Run tests"}}
               ])
             ) == "Bash: Run tests"

      assert claude_event(assistant([%{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "mix test"}}])) ==
               "Bash: mix test"

      assert claude_event(assistant([%{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "/w/lib/a.ex"}}])) ==
               "Edit: /w/lib/a.ex"

      assert claude_event(assistant([%{"type" => "tool_use", "name" => "Grep", "input" => %{"pattern" => "defp foo"}}])) ==
               "Grep: defp foo"

      assert claude_event(assistant([%{"type" => "tool_use", "name" => "mcp__youtrack__get_issue", "input" => %{}}])) ==
               "mcp__youtrack__get_issue"
    end

    test "assistant text and thinking" do
      assert claude_event(assistant([%{"type" => "text", "text" => "Vendor isn't\ninstalled."}])) == "Vendor isn't installed."
      assert claude_event(assistant([%{"type" => "thinking", "thinking" => "hmm"}])) == "thinking"
      assert claude_event(assistant([])) == "assistant"
    end

    test "tool results, errors surfaced with their text" do
      ok = %{"type" => "user", "session_id" => "s-1", "message" => %{"content" => [%{"type" => "tool_result", "content" => "fine"}]}}
      assert claude_event(ok) == "tool result"

      error = %{
        "type" => "user",
        "session_id" => "s-1",
        "message" => %{
          "content" => [
            %{"type" => "tool_result", "is_error" => true, "content" => [%{"type" => "text", "text" => "command not found: docker"}]}
          ]
        }
      }

      assert claude_event(error) == "tool error: command not found: docker"

      prompt = %{"type" => "user", "session_id" => "s-1", "message" => %{"content" => "hello"}}
      assert claude_event(prompt) == "user message"
    end

    test "init reports model and skill count; result reports outcome" do
      init = %{
        "type" => "system",
        "subtype" => "init",
        "session_id" => "s-1",
        "model" => "claude-opus-5-5",
        "skills" => ["a", "b", "harvest-frontend-stack:harvest-frontend-stack"]
      }

      assert claude_event(init) == "session init (claude-opus-5-5, 3 skills)"
      assert claude_event(%{"type" => "system", "subtype" => "init", "session_id" => "s-1"}) == "session init"
      assert claude_event(%{"type" => "system", "subtype" => "compact_boundary", "session_id" => "s-1"}) == "system: compact_boundary"

      assert claude_event(%{"type" => "result", "subtype" => "success", "num_turns" => 12, "session_id" => "s-1"}) ==
               "result: success (12 turns)"

      assert claude_event(%{"type" => "result", "subtype" => "error_max_turns", "is_error" => true, "session_id" => "s-1"}) ==
               "result: error_max_turns"
    end
  end

  describe "antigravity NDJSON event humanization" do
    test "init includes a shortened conversation id" do
      humanized =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          message: %{
            "event" => "init",
            "conversation_id" => "conv-abcdefghijklmnop",
            "init" => %{"cwd" => "/tmp/ws", "tools" => [], "permission_mode" => "default"}
          }
        })

      assert humanized == "antigravity init (conv-abcdefg)"
    end

    test "init falls back to init.conversation_id and omits empty ids" do
      from_init =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          payload: %{"event" => "init", "init" => %{"conversation_id" => "nested-1"}}
        })

      assert from_init == "antigravity init (nested-1)"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"event" => "init"}
             }) == "antigravity init"
    end

    test "step_update uses step_type and state plus truncated text_delta" do
      humanized =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          message: %{
            "event" => "step_update",
            "step_update" => %{
              "step_type" => "think",
              "state" => "ACTIVE",
              "text_delta" => "planning the change to the orchestrator"
            }
          }
        })

      assert humanized == "think ACTIVE planning the change to the orchestrator"

      long_delta = String.duplicate("x", 90)

      truncated =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          message: %{
            "event" => "step_update",
            "step_update" => %{"step_type" => "think", "state" => "DONE", "text_delta" => long_delta}
          }
        })

      assert truncated == "think DONE " <> String.duplicate("x", 80) <> "..."
    end

    test "step_update tool steps prefer tool <tool_name>" do
      humanized =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          message: %{
            "event" => "step_update",
            "step_update" => %{
              "step_type" => "tool",
              "state" => "ACTIVE",
              "tool_name" => "read_file",
              "text_delta" => "opening WORKFLOW.md"
            }
          }
        })

      assert humanized == "tool read_file opening WORKFLOW.md"
    end

    test "step_update accepts flattened fields and missing type or state" do
      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"event" => "step_update", "step_type" => "think", "state" => "DONE"}
             }) == "think DONE"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"event" => "step_update", "step_update" => %{"step_type" => "think"}}
             }) == "think"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"event" => "step_update", "step_update" => %{"state" => "ACTIVE"}}
             }) == "ACTIVE"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"event" => "step_update"}
             }) == "step_update"
    end

    test "result includes status and usage summary" do
      humanized =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          message: %{
            "event" => "result",
            "result" => %{
              "status" => "SUCCESS",
              "conversation_id" => "conv-1",
              "response" => "done",
              "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
            }
          }
        })

      assert humanized == "result SUCCESS (in 10, out 5, total 15)"

      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"event" => "result", "result" => %{"status" => "ERROR", "error" => "boom"}}
             }) == "result ERROR"
    end

    test "unknown antigravity event names fall back to the event name" do
      assert StatusDashboard.humanize_agent_message(%{
               event: :stream_event,
               message: %{"event" => "waiting"}
             }) == "waiting"
    end

    test "type=turn.completed still uses the Codex path when event is absent" do
      humanized =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          message: %{
            "type" => "turn.completed",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
          }
        })

      assert humanized == "turn completed (tokens in 10 / out 5)"
      refute humanized =~ "result"
      refute humanized =~ "antigravity"
    end

    test "string event wins over type so Antigravity NDJSON is not mistaken for Codex" do
      humanized =
        StatusDashboard.humanize_agent_message(%{
          event: :stream_event,
          message: %{"event" => "result", "type" => "turn.completed", "status" => "SUCCESS"}
        })

      assert humanized == "result SUCCESS"
    end

    test "harness_stdout and harness_heartbeat leak as harness, not a TUI log line" do
      assert StatusDashboard.humanize_agent_message(%{event: :harness_stdout, raw: "agy -p hello"}) == "harness"

      assert StatusDashboard.humanize_agent_message(%{
               event: :harness_heartbeat,
               timestamp: DateTime.utc_now()
             }) == "harness"

      assert StatusDashboard.humanize_agent_message(%{
               event: :harness_stdout,
               message: %{"raw" => "should not be inspected"}
             }) == "harness"
    end

    test "running row event column humanizes antigravity init" do
      row =
        StatusDashboard.format_running_summary_for_test(
          running_entry(%{
            last_agent_event: :stream_event,
            last_agent_message: %{
              event: :stream_event,
              message: %{"event" => "init", "conversation_id" => "conv-abcdefghijklmnop"}
            }
          }),
          @terminal_columns
        )

      assert row =~ "antigravity init (conv-abcdefg)"
    end
  end
end
