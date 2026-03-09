# TinkerTown Application Review: “Gas Town–Style, Tuned for Local Models”

**Goal:** Assess TinkerTown as a local-model analogue to Gas Town and recommend changes to align behavior, semantics, and operability.

---

## 1. Executive Summary

TinkerTown is a **single-process, file-based** multi-agent coding orchestrator: it plans from a request, runs tasks in isolated git worktrees, verifies with local builds, and merges to `main` with an audit trail. It already shares **conceptual roles** with Gas Town (Mayor = planner, Tinker = worker) and is **correctly tuned for local execution** (Ollama config, worktrees, no cloud). The main gaps versus “Gas Town but local” are: **no durable cross-session communication (mail/beads)**, **no escalation path**, **no role/identity model**, **Mayor/Tinker are placeholders (no LLM)**, and **persistence is file-based only** (no Dolt). The codebase is well-structured, spec-aligned, and test-covered; closing the gaps is mostly additive.

---

## 2. Gas Town vs TinkerTown (Reference)

| Concern | Gas Town | TinkerTown |
|--------|-----------|------------|
| **Data plane** | Dolt (port 3307), beads, mail, work history | File-based: `.tinkertown/runs/<run_id>/`, JSON, NDJSON |
| **Identity / role** | `gt prime`, `GT_ROLE`; Mayor, Overseer | Single operator; no role abstraction |
| **Communication** | Mail (persistent bead + commit) vs nudge (ephemeral) | None; orchestration is in-process only |
| **Escalation** | `gt escalate` → Mayor; CRITICAL → Overseer | None |
| **Planner** | Mayor (agent that plans from intent) | `MayorAdapting` / `DefaultMayorAdapter` (string-split, no LLM) |
| **Worker** | Tinker (agent that edits in scope) | `TinkerAdapting` / `DefaultTinkerAdapter` (shell placeholder, no LLM) |
| **Audit** | Dolt history, war room, incidents | `events.ndjson`, run/task JSON, attempt logs |
| **Operational awareness** | Dolt status, cleanup, escalation protocol | CLI: status, logs, retry, cleanup |

---

## 3. Architecture Review

### 3.1 Strengths

- **Spec alignment:** State machines (run/task), contracts (RunRecord, TaskRecord, DiagnosticRecord), worktree lifecycle, guardrails, retry/backoff, and merge policy match the written spec.
- **Clean boundaries:** Orchestrator composes store, events, worktrees, inspector, scheduler, merge gate, and pluggable Mayor/Tinker adapters. No hidden globals.
- **Testability:** Protocols (`MayorAdapting`, `TinkerAdapting`, `ShellRunning`, `FileSysteming`) allow test doubles; state machine, scheduler, guardrails, config/store, and inspector have focused tests.
- **Safety:** Guardrails (path sandbox, blocked commands), merge gate (scope check, conflict markers), and redaction in EventLogger are implemented and tested.
- **Local-first:** Config and design are oriented to Ollama and local tooling (swift build / xcodebuild); no cloud coupling.

### 3.2 Component Summary

| Component | Role | Implementation notes |
|-----------|------|----------------------|
| **Orchestrator** | Run lifecycle, task dispatch, merge loop | Serial task execution (v1); respects scheduler policy for runnable set |
| **MayorAdapter** | Request → task graph | Default: split on " and "; no LLM; all tasks target `tinkertown-task-notes.md` |
| **TinkerAdapter** | Apply changes in worktree | Default: appends a line to notes file; no LLM, no real patches |
| **RunStore** | Persist run/task records | JSON under `.tinkertown/runs/<run_id>/`; no run directory pre-creation (relies on write creating parents) |
| **EventLogger** | Append-only audit | NDJSON + redaction; raw attempt logs under task dir |
| **WorktreeManager** | Create/teardown/cleanup | `git worktree add/remove`, `branch -D`; orphan cleanup by path pattern |
| **Scheduler** | Runnable set | Dependencies, file locks, queue policy (oldest then priority), max parallel |
| **MergeGate** | Scope + conflict check, merge | `git merge --no-ff`; single retry on conflict; scope = target files only |
| **Inspector** | Build + diagnostics | Command from config; logs; regex diagnostics; backoff 0/3/10s |
| **Guardrails** | Command blocklist, path sandbox | Enforced in Tinker adapter and tests |

### 3.3 Gaps and Risks

1. **Run/task directories:** `runDir(runID)` and `tasksDir(runID)` are created implicitly on first write (via `LocalFileSystem.write` creating parent). This is fine but could be made explicit (e.g. when creating a run) for clarity and for non-LocalFileSystem implementations.

2. **MergeGate conflict scan:** `git grep -n '<<<<<<<|=======|>>>>>>>' -- \(task.targetFiles.joined(separator: " "))` is fragile for filenames with spaces. Prefer passing files as separate arguments or using `--` with a single pattern and letting grep search the repo.

3. **Actual parallelism:** Orchestrator loop runs “runnable” tasks in a `for task in runnable` loop without async; execution is effectively serial. Spec and scheduler support `max_parallel_tasks` but the engine does not yet run tasks in parallel (e.g. with async/await or DispatchQueue).

4. **Ollama not used:** Config has `models.mayor`, `models.tinker`, and Ollama settings, but no code calls Ollama. Mayor and Tinker are deterministic placeholders. To be “tuned for local models,” an Ollama-backed Mayor (plan from request) and Tinker (generate/apply patches) are still to be implemented.

