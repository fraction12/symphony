# Tasks

## 1. Specification

- [x] Define SSE endpoint and payload requirements
- [x] Define metadata-only safety boundary

## 2. Symphony implementation

- [x] Add a Studio Runner SSE stream endpoint
- [x] Emit initial snapshot events on connect
- [x] Subscribe to Studio Runner/dashboard updates and emit subsequent events
- [x] Keep stream payloads bounded and metadata-only

## 3. Tests and validation

- [x] Add tests for SSE content type and initial snapshot framing
- [x] Add tests that stream payloads include PR/publication metadata
- [x] Run formatter, tests, specs check, and OpenSpec validation
