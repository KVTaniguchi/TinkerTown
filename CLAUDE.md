# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

TinkerTown is a local-first, autonomous multi-agent coding orchestrator written in Swift. It decomposes user requests into task graphs, executes them in isolated git worktrees using local Ollama models, verifies the results by building, and merges changes back — all without cloud APIs.

## Commands

```bash
# Build
swift build
swift build -c release

# Run all tests
swift test

# Run a single test
swift test --filter MergeGateTests
swift test --filter WorktreeManagerTests/testCreate

# Run CLI
swift run tinkertown run "add a README section for installation"
swift run tinkertown status <run_id>
swift run tinkertown logs <run_id> --task <task_id>
swift run tinkertown retry <run_id> <task_id>
swift run tinkertown cleanup <run_id>
swift run tinkertown pdr init --title "My project"
```

## Architecture

### Execution Flow

```
User Request
    → Orchestrator.generatePlan() → creates RunRecord + TaskRecords (with dependency graph)
    → Orchestrator.execute() → main task queue loop:
        - Scheduler.runnableTasks() respects dependsOn graph
        - WorktreeManager creates isolated git worktree per task
        - OllamaTinkerAdapter (or fallback) generates patch
        - Inspector.verify() runs build command (auto-detects SPM/xcodebuild/npm)
        - Retry with backoff (0s, 3s, 10s; default max 3 retries)
        - MergeGate.validateScope() + merge() on success
    → Cleanup: tear down worktrees and branches
```

### Agent Roles (Single Process)

| Agent | File | Purpose |
|---|---|---|
| Mayor (Planner) | `OllamaAdapters.swift` | Decomposes requests into task graphs |
| Orchestrator | `Core/Orchestrator.swift` | Coordinates the full run lifecycle |
| Tinker (Worker) | `OllamaAdapters.swift` | Generates patches per task |
| Inspector | `Services/Inspector.swift` | Verifies builds; parses Swift/Node diagnostics |
| MergeGate | `Services/MergeGate.swift` | Scope validation + `git merge --no-ff` |

Both Mayor and Tinker fall back to deterministic adapters when Ollama is disabled.

### State Machines

Defined in `Models/Contracts.swift`:
- **RunState**: `runCreated → planning → executing → merging → completed/failed`
- **TaskState**: `taskCreated → worktreeReady → prompted → patchApplied → verifying → verifyPassed → mergeReady → merged/rejected/failed → cleaned`

Transitions are validated by `Core/StateMachine.swift`.

### Key Services

- **`Services/RunStore.swift`** — Persists RunRecord/TaskRecord as JSON under `.tinkertown/runs/<run_id>/`
- **`Services/EventLogger.swift`** — Appends state-change events to `events.ndjson`; attempt logs under `tasks/<task_id>/attempts/`
- **`Services/Scheduler.swift`** — Returns next runnable tasks given the dependency graph
- **`Services/Guardrails.swift`** — Validates allowed shell commands and path writes per task scope
- **`Services/WorktreeManager.swift`** — `git worktree add/remove` lifecycle; `cleanupOrphaned()` finds stale TinkerTown branches
- **`Services/PlanningService.swift`** — Reads/writes `plan/PROJECT_PLAN.md`; derives PDR metadata
- **`Services/HealthCheckRunner.swift`** — Preflight: checks git, swift/xcodebuild, Ollama

### Targets

| Target | Path | Role |
|---|---|---|
| `TinkerTownCore` | `Sources/TinkerTownCore/` | Library: all orchestration logic |
| `tinkertown` | `Sources/tinkertown/main.swift` | CLI executable |
| `TinkerTownApp` | `Sources/TinkerTownApp/` | macOS SwiftUI app |

### Runtime Data

All state is stored in the target repository under `.tinkertown/`:
- `config.json` — user config (Ollama models, retries, guardrails, verification mode)
- `pdr.json` — Product Design Requirement (required before any run; create with `pdr init`)
- `runs/<run_id>/run.json` + `tasks/<task_id>.json` — serialized state
- `escalations.ndjson` — escalation audit trail

### Configuration

`AppConfig` (loaded from `.tinkertown/config.json`) controls:
- `use_ollama`, mayor/tinker model names
- `max_retries_per_task`, `max_parallel_tasks`
- `verification_mode` (`auto`/`spm`/`xcodebuild`/`none`) and custom build command
- `guardrails` — allowed commands, path restrictions
