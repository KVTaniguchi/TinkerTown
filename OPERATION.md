# TinkerTown Operation Guide

## Role model (single-process)

When you run `tinkertown run "<request>"`, the **same process** acts as:

- **Mayor (planner):** Decomposes the request into a task graph. With `use_ollama: true` in config, this uses the configured local Ollama model; otherwise a simple string-split fallback is used.
- **Orchestrator:** Dispatches tasks, manages worktrees, runs the Inspector, and applies the Merge Gate.
- **Tinker (worker):** For each task, applies changes in the task’s worktree. With `use_ollama: true`, the configured Ollama model is used to generate patches; otherwise a placeholder that appends to a notes file is used.

There is no separate “Mayor” or “Tinker” process or identity. Future multi-agent setups could introduce role/identity (e.g. via `TT_ROLE` or similar) and separate processes.

## Escalation

Use `tinkertown escalate` when something needs to be recorded for follow-up (e.g. a failure, a handoff, or a manual decision):

```bash
tinkertown escalate "Dolt connection timeout after 30s"
tinkertown escalate --severity CRITICAL "Build server unreachable"
tinkertown escalate --run run_20260308_120000 "Task task_001 failed after 3 retries"
```

Escalations are appended to `.tinkertown/escalations.ndjson` (one JSON object per line: `ts`, `severity`, `message`, optional `run_id`). They are not sent to any external service; they are for local audit and for a human or another process to read later.

## Config: local models

Set `use_ollama: true` in `.tinkertown/config.json` to use Ollama for planning and for generating patches. Ensure Ollama is running and the configured `models.mayor` and `models.tinker` are available (e.g. `ollama pull qwen2.5-coder:7b`).

## Health and cleanup

- **Status:** `tinkertown status <run_id>` shows run state and task list.
- **Logs:** `tinkertown logs <run_id>` or `tinkertown logs <run_id> --task <task_id>` for events and attempt logs.
- **Cleanup:** `tinkertown cleanup <run_id>` tears down worktrees and removes branches for that run; it also runs orphan cleanup for `.tinkertown` worktrees.

Run from the repository root (git worktree) that contains `.tinkertown`.
