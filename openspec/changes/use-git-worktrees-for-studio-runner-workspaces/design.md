# Design: Git worktrees for Studio Runner workspaces

## Current State

The `execute-studio-runner-work` change introduces real execution for accepted Studio Runner events. It prepares a managed workspace, builds an OpenSpec-native prompt, runs Codex, and inspects publication state.

The remaining workspace concern is storage and lifecycle: creating a full repository copy per run is safe but wasteful. Reusing arbitrary old directories is cheaper but unsafe. Git worktrees provide the middle path: isolated working directories sharing object storage with the source repository.

## Workspace Model

### Canonical source repository

The Studio-supplied `repoPath` remains the canonical local repository. Symphony SHALL use it to discover:

- repository root;
- remote name/URL, defaulting to `origin`;
- default branch, preferring remote HEAD when available;
- current repo identity for workspace naming.

Before creating a worktree, Symphony SHALL fetch the remote:

```bash
git -C <source-repo> fetch <remote>
```

The run base SHALL be the remote-tracking default branch, e.g. `origin/main`, not local `main`. This avoids depending on whether the user's local main has been pulled recently.

### Per-run worktree

Each new accepted event gets a deterministic branch and worktree path:

```text
branch: studio-runner/<safe-change-name>/<short-event-id>
path:   <workspace-root>/runs/<safe-repo-name>/<safe-change-name>/<run-id>
```

The worktree is created from the fetched remote branch:

```bash
git -C <source-repo> worktree add <workspace-path> -b <branch> <remote>/<default-branch>
```

Codex runs with `<workspace-path>` as cwd. The original repo is never the Codex cwd.

### Retry behavior

Retries for the same event/run MAY reuse the existing worktree when all of these are true:

- the worktree path still exists;
- it is associated with the same event ID/run ID;
- no other active process owns it;
- Symphony can determine it is safe to continue.

A fresh accepted event SHALL NOT reuse a random inactive worktree. If a clean retry is desired later, expose it as an explicit operator action.

## Lifecycle State

Symphony should track enough metadata to reason about cleanup without reading the entire workspace:

- `event_id`
- `run_id`
- `repo_path`
- `repo_name`
- `change_name`
- `workspace_path`
- `branch_name`
- `base_commit_sha`
- `commit_sha`
- `pr_url`
- `status`: `active`, `blocked`, `failed`, `published`, `merged`, `closed`, `abandoned`, `cleaned`
- `created_at`
- `updated_at`
- `last_checked_at`
- bounded `cleanup_error` when cleanup fails

This can begin in existing in-memory/event payloads and later move to durable local storage if needed. The important design point is that cleanup decisions are stateful and explicit, not based on a blind directory sweep.

## Cleanup Policy

Cleanup must never remove active worktrees. For inactive worktrees:

- `merged`: remove immediately or within 24 hours.
- `closed`/unmerged PR: keep 3–7 days, then remove.
- `blocked`/`failed`: keep 3–7 days for debugging, then remove unless pinned.
- `abandoned` with no PR and no activity: remove after a shorter TTL, e.g. 24–72 hours.

Removal should use Git-aware cleanup:

```bash
git -C <source-repo> worktree remove <workspace-path>
git -C <source-repo> worktree prune
```

If Git-aware removal fails because the directory is already gone, Symphony should record a bounded cleanup result and prune stale metadata where safe.

## PR Awareness

Completion already requires a PR URL. For cleanup, Symphony can inspect PR state when `gh` is available:

```bash
gh pr view <branch-or-pr-url> --json url,state,mergedAt,closedAt
```

If PR state cannot be checked because auth/tooling is missing, cleanup should not delete the workspace automatically. It should mark cleanup as blocked/deferred and surface the reason.

## Safety Rules

- Only remove worktrees that are under the configured Symphony workspace root.
- Only remove worktrees that Symphony can associate with a known Studio Runner event/run.
- Never remove the source repository.
- Never remove a path outside the workspace root, even if metadata claims it is a worktree.
- Never claim an arbitrary directory as reusable just because it is inactive.
- Prefer rejecting a new run over contaminating it with unknown workspace state.

## Agent Skills

When the source repository contains repo-local Codex skills under `.codex/skills`, Symphony should copy those skills into the managed worktree before launching Codex. This lets OpenSpec Studio provide a repository-specific GitHub CLI skill alongside the OpenSpec skills, so the unattended agent can publish its own branch and PR with `git`/`gh` rather than falling back to connector/MCP PR creation.

## Studio Responsibilities

OpenSpec Studio should not implement worktree creation. Studio may later display:

- workspace path;
- branch;
- PR URL;
- lifecycle status;
- cleanup eligibility;
- manual cleanup/retry actions.

But Symphony remains the authority for execution workspace lifecycle.

## Rollback

If worktree creation proves unreliable, Symphony can temporarily fall back to the current full-copy workspace creation while preserving the cleanup metadata and PR-aware lifecycle requirements. The API contract with Studio does not need to change.
