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
               end,
               publish_inspector: fn _workspace, _context ->
                 {:ok,
                  %{
                    status: "completed",
                    branch_name: "studio-runner/add-runner-work/evtexecute",
                    commit_sha: "0123456789abcdef0123456789abcdef01234567",
                    pr_url: "https://github.com/example/source/pull/123"
                  }}
               end
             )

    assert context.change == "add-runner-work"
    assert context.workspace_path != source_repo

    assert {:ok, canonical_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(workspace_root)

    assert String.starts_with?(context.workspace_path, canonical_workspace_root <> "/")
    assert result.session_id == "session-test"
    assert result.status == "completed"
    assert result.pr_url == "https://github.com/example/source/pull/123"

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

  test "publication inspection reports completed only when a pull request exists" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-publication-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "--quiet"], cd: workspace)
    System.cmd("git", ["checkout", "-B", "studio-runner/change/event", "--quiet"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    File.write!(Path.join(workspace, "CHANGE"), "done")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-m", "change"], cd: workspace)

    gh_bin = Path.join(test_root, "bin/gh")
    File.mkdir_p!(Path.dirname(gh_bin))

    File.write!(gh_bin, """
    #!/bin/sh
    echo https://github.com/example/source/pull/42
    """)

    File.chmod!(gh_bin, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", Path.dirname(gh_bin) <> ":" <> (old_path || ""))

    try do
      assert {:ok, metadata} =
               Executor.inspect_workspace_publication(workspace, %{
                 branch_name: "studio-runner/change/event"
               })

      assert metadata.status == "completed"
      assert metadata.branch_name == "studio-runner/change/event"
      assert metadata.commit_sha =~ ~r/^[0-9a-f]{40}$/
      assert metadata.pr_url == "https://github.com/example/source/pull/42"
      refute Map.has_key?(metadata, :error)
    after
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      File.rm_rf!(test_root)
    end
  end

  test "publication inspection reports blocked when commit exists without pull request" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-blocked-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "--quiet"], cd: workspace)
    System.cmd("git", ["checkout", "-B", "studio-runner/change/event", "--quiet"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    File.write!(Path.join(workspace, "CHANGE"), "done")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-m", "change"], cd: workspace)

    old_path = System.get_env("PATH")
    System.put_env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")

    try do
      assert {:ok, metadata} =
               Executor.inspect_workspace_publication(workspace, %{
                 branch_name: "studio-runner/change/event"
               })

      assert metadata.status == "blocked"
      assert metadata.branch_name == "studio-runner/change/event"
      assert metadata.commit_sha =~ ~r/^[0-9a-f]{40}$/
      assert metadata.pr_url == nil
      assert metadata.error =~ "no pushed branch or pull request"
    after
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      File.rm_rf!(test_root)
    end
  end

  test "publication inspection blocks unchanged workspace at dispatch commit" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-unchanged-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "--quiet"], cd: workspace)
    System.cmd("git", ["checkout", "-B", "studio-runner/change/event", "--quiet"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    File.write!(Path.join(workspace, "CHANGE"), "original")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-m", "initial"], cd: workspace)
    {base_commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)

    try do
      assert {:ok, metadata} =
               Executor.inspect_workspace_publication(workspace, %{
                 branch_name: "studio-runner/change/event",
                 base_commit_sha: String.trim(base_commit)
               })

      assert metadata.status == "blocked"
      assert metadata.commit_sha == nil
      assert metadata.error =~ "without a new workspace commit"
    after
      File.rm_rf!(test_root)
    end
  end

  test "publication inspection blocks work on the wrong branch" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-wrong-branch-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "--quiet"], cd: workspace)
    System.cmd("git", ["checkout", "-B", "wrong-branch", "--quiet"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    File.write!(Path.join(workspace, "CHANGE"), "done")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-m", "change"], cd: workspace)

    try do
      assert {:ok, metadata} =
               Executor.inspect_workspace_publication(workspace, %{
                 branch_name: "studio-runner/change/event"
               })

      assert metadata.status == "blocked"
      assert metadata.commit_sha =~ ~r/^[0-9a-f]{40}$/
      assert metadata.error =~ "instead of expected branch"
    after
      File.rm_rf!(test_root)
    end
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
