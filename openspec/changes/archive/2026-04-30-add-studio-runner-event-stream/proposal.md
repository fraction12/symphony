# Proposal: Add Studio Runner event stream

## Problem

OpenSpec Studio can dispatch signed `build.requested` events and Symphony can now execute them, inspect publication state, and expose run metadata through status payloads. Studio still has no live way to receive completion, blocked, failed, PR URL, branch, commit, workspace, or session metadata after the initial `202 Accepted` response.

Manual refresh of `/api/v1/state` would work, but it reintroduces polling behavior and makes the Studio Runner feel stale.

## Change

Expose a local Server-Sent Events stream from Symphony for Studio Runner execution events.

The stream is read-only, local observability/control metadata only, and does not include raw Codex logs or repository contents. It should emit an initial snapshot and then publish updates whenever Studio Runner state changes.

## Scope

- Add `GET /api/v1/studio-runner/events/stream`.
- Use SSE framing with bounded JSON event payloads.
- Emit current Studio Runner event snapshots on connect.
- Broadcast updates when Studio Runner state changes.
- Include execution/publication fields already exposed by Symphony: event ID, run ID, repo/change identity, status, workspace path, session ID, branch name, commit SHA, PR URL, error, and recorded timestamp.
- Add controller/stream tests.

## Non-goals

- No Studio UI/Tauri ingestion in this change.
- No raw Codex log streaming.
- No arbitrary repo file contents.
- No WebSocket protocol.
- No cross-machine/public network stream support.
