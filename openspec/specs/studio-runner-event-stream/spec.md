# studio-runner-event-stream Specification

## Purpose
TBD - created by archiving change add-studio-runner-event-stream. Update Purpose after archive.
## Requirements
### Requirement: Studio Runner exposes a metadata event stream
Symphony SHALL expose a read-only Server-Sent Events stream for Studio Runner execution updates.

#### Scenario: Client opens the stream
- **GIVEN** Symphony's local HTTP server is running
- **WHEN** a client sends `GET /api/v1/studio-runner/events/stream`
- **THEN** Symphony SHALL respond with an SSE-compatible `text/event-stream` response
- **AND** the stream SHALL emit bounded JSON event payloads for Studio Runner events

### Requirement: Stream emits current and subsequent Studio Runner state
The event stream SHALL provide enough state for OpenSpec Studio to render live build-request status without polling.

#### Scenario: Initial snapshot is available
- **GIVEN** Studio Runner has recorded one or more execution events
- **WHEN** a client connects to the stream
- **THEN** Symphony SHALL emit the current Studio Runner event state
- **AND** each payload SHOULD include event ID, run ID, status, repo/change identity, recorded timestamp, and available publication metadata such as workspace path, session ID, branch name, commit SHA, PR URL, and error

#### Scenario: Runner state changes after connect
- **GIVEN** a client is connected to the stream
- **WHEN** Studio Runner accepts, updates, completes, blocks, or fails work
- **THEN** Symphony SHALL publish a new metadata event to the stream without requiring Studio to poll `/api/v1/state`

### Requirement: Stream remains metadata-only
The event stream SHALL NOT expose raw Codex logs or repository contents.

#### Scenario: Execution metadata is streamed
- **GIVEN** a Studio Runner execution produced status metadata
- **WHEN** Symphony emits a stream event
- **THEN** the payload SHALL be limited to bounded control/status metadata
- **AND** it SHALL NOT include raw prompts, raw Codex logs, full OpenSpec artifact contents, diffs, or arbitrary repository file contents

