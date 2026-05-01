## Context

The current Symphony fork is an Elixir/OTP service built around polling Linear. `SymphonyElixir.Orchestrator` periodically fetches candidate tracker issues, reconciles running work, applies capacity/routing checks, then spawns `AgentRunner` tasks through `Task.Supervisor`. `AgentRunner` creates an isolated workspace, starts Codex app-server sessions, and continues turns according to workflow policy. That machinery is valuable.

The intake shape is the mismatch. OpenSpec Studio is not a tracker and should not be polled. Studio is the human/operator control plane: a user selects one active OpenSpec change and presses **Build with agent**. Studio then sends a signed `build.requested` event to Studio Runner. Runner should verify, dedupe, claim, and dispatch that exact change.

## Goals / Non-Goals

**Goals:**

- Add a push API that receives OpenSpec Studio `build.requested` events.
- Keep dispatch explicit, signed, idempotent, and one-change-at-a-time.
- Bypass Linear/tracker polling for the OpenSpec path.
- Reuse existing orchestrator/workspace/AgentRunner/Codex execution machinery.
- Return bounded acceptance/status data that Studio can store locally.
- Preserve existing Linear polling behavior for compatibility.

**Non-Goals:**

- Do not make OpenSpec changes appear as Linear issues or tracker records discovered by polling.
- Do not add automatic background discovery of OpenSpec changes.
- Do not accept arbitrary event types in v1; only `build.requested` is in scope.
- Do not include full repository file contents in the webhook payload.
- Do not replace Studio's validation/eligibility checks; Runner still verifies what it needs before execution.
- Do not build hosted relay/cloud control plane behavior.

## Decisions

### 1. Add a push ingress alongside the tracker path

Studio Runner SHALL add a Phoenix endpoint such as:

```http
POST /api/v1/studio-runner/events
```

This endpoint is the OpenSpec Studio intake path. It should not call tracker polling, require Linear config, or wait for the next poll cycle. It should verify the request and hand accepted work directly to a push-dispatch entrypoint in the orchestrator.

Alternative considered: implement an OpenSpec tracker adapter. Rejected because the Studio path is user-triggered push dispatch, not continuous work discovery. A tracker adapter would preserve the wrong mental model and drag polling semantics into the product.

### 2. Use Standard Webhooks-style request verification

Studio sends:

```http
webhook-id: evt_...
webhook-timestamp: 1710000000
webhook-signature: v1,<base64-hmac-sha256>
content-type: application/json
```

The signature base string is:

```text
webhook-id.webhook-timestamp.raw-body
```

Runner verifies with a configured shared secret, constant-time comparison, and a default five-minute replay window. Requests with missing headers, malformed timestamps, stale timestamps, invalid signatures, or unsupported signature versions are rejected before any work claim occurs.

### 3. Keep payload thin and repository-scoped

The payload uses a CloudEvents-like shape:

```json
{
  "id": "evt_01j...",
  "type": "build.requested",
  "source": "openspec-studio",
  "time": "2026-04-29T12:40:10Z",
  "data": {
    "runner": "studio-runner",
    "repoPath": "/path/to/repo",
    "repoName": "openspec-studio",
    "repoRemote": "git@github.com:fraction12/openspec-studio.git",
    "gitRef": "main",
    "change": "introduce-studio-runner",
    "artifactPaths": [
      "openspec/changes/introduce-studio-runner/proposal.md",
      "openspec/changes/introduce-studio-runner/design.md",
      "openspec/changes/introduce-studio-runner/tasks.md"
    ],
    "validation": {
      "state": "passed",
      "checkedAt": "2026-04-29T12:40:00Z"
    },
    "requestedBy": "local-user"
  }
}
```

Runner should treat repo path, change name, and artifact paths as identifiers/metadata, not trusted proof of correctness. After accepting and claiming the work, Runner or the spawned agent reads the repository directly from the isolated workspace.

### 4. Deduplicate event IDs and claim repo/change pairs

Delivery is at-least-once. Studio may retry a failed delivery with the same event ID/idempotency key. Runner MUST dedupe by event ID and MUST avoid launching duplicate concurrent runs for the same repository/change pair.

Recommended behavior:

- duplicate event ID already accepted: return the existing accepted/run status if available;
- same repo/change already running under a different event ID: reject with a conflict-style response or no-op acceptance that references the existing run;
- invalid/stale/signature-failed event: reject without recording a run claim.

### 5. Add an orchestrator push-dispatch entrypoint

The orchestrator needs an explicit function/message for external work, for example:

```elixir
SymphonyElixir.Orchestrator.dispatch_external_work(work, opts \\ [])
```

or a GenServer call/cast with equivalent semantics. It should apply capacity and duplicate-run checks comparable to the existing issue dispatch path, then spawn the runner using the existing `Task.Supervisor` / `AgentRunner` mechanics.

The internal representation can initially reuse the existing issue-shaped metadata if that is the smallest safe step, but the public API should name the domain as Studio Runner work, not tracker issues. A dedicated `WorkItem` model is cleaner if implementation cost stays modest.

### 6. Return bounded response data

On success, Runner should return `202 Accepted` or similar with a bounded JSON body:

```json
{
  "status": "accepted",
  "eventId": "evt_01j...",
  "runId": "run_01j...",
  "repoPath": "/path/to/repo",
  "change": "introduce-studio-runner"
}
```

Failures should also be bounded and machine-readable enough for Studio to display delivery state without leaking secrets or huge logs.

## Risks / Trade-offs

- **Risk: Force-fitting OpenSpec into existing Linear issue structs creates confusing abstractions.** → Prefer a `WorkItem` model if practical; if reusing issue-shaped metadata initially, keep it private and document the migration path.
- **Risk: Duplicate dispatch can spawn duplicate agents.** → Deduplicate by event ID and claim repo/change before spawning.
- **Risk: Signed requests leak secrets into logs.** → Never log signing secrets or raw signature material; bound request/error logging.
- **Risk: Local repo paths are dangerous if trusted blindly.** → Validate/canonicalize paths and constrain workspace creation to configured roots where possible.
- **Risk: Existing polling loop and push dispatch contend for capacity.** → Reuse global/worker capacity checks and expose clear conflict responses.
- **Risk: Long-running controller request.** → Endpoint should accept/enqueue quickly and return; agent work happens asynchronously.

## Migration Plan

1. Add OpenSpec Studio runner config fields for endpoint/secret on the Symphony side.
2. Add signature verification and payload normalization modules with unit tests.
3. Add idempotency/claim storage in memory first, matching current orchestrator state style.
4. Add orchestrator push-dispatch entrypoint and route accepted work to AgentRunner.
5. Add Phoenix endpoint and health/status response.
6. Add integration tests for signed request acceptance and duplicate behavior.
7. Document that Linear polling remains separate and is not required for Studio Runner.

Rollback: disable or remove the Studio Runner endpoint without changing existing Linear polling behavior.

## Open Questions

- Should v1 persist idempotency records across process restarts, or is in-memory acceptable for the first local alpha?
- Should the internal work model reuse existing `Issue` fields temporarily or introduce a dedicated `StudioRunner.WorkItem` immediately?
- What configured root restrictions should apply to incoming `repoPath` values?
- Should accepted responses always include a run ID synchronously, or can run ID be unavailable until the orchestrator claims the work?
