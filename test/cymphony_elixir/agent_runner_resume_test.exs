defmodule CymphonyElixir.AgentRunnerResumeTest do
  use CymphonyElixir.TestSupport

  setup do
    test_root = Path.join(System.tmp_dir!(), "cymphony-agent-runner-resume-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    trace = Path.join(test_root, "claude.trace")
    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    issue = %Issue{
      id: "issue-resume",
      identifier: "MT-880",
      title: "Resume me",
      description: "Pick up where it stopped",
      state: "In Progress",
      url: "https://example.org/issues/MT-880",
      labels: []
    }

    %{test_root: test_root, workspace_root: workspace_root, trace: trace, issue: issue}
  end

  # Every invocation appends `RUN:<argv>` to the trace; `body` decides output.
  defp fake_cli!(ctx, body) do
    binary = Path.join(ctx.test_root, "fake-claude")

    File.write!(binary, """
    #!/bin/sh
    printf 'RUN:%s\\n' "$*" >> "#{ctx.trace}"
    #{body}
    """)

    File.chmod!(binary, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: ctx.workspace_root, claude_command: binary)
  end

  defp runs(ctx) do
    ctx.trace |> File.read!() |> String.split("RUN:", trim: true)
  end

  defp done_fetcher(issue), do: fn _ids -> {:ok, [%{issue | state: "Done"}]} end

  test "a resumed run passes --resume and the interruption prompt instead of the task prompt", ctx do
    fake_cli!(ctx, ~s(echo '{"result":"ok","session_id":"sess-old"}'))

    assert :ok =
             AgentRunner.run(ctx.issue, nil,
               issue_state_fetcher: done_fetcher(ctx.issue),
               resume_session_id: "sess-old",
               resume_reason: "the agent hit its usage limit"
             )

    assert [run] = runs(ctx)
    assert run =~ "--resume sess-old"
    assert run =~ "Resuming after an interruption"
    assert run =~ "the agent hit its usage limit"
    refute run =~ "You are an agent for this repository."
  end

  test "a resume the CLI refuses before printing a session falls back to a fresh session", ctx do
    fake_cli!(ctx, """
    case "$*" in
      *--resume*) echo 'No conversation found with session ID: sess-gone' >&2; exit 1 ;;
    esac
    echo '{"result":"ok","session_id":"sess-new"}'
    """)

    log =
      capture_log(fn ->
        assert :ok = AgentRunner.run(ctx.issue, nil, issue_state_fetcher: done_fetcher(ctx.issue), resume_session_id: "sess-gone")
      end)

    assert log =~ "Could not resume session sess-gone"
    assert [first, second] = runs(ctx)
    assert first =~ "--resume sess-gone"
    refute second =~ "--resume"
    assert second =~ "You are an agent for this repository."
  end

  test "a resumed run that got going and then failed is a real failure, not a fallback", ctx do
    fake_cli!(ctx, """
    echo '{"type":"system","subtype":"init","session_id":"sess-old"}'
    exit 1
    """)

    capture_log(fn ->
      assert_raise RuntimeError, ~r/agent_exit/, fn ->
        AgentRunner.run(ctx.issue, nil, issue_state_fetcher: done_fetcher(ctx.issue), resume_session_id: "sess-old")
      end
    end)

    assert [_only] = runs(ctx)
  end

  test "a usage limit exits with {:shutdown, {:usage_limit, …}}, even on a resumed run", ctx do
    fake_cli!(ctx, """
    echo '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1791333000,"rateLimitType":"five_hour"}}'
    exit 1
    """)

    log =
      capture_log(fn ->
        assert {:shutdown, {:usage_limit, limit}} =
                 catch_exit(AgentRunner.run(ctx.issue, nil, resume_session_id: "sess-old"))

        assert limit.resets_at == 1_791_333_000
        refute Map.has_key?(limit, :tail)
      end)

    assert log =~ "hit its usage limit"
    # No fallback: the limit applies to a fresh session just the same.
    assert [_only] = runs(ctx)
  end

  test "a blank resume id is a fresh run", ctx do
    fake_cli!(ctx, ~s(echo '{"result":"ok","session_id":"s"}'))

    assert :ok = AgentRunner.run(ctx.issue, nil, issue_state_fetcher: done_fetcher(ctx.issue), resume_session_id: "")
    assert [run] = runs(ctx)
    refute run =~ "--resume"
  end
end
