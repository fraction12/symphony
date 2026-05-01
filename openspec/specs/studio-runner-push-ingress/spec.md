# studio-runner-push-ingress Specification

## Purpose
Define the signed push ingress contract that lets OpenSpec Studio dispatch
`build.requested` work directly to Studio Runner without tracker polling,
including verification, deduplication, dispatch, and bounded response metadata.
## Requirements
### Requirement: Signed Studio Runner event ingress
Studio Runner SHALL expose a push ingress endpoint for OpenSpec Studio `build.requested` events and verify each request before accepting work.

#### Scenario: Valid build request is accepted
- **GIVEN** Studio Runner is configured with a signing secret
- **AND** a request includes `webhook-id`, `webhook-timestamp`, and `webhook-signature` headers
- **AND** the HMAC-SHA256 signature matches `webhook-id.webhook-timestamp.raw-body`
- **AND** the timestamp is within the configured replay window
- **AND** the payload type is `build.requested`
- **WHEN** the request is posted to the Studio Runner event ingress
- **THEN** Studio Runner SHALL accept the event for dispatch
- **AND** Studio Runner SHALL return a bounded machine-readable response

#### Scenario: Invalid signature is rejected
- **GIVEN** a request has a missing, malformed, or non-matching webhook signature
- **WHEN** the request is posted to the Studio Runner event ingress
- **THEN** Studio Runner SHALL reject the request before claiming or dispatching work
- **AND** Studio Runner SHALL NOT launch an agent run

#### Scenario: Stale timestamp is rejected
- **GIVEN** a request timestamp is outside the configured replay window
- **WHEN** the request is posted to the Studio Runner event ingress
- **THEN** Studio Runner SHALL reject the request before claiming or dispatching work
- **AND** Studio Runner SHALL NOT launch an agent run

#### Scenario: Unsupported event type is rejected
- **GIVEN** a signed request uses an event type other than `build.requested`
- **WHEN** the request is posted to the Studio Runner event ingress
- **THEN** Studio Runner SHALL reject the request as unsupported
- **AND** Studio Runner SHALL NOT launch an agent run

#### Scenario: Unknown repository path is rejected
- **GIVEN** a signed request identifies a repository path that does not exist on the runner host
- **WHEN** the request is posted to the Studio Runner event ingress
- **THEN** Studio Runner SHALL reject the request before claiming or dispatching work
- **AND** Studio Runner SHALL NOT launch an agent run

### Requirement: OpenSpec push dispatch bypasses tracker polling
Studio Runner SHALL process OpenSpec Studio dispatch through a push path that does not require Linear configuration, tracker polling, or OpenSpec-as-tracker-adapter behavior.

#### Scenario: Build request does not require Linear
- **GIVEN** Studio Runner receives a valid `build.requested` event
- **AND** Linear credentials are not configured
- **WHEN** Studio Runner accepts the event
- **THEN** Studio Runner SHALL NOT require Linear credentials for the OpenSpec dispatch path
- **AND** Studio Runner SHALL NOT wait for a tracker polling cycle before dispatching accepted work

#### Scenario: OpenSpec change is adapted into runner work
- **GIVEN** Studio Runner accepts a valid `build.requested` event identifying one repository and one OpenSpec change
- **WHEN** the event is handed to the orchestrator
- **THEN** Studio Runner SHALL adapt the event into runner-owned work metadata
- **AND** Studio Runner SHALL preserve the repository path, change name, event ID, validation metadata, and artifact path metadata needed by the agent prompt

### Requirement: Idempotent dispatch and duplicate run protection
Studio Runner SHALL make repeated delivery safe by deduplicating event IDs and preventing concurrent duplicate runs for the same repository/change pair.

#### Scenario: Duplicate event ID does not start a second run
- **GIVEN** Studio Runner has already accepted a `build.requested` event with a specific event ID
- **WHEN** the same event ID is delivered again
- **THEN** Studio Runner SHALL NOT launch a second agent run
- **AND** Studio Runner SHALL return the existing accepted or run status when available

#### Scenario: Same repository and change already running blocks duplicate work
- **GIVEN** an agent run is already active for a repository/change pair
- **WHEN** Studio Runner receives a different valid event for the same repository/change pair
- **THEN** Studio Runner SHALL NOT launch a concurrent duplicate agent run for that repository/change pair
- **AND** Studio Runner SHALL return a bounded conflict or existing-run response

### Requirement: Accepted work uses existing runner execution machinery
Studio Runner SHALL execute accepted OpenSpec Studio work through Symphony's runner machinery for isolated workspaces and Codex agent sessions.

#### Scenario: Accepted work is handed to orchestrator
- **GIVEN** Studio Runner has verified, deduplicated, and claimed a `build.requested` event
- **WHEN** the event is ready for execution
- **THEN** Studio Runner SHALL hand the work to an orchestrator push-dispatch entrypoint
- **AND** Studio Runner SHALL execute agent work asynchronously rather than blocking the ingress request until completion

#### Scenario: Agent run uses isolated workspace flow
- **GIVEN** accepted OpenSpec Studio work has been dispatched
- **WHEN** Studio Runner launches the agent
- **THEN** Studio Runner SHALL use the configured isolated workspace creation flow
- **AND** Studio Runner SHALL run the existing AgentRunner/Codex execution path or an equivalent runner path with the same workspace-safety guarantees

### Requirement: Runner health and response contract
Studio Runner SHALL expose enough bounded status information for OpenSpec Studio to determine reachability and record dispatch state.

#### Scenario: Health endpoint reports runner readiness
- **WHEN** OpenSpec Studio checks Studio Runner health
- **THEN** Studio Runner SHALL return a bounded machine-readable health response
- **AND** the response SHALL indicate whether the push ingress is configured to accept signed dispatch

#### Scenario: Accepted response includes event and run metadata
- **GIVEN** Studio Runner accepts a `build.requested` event
- **WHEN** Studio Runner responds to the ingress request
- **THEN** the response SHALL include the event ID
- **AND** the response SHALL include the repository/change identity
- **AND** the response SHOULD include a run ID when one is available synchronously
