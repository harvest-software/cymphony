defmodule CymphonyElixir.AgentOutputRetentionIntegrationTest do
  use CymphonyElixir.TestSupport

  test "runner rejects an unbounded unterminated output line" do
    test_root = Path.join(System.tmp_dir!(), "cymphony-output-line-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-4901")
    cli = Path.join(test_root, "fake-claude")

    try do
      File.mkdir_p!(workspace)
      File.write!(cli, "#!/bin/sh\nawk 'BEGIN{for(i=0;i<2000000;i++) printf \"x\"}'\n")
      File.chmod!(cli, 0o755)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, claude_command: cli)

      issue = %Issue{
        id: "issue-output-line-boundary",
        identifier: "MT-4901",
        title: "Bound line",
        description: "Do not retain a giant unbroken CLI line",
        state: "In Progress",
        url: "https://example.org/issues/MT-4901"
      }

      assert {:error, :agent_output_line_too_large} = Runner.run(workspace, "run", issue)
    after
      File.rm_rf(test_root)
    end
  end

  # An image read by the agent comes back as one base64 JSON line of several
  # hundred KB. Failing the run on it left an agent that read a screenshot
  # unable to finish or resume; the line is dropped and the run carries on.
  test "runner drops a terminated oversized line and still returns the result" do
    test_root = Path.join(System.tmp_dir!(), "cymphony-output-drop-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-4903")
    cli = Path.join(test_root, "fake-claude")

    try do
      File.mkdir_p!(workspace)

      File.write!(cli, """
      #!/bin/sh
      echo '{"type":"system","subtype":"init","session_id":"sess-image"}'
      awk 'BEGIN{printf "{\\"type\\":\\"user\\",\\"image\\":\\""; for(i=0;i<600000;i++) printf "A"; print "\\"}"}'
      echo '{"type":"assistant","message":"after the image"}'
      echo '{"result":"done after image","session_id":"sess-image"}'
      """)

      File.chmod!(cli, 0o755)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root, claude_command: cli)

      issue = %Issue{
        id: "issue-output-line-drop",
        identifier: "MT-4903",
        title: "Drop a giant line",
        description: "An image tool result must not end the run",
        state: "In Progress",
        url: "https://example.org/issues/MT-4903"
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{session_id: "sess-image", result: result}} = Runner.run(workspace, "run", issue)
          assert result.result == "done after image"
        end)

      assert log =~ "Dropped an agent output line of"
    after
      File.rm_rf(test_root)
    end
  end

  test "runner preserves parsed Codex result but emits only a bounded retained transcript" do
    test_root = Path.join(System.tmp_dir!(), "cymphony-output-window-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-4902")
    cli = Path.join(test_root, "fake-codex")

    try do
      File.mkdir_p!(workspace)

      File.write!(cli, """
      #!/bin/sh
      echo '{"type":"thread.started","thread_id":"thread-long-stream"}'
      awk 'BEGIN{for(i=0;i<150;i++) print "{\\"type\\":\\"item.updated\\",\\"n\\":" i "}"}'
      echo '{"type":"item.completed","item":{"type":"agent_message","text":"final result"}}'
      awk 'BEGIN{for(i=0;i<150;i++) print "{\\"type\\":\\"item.updated\\",\\"n\\":" i "}"}'
      echo '{"type":"turn.completed","usage":{"input_tokens":9,"output_tokens":4}}'
      """)

      File.chmod!(cli, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_kind: "codex",
        codex_command: cli
      )

      issue = %Issue{
        id: "issue-output-window",
        identifier: "MT-4902",
        title: "Bound transcript",
        description: "Retain semantic milestones without the whole transcript",
        state: "In Progress",
        url: "https://example.org/issues/MT-4902"
      }

      {:ok, collector} = Agent.start_link(fn -> 0 end)

      on_message = fn message ->
        if message.event == :stream_event, do: Agent.update(collector, &(&1 + 1))
      end

      assert {:ok, %{session_id: "thread-long-stream", result: result}} =
               Runner.run(workspace, "run", issue, on_message: on_message)

      assert result.result == "final result"
      assert result.usage["total_tokens"] == 13
      assert Agent.get(collector, & &1) < 200
    after
      File.rm_rf(test_root)
    end
  end
end
