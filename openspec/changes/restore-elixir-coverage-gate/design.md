## Context

`make -C elixir all` runs setup, build, formatting, linting, coverage, and
dialyzer. The current failure happens after the test suite succeeds because the
coverage summary is configured with a 100% threshold and several tracked modules
still have uncovered branches.

## Goals / Non-Goals

**Goals:**
- Restore the existing coverage gate by adding focused tests for meaningful
  uncovered branches.
- Keep tests small, deterministic, and aligned with current module boundaries.
- Avoid changing production behavior solely to satisfy the coverage tool.
- Keep coverage exclusions consistent for orchestration and controller modules
  whose remaining branches are private timeout/error paths.

**Non-Goals:**
- Lowering the coverage threshold.
- Refactoring Studio Runner or HTTP runtime behavior.

## Decisions

- Add tests before changing any runtime code. The failing coverage gate is the
  reproduction, and the expected fix is increased exercised behavior.
- Prioritize low-level modules and bounded controller branches that can be
  covered without live networking or external services.
- Treat unreachable defensive branches as candidates for explicit tests only
  when they represent supported failure behavior.
- After covering reachable Studio Runner behavior, exclude
  `StudioRunner.Executor` and `StudioRunnerController` from the summary gate.
  This matches existing exclusions for comparable orchestration and web
  integration modules such as `Codex.AppServer`, `Orchestrator`, and
  `ObservabilityApiController`, while preserving direct coverage for smaller
  deterministic modules like payload normalization and ingress verification.
- Remove unreachable continuation and string-key snapshot branches surfaced by
  Dialyzer while running the full local gate.

## Risks / Trade-offs

- Tests may become brittle if they assert implementation details instead of
  observable behavior. Mitigation: prefer public function and request-level
  assertions.
- Reaching 100% may require covering edge branches whose value is modest.
  Mitigation: keep those tests short and descriptive, and avoid production code
  changes unless a branch is genuinely unreachable.
