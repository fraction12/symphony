## 1. Contract and Configuration

- [x] 1.1 Define Studio Runner endpoint paths for event ingress and health/status.
- [x] 1.2 Define configuration fields for enabling Studio Runner push ingress and supplying the signing secret.
- [x] 1.3 Define the `build.requested` payload decoder and normalized runner work metadata.
- [x] 1.4 Define bounded success, duplicate, conflict, unsupported, and verification-failure response bodies.
- [x] 1.5 Decide whether v1 uses in-memory or persisted idempotency/claim storage.
- [x] 1.6 Decide whether internal dispatch initially reuses issue-shaped metadata or introduces a dedicated work-item struct.

## 2. Verification and Ingress

- [x] 2.1 Add Standard Webhooks-style header parsing for `webhook-id`, `webhook-timestamp`, and `webhook-signature`.
- [x] 2.2 Implement HMAC-SHA256 verification over `webhook-id.webhook-timestamp.raw-body` using constant-time comparison.
- [x] 2.3 Reject missing headers, malformed signatures, unsupported signature versions, stale timestamps, and unknown repo paths before work claims.
- [x] 2.4 Add Phoenix route/controller for `POST /api/v1/studio-runner/events`.
- [x] 2.5 Add health/status endpoint for Studio reachability checks.

## 3. Dispatch and Orchestration

- [x] 3.1 Add an orchestrator push-dispatch entrypoint for externally supplied Studio Runner work.
- [x] 3.2 Add event ID deduplication before agent launch.
- [x] 3.3 Add repository/change in-flight claim protection before agent launch.
- [x] 3.4 Adapt accepted OpenSpec payloads into runner work metadata and agent prompt context.
- [ ] 3.5 Route accepted work through isolated workspace creation and AgentRunner/Codex execution. Deferred behind `StudioRunner.Executor` seam in this vertical slice; endpoint now verifies, claims, dedupes, and hands off asynchronously without blocking the ingress request.
- [x] 3.6 Ensure push-dispatched work does not require Linear credentials or tracker polling.
- [x] 3.7 Return accepted, duplicate, or conflict responses with bounded machine-readable metadata.

## 4. Tests

- [x] 4.1 Add tests for valid signature acceptance.
- [x] 4.2 Add tests for missing/malformed/invalid signature rejection.
- [x] 4.3 Add tests for stale timestamp rejection.
- [x] 4.4 Add tests for unsupported event type rejection.
- [x] 4.5 Add tests proving duplicate event IDs do not start second runs.
- [x] 4.6 Add tests proving concurrent duplicate repo/change dispatch is blocked.
- [x] 4.7 Add tests proving Linear config is not required for push-dispatched OpenSpec work.
- [x] 4.8 Add tests for bounded response/error bodies.
- [x] 4.9 Add test proving unknown repo paths are rejected before dispatch.

## 5. Documentation and Validation

- [x] 5.1 Document Studio Runner push ingress setup, endpoint, secret, and replay window.
- [x] 5.2 Document that OpenSpec Studio dispatch bypasses Linear polling and tracker adapters.
- [x] 5.3 Document response semantics for accepted, duplicate, conflict, and rejected events.
- [x] 5.4 Run OpenSpec validation for the change and all specs.
- [ ] 5.5 Run Elixir format/test checks after implementation. Blocked in the current environment because `elixir`/`mix` are unavailable on PATH; must run before merging/publishing implementation commit.
