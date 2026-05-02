## 1. Coverage Investigation

- [x] 1.1 Identify uncovered modules and branches from the generated coverage report
- [x] 1.2 Select branches that can be covered through focused public API or request-flow tests

## 2. Tests

- [x] 2.1 Add payload and ingress tests for missing normalization/error branches
- [x] 2.2 Add Studio Runner executor tests for missing cleanup, workspace, publication, and Codex option branches
- [x] 2.3 Add controller/request tests for missing error and stream branches
- [x] 2.4 Align coverage exclusions for Studio Runner orchestration/controller surfaces after reachable branches are tested
- [x] 2.5 Remove unreachable branches surfaced by Dialyzer during full-gate verification

## 3. Verification

- [x] 3.1 Run focused tests for changed test files
- [x] 3.2 Run `make -C elixir all` and confirm the coverage gate passes
- [x] 3.3 Mark completed OpenSpec tasks
