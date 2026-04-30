## ADDED Requirements

### Requirement: Studio Runner uses Git worktrees for execution workspaces
Studio Runner SHALL prepare per-run execution workspaces as Git worktrees derived from the Studio-selected source repository rather than creating a fresh full repository copy for every run.

#### Scenario: Worktree is created from fetched remote default branch
- **GIVEN** Studio dispatches a valid run for a local Git repository
- **WHEN** Symphony prepares the execution workspace
- **THEN** Symphony SHALL fetch the repository remote
- **AND** Symphony SHALL identify the remote default branch
- **AND** Symphony SHALL create a per-run Git worktree from the fetched remote default branch
- **AND** the worktree SHALL use a deterministic Studio Runner branch name

#### Scenario: Codex runs only inside the worktree
- **GIVEN** Symphony has created a Studio Runner worktree
- **WHEN** Codex execution starts
- **THEN** Codex SHALL use the worktree path as its current working directory
- **AND** Codex SHALL NOT use the original source repository as its working directory

### Requirement: Studio Runner avoids arbitrary workspace reuse
Studio Runner SHALL NOT reuse arbitrary inactive workspaces for new run events.

#### Scenario: New event receives isolated worktree
- **GIVEN** an inactive worktree exists from a previous Studio Runner event
- **WHEN** a new accepted event is prepared
- **THEN** Symphony SHALL create a distinct worktree for the new event
- **AND** Symphony SHALL NOT reuse the inactive worktree unless the operator explicitly requests a future clean-reuse action

#### Scenario: Same event retry may reuse same worktree
- **GIVEN** a retry uses the same event ID and run identity
- **AND** the existing worktree is still present and not actively owned by another process
- **WHEN** Symphony retries the run
- **THEN** Symphony MAY reuse the same worktree
- **AND** Symphony SHALL preserve the existing run history and idempotency identity

### Requirement: Studio Runner tracks workspace lifecycle metadata
Studio Runner SHALL track enough per-run workspace metadata to support status display and safe cleanup.

#### Scenario: Workspace metadata is recorded
- **GIVEN** Symphony creates a Studio Runner worktree
- **WHEN** the run status is recorded
- **THEN** the status payload SHALL include the event ID, run ID, repository/change identity, workspace path, branch name, and lifecycle status when available
- **AND** the metadata SHOULD include base commit SHA, produced commit SHA, PR URL, PR state, PR merge timestamp, PR close timestamp, lifecycle timestamps, and bounded cleanup errors when available

#### Scenario: Metadata survives cleanup
- **GIVEN** a Studio Runner worktree has been removed safely
- **WHEN** Studio Runner status is requested later
- **THEN** Symphony SHALL preserve bounded metadata about the run
- **AND** Symphony SHALL NOT require the deleted worktree directory to display branch, PR, terminal status, or cleanup result

### Requirement: Studio Runner cleans up inactive worktrees safely
Studio Runner SHALL provide PR-aware and TTL-aware cleanup for inactive Studio Runner worktrees.

#### Scenario: Merged PR workspace becomes cleanup eligible
- **GIVEN** a Studio Runner run produced a PR URL
- **AND** the PR has been merged
- **WHEN** cleanup runs
- **THEN** Symphony SHALL mark the associated worktree cleanup eligible
- **AND** Symphony MAY remove the worktree using Git-aware removal
- **AND** Symphony SHALL preserve run metadata after removal

#### Scenario: Closed PR workspace is retained until the cleanup TTL expires
- **GIVEN** a Studio Runner run produced a PR URL
- **AND** the PR has been closed
- **WHEN** cleanup runs
- **THEN** Symphony SHALL retain the associated worktree until the closed PR retention TTL expires
- **AND** Symphony SHALL surface that the closed PR retention TTL is still active

#### Scenario: Closed PR workspace becomes cleanup eligible after TTL
- **GIVEN** a Studio Runner run produced a PR URL
- **AND** the PR has been closed
- **AND** the closed PR retention TTL has expired
- **WHEN** cleanup runs
- **THEN** Symphony SHALL mark the associated worktree cleanup eligible
- **AND** Symphony MAY remove the worktree using Git-aware removal
- **AND** Symphony SHALL preserve run metadata after removal

#### Scenario: Open PR workspace is retained
- **GIVEN** a Studio Runner run produced a PR URL
- **AND** the PR is still open
- **WHEN** cleanup evaluates the workspace
- **THEN** Symphony SHALL retain the worktree
- **AND** Symphony SHALL surface that the PR is still open

#### Scenario: Blocked or failed workspace is retained temporarily
- **GIVEN** a Studio Runner run ended blocked or failed
- **WHEN** cleanup evaluates the workspace
- **THEN** Symphony SHALL retain the worktree for a debugging TTL
- **AND** Symphony SHALL NOT delete it immediately unless explicitly requested by a safe cleanup action

#### Scenario: Cleanup refuses unsafe paths
- **GIVEN** cleanup is asked to remove a workspace path
- **WHEN** the path is active, unknown, outside the configured workspace root, or equal to the source repository
- **THEN** Symphony SHALL refuse cleanup
- **AND** Symphony SHALL record a bounded cleanup error instead of deleting the path

### Requirement: Studio Runner publishes before completion
Studio Runner SHALL continue to treat reviewable publication as the completion boundary for worktree-backed runs.

#### Scenario: Completed run has PR URL
- **GIVEN** Codex has made changes in a Studio Runner worktree
- **WHEN** Symphony inspects terminal run state
- **THEN** Symphony SHALL treat the run as completed only if a PR URL is available
- **AND** Symphony SHALL expose the branch, commit SHA, and PR URL when available

#### Scenario: Local-only work remains blocked
- **GIVEN** Codex made local changes or commits in the worktree
- **AND** no PR URL is available because push or PR creation is blocked
- **WHEN** Symphony inspects terminal run state
- **THEN** Symphony SHALL mark the run blocked rather than completed
