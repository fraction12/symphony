# Design: Studio Runner event stream

## Transport

Use Server-Sent Events (SSE):

```http
GET /api/v1/studio-runner/events/stream
Accept: text/event-stream
```

SSE is enough because the data flow is one-way from the local runner to Studio. It avoids a Studio-side HTTP listener and is simpler than WebSockets.

## Event model

The first implementation emits Studio Runner execution snapshots as JSON payloads. Suggested SSE event names:

- `runner.snapshot` for the initial current state after connect
- `runner.running`
- `runner.completed`
- `runner.blocked`
- `runner.failed`
- `runner.accepted` when a request has been accepted but not yet enriched

Each event payload should be bounded and include only metadata:

```json
{
  "eventId": "evt_...",
  "runId": "run_...",
  "repoChangeKey": "/repo::change-name",
  "status": "completed",
  "workspacePath": "...",
  "sessionId": "...",
  "branchName": "...",
  "commitSha": "...",
  "prUrl": "https://github.com/...",
  "error": null,
  "recordedAt": "2026-04-29T...Z"
}
```

## Source of truth

Use the existing orchestrator snapshot/presenter projection as the source of stream payloads. This keeps the SSE contract aligned with `/api/v1/state` and dashboard state.

## Broadcast trigger

Reuse the existing observability PubSub update signal. Orchestrator already notifies dashboard subscribers when Studio Runner events are accepted and when result metadata changes. The stream controller can subscribe to that signal, fetch the latest presenter state, and emit Studio Runner events.

## Security and boundaries

- Stream is read-only.
- Stream exposes bounded metadata only.
- It does not include raw agent logs, full prompts, OpenSpec file contents, diffs, or repo file contents.
- Alpha deployment remains localhost-focused through the existing runner server binding.
