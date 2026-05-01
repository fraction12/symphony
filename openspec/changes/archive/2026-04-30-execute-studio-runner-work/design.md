# Design: Execute Studio Runner work

## Current State

`POST /api/v1/studio-runner/events` accepts signed `build.requested` events and hands a normalized `StudioRunner.WorkItem` to `Orchestrator.dispatch_external_work/2`. The orchestrator deduplicates by event ID, blocks duplicate repo/change runs, assigns a run ID, starts a supervised async task, and returns `202` with bounded metadata.

The async task currently calls `StudioRunner.Executor.run/1`, which logs acceptance and exits. No workspace is created and no Codex session runs.

Existing useful primitives:

- `Codex.AppServer.start_session/2`, `run_turn/4`, and `stop_session/1` run Codex app-server in a workspace.
- `Workspace` already contains path safety, configured workspace roots, local/remote handling, and hook execution.
- `PromptBuilder` renders workflow templates from issue context; the same template engine can be reused with OpenSpec work context if the workflow schema supports it.
- `AgentRunner` already implements Codex app-server startup, max-turn continuation, update handling, and hook sequencing.
- `Orchestrator` already owns capacity, claims, event status, and async task supervision for Studio Runner work.

## Execution Model

### Work item to execution context

The executor SHALL derive an execution context from `WorkItem`:

- `event_id`
- `run_id`
- canonical `repo_path` supplied by Studio
- `repo_name`
- optional repo remote/default branch metadata when available
- `change`
- `git_ref`
- `artifact_paths`
- validation summary
- requested-by metadata

The executor SHALL re-check that the repository and change artifacts exist before launching Codex. Studio's eligibility checks are helpful but not trusted proof.

### Workflow prompt

This fork's `WORKFLOW.md` should be rewritten for OpenSpec Studio Runner rather than kept as a Linear-first workflow with a separate side prompt. The prompt should say, plainly: read the selected OpenSpec change, implement it, update `tasks.md`, validate, create a branch, commit, push, open a PR, and report the PR.

Linear-specific requirements should be removed from the Studio Runner workflow: no Linear ticket fetch, no Linear workpad comment, no Linear state transitions, and no PR attachment to Linear.

### Workspace creation

The first implementation should reuse Symphony's current workspace lifecycle instead of inventing a separate workspace engine. Linear currently creates a per-issue directory under `workspace.root`, runs `hooks.after_create`, then runs `hooks.before_run` and `hooks.after_run` around Codex execution. Studio Runner should use the same pattern with OpenSpec work metadata.

Default workspace storage should be user-home based and predictable, e.g.:

```text
~/Symphony Workspaces
```

Studio can later expose this as a configurable settings field. Avoid machine-specific defaults such as `/Volumes/MacSSD/Projects`.

A Studio Runner workspace path can be shaped as:

```text
~/Symphony Workspaces/studio-runner/<safe-repo-name>/<safe-change-name>/<run-id>
```

The bootstrap hook or a Studio-specific workspace helper must use the Studio-supplied repo path to discover the git remote and default branch, then clone/fetch into the managed workspace when possible. It must not hardcode this fork, OpenSpec Studio, `/Volumes/MacSSD/Projects`, or any single target repo.

The workflow should be allowed to create a branch, commit, push, and open a PR, matching how the Linear workflow expects agents to publish work. Merge/land remains out of scope for this change.

### Prompt construction

Use the existing workflow template engine with OpenSpec work context. It should read from the prepared workspace, not the original repo:

- `openspec/changes/<change>/proposal.md`
- `openspec/changes/<change>/design.md` when present
- `openspec/changes/<change>/tasks.md`
- `openspec/changes/<change>/specs/**/spec.md`

The prompt should instruct the agent to:

- work only in the prepared Symphony workspace;
- treat the OpenSpec change as the task source, analogous to a Linear issue;
- create/use a branch for the work;
- preserve OpenSpec source-of-truth files;
- update `tasks.md` only for work actually completed;
- run targeted validation/tests and report results;
- commit completed work on a deterministic branch such as `studio-runner/<change-name>/<short-event-id>`;
- push the branch and open a PR using normal repo/GitHub skills when auth/tools permit;
- stop as blocked if branch push or PR creation cannot be completed because required auth/tools are missing;
- avoid Linear-specific comments or tracker updates.

### Codex execution

The execution path SHOULD reuse Symphony's existing AgentRunner/Codex loop rather than introducing a second behavioral model. If the current `AgentRunner` is too Linear-shaped, extract generic runner primitives or add a Studio-specific wrapper that still uses the same Codex app-server session and continuation behavior.

The default v1 behavior should match Symphony's configured `agent.max_turns` continuation model. We are not optimizing for a cautious one-turn dry run; this is meant to let Symphony take over after Studio dispatches.

### Status and observability

The orchestrator already tracks accepted/running event state. This change should extend Studio Runner status with bounded execution details where practical:

- `run_id`
- `event_id`
- `repo_path`
- `change`
- `workspace_path`
- `status`: running/completed/failed
- started/completed timestamps
- final error reason, bounded and sanitized
- Codex session ID if available
- branch name, commit SHA, and PR URL when available

Studio should treat the run as completed only when the PR URL is known. If the agent produced local changes but could not push/open a PR, the terminal state should be blocked or failed with a bounded reason.

The ingress response should remain fast. It does not wait for completion.

## Risks

- **Workspace mutation risk:** agent writes to the original repo. Mitigation: Codex cwd must be the Symphony-managed workspace, not `repo_path`.
- **Fake Linear abstraction risk:** reusing `AgentRunner.run(issue)` could pull in Linear-specific prompt/workflow assumptions. Mitigation: reuse execution primitives, but pass explicit OpenSpec work context and avoid Linear tracker calls.
- **Path traversal risk:** artifact paths and repo paths must be canonicalized and constrained.
- **Unclear output ownership:** Studio should not consider work complete just because files changed locally. Mitigation: require branch/commit/PR publication when auth permits and expose the PR URL.
- **Long-running task visibility:** Studio currently only sees dispatch history. Mitigation: Symphony status/dashboard should expose enough bounded state first; push progress back to Studio can be a later change.

## Rollback

Disable the Studio Runner executor path or revert `StudioRunner.Executor.run/1` to a no-op while keeping signed ingress intact. Existing Linear polling behavior remains separate.