5. **Indexer / TinkerMap:** Spec and checklist mention TinkerMap.json and code map; not present in code. Optional for v1 but part of “Gas Town–style” context routing.

---

## 4. Alignment with “Gas Town but Local”

### 4.1 Already Aligned

- **Local execution:** Worktrees, local build verification, merge to main, no cloud.
- **Role names:** Mayor (planner) and Tinker (worker) match Gas Town conceptually.
- **Audit trail:** Events and logs give a run-scoped audit (similar in spirit to beads, but file-based).
- **Operational commands:** status, logs, retry, cleanup parallel `gt`-style operations.
- **Guardrails:** Path and command restrictions support a “fail closed” stance.

### 4.2 Gaps to Close for “Gas Town–Style”

1. **Durable, cross-session communication (mail/beads)**  
   Gas Town uses mail (persistent bead + Dolt commit) for handoffs and protocol messages. TinkerTown has no equivalent. Options:
   - **Lightweight:** Add a “run mailbox” or “run memos” under `.tinkertown/runs/<run_id>/` (e.g. `memos.ndjson` or one file per message) so that a future multi-process or multi-agent setup can leave messages that survive session death.
   - **Heavy:** Integrate Dolt (or SQLite) as an optional data plane for runs/tasks/events and optional “beads” (e.g. one row per message or artifact), with file-based remaining as default.

2. **Escalation path**  
   Gas Town has `gt escalate` → Mayor, CRITICAL → Overseer. TinkerTown has no escalation. Options:
   - Add a minimal `tinkertown escalate [--severity HIGH|CRITICAL] "<message>"` that appends to `events.ndjson` (and optionally to a dedicated `escalations.ndjson`) so that a human or a “Mayor” process can later read and act. No Dolt required for v1.

3. **Role / identity**  
   Gas Town uses `gt prime` and `GT_ROLE`. TinkerTown is single-operator. Options:
   - For single-process v1: document that the process acts as “Mayor + Orchestrator”; no code change.
   - For later multi-agent: introduce an optional `TT_ROLE` (e.g. `mayor` | `tinker` | `operator`) and a small “identity” file or env-driven config so that logs and events can tag the actor.

4. **Mayor and Tinker backed by local LLM**  
   To be “tuned for local models,” the default adapters should be replaceable by Ollama-backed implementations:
   - **Mayor:** Input: user request + optional TinkerMap/summary. Output: list of `PlannedTask` (title, priority, depends_on, target_files). Use `models.mayor` and `ollama.mayor_num_ctx`.
   - **Tinker:** Input: task + context (request, target files, optional code snippets). Output: patch or edit instructions. Use `models.tinker` and `ollama.tinker_num_ctx`. Apply patch in worktree and run Inspector.

5. **Persistence and operational awareness**  
   Gas Town has “Dolt is fragile” and explicit status/cleanup/escalation. TinkerTown already has:
   - status (run state, task list)
   - logs (events + per-task attempt logs)
   - cleanup (teardown + orphan worktrees)  
   Optional: add a `tinkertown doctor` or `tinkertown status --server` that checks git, worktree list, and disk usage of `.tinkertown`, and writes a one-line summary (e.g. “ok” vs “orphaned worktrees: 2”) for scripting.

---

## 5. Recommendations (Prioritized)

### P0 – Required for “local Gas Town–style”

1. **Implement Ollama-backed Mayor and Tinker adapters** (optional in config: `use_ollama: true`). Keep current adapters as fallback so tests and demos still work without Ollama.
2. **Add a minimal escalation mechanism:** e.g. `tinkertown escalate "<message>"` appending to run or global events so that “something went wrong” is recorded and visible in logs.

### P1 – High value

3. **Run/task directory creation:** Explicitly create `runDir(runID)` and `tasksDir(runID)` when creating a new run (or in ConfigStore when bootstrapping a run) so that all backends behave consistently.
4. **Harden MergeGate conflict scan:** Avoid `targetFiles.joined(separator: " ")` for `git grep`; use proper argument list or a single safe pattern.
5. **Document “role” for single-process:** In README or OPERATION.md, state that the CLI process acts as Mayor + Orchestrator and that future multi-agent could use TT_ROLE.

### P2 – Nice to have

6. **Run mailbox / memos:** Optional `memos.ndjson` (or similar) per run for durable, cross-session messages (handoffs, approvals).
7. **Optional Dolt (or SQLite) backend:** For teams that want Gas Town–like durability and queryability; keep file-based as default.
8. **`tinkertown doctor`:** Quick health check (git, worktrees, `.tinkertown` size) and exit code for scripts.
9. **True parallel task execution:** Use async/await or GCD so that multiple runnable tasks actually run concurrently up to `max_parallel_tasks`.

### P3 – Later

10. **TinkerMap / Indexer:** Code map for context routing and scoped prompts.
11. **Identity/role in events:** If multi-agent is added, tag events with actor role and optional identity.

---

## 6. Conclusion

TinkerTown’s design and implementation are solid and spec-aligned. It is already “local-first” and uses Mayor/Tinker roles in name and interface. To make it “like Gas Town but tuned for local models,” the critical additions are: **Ollama-backed Mayor and Tinker** (so planning and editing use local models), and a **minimal escalation path** (so failures and handoffs are recorded). Optional but valuable are: explicit run dir creation, a safer conflict scan in MergeGate, a run-level “mailbox” for durable messages, and (later) an optional Dolt/SQLite backend and true parallel execution. The codebase is in good shape to absorb these changes without a redesign.
