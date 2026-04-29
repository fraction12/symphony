## 1. Execution Design Decisions

- [x] 1.1 Reuse Symphony's existing workspace lifecycle pattern rather than designing an unrelated workspace engine.
- [x] 1.2 Use Studio's repo path to discover git remote/default branch, then clone/fetch into the Symphony workspace when possible.
- [x] 1.3 Reuse Symphony's configured multi-turn AgentRunner/Codex behavior rather than forcing a one-turn dry run.
- [x] 1.4 Require branch, commit, push, and PR creation when auth/tools permit; do not auto-merge.
- [x] 1.5 Keep repo-path input dynamic; do not hardcode a target repo. Preserve canonicalization/safety checks.

## 2. Workspace and Artifact Loading

- [x] 2.0 Default workspace root design to a user-home path such as `~/Symphony Workspaces`, configurable from Studio later.
- [ ] 2.1 Add Studio Runner workspace creation under configured workspace root using Symphony's existing hook/workspace pattern.
- [ ] 2.2 Canonicalize and validate source repo, selected change, and artifact paths.
- [ ] 2.3 Read OpenSpec change artifacts from the Symphony-managed workspace.
- [ ] 2.4 Add cleanup/removal helpers for Studio Runner workspaces.

## 3. Prompt and Agent Execution

- [ ] 3.1 Rewrite `WORKFLOW.md` as an OpenSpec-native Studio Runner workflow with no Linear issue/comment/state requirements.
- [ ] 3.2 Include proposal/design/tasks/spec deltas and validation metadata in the prompt context.
- [ ] 3.3 Wire `StudioRunner.Executor.run/1` into Symphony's AgentRunner/Codex app-server execution flow.
- [ ] 3.4 Ensure Codex cwd is the Symphony workspace, never the original repo path.
- [ ] 3.5 Capture bounded Codex session/run metadata for observability.
- [ ] 3.6 Capture branch name, commit SHA, and PR URL when the agent publishes work.
- [ ] 3.7 Treat completed as PR-created; treat missing auth/tooling for push/PR as blocked rather than completed.

## 4. Status and Observability

- [ ] 4.1 Extend Studio Runner run status with workspace path, execution status, and PR URL when available.
- [ ] 4.2 Record completed/failed status and bounded failure reasons.
- [ ] 4.3 Expose execution status through the existing dashboard/status payload.

## 5. Tests and Validation

- [ ] 5.1 Test prompt building from a fake OpenSpec change.
- [ ] 5.2 Test workspace creation does not mutate the original repo.
- [ ] 5.3 Test executor invokes a mock Codex runner with the Symphony-managed workspace and prompt.
- [ ] 5.4 Test failed artifact/repo validation fails before Codex launch.
- [ ] 5.5 Run `mix format --check-formatted`, focused tests, broader tests where stable, and `openspec validate --all`.
