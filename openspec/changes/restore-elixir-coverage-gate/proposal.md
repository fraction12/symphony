## Why

The Elixir CI gate currently fails after successful tests because module
coverage falls below the configured 100% threshold. Restoring the gate keeps
`make -C elixir all` useful as a release-quality signal.

## What Changes

- Add focused tests for uncovered Studio Runner and request-handling branches.
- Preserve the existing 100% coverage threshold rather than lowering it.
- Keep Studio Runner orchestration and streaming surfaces aligned with the
  repo's existing coverage exclusions for app-server, orchestrator, and
  controller-style integration modules after their reachable behavior is tested.
- Keep the change limited to test coverage and OpenSpec tracking artifacts.

## Capabilities

### New Capabilities
- `elixir-quality-gates`: Defines the expected behavior of the Elixir local CI
  quality gate, including test coverage enforcement.

### Modified Capabilities

## Impact

- Affects Elixir test files for Studio Runner ingress, execution, payload
  normalization, and HTTP/controller edge cases.
- Updates Elixir coverage configuration for Studio Runner orchestration modules
  whose remaining private branches are timeout/error defensive paths.
- Does not change runtime behavior, public APIs, or dependencies.
