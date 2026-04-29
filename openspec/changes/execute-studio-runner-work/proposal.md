# Proposal: Execute Studio Runner work

## Summary

The existing Studio Runner ingress verifies signed `build.requested` events, deduplicates them, claims one repo/change pair, and returns `202 Accepted`. The current executor stops there. This change makes that accepted work actually run through Symphony: create a Symphony-managed workspace for the target repository/change, build an OpenSpec-native workflow prompt from the change artifacts, run Codex app-server in that workspace, and surface bounded run lifecycle status and PR metadata back through Symphony observability.

## Problem

OpenSpec Studio can now start a local Symphony runner and deliver signed build requests. Symphony can accept those requests, but `SymphonyElixir.StudioRunner.Executor.run/1` is only a handoff stub. A successful `202` therefore means "message accepted," not "agent work started."

That is misleading for the product. The next useful contract is: when Symphony accepts a Studio Runner event, it starts one actual agent run for the selected OpenSpec change in a Symphony-managed workspace derived from the target repository.

## Goals

- Execute accepted Studio Runner work without Linear polling or Linear credentials.
- Preserve the current signed/idempotent/one-change-at-a-time ingress contract.
- Keep OpenSpec Studio as the operator control plane and the OpenSpec repo as source of truth.
- Reuse Symphony's existing Codex app-server execution machinery, workspace hooks, and multi-turn run behavior instead of designing a second runner.
- Rewrite the repo-local `WORKFLOW.md` for OpenSpec Studio Runner work: remove Linear-specific instructions and make the OpenSpec change the task source.
- Use Symphony's existing workspace lifecycle and hooks wherever possible, replacing Linear issue context with OpenSpec work context.
- Build prompts from repo-local OpenSpec artifacts while preserving Symphony's proven branch/commit/push/PR workflow expectations.
- Surface bounded lifecycle information: accepted, started, workspace path, Codex session metadata when available, completed, failed, PR URL when available.
- Default Studio Runner workspaces to a predictable user-home folder, with Studio later able to configure the location.

## Non-Goals

- Do not turn OpenSpec changes into fake Linear issues or require Linear MCP.
- Do not add polling of OpenSpec repos.
- Do not make Studio send full repo contents in the webhook payload.
- Do not implement multi-agent planning or parallel subtasks in v1.
- Do not keep a Linear-mode prompt section for Studio Runner; this fork's workflow should be OpenSpec-native.
- Do not automatically merge or archive OpenSpec changes. Human review still owns merge/land decisions.
- Do not hardcode one repository path; Studio supplies the target repo path dynamically.
- Do not weaken existing workspace/path safety in order to make the first run work.

## Proposed Approach

Add a dedicated Studio Runner execution path behind the existing `StudioRunner.Executor` seam:

1. Validate and canonicalize the accepted `WorkItem` against the local repository.
2. Create a Symphony workspace for the target repo/change/run using the same lifecycle pattern as the Linear path: configured workspace root, `after_create`/`before_run`/`after_run` hooks where applicable, Codex app-server execution, and max-turn continuation semantics.
3. Default the workspace root to a user-home path such as `~/Symphony Workspaces`, while allowing Studio settings to configure a different root later.
4. Use Studio's repo path to discover the git remote/default branch, then clone/fetch into the managed workspace whenever possible. Do not hardcode the Symphony repo, OpenSpec Studio repo, or any developer-machine path.
5. Read the OpenSpec change artifacts from the prepared workspace: `proposal.md`, `design.md`, `tasks.md`, and spec deltas under `specs/`.
6. Build an OpenSpec-native workflow prompt that tells Codex this is the task source: implement the selected change, update `tasks.md`, validate, create a branch, commit, push, and open a PR according to `WORKFLOW.md`.
7. Run Codex through Symphony's normal app-server/turn loop rather than inventing a second runner lifecycle.
8. Update Symphony's Studio Runner status as the run starts, completes, fails, and when a PR URL is known.

The executor should be domain-specific at the boundary: Studio Runner work is OpenSpec work, but internally it should reuse Symphony's proven issue-run machinery where that machinery is genuinely generic.

## Decisions

- `WORKFLOW.md` should be rewritten for OpenSpec Studio Runner work in this fork; do not add a separate Studio Runner prompt while leaving the Linear workflow as the primary prompt.
- Studio's repo path is dynamic input. Symphony uses it to discover the git remote/default branch and prepares a managed workspace clone/fetch from that remote when possible.
- Default workspace storage is a predictable user-home folder such as `~/Symphony Workspaces`; Studio settings can expose this path later.
- Branch names should be deterministic, e.g. `studio-runner/<change-name>/<short-event-id>`.
- The agent opens the PR using normal repository/GitHub skills from the workflow prompt. Symphony should not over-program PR creation in v1.
- Studio should show completed only when a PR exists. If branch push or PR creation is blocked by auth/tooling, the run is blocked, not completed.
