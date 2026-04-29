## Why

OpenSpec Studio needs a first-class way to hand one selected OpenSpec change to the Studio-owned Symphony fork without relying on Linear, tracker polling, or manual Symphony wiring. The inspected Symphony implementation already has useful orchestration, workspace, and Codex agent-runner machinery, but its current intake model is Linear polling; Studio Runner needs an explicit signed push ingress instead.

## What Changes

- Add a Studio Runner push ingress for signed `build.requested` events from OpenSpec Studio.
- Accept only explicit, human-triggered, one-change-at-a-time dispatch from Studio.
- Verify Standard Webhooks-style request headers, timestamp freshness, and HMAC-SHA256 signatures before accepting work.
- Deduplicate events by stable event ID/idempotency key and prevent duplicate concurrent runs for the same repo/change pair.
- Adapt accepted OpenSpec repo/change payloads into Symphony-owned runner work without treating OpenSpec as a tracker adapter.
- Reuse Symphony's existing orchestrator, workspace isolation, and AgentRunner/Codex execution path behind the new ingress.
- Expose bounded acceptance/status responses so Studio can record delivery state and optional run IDs.
- Keep existing Linear polling behavior available for upstream compatibility, but make it separate from the OpenSpec Studio path.

## Capabilities

### New Capabilities
- `studio-runner-push-ingress`: Signed push ingress, idempotent acceptance, and runner dispatch contract for OpenSpec Studio `build.requested` events.

### Modified Capabilities
- None.

## Impact

- Phoenix router/controller/API surface for `POST /api/v1/studio-runner/events` and a minimal health/status endpoint.
- New signature verification, replay-window, event decoding, and idempotency/claiming logic.
- Orchestrator entrypoint for externally pushed work, distinct from the current polling/tracker path.
- Work metadata/adaptation layer for OpenSpec repo/change payloads.
- Tests for signature validation, stale timestamp rejection, malformed payloads, duplicate event handling, duplicate repo/change in-flight blocking, and dispatch handoff.
- Documentation/config updates for Studio Runner endpoint, secret, and OpenSpec-only dispatch path.
