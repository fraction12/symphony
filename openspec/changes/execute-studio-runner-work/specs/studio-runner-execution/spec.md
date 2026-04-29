## ADDED Requirements

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
