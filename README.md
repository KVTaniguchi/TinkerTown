# TinkerTown

Local multi-agent coding orchestrator for macOS/Apple Silicon, implemented as a Swift CLI. The same process acts as **Mayor** (planner), **Orchestrator**, and **Tinker** (worker); see [OPERATION.md](OPERATION.md) for role model and escalation.

## Prerequisites

- `git`
- `ollama` (optional; required only when `use_ollama: true` in config)
- `swift` (via Xcode command line tools) and/or `xcodebuild`

## Build and Test

```bash
swift test
swift build
```

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
