L1:# Gastown-Style Gap Analysis & v1 Implementation Plan
L2:
L3:This document maps the minimum code changes needed to evolve TinkerTown from its current “local orchestration engine with basic run/task UI” into a **v1 Gastown-style agent operations app**: goal-aware progress, actor identity/activity, background orchestration with live UI, and a persistent monitor that re-evaluates state and wakes agents automatically.
L4:
L5:**Reference:** [specifications](specifications), [OPERATION.md](OPERATION.md), [REVIEW.md](REVIEW.md), [MAC_APP_ONBOARDING_PLAN.md](MAC_APP_ONBOARDING_PLAN.md), [README.md](README.md).
L6:
L7:---
L8:
L9:## 1. Gap Summary
L10:
L11:| # | Gap | Current State | Target (v1 Gastown-style) |
L12:|---|-----|---------------|----------------------------|
L13:| **G1** | **Goal/spec model & progress** | UI shows run state + task counts/logs only. No link to goals, spec, milestones, or acceptance criteria. StatusAgent summarizes run/task metrics, not goal completion. | First-class goal/spec model; project progress computed against it; UI shows “where we are vs goals” (e.g. checklist, % complete, spec coverage). |
L14:| **G2** | **Actor identity & activity** | No durable agent identity or role in data contracts. Single-process “Mayor + Orchestrator” in one thread. No “who is doing what right now” in UI or events. | Run/task records and events carry actor role (e.g. planner/worker/monitor); activity records indicate “agent X is doing Y”; UI has an “agent activity” view. |
L15:| **G3** | **Background async + live UI** | Orchestration runs synchronously on the view model thread via `performTask`; UI blocks until run completes. No live console for ongoing work. | Orchestration runs in background (async/task); UI subscribes to run/task/event updates and refreshes in real time without blocking. |
L16:| **G4** | **Monitor/supervisor loop** | No background watcher. Runs progress only when `execute`/`resume` is invoked from app or CLI. Scheduler picks runnable tasks but nothing “wakes” the loop. | Persistent monitor (e.g. timer or process) re-evaluates project/run state and triggers `execute`/`resume` when conditions are met (e.g. runnable tasks, failed-but-retryable). |
L17:
L18:Two implementation details that affect the above:
L19:
L20:- **Sync on main thread:** `AppViewModel.performTask` runs all work (including `orchestrator.execute`) on the calling thread; the app is not a live console. *Location:* `TinkerTownApp.swift` (e.g. ~210, ~299).
L21:- **Serial execution:** Orchestrator loop is `for task in runnable { try executeTask(...) }`; scheduler advertises `max_parallel_tasks` but execution is serial. *Locations:* `Orchestrator.swift` ~205–233, `Scheduler.swift`.
L22:
L23:---
L24:
L25:## 2. Minimal Code Touchpoints (by Gap)
L26:
L27:### G1: Goal/spec model and project progress
L28:
L29:**Goal:** Add a first-class notion of “goals” (or spec/milestones) and compute “project progress” so the UI can show “where we are” relative to goals.
L30:
L31:| Layer | Current | Minimal change |
L32:|-------|---------|----------------|
L33:| **Data model** | `RunRecord` has `request` and `taskIDs`; no goal/spec/milestone. | Add optional `GoalSpec` (or equivalent) to run or to a small `ProjectGoals` artifact. At minimum: list of goal IDs + optional acceptance criteria; link tasks to goal IDs. |
L34:| **Contracts** | `Contracts.swift`: `RunRecord`, `TaskRecord` only. | Add `GoalSpec`, `GoalProgress` (or extend `RunRecord` with `goalIDs: [String]`, `milestones: [Milestone]`). Optionally add `goalId` to `TaskRecord` / `PlannedTask`. |
L35:| **Orchestrator / Mayor** | `Orchestrator.swift`, `PlannedTask`: no goal linkage. | When creating tasks (e.g. in `generatePlan`), optionally attach `goalId` from a passed-in or stored goal spec. No change to execution loop required for v1. |
L36:| **Progress computation** | `ObservabilityService` / `RunSummary`: only run/task metrics. | New helper (e.g. `GoalProgressService`) that takes run + tasks + goal spec and returns “progress per goal” and overall “project progress” (e.g. counts, %). |
L37:| **StatusAgent** | `StatusAgent.swift`: builds `RunStatusReport` from run + tasks; no goals. | Extend `RunStatusReport` (or add a parallel “goal report”) to include goal-level progress; StatusAgent calls the progress helper when a goal spec exists. |
L38:| **UI** | `TinkerTownApp.swift`: run header shows request, state, task counts. | Add a “Goals” or “Progress” section: show goal checklist or single “project progress” summary (e.g. “3/5 goals”, “60%”) when goal spec is present. |
L39:
L40:**Suggested new/edited files:**
L41:
L42:- `Sources/TinkerTownCore/Models/Contracts.swift` — add `GoalSpec`, `GoalProgress`, optional `goalId` on task.
L43:- `Sources/TinkerTownCore/Services/GoalProgressService.swift` (new) — compute progress from run + tasks + goals.
L44:- `Sources/TinkerTownCore/Services/StatusAgent.swift` — consume GoalProgressService, extend report.
L45:- `Sources/TinkerTownApp/TinkerTownApp.swift` — run header or new section for goal/progress display.
L46:- Optional: `Sources/TinkerTownCore/Models/GoalSpec.swift` if you prefer to keep Contracts lean.
L47:
L48:**Scope:** v1 can be “one goal spec per run” (e.g. derived from request or loaded from `.tinkertown/goals.json`) with a simple list of goal IDs and optional acceptance text; progress = fraction of linked tasks in terminal success state.
L49:
L50:---
L51:
L52:### G2: Actor identity and activity records
L53:
L54:**Goal:** Know “who” (which role) did what, and show “what is each agent doing right now” in the UI.
L55:
L56:| Layer | Current | Minimal change |
L57:|-------|---------|----------------|
L58:| **Data model** | `RunEvent` has `runID`, `taskID`, `type`, `from`, `to`, `meta`; no actor. `TaskRecord` has no `assignedAgent` or `lastActor`. | Add optional `actorRole: String?` (e.g. `"planner"`, `"worker"`, `"monitor"`) and optionally `actorId: String?` to `RunEvent`. Add optional `currentActorRole` / `lastActorRole` to `TaskRecord` if you want “who last touched this task.” |
L59:| **Contracts** | `Contracts.swift`: `RunEvent`, `TaskRecord`. | Extend `RunEvent` with `actorRole`, `actorId`. Optionally extend `TaskRecord` with `assignedRole`, `currentActivity` (string) for “worker is verifying” etc. |
L60:| **Orchestrator** | No role tagging when appending events or updating tasks. | When calling `events.append(...)` and when transitioning tasks, set `actorRole` (e.g. "planner" when creating plan, "worker" when applying patch, "orchestrator" when merging). Same process can use a fixed “identity” (e.g. `TT_ROLE=orchestrator` or single “local” agent id). |
L61:| **EventLogger** | `EventLogger` appends `RunEvent` with existing fields. | Ensure `RunEvent` includes new fields; API can be `append(..., actorRole: String?)`. |
L62:| **UI** | Task list shows task state and retries, not “who is doing what.” | Add an “Activity” or “Agents” section: e.g. “Planner: idle” / “Worker: task_001 (verifying)” from latest events or from task `currentActivity` / `assignedRole`. |
L63:
L64:**Suggested new/edited files:**
L65:
L66:- `Sources/TinkerTownCore/Models/Contracts.swift` — extend `RunEvent`, optionally `TaskRecord`.
L67:- `Sources/TinkerTownCore/Services/EventLogger.swift` — append with `actorRole` (and optional `actorId`).
L68:- `Sources/TinkerTownCore/Core/Orchestrator.swift` — pass role into every `events.append` and, if you add it, set `task.currentActorRole` / `currentActivity` on transitions.
L69:- `Sources/TinkerTownApp/TinkerTownApp.swift` — “Agent activity” block: derive from events or task fields and show in sidebar or above task list.
L70:
L71:**Scope:** v1 = single process with one logical “orchestrator” identity; roles are still “planner”, “worker”, “monitor” for clarity in logs and UI. No need for multiple processes or Dolt yet.
L72:
L73:---
L74:
L75:### G3: Background async orchestration and live UI
L76:
L77:**Goal:** Run orchestration off the main thread and have the UI update live as run/task/event state changes.
L78:
L79:| Layer | Current | Minimal change |
L80:|-------|---------|----------------|
L81:| **Orchestrator** | Synchronous `execute(runID:approvedTaskIDs:)` and `resume(runID:)`; no async API. | Add async entrypoints, e.g. `func execute(runID:approvedTaskIDs:) async throws` that perform the same loop on a background context; keep sync overload that wraps `Task { try await execute(...) }.result` for CLI. Alternatively, keep Orchestrator sync and run it inside a `Task { }` from the app. |
L82:| **App view model** | `performTask(success:work:)` runs `work()` synchronously on the caller (main) thread; blocks UI. | Replace “run orchestration” calls with `Task { @MainActor in ... }` or equivalent: start `orchestrator.execute(...)` in a detached or nonisolated task, and only touch `@Published` and UI on the main actor. |
L83:| **Live updates** | UI refreshes only after `performTask` completes (e.g. after full run). | Add a way to “subscribe” to run/task/event changes: either (a) polling (timer) that re-reads `RunStore` + events and updates `runRecord` / `tasks` / `logsText`, or (b) a shared stream/notification that the background executor writes to when it updates store/events. Polling is minimal and file-based friendly. |
L84:| **Concurrency** | Single-threaded execution. | No need to change Orchestrator internals for v1; just run the existing sync `execute` from a background `Task` and poll for state. Optional: use `Task.yield()` or short sleep in the loop to allow observer to run. |
L85:
L86:**Suggested new/edited files:**
L87:
L88:- `Sources/TinkerTownApp/TinkerTownApp.swift` — `AppViewModel`: for `runRequest` (execute path), `continueWorking`, `confirmAndStartExecution`, replace `performTask { ... orchestrator.execute(...) ... }` with starting a background `Task` that calls the sync `execute`, then on the main actor update `runRecord`, `tasks`, `logsText`; add a timer or similar that periodically re-loads run/tasks/events for the selected run while `isBusy` or run state is non-terminal.
L89:- Optional: `Sources/TinkerTownCore/Core/Orchestrator.swift` — add `execute(runID:approvedTaskIDs:) async throws` that runs the same loop on a background executor and optionally yields so UI can poll; CLI continues to use sync `execute`.
L90:
L91:**Scope:** v1 = “orchestration runs in background; UI polls every N seconds when a run is in progress and refreshes run/task/logs.” No need for true async/await inside Orchestrator yet if that would require large refactors.
L92:
L93:---
L94:
L95:### G4: Persistent monitor/supervisor loop
L96:
L97:**Goal:** A component that periodically re-evaluates state (e.g. “are there runnable tasks? failed-but-retryable?”) and triggers execution so agents are “woken up” without the user clicking Run/Continue.
L98:
L99:| Layer | Current | Minimal change |
L100:|-------|---------|----------------|
L101:| **Trigger** | Runs only when user invokes `execute` / `resume` from app or CLI. | A “monitor” process or in-process loop that periodically (e.g. every 30s): lists runs in non-terminal state, loads run + tasks, and if there are runnable tasks (or retryable failures), calls `orchestrator.execute(runID:)` or `resume(runID:)`. |
L102:| **Where it runs** | N/A. | Option A: Same process as the app — a timer or background task in the app that runs the monitor logic. Option B: Separate CLI daemon (e.g. `tinkertown monitor --interval 30`) that loops and exits when no work. Option C: LaunchAgent / cron that runs `tinkertown resume-all` or similar. v1 minimal = Option A (timer in app) or Option B (CLI loop). |
L103:| **Safety** | N/A. | Ensure only one executor runs per run (e.g. “run state must be EXECUTING or FAILED before calling execute/resume”; use a simple file lock or “monitor token” per run if needed). |
L104:
L105:**Suggested new/edited files:**
L106:
L107:- `Sources/TinkerTownCore/Services/MonitorLoop.swift` (new) — encapsulates “list runs, find runnable or retryable, call execute/resume.” Takes `RunStore`, `Orchestrator` (or a closure that performs execute/resume), and interval; runs in a loop or is called by a timer.
L108:- `Sources/TinkerTownApp/TinkerTownApp.swift` — when app is active (or always in background), start a timer that invokes the monitor (e.g. every 30s); ensure monitor does not start a new run for the same run_id if one is already in progress (e.g. check `run.state == .executing` and skip, or use a simple in-memory “running” set).
L109:- `Sources/tinkertown/main.swift` — optional new command `tinkertown monitor [--interval 30]` that runs the same MonitorLoop in a loop for headless use.
L110:
L111:**Scope:** v1 = one monitor loop (in-app timer or CLI daemon) that only triggers “resume” or “execute” for runs that are FAILED or have runnable tasks and are not already “in progress” (guarded by state or lock).
L112:
L113:---
L114:
L115:## 3. Implementation Order and Dependencies
L116:
L117:Recommended order so that each step is useful and builds on the previous:
L118:
L119:1. **G3 (background async + live UI)** — Unblock “live console” experience and avoid UI freezes. No dependency on G1/G2/G4. Enables responsive UI while long runs execute.
L120:2. **G2 (actor identity + activity)** — Add role/activity to events and optionally tasks; then add “agent activity” in the UI. Can be done in parallel with G1 if desired; slight dependency if you want “monitor” to emit events (G4).
L121:3. **G1 (goal/spec model + progress)** — Add goal model and progress computation; wire StatusAgent and UI. Independent of G4; benefits from live UI (G3) so progress updates in real time.
L122:4. **G4 (monitor loop)** — Add MonitorLoop and wire it (app timer or CLI). Depends on having a safe way to call `execute`/`resume` (G3 gives you background execution; monitor just invokes it periodically).
L123:
124:**Dependency diagram:**
125:
126:```
127:G3 (async + live UI)  ─────────────────────────────────────────┐
128:       │                                                         │
129:       ▼                                                         ▼
130:G2 (actor identity)    G1 (goal model)                    G4 (monitor loop)
131:       │                     │                                    │
132:       └─────────────────────┴────────────────────────────────────┘
133:                            (all feed into UI / observability)
134:```
135:
136:---
137:
138:## 4. Minimum File Checklist (v1)
139:
140:| Item | File(s) | Action |
141:|------|---------|--------|
142:| **G1** | `Contracts.swift` | Add goal/spec and progress types; optional `goalId` on task. |
143:| **G1** | `GoalProgressService.swift` (new) | Compute progress from run + tasks + goals. |
144:| **G1** | `StatusAgent.swift` | Use GoalProgressService; extend report. |
145:| **G1** | `TinkerTownApp.swift` | Show goal/progress in run header or new section. |
146:| **G2** | `Contracts.swift` | Add `actorRole`/`actorId` to `RunEvent`; optional activity on `TaskRecord`. |
147:| **G2** | `EventLogger.swift` | Append events with role. |
148:| **G2** | `Orchestrator.swift` | Pass role when appending events (and set task activity if added). |
149:| **G2** | `TinkerTownApp.swift` | “Agent activity” section from events/tasks. |
150:| **G3** | `TinkerTownApp.swift` | Run execute/resume in background Task; add polling for run/tasks/logs. |
151:| **G3** | `Orchestrator.swift` (optional) | Add async overload of execute if desired. |
152:| **G4** | `MonitorLoop.swift` (new) | Periodic “list runs → execute/resume if needed.” |
153:| **G4** | `TinkerTownApp.swift` | Start timer that calls MonitorLoop (and guard concurrent execution). |
154:| **G4** | `main.swift` (optional) | `tinkertown monitor` command. |
155:
156:---
157:
158:## 5. Out of Scope for v1 (Explicit)
159:
160:- **Parallel task execution:** Scheduler already selects up to `max_parallel_tasks`; making the orchestrator actually run them in parallel (e.g. async task group) is a separate change; not required for “Gastown-style UI/monitor” v1.
161:- **Dolt / SQLite:** Remain file-based; no persistence backend change.
162:- **Multiple processes / distributed agents:** Single process with logical roles; no `TT_ROLE`-driven separate processes in v1.
163:- **TinkerMap / Indexer for goals:** Goal spec can be a simple list or JSON file; no need for full codebase index in v1 goal model.
164:
165:---
166:
167:## 6. Success Criteria (v1 Gastown-style)
168:
169:- **UI shows progress relative to goals:** When a goal spec is present, the app shows at least one of: goal checklist, “X/Y goals done,” or “project progress N%.” ✅ Implemented: run header shows Progress %, goals X/Y, and GoalProgressService supports explicit goalIDs.
170:- **UI shows who is doing what:** At least one place (e.g. “Activity” or run header) shows current actor role and current activity (e.g. “Worker: task_001 — verifying”). ✅ Implemented: Activity section and task currentActorRole/currentActivity.
171:- **Orchestration does not block the UI:** Execute/resume run in background; UI stays responsive and updates (e.g. via polling) during the run. ✅ Implemented: runOrchestrationInBackground + 2s polling.
172:- **Monitor can wake execution:** With monitor enabled (app timer or CLI), runs in FAILED or with runnable tasks are advanced without user clicking “Continue” or “Run” every time. ✅ Implemented: MonitorLoop (30s), app onAppear/onDisappear, `tinkertown monitor [--interval N]`.
173:
174:This plan is the minimum set of code changes to reach that v1 state inside the existing repo structure and without replacing the current orchestration or persistence design.
175:
176:---
177:
178:## 7. Implementation Summary (Done)
179:
180:| Gap | Files touched | Notes |
181:|-----|----------------|-------|
182:| G1 | Contracts.swift, GoalProgressService.swift (new), StatusAgent.swift, TinkerTownApp.swift, main.swift | goalIDs/goalId optional; RunStatusReport.goalProgress; CLI summary prints goal_progress |
183:| G2 | Contracts.swift (RunEvent, TaskRecord), Orchestrator.swift, TinkerTownApp.swift | actorRole/actorId, currentActorRole/currentActivity; agentActivitySection |
184:| G3 | TinkerTownApp.swift | runOrchestrationInBackground, refreshSelectedRun, pollTimer, startPolling/stopPolling |
185:| G4 | MonitorLoop.swift (new), TinkerTownApp.swift, main.swift | MonitorLoop + runsNeedingResume; app start/stop on appear/disappear; `tinkertown monitor` |
186:*** End Patch```} ***!
JSON parsing error: Unexpected token '*' at position 4807. Fix the JSON input and try again. 😞}"} -->
