# TinkerTown

Local multi-agent coding orchestrator for macOS/Apple Silicon, implemented as a Swift core with both CLI and macOS app frontends. The same process acts as **Mayor** (planner), **Orchestrator**, and **Tinker** (worker); see [OPERATION.md](OPERATION.md) for role model and escalation.

## Prerequisites

- `git`
- `ollama` (optional; required only when `use_ollama: true` in config)
- `swift` (via Xcode command line tools) and/or `xcodebuild`

## Build and Test

```bash
swift test
swift build
```

## macOS App (No Terminal Workflow)

The `TinkerTownApp` target is a native SwiftUI macOS app that uses `TinkerTownCore` directly.

- Open `Package.swift` in Xcode.
- Select the `TinkerTownApp` scheme.
- Run the app.

Inside the app you can:

- Choose a repository (no terminal required).
- Run a request.
- View run/task status and logs.
- Retry failed tasks.
- Cleanup run worktrees.
- Log escalations.
- See prerequisite/preflight checks (`git`, `swift`, repo state, optional `ollama`).

## CLI

```bash
swift run tinkertown run "<request>"
swift run tinkertown status <run_id>
swift run tinkertown logs <run_id> [--task <task_id>]
swift run tinkertown retry <run_id> <task_id>
swift run tinkertown cleanup <run_id>
swift run tinkertown escalate [--severity HIGH|CRITICAL] [--run <run_id>] "<message>"
```

Set `use_ollama: true` in `.tinkertown/config.json` to use local Ollama models for planning and patch generation; otherwise default (string-split) adapters are used.

## Runtime Artifacts

- Config: `.tinkertown/config.json`
- Runs: `.tinkertown/runs/<run_id>/`
- Events: `.tinkertown/runs/<run_id>/events.ndjson`
- Task attempt logs: `.tinkertown/runs/<run_id>/tasks/<task_id>/attempt_<n>.log`
- Escalations: `.tinkertown/escalations.ndjson`
