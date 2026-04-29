## 1. Contract and Configuration

- [ ] 1.1 Define Studio Runner endpoint paths for event ingress and health/status.
- [ ] 1.2 Define configuration fields for enabling Studio Runner push ingress and supplying the signing secret.
- [ ] 1.3 Define the `build.requested` payload decoder and normalized runner work metadata.
- [ ] 1.4 Define bounded success, duplicate, conflict, unsupported, and verification-failure response bodies.
- [ ] 1.5 Decide whether v1 uses in-memory or persisted idempotency/claim storage.
- [ ] 1.6 Decide whether internal dispatch initially reuses issue-shaped metadata or introduces a dedicated work-item struct.

## 2. Verification and Ingress

- [ ] 2.1 Add Standard Webhooks-style header parsing for `webhook-id`, `webhook-timestamp`, and `webhook-signature`.
- [ ] 2.2 Implement HMAC-SHA256 verification over `webhook-id.webhook-timestamp.raw-body` using constant-time comparison.
- [ ] 2.3 Reject missing headers, malformed signatures, unsupported signature versions, and stale timestamps before work claims.
- [ ] 2.4 Add Phoenix route/controller for `POST /api/v1/studio-runner/events`.
- [ ] 2.5 Add health/status endpoint for Studio reachability checks.

## 3. Dispatch and Orchestration

- [ ] 3.1 Add an orchestrator push-dispatch entrypoint for externally supplied Studio Runner work.
- [ ] 3.2 Add event ID deduplication before agent launch.
- [ ] 3.3 Add repository/change in-flight claim protection before agent launch.
- [ ] 3.4 Adapt accepted OpenSpec payloads into runner work metadata and agent prompt context.
- [ ] 3.5 Route accepted work through isolated workspace creation and AgentRunner/Codex execution.
- [ ] 3.6 Ensure push-dispatched work does not require Linear credentials or tracker polling.
- [ ] 3.7 Return accepted, duplicate, or conflict responses with bounded machine-readable metadata.

## 4. Tests

- [ ] 4.1 Add tests for valid signature acceptance.
- [ ] 4.2 Add tests for missing/malformed/invalid signature rejection.
- [ ] 4.3 Add tests for stale timestamp rejection.
- [ ] 4.4 Add tests for unsupported event type rejection.
- [ ] 4.5 Add tests proving duplicate event IDs do not start second runs.
- [ ] 4.6 Add tests proving concurrent duplicate repo/change dispatch is blocked.
- [ ] 4.7 Add tests proving Linear config is not required for push-dispatched OpenSpec work.
- [ ] 4.8 Add tests for bounded response/error bodies.

## 5. Documentation and Validation

- [ ] 5.1 Document Studio Runner push ingress setup, endpoint, secret, and replay window.
- [ ] 5.2 Document that OpenSpec Studio dispatch bypasses Linear polling and tracker adapters.
- [ ] 5.3 Document response semantics for accepted, duplicate, conflict, and rejected events.
- [ ] 5.4 Run OpenSpec validation for the change and all specs.
- [ ] 5.5 Run Elixir format/test checks after implementation.
