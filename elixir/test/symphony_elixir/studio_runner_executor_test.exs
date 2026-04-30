defmodule SymphonyElixir.StudioRunnerExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StudioRunner.{Executor, WorkItem}

  test "executor prepares a managed workspace from source repo without mutating original" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-executor-#{System.unique_integer([:positive])}")

    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    File.mkdir_p!(Path.join(source_repo, "openspec/changes/add-runner-work/specs/runner"))

    File.write!(
      Path.join(source_repo, "openspec/changes/add-runner-work/proposal.md"),
      "# Proposal\n"
    )

    File.write!(
      Path.join(source_repo, "openspec/changes/add-runner-work/tasks.md"),
      "## Tasks\n- [ ] Do it\n"
    )

    File.write!(
      Path.join(source_repo, "openspec/changes/add-runner-work/design.md"),
      "# Design\n"
    )

    File.write!(
      Path.join(source_repo, "openspec/changes/add-runner-work/specs/runner/spec.md"),
      "## ADDED Requirements\n"
    )

    File.write!(Path.join(source_repo, "ORIGINAL"), "untouched")
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    parent = self()

    work_item = %WorkItem{
      event_id: "evt-execute-test",
      run_id: "run_execute_test",
      event_type: "build.requested",
      repo_path: source_repo,
      repo_name: "source",
      change: "add-runner-work",
      artifact_paths: ["openspec/changes/add-runner-work/proposal.md"],
      validation: %{"state" => "passed"},
      requested_by: "test"
    }

    assert {:ok, context, result} =
             Executor.execute(work_item,
               codex_runner: fn workspace, prompt, runner_work_item, _opts ->
                 send(parent, {:codex_invoked, workspace, prompt, runner_work_item})
                 File.write!(Path.join(workspace, "WORKSPACE_ONLY"), "changed")
                 {:ok, %{session_id: "session-test"}}
               end
             )

    assert context.change == "add-runner-work"
    assert context.workspace_path != source_repo

    assert {:ok, canonical_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(workspace_root)

    assert String.starts_with?(context.workspace_path, canonical_workspace_root <> "/")
    assert result.session_id == "session-test"

    assert_receive {:codex_invoked, workspace, prompt, ^work_item}, 500
    assert workspace == context.workspace_path
    assert prompt =~ "OpenSpec change"
    assert prompt =~ "add-runner-work"
    assert prompt =~ "studio-runner/add-runner-work/evtexecute"
    assert File.exists?(Path.join(workspace, "WORKSPACE_ONLY"))
    refute File.exists?(Path.join(source_repo, "WORKSPACE_ONLY"))
    assert File.read!(Path.join(source_repo, "ORIGINAL")) == "untouched"
    File.rm_rf!(test_root)

    :ok
  end

  test "orchestrator status captures blocked Studio Runner execution metadata" do
    work_item = %WorkItem{
      event_id: "evt-orchestrator-result",
      run_id: nil,
      event_type: "build.requested",
      repo_path: "/tmp/source",
      repo_name: "source",
      change: "add-runner-work"
    }

    orchestrator_name = Module.concat(__MODULE__, :StudioRunnerResultOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})

    executor = fn _work_item ->
      {:ok,
       %{
         status: "blocked",
         workspacePath: "/tmp/workspace",
         sessionId: "session-123",
         branchName: "studio-runner/add-runner-work/evt"
       }}
    end

    assert {:ok, response} =
             Orchestrator.dispatch_external_work(orchestrator_name, work_item, executor: executor)

    assert response.status == "accepted"

    snapshot =
      eventually_snapshot(orchestrator_name, fn snapshot ->
        match?(%{events: [%{status: "blocked"}]}, snapshot.studio_runner)
      end)

    assert %{events: [event]} = snapshot.studio_runner
    assert event.status == "blocked"
    assert event.run_id == response.runId
    assert event.event_id == "evt-orchestrator-result"

    event_payload = snapshot.studio_runner.events |> hd()
    assert event_payload.status == "blocked"
    assert event_payload.workspacePath == "/tmp/workspace"
    assert event_payload.sessionId == "session-123"
    assert event_payload.branchName == "studio-runner/add-runner-work/evt"
  end

  test "executor fails before Codex when required OpenSpec artifacts are missing" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-missing-#{System.unique_integer([:positive])}")

    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    File.mkdir_p!(Path.join(source_repo, "openspec/changes/missing-tasks"))

    File.write!(
      Path.join(source_repo, "openspec/changes/missing-tasks/proposal.md"),
      "# Proposal\n"
    )

    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    work_item = %WorkItem{
      event_id: "evt-missing-artifact",
      run_id: "run_missing_artifact",
      event_type: "build.requested",
      repo_path: source_repo,
      repo_name: "source",
      change: "missing-tasks"
    }

    assert {:error, {:missing_required_artifacts, ["tasks.md"]}} =
             Executor.execute(work_item,
               codex_runner: fn _workspace, _prompt, _work_item, _opts ->
                 flunk("Codex should not start when required artifacts are missing")
               end
             )

    File.rm_rf!(test_root)

    :ok
  end

  defp eventually_snapshot(orchestrator_name, predicate, attempts \\ 20)

  defp eventually_snapshot(orchestrator_name, predicate, attempts) when attempts > 0 do
    snapshot = Orchestrator.snapshot(orchestrator_name, 1_000)

    if predicate.(snapshot) do
      snapshot
    else
      Process.sleep(10)
      eventually_snapshot(orchestrator_name, predicate, attempts - 1)
    end
  end

  defp eventually_snapshot(orchestrator_name, _predicate, 0), do: Orchestrator.snapshot(orchestrator_name, 1_000)
end
