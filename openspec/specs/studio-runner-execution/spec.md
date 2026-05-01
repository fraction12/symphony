# studio-runner-execution Specification

## Purpose
Define how Studio Runner accepts OpenSpec Studio work, prepares isolated
execution workspaces, launches Codex agent runs, publishes reviewable output,
reports execution status, and safely manages workspace lifecycle cleanup.
## Requirements
### Requirement: Accepted Studio Runner work starts an agent run
Studio Runner SHALL turn accepted OpenSpec Studio `build.requested` work into an asynchronous Codex agent run.

#### Scenario: Accepted event launches execution
- **GIVEN** Studio Runner has accepted and claimed a valid `build.requested` event
- **WHEN** the event is handed to the Studio Runner executor
- **THEN** Studio Runner SHALL start an asynchronous agent execution path
- **AND** the ingress response SHALL NOT wait for agent completion
- **AND** the run SHALL be associated with the accepted event ID and run ID

### Requirement: Studio Runner execution uses a Symphony-managed workspace
Studio Runner SHALL execute OpenSpec Studio work in a Symphony-managed workspace derived from the target repository rather than mutating the original repository directly.

#### Scenario: Workspace is created for selected change
- **GIVEN** accepted work identifies a local repository and one OpenSpec change
- **WHEN** Studio Runner prepares execution
- **THEN** Studio Runner SHALL create a Symphony-managed workspace for that repo/change/run
- **AND** Codex SHALL run with that workspace as its current working directory
- **AND** Studio Runner SHALL NOT use the original repository path as the Codex working directory

#### Scenario: Missing change artifacts stop execution before Codex launch
- **GIVEN** accepted work identifies a change whose required OpenSpec artifacts are missing from the prepared workspace
- **WHEN** Studio Runner prepares execution
- **THEN** Studio Runner SHALL fail the run before launching Codex
- **AND** Studio Runner SHALL record a bounded failure reason

### Requirement: Studio Runner prompt is OpenSpec-native
Studio Runner SHALL use an OpenSpec-native workflow prompt from repository artifacts and SHALL NOT require Linear issue context for OpenSpec Studio work.

#### Scenario: Prompt includes OpenSpec change context
- **GIVEN** a Symphony-managed workspace contains the selected OpenSpec change
- **WHEN** Studio Runner builds the agent prompt
- **THEN** the prompt SHALL include the proposal, tasks, available design notes, and spec deltas for the selected change
- **AND** the prompt SHALL instruct the agent to work only in the Symphony-managed workspace
- **AND** the prompt SHALL instruct the agent to update task status only for completed work

#### Scenario: Prompt does not require Linear
- **GIVEN** Studio Runner is executing OpenSpec Studio work
- **WHEN** the prompt is built
- **THEN** the prompt SHALL NOT require Linear credentials, Linear MCP, tracker comments, or Linear issue state

### Requirement: Studio Runner workspaces are predictable and configurable
Studio Runner SHALL place managed workspaces under a predictable workspace root and SHALL avoid machine-specific defaults.

#### Scenario: Default workspace root is user-home based
- **GIVEN** Studio Runner is installed with default settings
- **WHEN** it creates a managed workspace
- **THEN** the workspace root SHALL be a predictable user-home location such as `~/Symphony Workspaces`
- **AND** it SHALL NOT default to a machine-specific project path such as `/Volumes/MacSSD/Projects`

#### Scenario: Studio controls workspace location later
- **GIVEN** Studio exposes runner workspace settings
- **WHEN** the user chooses a workspace storage location
- **THEN** Symphony SHALL use that configured root for future managed workspaces

### Requirement: Studio Runner work publishes reviewable output
Studio Runner SHALL guide agents to publish completed OpenSpec work as a branch and pull request when required tools and permissions are available.

#### Scenario: Agent publishes completed work
- **GIVEN** Studio Runner work has completed implementation and validation
- **AND** GitHub or equivalent remote publishing credentials are available
- **WHEN** the agent finalizes the run
- **THEN** the agent SHALL commit work on a deterministic branch
- **AND** the agent SHALL push the branch
- **AND** the agent SHALL open a pull request for human review
- **AND** Symphony SHOULD capture the PR URL when available
- **AND** Studio SHOULD treat the run as completed only when the PR URL is available

#### Scenario: Publishing is blocked by missing auth
- **GIVEN** Studio Runner work requires branch push or PR creation
- **AND** required GitHub or remote publishing credentials are missing
- **WHEN** the agent reaches the publishing step
- **THEN** the run SHALL stop with a bounded blocker rather than silently treating local-only changes as complete

### Requirement: Studio Runner execution status is observable
Studio Runner SHALL expose bounded execution status for Studio Runner work.

#### Scenario: Running and terminal status are reported
- **GIVEN** a Studio Runner agent run has started
- **WHEN** Symphony status or dashboard payloads are requested
- **THEN** the payload SHALL include bounded Studio Runner execution status
- **AND** the status SHOULD include run ID, event ID, repository/change identity, workspace path when available, PR URL when available, and running/completed/failed state
- **AND** failure details SHALL be bounded and sanitized

### Requirement: Studio Runner execution reuses Symphony runner behavior
Studio Runner SHALL reuse Symphony's existing workspace, hook, AgentRunner, Codex app-server, and continuation behavior where those primitives are applicable.

#### Scenario: OpenSpec work follows Symphony execution lifecycle
- **GIVEN** Studio Runner has accepted OpenSpec work
- **WHEN** Symphony starts execution
- **THEN** the run SHALL use the configured workspace root and lifecycle hooks where applicable
- **AND** the run SHALL use Symphony's configured Codex command, sandbox policy, and max-turn behavior
- **AND** the run SHALL avoid Linear tracker calls for OpenSpec work

### Requirement: Studio Runner accepts dynamic repositories from Studio
Studio Runner SHALL use the repository selected by Studio as dynamic input and SHALL NOT hardcode one target repository.

#### Scenario: Dynamic repo path drives workspace preparation
- **GIVEN** Studio dispatches a valid build request for a local repository path
- **WHEN** Symphony prepares the managed workspace
- **THEN** Symphony SHALL use that repository path to discover git metadata such as remote and default branch
- **AND** Symphony SHALL clone or fetch from that remote into the managed workspace when possible
- **AND** Symphony SHALL NOT use a hardcoded repository path for Studio Runner work

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
