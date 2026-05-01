# Proposal: Use Git worktrees for Studio Runner workspaces

## Summary

Studio Runner execution currently prepares a fresh managed copy of the target repository for each accepted event. That is safe, but it will become wasteful quickly: every agent run can leave behind another full repository clone.

This change moves Studio Runner workspace preparation to a Git worktree model. Symphony should treat the Studio-selected repository as the canonical local source, fetch its remote, create an isolated per-run worktree from the configured/default remote branch, run Codex inside that worktree, publish a branch/PR, and clean up inactive worktrees according to explicit lifecycle rules.

## Problem

Fresh full clones per run create predictable operational problems:

- redundant object storage for the same repository;
- slow startup as repositories grow;
- unclear ownership of old run directories;
- accumulating stale workspaces after blocked runs, closed PRs, or merged PRs;
- temptation to blindly reuse dirty directories, which risks contaminating future agent runs.

The right v1 does not need a separate bare cache. The canonical local repository already has the trusted remote configuration and can fetch from `origin`. Git worktrees give isolated working directories while sharing object storage with the canonical repo.

## Goals

- Use Git worktrees for Studio Runner execution workspaces instead of fresh full clones.
- Keep the Studio-selected local repository as the canonical source for remote/default-branch discovery.
- Fetch the remote before creating a new run workspace.
- Create each run on a deterministic branch from the latest remote default branch, usually `origin/main`.
- Keep Codex isolated from the original repository by running only inside the worktree.
- Reuse a workspace only for the same run/retry, never as a dirty generic pool.
- Track workspace lifecycle state so cleanup is safe and explainable.
- Remove/prune worktrees when their PR is merged, closed, abandoned, or stale according to policy.
- Preserve lightweight metadata/log/event history even after deleting the worktree directory.

## Non-Goals

- Do not add a separate bare repository cache in v1.
- Do not let Studio create worktrees directly; Symphony owns execution workspace lifecycle.
- Do not blindly reuse arbitrary inactive workspaces for new events.
- Do not delete active workspaces.
- Do not automatically merge PRs or archive OpenSpec changes.
- Do not require OpenSpec Studio to poll GitHub for PR merge state in v1.

## Proposed Approach

For each accepted Studio Runner work item:

1. Canonicalize and validate the Studio-supplied repository path.
2. Verify the source repository is a Git worktree/repository with a usable remote and default branch.
3. Fetch the remote before workspace creation.
4. Derive a deterministic branch name, e.g. `studio-runner/<change-name>/<short-event-id>`.
5. Create a worktree under Symphony's workspace root from the remote-tracking default branch, e.g.:

   ```text
   ~/code/symphony-workspaces/runs/<repo-name>/<change-name>/<run-id>
   ```

   backed by:

   ```bash
   git -C <source-repo> fetch origin
   git -C <source-repo> worktree add <workspace-path> -b <branch> origin/main
   ```

6. Run Codex only inside the worktree.
7. Require publication as branch push + PR URL before marking the run completed.
8. Keep blocked/failed worktrees temporarily for debugging.
9. Remove merged/closed/expired inactive worktrees with `git worktree remove` and `git worktree prune`.
10. Keep metadata after removal: event ID, run ID, repo/change, branch, commit SHA, PR URL, terminal status, timestamps, and cleanup result.

## Decisions

- Skip a bare cache for v1. It adds another source of truth and stale-cache risk without enough benefit yet.
- Worktree base is the latest fetched remote default branch, not whatever local `main` happens to contain.
- Same event retry may reuse the same worktree if it still exists and is safe; a new accepted event gets a new worktree/branch.
- If a duplicate repo/change run is active, reject it as today. Do not create a second worktree for the same active change.
- If an open PR already exists for the same repo/change, Studio/Symphony should surface that state rather than silently creating another run unless explicitly requested later.
- Cleanup should be conservative: delete only inactive worktrees whose lifecycle state is known.

## Open Questions

- Should PR merge/closed detection happen inside Symphony via `gh pr view`, or should Studio offer explicit cleanup actions first?
- What should the default TTL be for blocked/failed worktrees: 3 days or 7 days?
- Should a manual "Start clean" action be added later to intentionally discard/recreate a blocked workspace?
