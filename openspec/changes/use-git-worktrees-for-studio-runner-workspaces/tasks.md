# Tasks: Use Git worktrees for Studio Runner workspaces

## Design

- [x] Decide whether to use a bare cache or source-repo worktrees for v1.
- [x] Define canonical source repo, fetch, branch, worktree, and cleanup ownership boundaries.
- [x] Define retry/reuse policy for same-run worktrees versus new events.
- [x] Define PR-aware cleanup policy and safety rules.

## Workspace preparation

- [ ] Add helpers to discover source repo remote/default branch from the Studio-supplied repo path.
- [ ] Fetch the remote before creating a Studio Runner worktree.
- [ ] Create deterministic per-run branch names from change/event/run identity.
- [ ] Create per-run Git worktrees under the configured Symphony workspace root.
- [ ] Ensure Codex cwd is the worktree path, never the original repo path.
- [ ] Reject or safely handle branch/worktree conflicts.
- [ ] Preserve same-event retry behavior without creating duplicate worktrees.

## Lifecycle metadata

- [ ] Record workspace lifecycle metadata for event ID, run ID, repo/change, workspace path, branch, base commit, commit SHA, PR URL, status, and timestamps.
- [ ] Surface worktree path/branch/status in Studio Runner event/status payloads.
- [ ] Preserve metadata after worktree removal.

## Cleanup

- [ ] Implement Git-aware worktree removal using `git worktree remove` and `git worktree prune`.
- [ ] Add PR-state inspection for merged/closed PR cleanup when `gh` auth/tooling is available.
- [ ] Add TTL rules for blocked/failed/abandoned inactive worktrees.
- [ ] Ensure cleanup refuses active, unknown, outside-root, or source-repo paths.
- [ ] Add bounded cleanup errors to status payloads.

## Tests and validation

- [ ] Test that a Studio Runner run creates a worktree from a fetched remote default branch.
- [ ] Test that the original repo is not mutated and Codex cwd is the worktree.
- [ ] Test same-event retry reuse does not create duplicate worktrees.
- [ ] Test a new event does not reuse an arbitrary inactive workspace.
- [ ] Test merged/closed/blocked cleanup eligibility and safe removal behavior.
- [ ] Run `mix test`.
- [ ] Run `mix specs.check`.
- [ ] Run `openspec validate use-git-worktrees-for-studio-runner-workspaces`.
- [ ] Run `openspec validate --all`.
