L1:# TinkerTown Operation Guide
L2:
L3:This guide applies to both the CLI (`tinkertown`) and the macOS app (`TinkerTownApp`). The app triggers the same core orchestration flows (`run/status/logs/retry/cleanup/escalate`) without requiring terminal commands.
L4:
L5:## Role model (single-process)
L6:
L7:When you run `tinkertown run "<request>"`, the **same process** acts as:
L8:
L9:- **Mayor (planner):** Decomposes the request into a task graph and owns the end-to-end run plan. With `use_ollama: true` in config, this uses the configured local Ollama model (recommended: Qwen 2.5 Coder family, e.g. `qwen2.5-coder:32b`).
L10:- **Orchestrator:** Dispatches tasks, manages worktrees, runs the Inspector, and applies the Merge Gate, aiming to complete the run without human intervention under normal conditions.
L11:- **Tinker (worker):** For each task, applies changes in the task’s worktree. With `use_ollama: true`, the configured Ollama model is used to generate patches (recommended: Qwen 2.5 Coder family, e.g. `qwen2.5-coder:7b`); otherwise a placeholder that appends to a notes file is used.
L12:
L13:There is no separate “Mayor” or “Tinker” process or identity. Future multi-agent setups could introduce role/identity (e.g. via `TT_ROLE` or similar) and separate processes.
L14:
L15:## Product Design Requirement (PDR)
L16:
L17:Before any run can start, TinkerTown requires a **Product Design Requirement (PDR)** document. It defines what the project or run is building and is used by the Mayor to produce the task list and by the Tinker for context.
L18:
L19:- **Default location:** `.tinkertown/pdr.json` in the repo root. If this file is missing or invalid, run creation fails with a clear error.
L20:- **Override:** Use `tinkertown run --pdr <path> "<request>"` to point to another PDR file (e.g. `docs/pdr-feature-x.json`).
L21:- **Create a minimal PDR:** `tinkertown pdr init` creates `.tinkertown/pdr.json` with placeholder fields. Optionally: `tinkertown pdr init --title "My feature"`.
L22:- **Validate:** `tinkertown pdr validate` checks the default file; `tinkertown pdr validate --path <path>` checks a specific file.
L23:
L24:The Mayor does not create or edit the PDR; you (or an external process) must add or update it before starting work.
L25:
L26:## Fire-and-forget workflow
L27:
L28:The intended way to use TinkerTown is as a **fire-and-forget** local coding loop:
L29:
L30:1. Ensure a valid PDR exists (e.g. `.tinkertown/pdr.json` or use `--pdr <path>`). Then issue a high-level request via the CLI or app (e.g. `tinkertown run "add dark mode toggle to settings"`).
L31:2. The Mayor and Tinker agents, backed by local models, decompose, implement, and verify changes in isolated worktrees.
L32:3. The Inspector runs local builds and feeds structured diagnostics back into the loop until tasks converge or hit retry limits.
L33:4. The Merge Gate automatically decides merge/reject according to policy and evidence, without prompting for intermediate approvals.
L34:
L35:During a normal run, the system **does not require** additional human input after the initial `run` command. It only interrupts you in two cases:
L36:
L37:- **High-severity escalations:** When a failure is unrecoverable (e.g. guardrail violations, missing tools, or irreconcilable conflicts) and needs a human decision, it is surfaced via escalation records and, where applicable, UI/CLI messaging.
L38:- **Final reviews (optional):** Depending on policy, the Mayor can be configured to pause before merging and ask for a human review/approval; this is treated as an explicit override, not the default.
L39:
L40:## Escalation
L41:
L42:Use `tinkertown escalate` when something needs to be recorded for follow-up (e.g. a failure, a handoff, or a manual decision):
L43:
L44:```bash
L45:tinkertown escalate "Dolt connection timeout after 30s"
L46:tinkertown escalate --severity CRITICAL "Build server unreachable"
L47:tinkertown escalate --run run_20260308_120000 "Task task_001 failed after 3 retries"
L48:```
L49:
L50:Escalations are appended to `.tinkertown/escalations.ndjson` (one JSON object per line: `ts`, `severity`, `message`, optional `run_id`). They are not sent to any external service; they are for local audit and for a human or another process to read later.
L51:
L52:## Config: local models
L53:
L54:Set `use_ollama: true` in `.tinkertown/config.json` to use Ollama for planning and for generating patches. Ensure Ollama is running and the configured `models.mayor` and `models.tinker` are available.
L55:
L56:The recommended configuration for best local performance is:
L57:
L58:- `models.mayor`: a Qwen 2.5 Coder model optimized for planning and review (e.g. `qwen2.5-coder:32b` on capable Apple Silicon machines).
L59:- `models.tinker`: a Qwen 2.5 Coder model optimized for task execution (e.g. `qwen2.5-coder:7b` for parallel workers).
L60:
L61:Pull the models via Ollama, for example:
L62:
L63:```bash
L64:ollama pull qwen2.5-coder:32b
L65:ollama pull qwen2.5-coder:7b
L66:```
L67:
L68:## Health, status, and cleanup
L69:
L70:- **Status (machine-readable):** `tinkertown status <run_id>` shows run state and task list.
L71:- **Status (human summary):** `tinkertown summary <run_id>` uses the Status Agent to report a concise checklist-style summary for the run (overall metrics plus one line per task).
L72:- **Logs:** `tinkertown logs <run_id>` or `tinkertown logs <run_id> --task <task_id>` for events and attempt logs.
L73:- **Cleanup:** `tinkertown cleanup <run_id>` tears down worktrees and removes branches for that run; it also runs orphan cleanup for `.tinkertown` worktrees.
L74:
L75:Run from the repository root (git worktree) that contains `.tinkertown`.
L76:
L77:## Running the CLI from a workspace
L78:
L79:The CLI reads `.tinkertown/` in the **current working directory**, so you must run it from your workspace repo (e.g. `TodoExample`), not from the TinkerTown source repo.
L80:
L81:**Option A — Script (no install):** Build once, then from your workspace:
L82:
L83:```bash
L84:cd ~/Development/TinkerTown && swift build -c release
L85:cd ~/Development/TodoExample
L86:~/Development/TinkerTown/scripts/tinkertown-cli summary run_20260309_155935
L87:```
L88:
L89:Make the script executable once: `chmod +x ~/Development/TinkerTown/scripts/tinkertown-cli`
L90:
L91:**Option B — Full path to binary:** Same build, then from your workspace:
L92:
L93:```bash
L94:cd ~/Development/TodoExample
L95:~/Development/TinkerTown/.build/release/tinkertown summary run_20260309_155935
L96:```
L97:
L98:**Option C — On PATH:** Copy the binary to a directory on your PATH (e.g. `mkdir -p ~/bin && cp ~/Development/TinkerTown/.build/release/tinkertown ~/bin/` and add `export PATH="$HOME/bin:$PATH"` to `~/.zshrc`). Then from any workspace: `tinkertown summary <run_id>`.
L99:
