L1:# TinkerTown Cursor-Optimized Checklist
L2:
L3:This checklist is tuned for one operator using Cursor model quota efficiently.
L4:
L5:## Operating Rules (Quota-Safe)
L6:1. Work one phase at a time.
L7:2. In each Cursor prompt, include only:
L8:   1. Current phase section from this file.
L9:   2. The matching section from `/Users/ktaniguchi/Development/TinkerTown/specifications`.
L10:   3. Relevant files only.
L11:3. Cap each prompt to 1-3 unchecked tasks.
L12:4. Require Cursor to run/verify before ending each task.
L13:5. Record evidence immediately after completion.
L14:
L15:Evidence format:
L16:- `Evidence: commit <sha>, files <paths>, command output <summary>, artifacts <paths>`
L17:
L18:---
L19:
L20:## Phase 0: Bootstrap
L21:Goal: Create minimal runtime scaffold and config.
L22:
L23:- [x] Create `.tinkertown/` directory structure.
L24:- [x] Create `.tinkertown/config.json` from spec defaults.
L25:- [x] Create run artifact directory conventions (`runs/<run_id>/...`).
L26:- [x] Add README prerequisites section (`git`, `ollama`, `swift`/`xcodebuild`).
L27:
L28:### Prompt To Cursor (Phase 0)
L29:```text
L30:Implement Phase 0 from IMPLEMENTATION_CHECKLIST.md.
L31:Constraints:
L32:- Make only the minimum files/changes needed for these 4 tasks.
L33:- Follow /Users/ktaniguchi/Development/TinkerTown/specifications exactly for config keys.
L34:- Do not implement future phases yet.
L35:- After changes, run any lightweight validation possible.
L36:Return:
L37:1) What changed
L38:2) Validation run
L39:3) Any assumptions
L40:```
L41:
L42:---
L43:
L44:## Phase 1: State Engine + Schemas
L45:Goal: Make run/task/diagnostic persistence real and enforce transitions.
L46:
L47:- [x] Implement `RunRecord` schema + validation.
L48:- [x] Implement `TaskRecord` schema + validation.
L49:- [x] Implement `DiagnosticRecord` schema + validation.
L50:- [x] Implement run/task state enums and legal transitions.
L51:- [x] Persist/load run and task records from disk.
L52:- [x] Add version/migration field handling.
L53:
L54:### Prompt To Cursor (Phase 1)
L55:```text
L56:Implement Phase 1 from IMPLEMENTATION_CHECKLIST.md.
L57:Use /Users/ktaniguchi/Development/TinkerTown/specifications sections:
L58:- 4. State Machine
L59:- 5. Core Data Contracts
L60:- 15. Definition of Done (relevant parts)
L61:Constraints:
L62:- Enforce invalid transition rejection in code.
L63:- Add focused unit tests for schema validation and transition guards.
L64:- Keep interfaces small and explicit.
L65:Return:
L66:1) Changed files
L67:2) Tests added and results
L68:3) Remaining gaps
L69:```
L70:
L71:---
L72:
L73:## Phase 2: Worktree Manager
L74:Goal: Reliable create/use/teardown with cleanup guarantees.
L75:
L76:- [x] Implement worktree create flow and base SHA validation.
L77:- [x] Enforce task command execution inside worktree cwd.
L78:- [x] Implement teardown (`worktree remove --force` + branch delete).
L79:- [x] Add orphaned worktree detection/cleanup.
L80:- [x] Add tests for create/teardown/idempotent cleanup.
L81:
L82:### Prompt To Cursor (Phase 2)
L83:```text
L84:Implement Phase 2 from IMPLEMENTATION_CHECKLIST.md.
L85:Use /Users/ktaniguchi/Development/TinkerTown/specifications section 7.
L86:Constraints:
L87:- Never use destructive repo-wide reset commands.
L88:- Ensure cleanup is idempotent.
L89:- Add tests for partial-failure cleanup behavior.
L90:Return:
L91:1) Changed files
L92:2) Test runs
L93:3) Failure cases handled
L94:```
L95:
L96:---
L97:
L98:## Phase 3: Inspector + Retry Loop
L99:Goal: Deterministic verification with logs and structured diagnostics.
L100:
L101:- [x] Implement verifier command selection (`swift build` vs `xcodebuild build`).
L102:- [x] Persist attempt logs per task attempt path.
L103:- [x] Parse diagnostics into `DiagnosticRecord[]`.
L104:- [x] Implement pass/fail by exit code.
L105:- [x] Implement retry with backoff (0s, 3s, 10s) and max retries.
L106:- [x] Add retry-path tests (fail then pass).
L107:
L108:### Prompt To Cursor (Phase 3)
L109:```text
L110:Implement Phase 3 from IMPLEMENTATION_CHECKLIST.md.
L111:Use /Users/ktaniguchi/Development/TinkerTown/specifications sections:
L112:- 9. Error Taxonomy and Retry Policy
L113:- 10. Verification Contract
L114:Constraints:
L115:- Persist raw logs for every attempt.
L116:- Always emit diagnostic records, including empty arrays.
L117:- Add tests covering retry exhaustion and retry success.
L118:Return:
L119:1) Changed files
L120:2) Test and sample log output
L121:3) Any parser limitations
L122:```
L123:
L124:---
L125:
L126:## Phase 4: Scheduler + Task Graph
L127:Goal: Safe parallelism with dependency and file-lock rules.
L128:
L129:- [x] Implement dependency-aware runnable selection.
L130:- [x] Add same-file lock policy (unless explicitly coeditable).
L131:- [x] Enforce queue policy (oldest runnable, then priority).
L132:- [x] Enforce `max_parallel_tasks`.
L133:- [x] Enforce reassignment limit (`replacement_depth <= 1`).
L134:- [x] Add contention/dependency tests.
L135:
L136:### Prompt To Cursor (Phase 4)
L137:```text
L138:Implement Phase 4 from IMPLEMENTATION_CHECKLIST.md.
L139:Use /Users/ktaniguchi/Development/TinkerTown/specifications section 6.
L140:Constraints:
L141:- Deterministic scheduling behavior.
L142:- Add table-driven tests for dependencies and locks.
L143:- Keep scheduling side effects separate from selection logic for testability.
L144:Return:
L145:1) Changed files
L146:2) Scheduling test matrix summary
L147:3) Edge cases not yet handled
L148:```
L149:
L150:---
L151:
L152:## Phase 5: Mayor/Tinker Adapters
L153:Goal: Structured prompt I/O and patch lifecycle tracking.
L154:
L155:- [x] Implement mayor adapter (request -> task graph).
L156:- [x] Implement tinker adapter (scoped context + diagnostics).
L157:- [x] Implement patch apply stage and patch hash persistence.
L158:- [x] Persist prompt hash per attempt.
L159:- [x] Reject out-of-scope file touches unless explicitly expanded.
L160:- [ ] Add integration test for 2+ parallel tasks.
L161:
L162:### Prompt To Cursor (Phase 5)
L163:```text
L164:Implement Phase 5 from IMPLEMENTATION_CHECKLIST.md.
L165:Use /Users/ktaniguchi/Development/TinkerTown/specifications sections 3, 5, and 6.
L166:Constraints:
L167:- Strictly enforce target file scope.
L168:- Persist prompt/patch hashes for reproducibility.
L169:- Add one integration test that executes parallel task flow end-to-end (mock model output is fine).
L170:Return:
L171:1) Changed files
L172:2) Integration test behavior
L173:3) Contract assumptions
L174:```
L175:
L176:---
L177:
L178:## Phase 6: Merge Gate
L179:Goal: Reproducible merge decisions with conflict handling.
L180:
L181:- [x] Implement merge candidate package (diff stats + verify evidence).
L182:- [x] Reject stale verification evidence.
L183:- [x] Reject unresolved conflict markers.
L184:- [x] Handle merge conflict with single fresh-base retry.
L185:- [x] Persist merge outcome and commit SHA.
L186:- [x] Add merge conflict/reject tests.
L187:
L188:### Prompt To Cursor (Phase 6)
L189:```text
L190:Implement Phase 6 from IMPLEMENTATION_CHECKLIST.md.
L191:Use /Users/ktaniguchi/Development/TinkerTown/specifications section 8.2 and section 6/7 merge-related rules.
L192:Constraints:
L193:- Merge policy must be explicit and test-covered.
L194:- Only one automatic fresh-base retry on conflict.
L195:- Persist clear reason codes for reject/fail.
L196:Return:
L197:1) Changed files
L198:2) Merge policy tests and results
L199:3) Remaining ambiguity
L200:```
L201:
L202:---
L203:
L204:## Phase 7: Guardrails + Safety
L205:Goal: Prevent unsafe command/path behavior and redact sensitive output.
L206:
L207:- [x] Enforce worker path sandbox.
L208:- [x] Enforce blocked command list.
L209:- [x] Add secret redaction before persisting logs/events.
L210:- [ ] Emit `E_GUARDRAIL_VIOLATION` on policy breaks.
L211:- [x] Add negative tests proving guardrails.
L212:
213:### Prompt To Cursor (Phase 7)
214:```text
215:Implement Phase 7 from IMPLEMENTATION_CHECKLIST.md.
216:Use /Users/ktaniguchi/Development/TinkerTown/specifications section 8 and section 9.
217:Constraints:
218:- Fail closed on uncertainty (block when command/path cannot be proven safe).
219:- Add negative tests for blocked commands and out-of-root access.
220:- Show redaction behavior in tests.
221:Return:
222:1) Changed files
223:2) Negative tests and outcomes
224:3) Any remaining bypass risks
225:```
226:
227:---
228:
229:## Phase 8: Observability
230:Goal: Event stream + metrics required by spec.
231:
232:- [x] Implement append-only `events.ndjson`.
233:- [x] Emit run and task state transition events.
234:- [x] Compute required metrics:
235:- [x] `run_duration_seconds`
236:- [x] `task_cycle_time_seconds`
237:- [x] `retry_rate`
238:- [x] `merge_success_rate`
239:- [x] `conflict_rate`
240:- [x] `median_build_time_seconds`
241:- [ ] Add human-readable run summary output.
242:
243:### Prompt To Cursor (Phase 8)
244:```text
245:Implement Phase 8 from IMPLEMENTATION_CHECKLIST.md.
246:Use /Users/ktaniguchi/Development/TinkerTown/specifications section 11.
247:Constraints:
248:- Event writes must be append-only.
249:- Metrics must derive from persisted state/events, not transient memory only.
250:- Add one snapshot-style test for run summary output.
251:Return:
252:1) Changed files
253:2) Metrics calculation method
254:3) Example event lines
255:```
256:
257:---
258:
259:## Phase 9: CLI (v1)
260:Goal: Operable interface for local usage.
261:
262:- [x] Implement `tinkertown run "<request>"`.
263:- [x] Implement `tinkertown status <run_id>`.
264:- [x] Implement `tinkertown logs <run_id> [--task <task_id>]`.
265:- [x] Implement `tinkertown retry <run_id> <task_id>`.
266:- [x] Implement `tinkertown cleanup <run_id>`.
267:- [x] Add help text and examples.
268:
269:### Prompt To Cursor (Phase 9)
270:```text
271:Implement Phase 9 from IMPLEMENTATION_CHECKLIST.md.
272:Use /Users/ktaniguchi/Development/TinkerTown/specifications section 13.
273:Constraints:
274:- Keep CLI output concise and script-friendly.
275:- Return non-zero exit codes for command failures.
276:- Add command-level tests for argument validation.
277:Return:
278:1) Changed files
279:2) CLI usage examples
280:3) Test results
281:```
282:
283:---
284:
285:## Phase 10: Indexer (`TinkerMap.json`)
286:Goal: Refreshable code map with reproducible metadata.
287:
288:- [x] Implement index generation (SourceKitten or fallback parser).
289:- [x] Include `version`, `generated_at`, `source_revision`.
290:- [x] Emit module/file/symbol summaries only (no full bodies).
291:- [ ] Update index only after successful merge cycle.
292:- [x] Add smoke test for index refresh on merge.
293:
294:### Prompt To Cursor (Phase 10)
295:```text
296:Implement Phase 10 from IMPLEMENTATION_CHECKLIST.md.
297:Use /Users/ktaniguchi/Development/TinkerTown/specifications sections 3 and 5.4.
298:Constraints:
299:- Keep index size bounded; avoid implementation body dumping.
300:- Ensure deterministic output ordering for stable diffs.
301:- Add smoke test with fixture source files.
302:Return:
303:1) Changed files
304:2) Example TinkerMap output
305:3) Performance notes
306:```
307:
308:---
309:
310:## Phase 11: Acceptance Tests
311:Goal: Prove v1 behavior against spec scenarios.
312:
313:- [x] Happy path test.
314:- [x] Retry path test.
315:- [x] Conflict path test.
316:- [x] Guardrail path test.
317:- [x] Crash recovery path test.
318:
319:### Prompt To Cursor (Phase 11)
320:```text
321:Implement Phase 11 from IMPLEMENTATION_CHECKLIST.md.
322:Use /Users/ktaniguchi/Development/TinkerTown/specifications section 14.
323:Constraints:
324:- Keep tests deterministic and isolated.
325:- Persist artifacts/log paths for each scenario.
326:- Report pass/fail with concise reason if failing.
327:Return:
328:1) Added tests
329:2) Pass/fail summary by scenario
330:3) Remaining flakiness risks
331:```
332:
333:---
334:
335:## Phase 12: Release Readiness
336:Goal: v1 go/no-go decision with proof.
337:
338:- [x] Confirm all acceptance tests passing.
339:- [x] Confirm required metrics emitted.
340:- [x] Confirm evidence exists for every run/task.
341:- [x] Confirm guardrail negative tests passing.
342:- [ ] Record final end-to-end dry run with run ID/artifacts.
343:- [ ] Prepare v1 release notes and tag plan.
344:
345:### Prompt To Cursor (Phase 12)
346:```text
347:Execute Phase 12 release readiness checks from IMPLEMENTATION_CHECKLIST.md.
348:Use /Users/ktaniguchi/Development/TinkerTown/specifications sections 15 and 16.
349:Constraints:
350:- Produce a concise go/no-go report.
351:- Include specific failing gates if no-go.
352:- Do not introduce new features in this phase.
353:Return:
354:1) Gate-by-gate status
355:2) Evidence references
356:3) Go/no-go recommendation
357:```
358:
359:---
360:
361:## Phase 13: PDR as Required Input
362:Goal: Require a Product Design Requirement (PDR) before any run can start; Mayor consumes PDR + request to produce the task list. See specifications §5.5 and §3.1.
363:
364:- [x] Define `PDRRecord` schema in code (id, version, created_at, updated_at, title, summary, scope, acceptance_criteria, constraints, out_of_scope) and add to `Contracts.swift` (or equivalent) with validation.
365:- [x] Add default PDR path: `.tinkertown/pdr.json`. Document in README/OPERATION that this file is the active PDR when no override is given.
366:- [x] Implement PDR resolution: load from default path or from `--pdr <path>`; validate required fields (pdr_id, title); return clear error if missing or invalid ("Product Design Requirement required. Add `.tinkertown/pdr.json` or pass --pdr <path>.").
367:- [x] Gate run creation: before calling Mayor or creating a run, resolve PDR; if resolution fails, do not create run and surface error in CLI and app UI.
368:- [x] Add `pdr_id` (and optionally `pdr_path`) to `RunRecord`; persist when run is created; ensure existing runs without `pdr_id` still load (e.g. optional field, default or migrate).
369:- [x] Extend Mayor input: change planner API to accept PDR + request (e.g. `plan(pdr: PDRRecord, request: String) -> [PlannedTask]`). Default/fallback adapter and Ollama adapter must both accept and use PDR (e.g. include PDR summary/acceptance_criteria in prompt).
370:- [x] Pass PDR (or summary) into Tinker context so worker receives acceptance criteria and constraints for the task.
371:- [x] CLI: add `--pdr <path>` to `tinkertown run`; app: allow selecting or specifying PDR path before starting a run (or detect `.tinkertown/pdr.json` and show validation errors if missing).
372:- [x] Optional: add `tinkertown pdr validate [path]` to check PDR file and print errors; optional: add `tinkertown pdr init` to scaffold a minimal `.tinkertown/pdr.json`.
373:- [x] Add tests: PDR validation (valid/invalid/missing), run creation blocked when PDR missing, run creation succeeds with PDR, Mayor receives PDR in plan call (mock/adapter test), RunRecord stores pdr_id.
374:
375:### Prompt To Cursor (Phase 13)
376:```text
377:Implement Phase 13 (PDR as Required Input) from IMPLEMENTATION_CHECKLIST.md.
378:Use /Users/ktaniguchi/Development/TinkerTown/specifications sections 3.1, 5.1, 5.5, 13.1.
379:Constraints:
380:- PDR must be required for run creation; no silent fallback.
381:- Keep backward compatibility for loading existing RunRecords without pdr_id (optional field).
382:- Mayor and Tinker adapters must accept PDR; include PDR context in prompts where applicable.
383:Return:
384:1) Files changed (Contracts, Orchestrator, Mayor/Tinker adapters, CLI, app)
385:2) Test list and results
386:3) Any migration or defaulting for existing runs
387:```
388:
389:---
390:
391:## Progress Tracker
392:- Current phase: [12] Release Readiness
393:- Last completed task: Phase 11: Acceptance Tests
394:- Next 1-3 tasks:
395:  - Complete Phase 12 release checks (dry run, release notes).
396:  - Phase 13: PDR as required input (schema, gating, Mayor consumes PDR + request).
397:- Active blocker:
398:- Blocker owner:
399:- Target unblock date:
400:
401:## Completion Evidence Log
402:- [x] Phase 0 evidence: `.tinkertown/config.json`, `.tinkertown/runs/run_20260309_023647/*`, `README.md` prerequisites; commands: `swift build`, `swift test`
403:- [x] Phase 1 evidence: `RunRecord` / `TaskRecord` / `DiagnosticRecord` in `Contracts.swift`, `RunStore` persistence, `StateMachine` transitions; tests: `ConfigAndStoreTests`, `StateMachineTests`, `ContractValidationTests`; command: `swift test`
404:- [x] Phase 2 evidence: `WorktreeManager` with base SHA validation and orphan cleanup; worktree create/teardown invoked from `Orchestrator.executeTask`; tests: `WorktreeManagerTests`; command: `swift test`
405:- [x] Phase 3 evidence: `Inspector` with command selection, per-attempt log persistence via `EventLogger`, and diagnostic parsing; retry loop in `Orchestrator.executeTask` using exit code + backoff schedule; tests: `InspectorTests`, `InspectorCommandSelectionTests`; command: `swift test`
406:- [x] Phase 4 evidence: `Scheduler` implementing dependency-aware runnable selection, same-file lock policy, queue policy, max_parallel enforcement, and replacement depth guard; tests: `SchedulerTests`; used from `Orchestrator.execute` to drive task execution order; command: `swift test`
407:- [x] Phase 5 evidence: `DefaultMayorAdapter` and `DefaultTinkerAdapter` in `Orchestrator.swift` producing planned tasks and scoped worktree edits with prompt/patch hashes in `executeTask`; guardrails enforcing path/command scope; tests: `MayorTinkerAdapterTests`; command: `swift test`
408:- [x] Phase 6 evidence: `MergeGate` for scope validation, conflict marker detection, stale verification rejection, and single retry merge behavior; `TaskResult.verifiedAtSHA` set from `Orchestrator.executeTask`; merge outcome and SHA persisted via `TaskResult.mergeSHA`; tests: `MergeGateTests`; command: `swift test`
409:- [x] Phase 7 evidence: `GuardrailService` enforcing blocked commands and worktree path sandbox; `EventLogger` redacting secrets in events, logs, and escalations; tests: `GuardrailTests` and other suites indirectly using guardrails; command: `swift test`
410:- [x] Phase 8 evidence: `AppPaths` + `EventLogger` providing append-only `events.ndjson` and per-run events; `ObservabilityService` and `RunSummary` computing metrics from `RunRecord`/`RunMetrics`; tests: `EventLoggerTests`, `ObservabilityTests`; command: `swift test`
411:- [x] Phase 9 evidence: `tinkertown` CLI in `main.swift` implementing `run/status/logs/retry/cleanup/escalate` with usage/help text and non-zero exit codes on invalid usage; manual validation via `swift run tinkertown ...`
412:- [x] Phase 10 evidence: `IndexerService` and `TinkerMap` types generating `TinkerMap.json` with version/generated_at/source_revision/modules/files/symbols; tests: `IndexerTests`; command: `swift test`
413:- [x] Phase 11 evidence: high-level scenario tests in `AcceptanceTests` covering happy, retry, conflict, guardrail, and crash-recovery paths; command: `swift test`
414:- [ ] Phase 12 evidence:
415:- [x] Phase 13 evidence: PDRRecord + PDRService in Contracts.swift and PDRService.swift; AppPaths.pdrFile; RunRecord.pdrId/pdrPath/pdrContextSummary; Mayor.plan(pdr:request:), DefaultMayorAdapter + OllamaMayorAdapter; Orchestrator.generatePlan(request:pdr:pdrResolvedURL:), run(request:pdr:pdrResolvedURL:), buildTinkerContext; CLI run --pdr, pdr validate, pdr init; App PDR resolve before generatePlan; tests: ContractValidationTests (PDRRecord), PDRServiceTests, MayorTinkerAdapterTests (plan with PDR); README/OPERATION PDR docs; command: `swift test`
416:
