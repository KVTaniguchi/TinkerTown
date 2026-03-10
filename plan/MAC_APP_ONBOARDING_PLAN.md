L1:# TinkerTown Mac App Onboarding Plan
L2:
L3:## Objective
L4:Deliver a Mac App Store-quality onboarding experience for TinkerTown where users can set up and run local models with zero terminal usage.
L5:
L6:## Product Scope
L7:1. First-run onboarding wizard with model tier selection (`Fast`, `Balanced`, `Best quality`).
L8:2. Automatic system compatibility checks (chip, RAM, free disk, battery/power context).
L9:3. In-app model download/install manager (progress, pause/resume, retry, integrity verification).
L10:4. Plain-language role assignment (`Planner model`, `Worker model`) with defaults.
L11:5. Offline Mode toggle (`Use local models only`) with clear privacy messaging.
L12:6. One-click health check (model inference + repo preflight + build probe + orchestration smoke test).
L13:7. Model management screen (installed models, size, last used, update/remove/reinstall, auto-update policy).
L14:8. Consumer-grade failure handling with guided fix actions.
L15:
L16:## Non-Goals (v1)
L17:1. Multi-machine sync of installed models.
L18:2. Remote/cloud model execution.
L19:3. Multi-user profile management.
L20:4. Marketplace/community model discovery inside app.
L21:
L22:## Architecture Decisions (Must Resolve First)
L23:1. Runtime packaging strategy:
L24:- Option A (recommended): bundle a local inference runtime in app/helper so no Ollama install is required.
L25:- Option B: manage an internal Ollama helper process entirely from app UI.
L26:2. Model registry source:
L27:- Signed, versioned manifest endpoint (JSON) with strict schema and compatibility metadata.
L28:3. Storage layout:
L29:- Use app sandbox container directories for model blobs, manifests, metadata, temporary downloads, and logs.
L30:4. Background transfer model:
L31:- `URLSession` background download tasks with resume support and persistent job state.
L32:5. Integrity and trust:
L33:- Require checksum verification and signature verification before activating a model.
L34:6. App Store compliance:
L35:- Treat downloaded artifacts as model data assets only; avoid executable code download behavior.
L36:
L37:## End-to-End User Experience
L38:
L39:### 1) Welcome
L40:- Message: setup takes a few minutes and no terminal is required.
L41:- CTA: `Start setup`.
L42:
L43:### 2) Device Check
L44:- Detect Apple Silicon class, memory, free storage, power/battery context.
L45:- Present pass/warn status for each capability.
L46:- If the selected tier is too heavy, provide clear recommended fallback.
L47:
L48:### 3) Choose Performance Tier
L49:- Tier cards:
L50:  - `Fast` (recommended): small local coder model, lower resource use.
L51:  - `Balanced`: medium model.
L52:  - `Best quality`: largest model with higher memory/disk requirements.
L53:- Each card shows estimated disk usage, memory recommendation, and speed/quality tradeoff.
L54:
L55:### 4) Model Role Assignment
L56:- Preselect planner and worker models based on tier.
L57:- Advanced mode allows users to override role assignments.
L58:
L59:### 5) Privacy & Offline Mode
L60:- Toggle: `Use local models only`.
L61:- Explain exactly what stays local and when network is used (downloads/updates only).
L62:
L63:### 6) Download & Install
L64:- Display queue with per-model progress, ETA, and controls (pause/resume/cancel/retry).
L65:- Install pipeline: download -> verify checksum/signature -> unpack -> register -> mark ready.
L66:- If install fails, provide concrete reason and one-click remediation.
L67:
L68:### 7) Health Check
L69:- Button: `Run quick test`.
L70:- Checks:
L71:  - Model runtime responds.
L72:  - Planner and worker role calls succeed.
L73:  - Repo preflight checks pass.
L74:  - Build probe executes.
L75:  - Minimal orchestration task succeeds.
L76:- Output status in plain language with fix steps.
L77:
L78:### 8) Completion
L79:- Setup summary with installed models and selected mode.
L80:- CTA: `Open TinkerTown`.
L81:
L82:## Information Architecture
L83:
L84:### Primary Screens
L85:1. Onboarding Wizard
L86:2. Setup Progress/Installer View
L87:3. Health Check Results
L88:4. Model Management
L89:5. Settings (privacy, update policy, role overrides)
L90:
L91:### Model Management Features
L92:1. Installed model list with size/version/last-used/performance summary.
L93:2. Actions: update, reinstall, remove.
L94:3. Auto-update controls (`Wi-Fi only`, `charging only`, schedule window if needed).
L95:
L96:## Core Components
L97:1. `OnboardingStateMachine`
L98:- Deterministic step transitions and resume-on-restart behavior.
L99:
L100:2. `SystemDiagnosticsService`
L101:- Collects hardware/runtime constraints and scores compatibility.
L102:
L103:3. `ModelCatalogService`
L104:- Fetches and validates signed manifest; filters compatible models.
L105:
L106:4. `ModelInstallManager`
L107:- Queue, download orchestration, pause/resume, retries, verification, atomic activation.
L108:
L109:5. `ModelRuntimeAdapter`
L110:- Unified inference interface for planner/worker role usage.
L111:
L112:6. `ConfigFacade`
L113:- UI-facing settings layer that controls model selection and operational policy.
L114:- Internal config file remains implementation detail.
L115:
L116:7. `HealthCheckRunner`
L117:- Executes onboarding validation checks and returns structured outcomes.
L118:
L119:8. `RemediationEngine`
L120:- Maps errors to fix steps and suggested user actions.
L121:
L122:## Data Contracts
L123:
L124:### `ModelManifest`
L125:- `id`
L126:- `version`
L127:- `display_name`
L128:- `tier` (`fast|balanced|quality`)
L129:- `download_url`
L130:- `size_bytes`
L131:- `sha256`
L132:- `signature`
L133:- `min_ram_gb`
L134:- `min_disk_gb`
L135:- `supported_chips`
L136:- `role_default` (`planner|worker|both`)
L137:
L138:### `InstalledModel`
L139:- `id`
L140:- `version`
L141:- `path`
L142:- `size_bytes`
L143:- `installed_at`
L144:- `last_used_at`
L145:- `status` (`downloading|verifying|ready|failed|removing`)
L146:
L147:### `OnboardingState`
L148:- `current_step`
L149:- `selected_tier`
L150:- `planner_model_id`
L151:- `worker_model_id`
L152:- `offline_mode`
L153:- `download_jobs`
L154:- `last_error`
L155:
L156:### `HealthCheckResult`
L157:- `check_name`
L158:- `status` (`pass|warn|fail`)
L159:- `details`
L160:- `error_code`
L161:- `remediation`
L162:
L163:### `UpdatePolicy`
L164:- `auto_update_enabled`
L165:- `wifi_only`
L166:- `charging_only`
L167:
L168:## Failure Handling Requirements
L169:1. Every install/runtime failure maps to a user-readable reason and action.
L170:2. Common failures and remediations:
L171:- Insufficient disk -> show required vs available and open storage guidance.
L172:- Network interruption -> one-click resume/retry.
L173:- Checksum/signature mismatch -> discard artifact and retry from trusted source.
L174:- Unsupported device constraints -> recommend lower tier/model.
L175:- Runtime unavailable -> restart runtime helper and retry health check.
L176:3. Keep raw logs for diagnostics, but show simplified messages first.
L177:
L178:## Security and Privacy
L179:1. Verify manifest signatures and model checksums before activation.
L180:2. Store all model data inside app-managed container paths.
L181:3. Respect Offline Mode by blocking non-essential network calls after setup.
L182:4. Clearly disclose data flow in onboarding and settings.
L183:5. Avoid collecting prompt/code telemetry unless explicitly opted in.
L184:
L185:## App Store and Platform Considerations
L186:1. Ensure all behavior is sandbox-compatible.
L187:2. Use approved APIs for background downloads and local storage.
L188:3. Avoid dynamic code execution patterns that violate store rules.
L189:4. Treat model artifacts as data; runtime execution remains in bundled components.
L190:5. Provide robust behavior when app is terminated/relaunched mid-download.
L191:
L192:## Delivery Milestones and Acceptance Criteria
L193:
L194:### M1: Onboarding Skeleton + Resume
L195:- Wizard screens implemented with persistent progress.
L196:- App resumes exact step after relaunch.
L197:
L198:### M2: Device Diagnostics + Tier Recommendation
L199:- Hardware/disk/power checks working.
L200:- Tier recommendation and downgrade guidance functional.
L201:
L202:### M3: Download/Install Manager
L203:- Background downloads with pause/resume/retry.
L204:- Checksum/signature verification enforced.
L205:- Atomic activation of ready models.
L206:
L207:### M4: Runtime + Role Binding
L208:- Planner/worker role assignment persisted.
L209:- Inference calls route to selected installed models.
L210:
L211:### M5: Health Check + Guided Fixes
L212:- One-click quick test with structured outcomes.
L213:- Failures include clear remediation paths.
L214:
L215:### M6: Model Management + Update Policy
L216:- Model list with update/reinstall/remove.
L217:- Auto-update settings implemented.
L218:
L219:### M7: Hardening
L220:- Reliability, crash recovery, logging, accessibility pass, copy polish.
L221:
L222:### M8: App Store Readiness
L223:- Compliance review, privacy text, QA sign-off, release candidate.
L224:
225:## Testing Strategy
226:1. Unit tests:
227:- Recommendation rules
228:- Onboarding state transitions
229:- Verification logic
230:- Error-to-remediation mapping
231:
232:2. Integration tests:
233:- Interrupted downloads and resume
234:- Corrupt artifact rejection
235:- Install retry and rollback behavior
236:
237:3. UI tests:
238:- Full happy path from first launch to completion
239:- Key failure paths (disk, network, verification mismatch)
240:
241:4. Performance tests:
242:- First model response latency
243:- Setup duration metrics by tier
244:
245:5. Reliability tests:
246:- Resume after app crash/force quit
247:- Long-running download stability
248:
249:## Rollout Plan
250:1. Internal alpha across multiple Apple Silicon configurations.
251:2. Limited beta with instrumentation on setup completion/failure rates.
252:3. Phased release with feature flags for update behavior and optional advanced controls.
253:
254:## Implementation Backlog Template (for Cursor)
255:1. Epic: Onboarding Wizard
256:- Build step router + persistent state model
257:- Implement welcome/device/tier/role/privacy screens
258:
259:2. Epic: Installer
260:- Add manifest fetch/validation
261:- Implement download queue and install pipeline
262:- Implement pause/resume/retry and status events
263:
264:3. Epic: Runtime + Config
265:- Add runtime abstraction and role binding
266:- Add config facade and settings persistence
267:
268:4. Epic: Health Checks
269:- Implement quick test suite and result UI
270:- Add remediation catalog
271:
272:5. Epic: Model Management
273:- Build installed model list and actions
274:- Add auto-update policy controls
275:
276:6. Epic: Hardening + Release
277:- Add telemetry hooks (opt-in)
278:- Finalize QA matrix, accessibility, and App Store documentation
279:
280:## Definition of Done
281:1. A non-technical user can install the app, select a model tier, complete setup, and run a test task without opening Terminal.
282:2. Setup survives app restarts and network interruptions.
283:3. All downloaded models are verified before use.
284:4. Health check failures provide actionable in-app guidance.
285:5. Model lifecycle actions (update/reinstall/remove) are available and reliable.
286:
