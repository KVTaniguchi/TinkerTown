# TinkerTown Cursor-Optimized Checklist

This checklist is tuned for one operator using Cursor model quota efficiently.

## Operating Rules (Quota-Safe)
1. Work one phase at a time.
2. In each Cursor prompt, include only:
   1. Current phase section from this file.
   2. The matching section from `/Users/ktaniguchi/Development/TinkerTown/specifications`.
   3. Relevant files only.
3. Cap each prompt to 1-3 unchecked tasks.
4. Require Cursor to run/verify before ending each task.
5. Record evidence immediately after completion.

Evidence format:
- `Evidence: commit <sha>, files <paths>, command output <summary>, artifacts <paths>`

---

## Phase 0: Bootstrap
Goal: Create minimal runtime scaffold and config.

- [ ] Create `.tinkertown/` directory structure.
- [ ] Create `.tinkertown/config.json` from spec defaults.
- [ ] Create run artifact directory conventions (`runs/<run_id>/...`).
- [ ] Add README prerequisites section (`git`, `ollama`, `swift`/`xcodebuild`).

### Prompt To Cursor (Phase 0)
```text
Implement Phase 0 from IMPLEMENTATION_CHECKLIST.md.
Constraints:
- Make only the minimum files/changes needed for these 4 tasks.
- Follow /Users/ktaniguchi/Development/TinkerTown/specifications exactly for config keys.
- Do not implement future phases yet.
- After changes, run any lightweight validation possible.
Return:
1) What changed
2) Validation run
3) Any assumptions
```

---

## Phase 1: State Engine + Schemas
Goal: Make run/task/diagnostic persistence real and enforce transitions.

- [ ] Implement `RunRecord` schema + validation.
- [ ] Implement `TaskRecord` schema + validation.
- [ ] Implement `DiagnosticRecord` schema + validation.
- [ ] Implement run/task state enums and legal transitions.
- [ ] Persist/load run and task records from disk.
- [ ] Add version/migration field handling.

### Prompt To Cursor (Phase 1)
```text
Implement Phase 1 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications sections:
- 4. State Machine
- 5. Core Data Contracts
- 15. Definition of Done (relevant parts)
Constraints:
- Enforce invalid transition rejection in code.
- Add focused unit tests for schema validation and transition guards.
- Keep interfaces small and explicit.
Return:
1) Changed files
2) Tests added and results
3) Remaining gaps
```

---

## Phase 2: Worktree Manager
Goal: Reliable create/use/teardown with cleanup guarantees.

- [ ] Implement worktree create flow and base SHA validation.
- [ ] Enforce task command execution inside worktree cwd.
- [ ] Implement teardown (`worktree remove --force` + branch delete).
- [ ] Add orphaned worktree detection/cleanup.
- [ ] Add tests for create/teardown/idempotent cleanup.

### Prompt To Cursor (Phase 2)
```text
Implement Phase 2 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications section 7.
Constraints:
- Never use destructive repo-wide reset commands.
- Ensure cleanup is idempotent.
- Add tests for partial-failure cleanup behavior.
Return:
1) Changed files
2) Test runs
3) Failure cases handled
```

---

## Phase 3: Inspector + Retry Loop
Goal: Deterministic verification with logs and structured diagnostics.

- [ ] Implement verifier command selection (`swift build` vs `xcodebuild build`).
- [ ] Persist attempt logs per task attempt path.
- [ ] Parse diagnostics into `DiagnosticRecord[]`.
- [ ] Implement pass/fail by exit code.
- [ ] Implement retry with backoff (0s, 3s, 10s) and max retries.
- [ ] Add retry-path tests (fail then pass).

### Prompt To Cursor (Phase 3)
```text
Implement Phase 3 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications sections:
- 9. Error Taxonomy and Retry Policy
- 10. Verification Contract
Constraints:
- Persist raw logs for every attempt.
- Always emit diagnostic records, including empty arrays.
- Add tests covering retry exhaustion and retry success.
Return:
1) Changed files
2) Test and sample log output
3) Any parser limitations
```

---

## Phase 4: Scheduler + Task Graph
Goal: Safe parallelism with dependency and file-lock rules.

- [ ] Implement dependency-aware runnable selection.
- [ ] Add same-file lock policy (unless explicitly coeditable).
- [ ] Enforce queue policy (oldest runnable, then priority).
- [ ] Enforce `max_parallel_tasks`.
- [ ] Enforce reassignment limit (`replacement_depth <= 1`).
- [ ] Add contention/dependency tests.

### Prompt To Cursor (Phase 4)
```text
Implement Phase 4 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications section 6.
Constraints:
- Deterministic scheduling behavior.
- Add table-driven tests for dependencies and locks.
- Keep scheduling side effects separate from selection logic for testability.
Return:
1) Changed files
2) Scheduling test matrix summary
3) Edge cases not yet handled
```

---

## Phase 5: Mayor/Tinker Adapters
Goal: Structured prompt I/O and patch lifecycle tracking.

- [ ] Implement mayor adapter (request -> task graph).
- [ ] Implement tinker adapter (scoped context + diagnostics).
- [ ] Implement patch apply stage and patch hash persistence.
- [ ] Persist prompt hash per attempt.
- [ ] Reject out-of-scope file touches unless explicitly expanded.
- [ ] Add integration test for 2+ parallel tasks.

### Prompt To Cursor (Phase 5)
```text
Implement Phase 5 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications sections 3, 5, and 6.
Constraints:
- Strictly enforce target file scope.
- Persist prompt/patch hashes for reproducibility.
- Add one integration test that executes parallel task flow end-to-end (mock model output is fine).
Return:
1) Changed files
2) Integration test behavior
3) Contract assumptions
```

---

## Phase 6: Merge Gate
Goal: Reproducible merge decisions with conflict handling.

- [ ] Implement merge candidate package (diff stats + verify evidence).
- [ ] Reject stale verification evidence.
- [ ] Reject unresolved conflict markers.
- [ ] Handle merge conflict with single fresh-base retry.
- [ ] Persist merge outcome and commit SHA.
- [ ] Add merge conflict/reject tests.

### Prompt To Cursor (Phase 6)
```text
Implement Phase 6 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications section 8.2 and section 6/7 merge-related rules.
Constraints:
- Merge policy must be explicit and test-covered.
- Only one automatic fresh-base retry on conflict.
- Persist clear reason codes for reject/fail.
Return:
1) Changed files
2) Merge policy tests and results
3) Remaining ambiguity
```

---

## Phase 7: Guardrails + Safety
Goal: Prevent unsafe command/path behavior and redact sensitive output.

- [ ] Enforce worker path sandbox.
- [ ] Enforce blocked command list.
- [ ] Add secret redaction before persisting logs/events.
- [ ] Emit `E_GUARDRAIL_VIOLATION` on policy breaks.
- [ ] Add negative tests proving guardrails.

### Prompt To Cursor (Phase 7)
```text
Implement Phase 7 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications section 8 and section 9.
Constraints:
- Fail closed on uncertainty (block when command/path cannot be proven safe).
- Add negative tests for blocked commands and out-of-root access.
- Show redaction behavior in tests.
Return:
1) Changed files
2) Negative tests and outcomes
3) Any remaining bypass risks
```

---

## Phase 8: Observability
Goal: Event stream + metrics required by spec.

- [ ] Implement append-only `events.ndjson`.
- [ ] Emit run and task state transition events.
- [ ] Compute required metrics:
- [ ] `run_duration_seconds`
- [ ] `task_cycle_time_seconds`
- [ ] `retry_rate`
- [ ] `merge_success_rate`
- [ ] `conflict_rate`
- [ ] `median_build_time_seconds`
- [ ] Add human-readable run summary output.

### Prompt To Cursor (Phase 8)
```text
Implement Phase 8 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications section 11.
Constraints:
- Event writes must be append-only.
- Metrics must derive from persisted state/events, not transient memory only.
- Add one snapshot-style test for run summary output.
Return:
1) Changed files
2) Metrics calculation method
3) Example event lines
```

---

## Phase 9: CLI (v1)
Goal: Operable interface for local usage.

- [ ] Implement `tinkertown run "<request>"`.
- [ ] Implement `tinkertown status <run_id>`.
- [ ] Implement `tinkertown logs <run_id> [--task <task_id>]`.
- [ ] Implement `tinkertown retry <run_id> <task_id>`.
- [ ] Implement `tinkertown cleanup <run_id>`.
- [ ] Add help text and examples.

### Prompt To Cursor (Phase 9)
```text
Implement Phase 9 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications section 13.
Constraints:
- Keep CLI output concise and script-friendly.
- Return non-zero exit codes for command failures.
- Add command-level tests for argument validation.
Return:
1) Changed files
2) CLI usage examples
3) Test results
```

---

## Phase 10: Indexer (`TinkerMap.json`)
Goal: Refreshable code map with reproducible metadata.

- [ ] Implement index generation (SourceKitten or fallback parser).
- [ ] Include `version`, `generated_at`, `source_revision`.
- [ ] Emit module/file/symbol summaries only (no full bodies).
- [ ] Update index only after successful merge cycle.
- [ ] Add smoke test for index refresh on merge.

### Prompt To Cursor (Phase 10)
```text
Implement Phase 10 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications sections 3 and 5.4.
Constraints:
- Keep index size bounded; avoid implementation body dumping.
- Ensure deterministic output ordering for stable diffs.
- Add smoke test with fixture source files.
Return:
1) Changed files
2) Example TinkerMap output
3) Performance notes
```

---

## Phase 11: Acceptance Tests
Goal: Prove v1 behavior against spec scenarios.

- [ ] Happy path test.
- [ ] Retry path test.
- [ ] Conflict path test.
- [ ] Guardrail path test.
- [ ] Crash recovery path test.

### Prompt To Cursor (Phase 11)
```text
Implement Phase 11 from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications section 14.
Constraints:
- Keep tests deterministic and isolated.
- Persist artifacts/log paths for each scenario.
- Report pass/fail with concise reason if failing.
Return:
1) Added tests
2) Pass/fail summary by scenario
3) Remaining flakiness risks
```

---

## Phase 12: Release Readiness
Goal: v1 go/no-go decision with proof.

- [ ] Confirm all acceptance tests passing.
- [ ] Confirm required metrics emitted.
- [ ] Confirm evidence exists for every run/task.
- [ ] Confirm guardrail negative tests passing.
- [ ] Record final end-to-end dry run with run ID/artifacts.
- [ ] Prepare v1 release notes and tag plan.

### Prompt To Cursor (Phase 12)
```text
Execute Phase 12 release readiness checks from IMPLEMENTATION_CHECKLIST.md.
Use /Users/ktaniguchi/Development/TinkerTown/specifications sections 15 and 16.
Constraints:
- Produce a concise go/no-go report.
- Include specific failing gates if no-go.
- Do not introduce new features in this phase.
Return:
1) Gate-by-gate status
2) Evidence references
3) Go/no-go recommendation
```

---

## Progress Tracker
- Current phase: [ ]
- Last completed task:
- Next 1-3 tasks:
- Active blocker:
- Blocker owner:
- Target unblock date:

## Completion Evidence Log
- [ ] Phase 0 evidence:
- [ ] Phase 1 evidence:
- [ ] Phase 2 evidence:
- [ ] Phase 3 evidence:
- [ ] Phase 4 evidence:
- [ ] Phase 5 evidence:
- [ ] Phase 6 evidence:
- [ ] Phase 7 evidence:
- [ ] Phase 8 evidence:
- [ ] Phase 9 evidence:
- [ ] Phase 10 evidence:
- [ ] Phase 11 evidence:
- [ ] Phase 12 evidence:
