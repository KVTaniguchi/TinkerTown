# TinkerTown Gas Town Parity Delivery Plan

This plan turns the Gas Town parity matrix into an execution sequence for TinkerTown. The target is a local-first agent system with a Mac UI that feels like Gas Town while remaining practical to implement on top of the current Swift codebase.

The plan assumes the current baseline already exists:

- local Ollama-backed Mayor/Tinker adapters
- run/task persistence under `.tinkertown/`
- worktree execution, verification, merge, and retry
- background execution and a live macOS UI
- monitor/resume support and escalation logging

The remaining work is about closing the parity gap in reliability, agent semantics, durable communication, and UI model.

---

## Delivery Principles

1. Preserve the current file-backed architecture in early phases.
2. Ship vertical slices that are testable end-to-end.
3. Add new persistence models before adding agent behavior that depends on them.
4. Avoid UI-only progress; every UI phase must sit on durable core contracts.
5. Use fixture repos to validate runtime behavior before polishing UX.

---

## Phase 1: Durable Agent Model

**Goal:** Turn role labels into real persistent actors with state, assignments, and mailbox ownership.

### Scope

- Add durable agent records for Mayor, Tinkers, Monitor, and Operator.
- Persist agent status, current assignment, last activity, and inbox counters.
- Establish a stable identity model for logs, events, and UI.

### Core changes

- Add `AgentRecord` and `AgentState` contracts.
- Add agent storage under `.tinkertown/agents/`.
- Extend run/task/event flows so actions reference concrete agents, not just role strings.
- Add an agent registry bootstrap step for every workspace.

### Files likely touched

- `Sources/TinkerTownCore/Models/Contracts.swift`
- `Sources/TinkerTownCore/Services/RunStore.swift`
- `Sources/TinkerTownCore/Services/EventLogger.swift`
- `Sources/TinkerTownCore/Core/Orchestrator.swift`
- `Sources/TinkerTownApp/TinkerTownApp.swift`
- `Tests/TinkerTownCoreTests/ContractValidationTests.swift`
- `Tests/TinkerTownCoreTests/EventLoggerTests.swift`

### Success criteria

- Every run/task transition can be attributed to a concrete agent record.
- The app can list all agents and show current state from durable storage.
- Tests cover agent creation, persistence, and state updates.

### Risks

- Overfitting identities too early into a distributed model the runtime does not yet support.
- Duplicating state between tasks and agents unless ownership is explicit.

---

## Phase 2: Durable Mail and Handoffs

**Goal:** Add a Gas Town-like communication layer so agents can leave durable messages, not just mutate run/task state.

### Scope

- Add mailbox threads and message records.
- Support Mayor-to-Tinker, Tinker-to-Mayor, Monitor-to-Operator, and escalation-linked messages.
- Keep storage file-based for v1.

### Core changes

- Add `MailThreadRecord` and `MailMessageRecord`.
- Store mail under `.tinkertown/mail/threads/`.
- Add APIs for create thread, append message, mark read, and query inbox.
- Update planning/execution flows to emit mail for task assignment, failure, retry, and completion.

### Files likely touched

- `Sources/TinkerTownCore/Models/Contracts.swift`
- `Sources/TinkerTownCore/Services/RunStore.swift`
- `Sources/TinkerTownCore/Services/EventLogger.swift`
- `Sources/TinkerTownCore/Core/Orchestrator.swift`
- `Sources/TinkerTownCore/Services/StatusAgent.swift`
- `Sources/TinkerTownApp/TinkerTownApp.swift`
- `Sources/tinkertown/main.swift`
- `Tests/TinkerTownCoreTests/ContractValidationTests.swift`
- `Tests/TinkerTownCoreTests/AcceptanceTests.swift`

### Success criteria

- A task assignment produces a durable message thread.
- Failures and retries produce visible mailbox artifacts.
- The app can display unread mail counts and thread contents for each agent.

### Risks

- Building “mail” as just duplicated event logs.
- Letting mail semantics drift without a small, explicit state machine.

---

## Phase 3: Supervisor and Recovery Loop

**Goal:** Replace the narrow resume-on-failed-run monitor with a real supervisor loop that can wake and coordinate ongoing work.

### Scope

- Detect stalled runs.
- Detect merge-ready tasks that need merge progress.
- Detect retryable tasks and blocked tasks.
- Trigger resume/execute/escalate according to explicit policy.

### Core changes

- Expand `MonitorLoop` into a supervisor policy engine.
- Add stall detection timestamps and reason codes.
- Add a run lease or execution token to avoid concurrent supervisor interference.
- Emit supervisor events and agent activity updates.

### Files likely touched

- `Sources/TinkerTownCore/Services/MonitorLoop.swift`
- `Sources/TinkerTownCore/Core/Orchestrator.swift`
- `Sources/TinkerTownCore/Services/Scheduler.swift`
- `Sources/TinkerTownCore/Services/MergeManager.swift`
- `Sources/TinkerTownCore/Services/StatusAgent.swift`
- `Sources/TinkerTownApp/TinkerTownApp.swift`
- `Sources/tinkertown/main.swift`
- `Tests/TinkerTownCoreTests/SchedulerTests.swift`
- `Tests/TinkerTownCoreTests/AcceptanceTests.swift`

### Success criteria

- Runs with pending work can advance without manual “Continue Working”.
- Stalled runs are escalated with explicit reasons.
- The app can show when the supervisor is waiting, retrying, or escalating.

### Risks

- Infinite supervisor loops if no-progress states are not clearly modeled.
- Races between UI-triggered execution and monitor-triggered execution.

---

## Phase 4: Goal and Spec Parity

**Goal:** Upgrade from task-count progress to explicit goal/spec tracking that resembles Gas Town’s “where are we relative to the project goals?” model.

### Scope

- Introduce durable goal/spec artifacts.
- Link tasks to goals and milestones.
- Track acceptance criteria coverage.
- Show goal board/progress in UI and CLI summaries.

### Core changes

- Add `GoalSpecRecord`, `MilestoneRecord`, and acceptance criteria structures.
- Persist goal specs in workspace-local storage.
- Extend planning so tasks optionally target goals/milestones.
- Replace simple progress percentages with goal-aware summaries.

### Files likely touched

- `Sources/TinkerTownCore/Models/Contracts.swift`
- `Sources/TinkerTownCore/Services/GoalProgressService.swift`
- `Sources/TinkerTownCore/Services/PlanningService.swift`
- `Sources/TinkerTownCore/Services/StatusAgent.swift`
- `Sources/TinkerTownApp/TinkerTownApp.swift`
- `Sources/tinkertown/main.swift`
- `Tests/TinkerTownCoreTests/PlanningServiceTests.swift`
- `Tests/TinkerTownCoreTests/ContractValidationTests.swift`

### Success criteria

- The UI can show goals, milestones, and acceptance coverage.
- CLI summary reports goal-level progress, not just run metrics.
- Tasks can be traced back to a goal or milestone.

### Risks

- Allowing “goal progress” to become cosmetic if tasks are not actually linked.
- Overcomplicating the schema before acceptance criteria are used in execution.

---

## Phase 5: Worker Reliability and Repo Intelligence

**Goal:** Improve end-to-end execution quality so TinkerTown is reliable enough to justify the richer Gas Town-style UI.

### Scope

- Strengthen the worker patch contract.
- Improve repo-type detection and scaffolding.
- Integrate code map/index context into planning and execution.
- Add structured failure categories and postmortem artifacts.

### Core changes

- Tighten unified diff validation and file-creation semantics.
- Add richer repo bootstrap helpers for common app shapes.
- Feed index/code map context into Mayor/Tinker prompts.
- Persist failure analyses separately from raw attempt logs.

### Files likely touched

- `Sources/TinkerTownCore/Services/OllamaAdapters.swift`
- `Sources/TinkerTownCore/Core/Orchestrator.swift`
- `Sources/TinkerTownCore/Services/Indexer.swift`
- `Sources/TinkerTownCore/Services/Inspector.swift`
- `Sources/TinkerTownCore/Services/Scaffolder.swift`
- `Sources/TinkerTownCore/Services/RemediationEngine.swift`
- `Tests/TinkerTownCoreTests/MayorTinkerAdapterTests.swift`
- `Tests/TinkerTownCoreTests/InspectorTests.swift`
- `Tests/TinkerTownCoreTests/AcceptanceTests.swift`

### Success criteria

- Worker failures are classified and persisted in a structured way.
- Repo context selection is grounded in actual indexed files.
- Fixture repos show materially better completion rates.

### Risks

- Trying to solve model quality purely with prompt tweaks.
- Letting the execution loop grow opaque without better diagnostics.

---

## Phase 6: War Room UI

**Goal:** Make the macOS app feel like a Gas Town-style operations console rather than a generic run/task viewer.

### Scope

- Add first-class views for agents, mail, goals, escalations, and timeline.
- Keep the current activity feed, but demote it to one panel in a larger operations layout.
- Surface blocked reasons, unread mail, and current assignments directly.

### Core changes

- Add agent panel and mailbox panel.
- Add goal board/progress panel.
- Add escalation queue with state transitions.
- Add run timeline/war-room view with agent lanes.

### Files likely touched

- `Sources/TinkerTownApp/TinkerTownApp.swift`
- `Sources/TinkerTownApp/Settings/SettingsView.swift`
- `Sources/TinkerTownApp/Settings/ModelManagementView.swift`
- New view files under `Sources/TinkerTownApp/`

### Success criteria

- A user can understand who is doing what, what is blocked, and what messages are pending without opening logs.
- Mail, goals, and escalations are first-class screens, not hidden artifacts.
- The app visually communicates agent operations rather than just task rows.

### Risks

- Building UI faster than the underlying data model can support.
- Turning the app into a dashboard without useful interaction affordances.

---

## Phase 7: Fixture-Based Acceptance and Hardening

**Goal:** Prove the system works on representative repos before further expansion.

### Scope

- Add small fixture repos for backend, frontend, full-stack, and mixed Swift/Xcode cases.
- Add end-to-end scenarios covering planning, execution, retry, merge, escalation, and supervisor recovery.
- Define parity acceptance criteria for “usable local Gas Town”.

### Core changes

- Add fixture workspaces under test resources.
- Add acceptance tests that invoke the real orchestration stack.
- Add a repeatable scorecard for run success rate, merge rate, and recovery behavior.

### Files likely touched

- `Tests/TinkerTownCoreTests/AcceptanceTests.swift`
- `Tests/TinkerTownCoreTests/ConcurrentExecutionTests.swift`
- new test fixture directories under `Tests/Fixtures/`
- optional docs updates in `README.md` and `plan/OPERATION.md`

### Success criteria

- The test suite covers the major operational paths, not just unit contracts.
- Failures are reproducible and debuggable from saved artifacts.
- The team can measure whether a change improves or regresses real run quality.

### Risks

- Fixture repos that are too synthetic to predict real-world behavior.
- Slow tests that no one runs unless execution tiers are separated clearly.

---

## Phase 8: Optional Storage Abstraction

**Goal:** Prepare for SQLite or Dolt later without blocking the file-based v1.

### Scope

- Introduce storage interfaces for runs, tasks, agents, mail, goals, and escalations.
- Keep local file storage as the default backend.
- Make future migration possible without rewriting the orchestration logic.

### Core changes

- Extract store protocols around existing file-based services.
- Separate persistence semantics from file layout details.
- Add compatibility tests for file-backed storage.

### Files likely touched

- `Sources/TinkerTownCore/Services/RunStore.swift`
- `Sources/TinkerTownCore/Services/ConfigStore.swift`
- `Sources/TinkerTownCore/Services/EventLogger.swift`
- new storage abstraction files under `Sources/TinkerTownCore/Services/`

### Success criteria

- Core orchestration code no longer depends directly on one concrete storage mechanism.
- File-backed behavior remains unchanged.

### Risks

- Premature abstraction before the file model stabilizes.
- Introducing protocol churn that slows feature delivery.

---

## Suggested Execution Order

1. Phase 1: Durable Agent Model
2. Phase 2: Durable Mail and Handoffs
3. Phase 3: Supervisor and Recovery Loop
4. Phase 4: Goal and Spec Parity
5. Phase 5: Worker Reliability and Repo Intelligence
6. Phase 6: War Room UI
7. Phase 7: Fixture-Based Acceptance and Hardening
8. Phase 8: Optional Storage Abstraction

This order keeps the architecture honest:

- identity before communication
- communication before supervision
- supervision before UI polish
- reliability before storage abstraction

---

## Immediate Next Slice

If the work starts now, the next implementation slice should be:

1. Add `AgentRecord` and file-backed agent persistence.
2. Extend `RunEvent` usage so events always carry concrete agent identity.
3. Add a simple Agents panel in the app backed by durable agent records.
4. Add tests for agent bootstrap, updates, and event attribution.

That slice is small enough to ship independently and unlocks the later mail and supervisor phases.
