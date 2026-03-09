# Cursor Prompt Templates

Use these as short, repeatable prompts to keep Cursor loops fast and focused.

## 1) Fix Failing Test
```text
A test is failing. Fix only what is necessary.

Context:
- Project: /Users/ktaniguchi/Development/TinkerTown
- Relevant spec: /Users/ktaniguchi/Development/TinkerTown/specifications
- Relevant checklist phase: <phase number/title>
- Failing test(s): <test names>
- Failure output:
<paste failure output>

Constraints:
- Do not change public behavior beyond what is needed to make the test pass.
- Prefer minimal, targeted edits.
- If the test is wrong, explain why and propose the smallest correct test update.
- Keep changes scoped to files directly related to the failure.

Run:
1) Reproduce failure
2) Apply fix
3) Re-run the specific failing test(s)
4) Re-run closely related tests

Return:
1) Root cause
2) Files changed
3) Test results after fix
4) Any residual risk
```

## 2) Continue From Partial Progress
```text
Continue implementation from partial progress without redoing completed work.

Context:
- Project: /Users/ktaniguchi/Development/TinkerTown
- Spec: /Users/ktaniguchi/Development/TinkerTown/specifications
- Checklist: /Users/ktaniguchi/Development/TinkerTown/IMPLEMENTATION_CHECKLIST.md
- Current phase: <phase number/title>
- Already completed:
<paste completed items>
- Next 1-3 tasks:
<paste tasks>

Constraints:
- Preserve existing working behavior.
- Implement only the listed next tasks.
- Reuse existing code patterns before introducing new abstractions.
- Add/update tests only for the changed behavior.

Run:
1) Confirm current status in code/tests
2) Implement next tasks
3) Run targeted validation/tests
4) Update checklist evidence notes in output

Return:
1) Completed tasks
2) Files changed
3) Validation results
4) Remaining next tasks
```

## 3) Refactor Only (No Behavior Change)
```text
Refactor selected code for clarity/maintainability with no behavior change.

Context:
- Project: /Users/ktaniguchi/Development/TinkerTown
- Target files:
<paste file paths>
- Refactor goal:
<paste goal: readability, duplication reduction, structure, naming, etc.>

Constraints:
- No functional changes.
- Preserve interfaces unless explicitly listed as safe to change.
- Keep diffs reviewable and avoid broad rewrites.
- Add/adjust tests only if needed to prove behavior parity.

Run:
1) Identify smallest safe refactor steps
2) Apply refactor in small commits/logical chunks
3) Run existing related tests before/after
4) Report any accidental behavior risks found

Return:
1) Refactor summary
2) Files changed
3) Proof of no behavior change (tests/checks)
4) Optional follow-up refactors (small, separate)
```

## 4) Optional Fast-Loop Footer
Append this footer to any template when you want extra strictness:

```text
Execution discipline:
- Stop after completing the requested scope.
- If blocked by missing context, state the exact missing input and best assumption.
- Prefer concrete edits and test output over long explanations.
```

## 5) Investigate and Stabilize Flaky Test
```text
Investigate and stabilize a flaky test with the smallest safe change.

Context:
- Project: /Users/ktaniguchi/Development/TinkerTown
- Flaky test(s): <test names>
- Observed failure pattern:
<paste intermittent errors/timeouts>
- Recent related changes (if known):
<paste commits/files>

Constraints:
- First prove flakiness by repeated runs before changing code.
- Prioritize deterministic fixes (explicit waits, controlled clocks, isolated state, stable ordering).
- Avoid masking real bugs (no blind retries in production code).
- Keep scope narrow to flaky test path and directly related code.

Run:
1) Reproduce with repeated runs and capture pass/fail counts
2) Identify likely nondeterminism source (timing, shared state, ordering, randomness, I/O)
3) Apply minimal stabilization fix
4) Re-run repeated test loop to verify stability
5) Run nearby tests to check for regressions

Return:
1) Flake root cause hypothesis and confidence
2) Changes made
3) Before/after repeat-run stats
4) Residual risk and next fallback if flake reappears
```
