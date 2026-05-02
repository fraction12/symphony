defmodule SymphonyElixir.StudioRunnerExecutorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.StudioRunner.{Executor, WorkItem}

  test "run reports execution preparation failures" do
    work_item = %WorkItem{
      event_id: "evt-invalid-run",
      event_type: "build.requested",
      repo_path: 123,
      change: "add-runner-work"
    }

    assert {:error, {:invalid_repo_path, :not_string}} = Executor.run(work_item)
  end

  test "source repo metadata accepts injected discovery and fetch failure is bounded" do
    parent = self()
    work_item = %WorkItem{event_id: "evt-source-meta", change: "add-runner-work"}

    assert {:ok, %{remote_name: "origin"}} =
             Executor.source_repo_git_metadata("/tmp/source", work_item,
               discover_git_source: fn source_repo, discovered_work_item ->
                 send(parent, {:discovered, source_repo, discovered_work_item})
                 {:ok, %{remote_name: "origin"}}
               end
             )

    assert_receive {:discovered, "/tmp/source", ^work_item}, 500

    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-fetch-failure-#{System.unique_integer([:positive])}"
      )

    source_repo = Path.join(test_root, "source")
    File.mkdir_p!(source_repo)
    System.cmd("git", ["init", "--quiet"], cd: source_repo)

    try do
      assert {:error, {:source_fetch_failed, {_command, _status, _output}}} =
               Executor.fetch_source_remote(source_repo, %{remote_name: "origin"})
    after
      File.rm_rf!(test_root)
    end
  end

  test "source repo metadata falls back to request remote metadata" do
    test_root = Path.join(System.tmp_dir!(), "studio-runner-source-fallback-#{System.unique_integer([:positive])}")
    source_repo = Path.join(test_root, "source")
    File.mkdir_p!(source_repo)
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    File.write!(Path.join(source_repo, "README.md"), "source")
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: source_repo)
    System.cmd("git", ["update-ref", "refs/remotes/origin/main", String.trim(head)], cd: source_repo)
    {:ok, canonical_source_repo} = SymphonyElixir.PathSafety.canonicalize(source_repo)

    try do
      fallback_work_item = %WorkItem{
        event_id: "evt-source-fallback",
        repo_remote: " git@example.com:source.git "
      }

      assert {:ok, git_source} = Executor.source_repo_git_metadata(canonical_source_repo, fallback_work_item)

      assert git_source.remote_url == "git@example.com:source.git"
      assert git_source.default_branch == "main"

      assert {:error, {:missing_remote, "origin"}} =
               Executor.discover_git_source(canonical_source_repo, %WorkItem{
                 event_id: "evt-source-blank-remote",
                 repo_remote: " "
               })
    after
      File.rm_rf!(test_root)
    end
  end

  test "source repo metadata parses remote show default branch" do
    test_root = Path.join(System.tmp_dir!(), "studio-runner-remote-show-#{System.unique_integer([:positive])}")
    source_repo = Path.join(test_root, "source")
    remote_repo = Path.join(test_root, "remote.git")

    File.mkdir_p!(source_repo)
    System.cmd("git", ["init", "--bare", "--quiet", remote_repo])
    System.cmd("git", ["symbolic-ref", "HEAD", "refs/heads/main"], cd: remote_repo)
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    File.write!(Path.join(source_repo, "README.md"), "source")
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)
    System.cmd("git", ["remote", "add", "origin", remote_repo], cd: source_repo)
    System.cmd("git", ["push", "-u", "origin", "main"], cd: source_repo)
    System.cmd("git", ["remote", "set-head", "origin", "-d"], cd: source_repo)
    {:ok, canonical_source_repo} = SymphonyElixir.PathSafety.canonicalize(source_repo)

    try do
      assert {:ok, git_source} =
               Executor.discover_git_source(canonical_source_repo, %WorkItem{event_id: "evt-remote-show"})

      assert git_source.default_branch == "main"
      assert git_source.remote_ref == "origin/main"
    after
      File.rm_rf!(test_root)
    end
  end

  test "source repo metadata includes remote lookup reason when no fallback exists" do
    test_root = Path.join(System.tmp_dir!(), "studio-runner-no-remote-#{System.unique_integer([:positive])}")
    source_repo = Path.join(test_root, "source")
    File.mkdir_p!(source_repo)
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    File.write!(Path.join(source_repo, "README.md"), "source")
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)
    {:ok, canonical_source_repo} = SymphonyElixir.PathSafety.canonicalize(source_repo)

    try do
      assert {:error, {:missing_remote, "origin", {_command, _status, _output}}} =
               Executor.discover_git_source(canonical_source_repo, %WorkItem{
                 event_id: "evt-source-no-remote"
               })
    after
      File.rm_rf!(test_root)
    end
  end

  test "source repo metadata reports missing default branch when it cannot be inferred" do
    test_root = Path.join(System.tmp_dir!(), "studio-runner-missing-default-#{System.unique_integer([:positive])}")
    source_repo = Path.join(test_root, "source")
    File.mkdir_p!(source_repo)
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    File.write!(Path.join(source_repo, "README.md"), "source")
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)
    {:ok, canonical_source_repo} = SymphonyElixir.PathSafety.canonicalize(source_repo)

    try do
      assert {:error, {:missing_remote_default_branch, _reason}} =
               Executor.discover_git_source(canonical_source_repo, %WorkItem{
                 event_id: "evt-source-no-default",
                 repo_remote: "git@example.com:source.git"
               })
    after
      File.rm_rf!(test_root)
    end
  end

  test "workspace preparation stops when source fetch fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-prepare-fetch-#{System.unique_integer([:positive])}"
      )

    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    File.mkdir_p!(source_repo)
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    git_source = %{remote_name: "origin", remote_ref: "origin/main"}

    work_item = %WorkItem{
      event_id: "evt-fetch-fails",
      repo_path: source_repo,
      change: "add-runner-work"
    }

    fetch_remote = fn _source_repo, _git_source -> {:error, :fetch_blocked} end

    try do
      assert {:error, :fetch_blocked} =
               Executor.prepare_worktree_workspace(source_repo, git_source, work_item, fetch_remote: fetch_remote)
    after
      File.rm_rf!(test_root)
    end
  end

  test "workspace cleanup rejects the configured workspace root" do
    test_root = Path.join(System.tmp_dir!(), "studio-runner-root-cleanup-#{System.unique_integer([:positive])}")
    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    create_source_repo!(source_repo, test_root, "cleanup-root")
    File.mkdir_p!(workspace_root)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    try do
      assert %{cleanupStatus: "blocked", cleanupError: error} =
               Executor.remove_worktree(source_repo, workspace_root)

      assert error =~ "workspace_equals_root"
    after
      File.rm_rf!(test_root)
    end
  end

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
    File.mkdir_p!(Path.join(source_repo, ".codex/skills/github"))
    File.write!(Path.join(source_repo, ".codex/skills/github/SKILL.md"), "# GitHub CLI
")
    remote_repo = Path.join(test_root, "remote.git")
    System.cmd("git", ["init", "--bare", "--quiet", remote_repo])
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)
    System.cmd("git", ["remote", "add", "origin", remote_repo], cd: source_repo)
    System.cmd("git", ["push", "-u", "origin", "main"], cd: source_repo)
    System.cmd("git", ["remote", "set-head", "origin", "main"], cd: source_repo)

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
      requested_by: "test",
      runner_model: "gpt-custom",
      runner_effort: "high"
    }

    assert {:ok, context, result} =
             Executor.execute(work_item,
               codex_runner: fn workspace, prompt, runner_work_item, opts ->
                 send(parent, {:codex_invoked, workspace, prompt, runner_work_item, opts})
                 File.write!(Path.join(workspace, "WORKSPACE_ONLY"), "changed")
                 {:ok, %{session_id: "session-test"}}
               end,
               publish_inspector: fn _workspace, _context ->
                 {:ok,
                  %{
                    status: "completed",
                    branch_name: "studio-runner/add-runner-work/executetest",
                    commit_sha: "0123456789abcdef0123456789abcdef01234567",
                    pr_url: "https://github.com/example/source/pull/123"
                  }}
               end
             )

    assert context.change == "add-runner-work"
    assert context.workspace_path != source_repo
    assert context.branch_name == "studio-runner/add-runner-work/executetest"
    assert context.base_commit_sha =~ ~r/^[0-9a-f]{40}$/

    assert {:ok, canonical_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(workspace_root)

    assert String.starts_with?(
             context.workspace_path,
             Path.join([canonical_workspace_root, "runs", "source", "add-runner-work"]) <> "/"
           )

    assert File.exists?(Path.join(context.workspace_path, ".symphony-studio-runner.json"))

    assert File.read!(Path.join(context.workspace_path, ".codex/skills/github/SKILL.md")) ==
             "# GitHub CLI
"

    assert {"true
", 0} =
             System.cmd("git", ["rev-parse", "--is-inside-work-tree"], cd: context.workspace_path)

    assert result.session_id == "session-test"
    assert result.status == "completed"
    assert result.pr_url == "https://github.com/example/source/pull/123"
    assert context.base_commit_sha =~ ~r/^[0-9a-f]{40}$/

    assert_receive {:codex_invoked, workspace, prompt, ^work_item, opts}, 500
    assert opts[:model] == "gpt-custom"
    assert opts[:effort] == "high"
    assert workspace == context.workspace_path
    assert prompt =~ "OpenSpec change"
    assert prompt =~ "add-runner-work"
    assert prompt =~ "studio-runner/add-runner-work/executetest"
    assert File.exists?(Path.join(workspace, "WORKSPACE_ONLY"))
    refute File.exists?(Path.join(source_repo, "WORKSPACE_ONLY"))
    assert File.read!(Path.join(source_repo, "ORIGINAL")) == "untouched"
    assert {"main
", 0} = System.cmd("git", ["branch", "--show-current"], cd: source_repo)
    File.rm_rf!(test_root)

    :ok
  end

  test "executor run completes through default Codex runner and publication inspection" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-default-run-#{System.unique_integer([:positive])}")

    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    change = "default-run-work"
    create_source_repo!(source_repo, test_root, change)

    codex_bin = Path.join(test_root, "bin/codex")
    gh_bin = Path.join(test_root, "bin/gh")
    File.mkdir_p!(Path.dirname(codex_bin))

    File.write!(codex_bin, """
    #!/bin/sh
    count=0

    while IFS= read -r line; do
      count=$((count + 1))

      case "$count" in
        1)
          printf '%s\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-default-run"}}}'
          ;;
        3)
          printf 'changed\n' > DEFAULT_RUN_RESULT
          git add DEFAULT_RUN_RESULT >/dev/null 2>&1
          git commit -m 'default runner result' >/dev/null 2>&1
          printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-default-run"}}}'
          ;;
        4)
          printf '%s\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.write!(gh_bin, """
    #!/bin/sh
    echo '{"url":"https://github.com/example/source/pull/99","state":"MERGED","mergedAt":"2026-05-02T12:00:00Z","closedAt":"2026-05-02T12:00:00Z"}'
    """)

    File.chmod!(codex_bin, 0o755)
    File.chmod!(gh_bin, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", Path.dirname(codex_bin) <> ":" <> (old_path || ""))

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_bin} app-server"
    )

    try do
      assert {:ok, metadata} =
               Executor.run(%WorkItem{
                 event_id: "evt-default-run",
                 run_id: "run_default_run",
                 event_type: "build.requested",
                 repo_path: source_repo,
                 repo_name: "source",
                 change: change
               })

      assert metadata.status == "completed"
      assert metadata.workspaceStatus == "published"
      assert metadata.sessionId == "thread-default-run-turn-default-run"
      assert metadata.prUrl == "https://github.com/example/source/pull/99"
      assert metadata.prState == "MERGED"
      assert metadata.cleanupEligible == true
      assert metadata.cleanupReason == "pr_merged"
      assert File.exists?(Path.join(metadata.workspacePath, "DEFAULT_RUN_RESULT"))
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "executor rejects invalid change names before workspace preparation" do
    test_root = Path.join(System.tmp_dir!(), "studio-runner-invalid-change-#{System.unique_integer([:positive])}")
    source_repo = Path.join(test_root, "source")
    create_source_repo!(source_repo, test_root, "safe-change")

    try do
      assert {:error, {:invalid_change_name, nil}} =
               Executor.execute(%WorkItem{
                 event_id: "evt-invalid-change",
                 event_type: "build.requested",
                 repo_path: source_repo,
                 repo_name: "source",
                 change: nil
               })
    after
      File.rm_rf!(test_root)
    end
  end

  test "same event retry reuses its existing worktree but new events do not" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-retry-#{System.unique_integer([:positive])}")

    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    change = "retry-work"
    create_source_repo!(source_repo, test_root, change)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    git_source = %{
      remote_name: "origin",
      remote_url: Path.join(test_root, "remote.git"),
      default_branch: "main",
      remote_ref: "origin/main"
    }

    work_item = %WorkItem{
      event_id: "evt-retry-test",
      run_id: "run_retry_test",
      event_type: "build.requested",
      repo_path: source_repo,
      repo_name: "source",
      change: change
    }

    assert {:ok, first} = Executor.prepare_worktree_workspace(source_repo, git_source, work_item)
    File.write!(Path.join(first.workspace_path, "RETRY_MARKER"), "keep")
    assert {:ok, second} = Executor.prepare_worktree_workspace(source_repo, git_source, work_item)
    assert second.workspace_path == first.workspace_path
    assert File.read!(Path.join(second.workspace_path, "RETRY_MARKER")) == "keep"

    new_event = %{work_item | event_id: "evt-retry-test-two", run_id: "run_retry_test_two"}
    assert {:ok, third} = Executor.prepare_worktree_workspace(source_repo, git_source, new_event)
    assert third.workspace_path != first.workspace_path
    refute File.exists?(Path.join(third.workspace_path, "RETRY_MARKER"))

    File.rm_rf!(test_root)
  end

  test "worktree cleanup refuses source and outside-root paths while removing known worktrees" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-cleanup-#{System.unique_integer([:positive])}")

    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    change = "cleanup-work"
    create_source_repo!(source_repo, test_root, change)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    git_source = %{
      remote_name: "origin",
      remote_url: Path.join(test_root, "remote.git"),
      default_branch: "main",
      remote_ref: "origin/main"
    }

    work_item = %WorkItem{
      event_id: "evt-cleanup-test",
      run_id: "run_cleanup_test",
      event_type: "build.requested",
      repo_path: source_repo,
      repo_name: "source",
      change: change
    }

    assert {:ok, lifecycle} =
             Executor.prepare_worktree_workspace(source_repo, git_source, work_item)

    assert %{cleanupStatus: "blocked", cleanupError: active_error} =
             Executor.remove_worktree(source_repo, lifecycle.workspace_path)

    assert active_error =~ "workspace_active"

    File.rm!(Path.join(lifecycle.workspace_path, ".symphony-studio-runner.json"))

    assert %{cleanupStatus: "cleaned"} =
             Executor.remove_worktree(source_repo, lifecycle.workspace_path)

    refute File.exists?(lifecycle.workspace_path)

    assert %{cleanupStatus: "blocked", cleanupError: error} =
             Executor.remove_worktree(source_repo, source_repo)

    assert error =~ "workspace_equals_source_repo"

    outside = Path.join(test_root, "outside-worktree")
    File.mkdir_p!(outside)

    assert %{cleanupStatus: "blocked", cleanupError: outside_error} =
             Executor.remove_worktree(source_repo, outside)

    assert outside_error =~ "workspace_outside_root"
    assert File.dir?(outside)

    File.rm_rf!(test_root)
  end

  test "cleanup metadata covers active, debugging, abandoned, and unknown workspace states" do
    now = ~U[2026-05-02 12:00:00Z]
    recent = ~U[2026-05-02 11:00:00Z]
    stale_debug = ~U[2026-04-20 12:00:00Z]
    stale_abandoned = "2026-04-20T12:00:00Z"

    assert %{cleanupEligible: false, cleanupReason: "active"} =
             Executor.cleanup_metadata(
               %{status: "running", workspacePath: "/workspace/running"},
               now
             )

    assert %{cleanupEligible: false, cleanupReason: "active"} =
             Executor.cleanup_metadata(
               %{status: "accepted", workspacePath: "/workspace/accepted"},
               now
             )

    assert %{cleanupEligible: false, cleanupReason: "debug_ttl"} =
             Executor.cleanup_metadata(
               %{status: "blocked", workspacePath: "/workspace/blocked", updatedAt: recent},
               now
             )

    assert %{cleanupEligible: true, cleanupReason: "debug_ttl_expired"} =
             Executor.cleanup_metadata(
               %{status: "failed", workspacePath: "/workspace/failed", updatedAt: stale_debug},
               now
             )

    assert %{cleanupEligible: false, cleanupReason: "abandoned_ttl"} =
             Executor.cleanup_metadata(
               %{
                 status: "abandoned",
                 workspacePath: "/workspace/abandoned",
                 updatedAt: "not-a-date"
               },
               now
             )

    assert %{cleanupEligible: true, cleanupReason: "abandoned_ttl_expired"} =
             Executor.cleanup_metadata(
               %{
                 status: "abandoned",
                 workspacePath: "/workspace/abandoned-old",
                 updatedAt: stale_abandoned
               },
               now
             )

    assert %{cleanupEligible: false, cleanupReason: "abandoned_ttl"} =
             Executor.cleanup_metadata(
               %{
                 status: "abandoned",
                 workspacePath: "/workspace/abandoned-integer",
                 updatedAt: 123
               },
               now
             )

    assert %{cleanupEligible: false} =
             completed_without_pr =
             Executor.cleanup_metadata(
               %{status: "completed", workspacePath: "/workspace/completed"},
               now
             )

    refute Map.has_key?(completed_without_pr, :cleanupReason)

    assert %{cleanupEligible: false} =
             metadata =
             Executor.cleanup_metadata(
               %{status: "mystery", workspacePath: "/workspace/mystery"},
               now
             )

    refute Map.has_key?(metadata, :cleanupReason)
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

  test "orchestrator status echoes requested runner execution defaults" do
    work_item = %WorkItem{
      event_id: "evt-runner-defaults",
      run_id: nil,
      event_type: "build.requested",
      repo_path: "/tmp/source",
      repo_name: "source",
      change: "add-runner-work",
      runner_model: "gpt-custom",
      runner_effort: "high"
    }

    orchestrator_name = Module.concat(__MODULE__, :StudioRunnerDefaultsOrchestrator)
    start_supervised!({Orchestrator, name: orchestrator_name})

    executor = fn _work_item ->
      {:ok,
       %{
         status: "completed",
         workspacePath: "/tmp/workspace",
         sessionId: "session-123",
         branchName: "studio-runner/add-runner-work/defaults",
         runnerModel: "gpt-custom",
         runnerEffort: "high"
       }}
    end

    assert {:ok, response} =
             Orchestrator.dispatch_external_work(orchestrator_name, work_item, executor: executor)

    assert response.runnerModel == "gpt-custom"
    assert response.runnerEffort == "high"

    snapshot =
      eventually_snapshot(orchestrator_name, fn snapshot ->
        match?(%{events: [%{status: "completed"}]}, snapshot.studio_runner)
      end)

    assert %{events: [event_payload]} = snapshot.studio_runner
    assert event_payload.runnerModel == "gpt-custom"
    assert event_payload.runnerEffort == "high"
  end

  test "executor omits blank runner turn options" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-blank-options-#{System.unique_integer([:positive])}")

    source_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")
    change = "blank-options-work"
    create_source_repo!(source_repo, test_root, change)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    parent = self()

    work_item = %WorkItem{
      event_id: "evt-blank-options",
      run_id: "run_blank_options",
      event_type: "build.requested",
      repo_path: source_repo,
      repo_name: "source",
      change: change,
      runner_model: "",
      runner_effort: ""
    }

    try do
      assert {:ok, _context, _result} =
               Executor.execute(work_item,
                 codex_runner: fn _workspace, _prompt, _runner_work_item, opts ->
                   send(parent, {:codex_opts, opts})
                   {:ok, %{session_id: "session-blank-options"}}
                 end,
                 publish_inspector: fn _workspace, context ->
                   {:ok,
                    %{
                      status: "completed",
                      branch_name: context.branch_name,
                      commit_sha: "0123456789abcdef0123456789abcdef01234567",
                      pr_url: "https://github.com/example/source/pull/123"
                    }}
                 end
               )

      assert_receive {:codex_opts, opts}, 500
      refute Keyword.has_key?(opts, :model)
      refute Keyword.has_key?(opts, :effort)
    after
      File.rm_rf!(test_root)
    end
  end

  test "publication inspection reports completed only when a pull request exists" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-publication-#{System.unique_integer([:positive])}"
      )

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

  test "publication inspection captures pull request state when gh returns JSON" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-pr-state-#{System.unique_integer([:positive])}"
      )

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
    echo '{"url":"https://github.com/example/source/pull/42","state":"OPEN","mergedAt":null}'
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
      assert metadata.pr_url == "https://github.com/example/source/pull/42"
      assert metadata.pr_state == "OPEN"
      assert metadata.pr_merged_at == nil
    after
      if old_path, do: System.put_env("PATH", old_path), else: System.delete_env("PATH")
      File.rm_rf!(test_root)
    end
  end

  test "cleanup metadata waits while a completed run's pull request is still open" do
    test_root =
      Path.join(System.tmp_dir!(), "studio-runner-open-pr-#{System.unique_integer([:positive])}")

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    old_path =
      install_fake_gh!(
        test_root,
        ~s({"url":"https://github.com/example/source/pull/42","state":"OPEN","mergedAt":null,"closedAt":null})
      )

    try do
      assert %{
               cleanupEligible: false,
               cleanupReason: "pr_open",
               prState: "OPEN"
             } =
               Executor.cleanup_metadata(%{
                 status: "completed",
                 prUrl: "https://github.com/example/source/pull/42",
                 prState: "OPEN",
                 workspacePath: workspace
               })
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "cleanup metadata refreshes stale pull request state before evaluating cleanup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-merged-pr-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    merged_at = "2026-04-30T15:00:00Z"

    old_path =
      install_fake_gh!(
        test_root,
        ~s({"url":"https://github.com/example/source/pull/42","state":"MERGED","mergedAt":"#{merged_at}","closedAt":"#{merged_at}"})
      )

    try do
      assert %{
               cleanupEligible: true,
               cleanupReason: "pr_merged",
               prState: "MERGED",
               prMergedAt: ^merged_at
             } =
               Executor.cleanup_metadata(%{
                 status: "completed",
                 prUrl: "https://github.com/example/source/pull/42",
                 prState: "OPEN",
                 workspacePath: workspace
               })
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "cleanup metadata defers completed pull requests when state cannot be refreshed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-unknown-pr-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    bin_dir = Path.join(test_root, "bin")
    File.mkdir_p!(workspace)
    File.mkdir_p!(bin_dir)

    old_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir)

    try do
      assert %{
               cleanupEligible: false,
               cleanupReason: "pr_state_unavailable"
             } =
               Executor.cleanup_metadata(%{
                 status: "completed",
                 prUrl: "https://github.com/example/source/pull/42",
                 workspacePath: workspace
               })
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "cleanup metadata retains recently closed pull requests until the retention TTL expires" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-closed-pr-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    now = ~U[2026-04-30 20:00:00Z]
    closed_at = "2026-04-29T20:00:00Z"

    old_path =
      install_fake_gh!(
        test_root,
        ~s({"url":"https://github.com/example/source/pull/42","state":"CLOSED","mergedAt":null,"closedAt":"#{closed_at}"})
      )

    try do
      assert %{
               cleanupEligible: false,
               cleanupReason: "pr_closed_ttl",
               prState: "CLOSED",
               prClosedAt: ^closed_at
             } =
               Executor.cleanup_metadata(
                 %{
                   status: "completed",
                   prUrl: "https://github.com/example/source/pull/42",
                   workspacePath: workspace
                 },
                 now
               )
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "cleanup metadata allows closed pull requests after the retention TTL" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-expired-pr-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    now = ~U[2026-04-30 20:00:00Z]
    closed_at = "2026-04-20T20:00:00Z"

    old_path =
      install_fake_gh!(
        test_root,
        ~s({"url":"https://github.com/example/source/pull/42","state":"CLOSED","mergedAt":null,"closedAt":"#{closed_at}"})
      )

    try do
      assert %{
               cleanupEligible: true,
               cleanupReason: "pr_closed_ttl_expired",
               prState: "CLOSED",
               prClosedAt: ^closed_at
             } =
               Executor.cleanup_metadata(
                 %{
                   status: "completed",
                   prUrl: "https://github.com/example/source/pull/42",
                   workspacePath: workspace
                 },
                 now
               )
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "cleanup metadata retains legacy completed pull requests without refreshable state" do
    assert %{
             cleanupEligible: false,
             cleanupReason: "pr_state_unavailable"
           } =
             Executor.cleanup_metadata(%{
               status: "completed",
               prUrl: "https://github.com/example/source/pull/42",
               workspacePath: "/workspace/run-demo"
             })
  end

  test "cleanup metadata allows merged pull request workspaces when refreshed state is available" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-merged-pr-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)

    merged_at = "2026-04-30T15:00:00Z"

    old_path =
      install_fake_gh!(
        test_root,
        ~s({"url":"https://github.com/example/source/pull/42","state":"MERGED","mergedAt":"#{merged_at}","closedAt":"#{merged_at}"})
      )

    try do
      assert %{
               cleanupEligible: true,
               cleanupReason: "pr_merged"
             } =
               Executor.cleanup_metadata(%{
                 status: "completed",
                 prUrl: "https://github.com/example/source/pull/42",
                 workspacePath: workspace
               })
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "cleanup metadata keeps stored merged state for already captured publication metadata" do
    assert %{
             cleanupEligible: true,
             cleanupReason: "pr_merged"
           } =
             Executor.cleanup_metadata(%{
               status: "completed",
               prUrl: "https://github.com/example/source/pull/42",
               prState: "MERGED",
               workspacePath: "/workspace/run-demo"
             })
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

  test "publication inspection reports blocked when branch cannot be detected" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-detached-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "--quiet"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    File.write!(Path.join(workspace, "CHANGE"), "done")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-m", "change"], cd: workspace)
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace)
    System.cmd("git", ["checkout", "--detach", String.trim(head), "--quiet"], cd: workspace)

    try do
      assert {:ok, metadata} =
               Executor.inspect_workspace_publication(workspace, %{branch_name: nil})

      assert metadata.status == "blocked"
      assert metadata.branch_name == nil
      assert metadata.commit_sha =~ ~r/^[0-9a-f]{40}$/
      assert metadata.error =~ "without a detectable branch"
    after
      File.rm_rf!(test_root)
    end
  end

  test "publication inspection reports pushed branches without pull requests" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-pushed-branch-#{System.unique_integer([:positive])}"
      )

    remote_repo = Path.join(test_root, "remote.git")
    workspace = Path.join(test_root, "workspace")
    File.mkdir_p!(workspace)
    System.cmd("git", ["init", "--bare", "--quiet", remote_repo])
    System.cmd("git", ["init", "--quiet"], cd: workspace)
    System.cmd("git", ["checkout", "-B", "studio-runner/change/event", "--quiet"], cd: workspace)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: workspace)
    System.cmd("git", ["config", "user.name", "Test User"], cd: workspace)
    File.write!(Path.join(workspace, "CHANGE"), "done")
    System.cmd("git", ["add", "."], cd: workspace)
    System.cmd("git", ["commit", "-m", "change"], cd: workspace)
    System.cmd("git", ["remote", "add", "origin", remote_repo], cd: workspace)
    System.cmd("git", ["push", "-u", "origin", "studio-runner/change/event"], cd: workspace)

    old_path = System.get_env("PATH")
    System.put_env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")

    try do
      assert {:ok, metadata} =
               Executor.inspect_workspace_publication(workspace, %{
                 branch_name: "studio-runner/change/event"
               })

      assert metadata.status == "blocked"
      assert metadata.error =~ "created/pushed branch"
    after
      restore_path!(old_path)
      File.rm_rf!(test_root)
    end
  end

  test "change artifact loading normalizes optional and truncated artifacts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-artifacts-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "workspace")
    change_root = Path.join(workspace, "openspec/changes/coverage-work")
    File.mkdir_p!(Path.join(change_root, "specs/runner"))
    File.write!(Path.join(change_root, "proposal.md"), String.duplicate("p", 65_000))
    File.write!(Path.join(change_root, "tasks.md"), "## Tasks\n- [ ] Cover branches\n")
    File.mkdir_p!(Path.join(change_root, "design.md"))
    File.write!(Path.join(change_root, "specs/runner/spec.md"), String.duplicate("s", 65_000))

    try do
      assert {:ok, artifacts} = Executor.load_change_artifacts(workspace, "coverage-work")
      assert artifacts.proposal =~ "[truncated]"
      assert artifacts.design == nil
      assert artifacts.tasks =~ "Cover branches"
      assert [{"specs/runner/spec.md", spec_content}] = artifacts.specs
      assert spec_content =~ "[truncated]"

      assert {:error, {:missing_change, "missing-work"}} =
               Executor.load_change_artifacts(workspace, "missing-work")
    after
      File.rm_rf!(test_root)
    end
  end

  test "publication inspection blocks unchanged workspace at dispatch commit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "studio-runner-unchanged-#{System.unique_integer([:positive])}"
      )

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
      Path.join(
        System.tmp_dir!(),
        "studio-runner-wrong-branch-#{System.unique_integer([:positive])}"
      )

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

    remote_repo = Path.join(test_root, "remote.git")
    System.cmd("git", ["init", "--bare", "--quiet", remote_repo])
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)
    System.cmd("git", ["remote", "add", "origin", remote_repo], cd: source_repo)
    System.cmd("git", ["push", "-u", "origin", "main"], cd: source_repo)
    System.cmd("git", ["remote", "set-head", "origin", "main"], cd: source_repo)

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

  defp eventually_snapshot(orchestrator_name, _predicate, 0),
    do: Orchestrator.snapshot(orchestrator_name, 1_000)

  defp create_source_repo!(source_repo, test_root, change) do
    File.mkdir_p!(Path.join(source_repo, "openspec/changes/#{change}/specs/runner"))
    File.write!(Path.join(source_repo, "openspec/changes/#{change}/proposal.md"), "# Proposal\n")

    File.write!(
      Path.join(source_repo, "openspec/changes/#{change}/tasks.md"),
      "## Tasks\n- [ ] Do it\n"
    )

    File.write!(Path.join(source_repo, "openspec/changes/#{change}/design.md"), "# Design\n")

    File.write!(
      Path.join(source_repo, "openspec/changes/#{change}/specs/runner/spec.md"),
      "## ADDED Requirements\n"
    )

    remote_repo = Path.join(test_root, "remote.git")
    System.cmd("git", ["init", "--bare", "--quiet", remote_repo])
    System.cmd("git", ["init", "--quiet"], cd: source_repo)
    System.cmd("git", ["checkout", "-B", "main", "--quiet"], cd: source_repo)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: source_repo)
    System.cmd("git", ["config", "user.name", "Test User"], cd: source_repo)
    System.cmd("git", ["add", "."], cd: source_repo)
    System.cmd("git", ["commit", "-m", "initial"], cd: source_repo)
    System.cmd("git", ["remote", "add", "origin", remote_repo], cd: source_repo)
    System.cmd("git", ["push", "-u", "origin", "main"], cd: source_repo)
    System.cmd("git", ["remote", "set-head", "origin", "main"], cd: source_repo)
  end

  defp install_fake_gh!(test_root, output) do
    gh_bin = Path.join(test_root, "bin/gh")
    File.mkdir_p!(Path.dirname(gh_bin))

    File.write!(gh_bin, """
    #!/bin/sh
    echo '#{output}'
    """)

    File.chmod!(gh_bin, 0o755)

    old_path = System.get_env("PATH")
    System.put_env("PATH", Path.dirname(gh_bin) <> ":" <> (old_path || ""))
    old_path
  end

  defp restore_path!(nil), do: System.delete_env("PATH")
  defp restore_path!(old_path), do: System.put_env("PATH", old_path)
end
