## ADDED Requirements

### Requirement: Elixir local CI coverage gate passes
The Elixir project SHALL keep `make -C elixir all` passing under the configured
coverage threshold.

#### Scenario: Coverage gate succeeds after tests
- **WHEN** the Elixir local CI target runs the coverage step
- **THEN** the test suite SHALL pass
- **AND** the coverage summary SHALL meet the configured threshold

### Requirement: Coverage restoration preserves runtime behavior
Coverage restoration work SHALL add focused tests for existing behavior without
changing runtime semantics solely to satisfy coverage.

#### Scenario: Missing coverage is addressed with tests
- **WHEN** uncovered but supported branches are identified
- **THEN** tests SHALL exercise those branches through public APIs or request
  flows where practical
- **AND** production behavior SHALL remain unchanged unless a real defect is
  found
