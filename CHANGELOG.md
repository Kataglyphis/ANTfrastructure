# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-10-20 … 2026-10-22`](docs/changelog-archive-2026-10-22.md) ·
> [`2026-10-19`](docs/changelog-archive-2026-10-19.md) ·
> [`2026-10-13 … 2026-10-18`](docs/changelog-archive-2026-10-18.md) ·
> [`2026-10-08 … 2026-10-12`](docs/changelog-archive-2026-10-12.md) ·
> [`2026-10-01 … 2026-10-07`](docs/changelog-archive-2026-10-07.md) ·
> [`2026-09-22 … 2026-09-30`](docs/changelog-archive-2026-09-30.md) ·
> [`2026-09-08 … 2026-09-21`](docs/changelog-archive-2026-09-21.md) ·
> [`2026-08-29 … 2026-09-07`](docs/changelog-archive-2026-09-07.md) ·
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.

## 2026-10-24 — Python type analysis

- Pin ty 0.0.91 beside Ruff and run it in the Linux x64 preflight: tracked documentation and Linux verifier quality scripts are a strict type gate, while full Linux and Windows scans save findings under ignored `logs/code-quality/`.
- Report missing Python parameter and return annotations with Ruff ANN rules in the same folder and upload the reports from CI. Ty checks types but does not itself require annotations.
- Correct type errors in quality scripts, build helpers and tests; prove that a planted type error fails the new gate and that a failed consumer ty check fails the existing static-analysis driver.
- Keep curated SBOM `--stdout` byte-identical to the generated file on Windows as well as Linux.
- Refresh the mutation manifest totals so the documentation-number suite and Linux preflight agree with the measured inventory.
- Preserve an ignored interrupt for scheduled job commands and use a valid module spec in the free-threaded load-trace fixture, fixing two Linux preflight failures.
- Keep the quick-start README within its 100-line gate and set the ordered-job interrupt trap without a ShellCheck warning.
- Reap mutation test sessions when their shell exits so an inherited output pipe cannot turn a completed baseline into a timeout; refresh stale mutation recipes and the generated gate proof registry.

## 2026-10-24 — CI quality evidence

- Lint Python embedded in tracked consumer shell scripts, including shell-only consumers; fail on extraction errors and batch the hub sweep for Windows Git Bash.
- Require fresh JUnit and package coverage XML after each successful stable Linux Python test leg; expose a per-leg `coverage-min` workflow input.
- Report PowerShell complexity on the selected path in the reusable Windows lint job, with `complexity-strict` available once a consumer meets the limits.
- Grade detected consumer CI lint calls for active, fatal ratchets in the weekly inventory, and report consumers with no detected call.
- Add focused fixtures and mutations for the new failure paths.

## 2026-10-24 — Windows PowerShell quality and harness controls

- Consolidate generated build logs, resource samples and test reports under ignored `logs/` paths on both lanes, including a durable Windows test summary; retain root chain status for live readers and the separate `out/complexity/` reports.
- Move generated complexity JSON results into the Git-ignored `out/complexity/` folder; keep `-JsonPath` optional for local snapshots.
- Add an AST-based Windows PowerShell complexity gate to Windows x64 CI, enforcing 15/5/80 across the full tracked tree; share its parser with the test harness and mutation-test its metrics.
- Refactor Windows build, host, diagnostic and test code until the strict PowerShell scan is clear; lower 25 measured duplication budgets and remove 30 stale entries. The owner-approved budget-12 syntax exception closes the last PowerShell duplication finding without raising the threshold or narrowing coverage.
- Import the exact pinned PSScriptAnalyzer version in parent and batch lint processes; both Windows CI installers read the pin, and action changes trigger the x64 workflow.
- Split Slang shader compilation and CodeQL analysis into smaller phases, with regression tests for cache, failure, fallback and result policies.
- Separate image config token checks from finding assembly while keeping order and deduplication; the history gate tests both.
- Split target CPython staging into PE, copy, redist, launcher and CRT phases; split the LLVM arm64 layout diagnostic's plan and run phases. Both now meet the strict function limits, with new edge-case tests.
- Separate CMake configure's base, CUDA and cross/ROCm argument phases without changing caller override order; focused tests cover both CUDA cache opt-in and ROCm opt-out.
- Split free-threaded wheel setup from the cross-stage plan; tests preserve stale GIL wheel cleanup, one target tag and native no-op behavior.
- Split BuildKit stage argument, cache, metadata and retry preparation into private helpers; stage execution now meets the strict function limits, and tests preserve three or five attempts and gate order.
- Split the BuildKit driver into stage, preseed, cleanup and child argument phases; shared optional stage and child option policies keep cross-lane checks intact.
- Split the ONNX, OpenCV and sccache diagnostics into focused probes, and separated VS bootstrap, MSIX signing and lint reporting phases; the changed scripts now meet the strict PowerShell limits.
- Share ROCm pin forwarding, silo stack capture, host dufs change handling and diagnostic report helpers; focused fixtures keep argument, output and failure behavior covered.
- Share the agent process output reader and separate loop input validation and Claude arguments; real child-process tests cover stderr, timeout and role policy.
- Separate warning-baseline rendering from log streaming so the diagnostic meets strict complexity limits; tests preserve the narrower clang group in the flood count.
- Separate warning-stream parsing from reporting while retaining bounded input batches and compact signal evidence; a new fixture checks counts and CLI output.
- Split RDNA4 per-device changes from host discovery; tests preserve already-correct skips and failure aggregation without touching real hardware.
- Separate host disk-reclaim reporting and daemon work from the guarded file deletion loop; tests retain report-only, apply, build-prune and junction protections.
- Split host dufs setup into executable, server, task and endpoint phases; tests preserve report-only behavior and hidden process launch.
- Separate VHDX guest reporting from compaction; host-free tests cover ReFS warnings and unattached disks.
- Separate cuDNN verification from CUDA installation; tests fail each missing header, library and DLL class.
- Separate TensorRT archive search from bounded NVIDIA download fallbacks; tests preserve staged-archive precedence and failure reporting.
- Separate the module-free Windows build-copy probe's base pin reader; tests reject incomplete version fields.
- Separate active CDSP driver discovery from the GenieX NPU symbol report; tests preserve stale-copy rejection and advisory discovery failures.
- Split the publish-gate AST fixture into solve, export, toolchain and parent checks; its 36 behavior and mutation tests still pass.
- Split Python app bundle launcher and data staging into separate steps; tests preserve declared console scripts and copied data paths.
- Split BuildKit variant behavior from tag and chain wiring tests with one shared fixture; all 30 focused assertions still pass.
- Separate Python CI leg selection and failure policy from the driver; existing settings and child-process tests cover the handoff.
- Split GenieX lane launch from listener checks, serve arguments and endpoint reporting; tests preserve hidden startup and model mismatch warnings.
- Separate LSM wait-handle discovery from system-wide holder reporting; a fake debugger fixture verifies thread binding and the R10 handle.
- Split arm64 Python test staging into interpreter, site-install and per-leg steps; fixtures check cleanup and free-threaded inputs.
- Remove one obsolete duplication exception and lower a measured budget after the refactors.

- Require all 44 current harness fixture tests to pass in the byte-verdict mutation control; retain exact discovery, failure and skip checks.
- Verify that removing the byte comparison still fails the suite.

## 2026-10-24 — share architecture parsing, triplet queries and installer transport

- Share rootless binfmt CSV parsing while retaining caller-specific architecture validation, namespace commands and statuses.
- Share best-effort triplet queries without changing compiler or GStreamer directory and fallback policies.
- Share UV/Rust installer curl, checksum, execution and cleanup while retaining temporary variables and mismatch diagnostics.
- Carry the installer companion in copied UV fixtures and the narrow Rust build mount; verify cold imports and recovery.
- Remove three resolved duplication exceptions with independent original/current receipts and unchanged gate settings.

## 2026-10-24 — share compiler probes, ORT selectors and wheel platform policies

- Share compiler source-fixture transport and GCC version capture without changing probe verdicts, temporary state or strict-shell failures.
- Share ORT component exclusions and file predicates while retaining shallow record scans, tree archive candidates and partial traversal findings.
- Share wheel platform resolution with distinct LiteRT and Torch fallback policies; preserve each GStreamer architecture lookup and its failure status.
- Share stream-fixture startup while retaining independent tag, packaging and provenance expectations.
- Point Linux action image inputs at the existing common defaults contract.
- Remove four resolved duplication exceptions without changing scanner thresholds or independent expected results.

## 2026-10-24 — share lint scope, wheel transport and packaging execution

- Share lint scope initialization in the driver shell while preserving root selection, remaining arguments and rejected-root errors.
- Carry both scope companions in copied-driver fixtures and retain independent lint verdict assertions.
- Share quiet wheel unpack/pack commands while keeping caller-specific payload edits, statuses and cleanup.
- Share packaging command execution with separate best-effort and sudo failure handlers.
- Remove five resolved duplication exceptions; verify 48 lint, 96 wheel and 28 packaging original/current receipts without changing scanner settings.

## 2026-10-24 — share version shape, guarded links and raw pin lookup

- Share three- and four-part numeric version checks while preserving exact match state, compiler defaults, builder warnings, docs failures and Rust normalization.
- Share guarded GCC/Vulkan link actions with unchanged source-probe order, link flags, lazy sudo policy and failure behavior.
- Share Android/Rust raw pin lookup while retaining empty/unset/export state, all matching lines, whitespace and read-failure behavior.
- Require fresh canonical companions and expected exports; selected-file failures stay failures in conditional contexts.
- Remove seven resolved duplication exceptions while keeping literal test oracles and the scanner settings unchanged.

## 2026-10-23 — share artifact refusal, media probes and download initialization

- Share unsupported artifact-mode diagnostics while preserving exact stderr, status and lazy branch behavior.
- Share media cross/native dispatch and FFmpeg encode/decode commands, retaining native failure policy, caller globals, codec diagnostics and temporary-file cleanup.
- Share standalone Android/Vulkan download initialization with unchanged supplied-helper precedence, core lookup order and source-failure policy.
- Carry the bootstrap beside both standalone callers across Android, SDK, package and Torch copies, including the Vulkan install companion in Torch.
- Remove three resolved duplication exceptions; retain all independent smoke and architecture assertions.

## 2026-10-23 — share linker policy, service actions and cross-chain help

- Share the optional LLD check with its original literal-`false` policy, preserving lookup order, status, compiler arguments and logs.
- Share host Python path selection with explicit and version-derived profiles, preserving caller overrides, pin order, PATH fallback and required platform companions.
- Share nerdctl installer service actions while retaining caller guards, unit splitting, action order and warning policy; verify 204 independent offline scenarios.
- Share architecture and repository help rows between the cross-chain driver and its verification wrapper with unchanged complete output.
- Load the verification wrapper's function-only renderer only for help; preserve opaque argument forwarding and the child's exit status without that companion.
- Keep independent full-help receipts and explicit missing-renderer and forwarding assertions.
- Share actual cache-slug deletion while retaining separate trim-stop and protect-and-continue policies, quiet diagnostics and guarded cache roots.
- Remove four resolved duplication exceptions without adding allowances or changing scanner settings.

## 2026-10-23 — share native compiler paths and test fixtures

- Share native GCC system-path exports between Torch setup and the generated shell profile, preserving existing flags and expansion at profile sourcing time.
- Carry the mandatory path helper through Android, package and Torch images; keep independent environment receipts and negative gate tests.
- Use canonical truthiness in the FFmpeg fixture and share lifecycle fixture setup and cleanup while keeping explicit test assertions.
- Remove two resolved duplication exceptions and lower the lifecycle budget from 12 to 11; retain the remaining independent retention assertions.

## 2026-10-23 — share push selection, compiler opt-ins and wheel manifests

- Share runtime push selectors with unchanged accepted flags, assignment order, unset state and gates-only behavior.
- Share optional compiler-tool checks while preserving legacy opt-out spellings, lookup status and each caller's command arguments.
- Share wheelhouse manifest bytes between host and image diagnostics, with independent golden hashes and required copied companions.
- Remove four resolved duplication exceptions without raising budgets or weakening gates.
- Archive complete 2026-10-20 through 2026-10-22 entries with text preserved and relative links rebased.

## 2026-10-23 — share containment, image arguments and FFmpeg enumeration

- Share lexical root containment with unchanged caller slash policies; carry its canonical helper through narrow media mounts and copied provenance fixtures.
- Share image-CLI argument binding while keeping inspect and registry status, diagnostics and default-tool policies separate.
- Share FFmpeg runtime-file enumeration with exact selection, output and distinct process-substitution/pipeline failure behavior.
- Share runtime help stage descriptions and section rendering without changing complete help bytes or caller-specific text.
- Share cross-target callback assignment and repository help text while preserving raw values, dynamic caller locals and exact help columns.
- Remove resolved duplication exceptions and lower measured overlap budgets without raising limits or reducing scan coverage.

## 2026-10-23 — reduce Windows fixture and tool lookup duplication

- Share LLVM bare-name and `.exe` lookup while preserving optional archiver use and required MASM selection.
- Keep the scoped environment helper's loop variables from shadowing caller locals, move the FFmpeg fixture into Pester's shared scope, convert full-loop engine smoke tests to distinct data cases, reuse the batch-tool fixture for Bazel, and lower the measured agentic-test self-match from 45 to 39.
- Share Torch and torchvision ROCm target-family selection through one helper at both original setup points.
- Share leaf-file gap detection across MIGraphX install, ORT EP staging and license checks while preserving each caller's required-file list.
- Share host tree byte, file and access-error enumeration for VHDX verification and disk-reclaim sizing while preserving caller-specific verdicts.
- Centralize host buildctl lookup while retaining each script's candidate and PATH fallback policy.
- Share host elevation detection between lock reset and component-store repair while keeping their throw and interactive-exit policies.
- Share the wininit CIM query between silo baseline collection and polling while retaining timeout and baseline-exclusion behavior.
- Share CPython ABI probing between app and uv modules while preserving fatal wheel-fit checks and optional twin-store selection.
- Share Meson wrap-git and forced-libffi archive download, extraction and cleanup while keeping caller-specific failure and wrap deletion policies.
- Share operation timing and failure capture across build steps, gates and optional operations while preserving each caller's verdict policy.
- Pass the flat ROCm BuildKit module mount explicitly to the llama.cpp and Torch installers, removing their duplicate root discovery while retaining checkout defaults.
- Share source-build copy-if-absent and lavapipe module-path validation; pass the mounted module root explicitly to keep the BuildKit installer mount flat.
- Share OpenCL ICD 64-bit registry entry access between ROCm installation and smoke checks; keep path validation fatal and findings caller-owned.
- Delegate the CrossBundle package-architecture export to `WindowsTargetArch.Common`.
- Share the bounded dual-stack TCP probe between URL checks and the BuildKit sccache guard while preserving malformed-URL and timeout behavior.
- Share Dockerfile stage indexing and literal test-directory cleanup across Windows suites, preserving suite-specific stage rules and cleanup scopes.
- Return validated snippet ASTs and lexer tokens from one harness parse, so comment-aware structural scans reject malformed input before inspecting declarations; reuse harness ancestor traversal in GenAI wiring checks.
- Route the ORT WebGPU image probe through the shared Python JSON transport, preserving mode arguments and caller-owned findings for malformed or failed runs.
- Route TVM ROCm runtime and codegen probes through the shared Python JSON transport, preserving TVM finding labels and child diagnostics.
- Share Python report selection, exit verdict and decoding with the injectable IREE ROCm runner, preserving its no-tail finding policy.
- Resolve CUDA and TensorRT image installer modules through the shared container-image bootstrap, passing the flat BuildKit module root explicitly.
- Share `SCCACHE_MAX_JOBS` defaulting across host-cache and CMake setup while preserving each caller's activation point and logging.

## 2026-10-23 — close the ordered-worker cancellation race

- Register and gate scheduled work before it can escape cancellation; join only owned supervisors and their suite/watchdog groups.
- Preserve caller signal policies and ordered reports while recording failed supervision or cleanup as a failed job.
- Exercise interruption during blocked PGID publication, nested runner cancellation, timeout cleanup and unrelated caller jobs with deterministic fixtures.
- Share apt-list cleanup between package and Torch setup with the early image companion, and retain exact GenAI exception reporting through one emitted recorder.

## 2026-10-23 — share fetch and runtime validation lifecycles

- Share missing-checkout clone preparation while preserving exact ORT and GenAI retry, submodule, cwd and Python requirement policies.
- Share unresolved-library collection and summaries without changing artifact selection, partial resolver output, repair advice or fatal denial gates.
- Share ordered consumer fact guards in the existing consumer-contract library while preserving lazy Android checks and caller-specific verdicts.
- Render common runtime/SDK help rows centrally with exact caller formatting and runtime-only environment-consumption checks.
- Share best-effort Torch-missing marker writes and cache-aware apt-list cleanup with unchanged import, fallback and failure policies.
- Compare original outputs, statuses and lookup order against independent fixtures; remove resolved duplication exceptions without increasing limits.

## 2026-10-23 — remove another Windows duplication wave

- Scope FFmpeg codec and Vulkan Validation Layers compiler variables with the shared environment helper, route GPU diagnostics through shared Docker discovery, and build wheel/sccache fakes with the shared batch-tool fixture.
- Cover environment restoration after success and failure, resolver removal and parse mutations, while retaining the original fixture behavior.

## 2026-10-23 — remove another Windows duplication wave

- Share CMake cache parsing, lavapipe ICD registry writes and container-client capture while preserving caller-specific verdict and failure policies.
- Split the PowerShell literal masker into state handlers so the complexity gate can grade it without freezing an exception.
- Add focused regression cases for raw cache values, registry write failures and container inspect stream policy.

## 2026-10-23 — share source-build failure summaries

- Close the active failed phase and print its caller-labeled summary through one helper across source builders; keep each caller's rethrow, cleanup and trap behavior.
- Add integration and mutation coverage for failure labeling, phase status and error propagation.

## 2026-10-23 — remove another Windows duplication wave

- Share ONNX source-patch fallback and TVM ROCm probe lifecycles while preserving caller patch, argv, wait and verdict policies.
- Share CUDA target-usability checks, source-build preparation, Python wheel DLL search paths and requirements, Agentic execution, RDNA4 filtering, and Lavapipe asset facts.
- Share Windows test fixtures and mutation setup while keeping suite-specific assertions and failure controls.
- Correct PowerShell function-boundary scanning for braces in strings, comments and here-strings; add a regression fixture without removing literal tokens from comparison.
- Remove 16 stale Windows duplication exceptions and lower 12 measured budgets without widening thresholds or narrowing scan coverage.

## 2026-10-23 — share Python paths, GPU repositories and runtime preparation

- Remove six resolved Linux duplication exceptions without changing scanner limits or coverage.
- Share executable venv selection and workspace overrides; copied UV and WebDAV modules carry the pure Python probe companion.
- Share optional-checksum repository-key downloads and ROCm source rendering while preserving warnings, retries, status and exact repository bytes.
- Share media development-link eligibility while keeping link actions, logging order and failure handling with their callers.
- Share runtime preparation with unchanged architecture binding, exported dry-run state and validation failures.
- Preserve independent behavioral receipts and add 44 mutation checks; remove the exercised WebDAV dead-function exception.

## 2026-10-23 — share logger fallbacks, ELF checks and media probes

- Share standalone logging fallback registration while retaining plain/ANSI bytes, command/function lookup, streams, fatal errors and caller state.
- Carry the logger in Toolchain, Media and isolated payload copies; reuse the canonical platform ELF parser without leaking platform initialization.
- Share raw compiler-header queries, optional Python paths and Cargo environment bindings with caller ordering and validation preserved.
- Share test fixture lifetimes and verdicts while keeping process cleanup independent of the production code under mutation.
- Remove measured duplication exceptions and lower existing budgets without changing scanner limits or scope.

## 2026-10-23 — share Windows graph, debugger and fixture lifetimes

- Reuse the architecture DLL graph for cross bundles while preserving multi-root breadth-first order, machine checks and indexed API-set/system traversal.
- Share LiteRT-LM regex guards and TVM artifact cardinality with existing source operations.
- Share native output capture and CMake/smoke environment scopes with unchanged caller verdicts and fatal companion imports.
- Share silo debugger transport and wininit queries; fix manual handle mode reading uninitialized debugger state and keep invasive argv intact.
- Share checked local git setup, batch writers, file-tree initialization and AST readers across Windows suites.
- Make shared source-probe children terminate on setup errors; retain portable consumer checks beside separately discovered native batch execution.
- Remove four resolved Windows duplication exceptions (372 to 368) and lower five measured budgets without increasing limits or reducing scan coverage.
- Pass all 2,467 Windows tests, strict lint across 451 files and 65 portable Linux cases; raise the discovery floor to 2,442.

## 2026-10-23 — share ONNX staging, Renovate reports and gate fixtures

- Share ONNX cross-toolchain arguments and advisory filename-based library actions, retaining compiler order, copy/strip selectors, depths and repack decisions.
- Share ONNX Runtime FetchContent names while keeping verifier traversal and caller-specific `ortlib` policies.
- Share Renovate listing indentation and conditional advice; preserve output bytes, refusal status and rollback dispatch.
- Share copied-gate, Vulkan and UV fixtures without dropping existing assertions; remove measured duplication exceptions without increasing budgets or limits.

## 2026-10-23 — share Windows acquisition, copy and probe operations

- Share pinned lavapipe acquisition across host and image installers while retaining caller PE, ICD, registry and environment checks.
- Share disk-space probing without confusing measured zero with an unknown drive or changing stage refusal policies.
- Share bounded artifact-copy transport and temporary test environments while retaining caller flags, failure thresholds and no-scope behavior.
- Share source file-tree staging and ordered patch accounting while keeping file filters, changed diagnostics and fatal minimums.
- Share working-directory, fake-download and source-command fixtures with failure cleanup and real mutation controls.
- Fix wildcard interpretation in fixture cleanup; bracketed directory prefixes must be removed after both successful and failed bodies.
- Remove one resolved Windows duplication exception and lower four measured budgets without adding exceptions or weakening gates.
- Pass all 2,441 Windows tests and strict lint over 441 files; raise the discovery floor to 2,416.
- Verify 68 portable cases on Linux, the three deferred batch-setup faults and all four shared harness mutation gates.

## 2026-10-23 — classify the shared cache utility as a core leaf

- Register `compiler-cache-utils.sh` as L0 so the layer gate accepts its intended use by `common.sh` and enforces that the helper sources no core modules.
- Prove the classification and no-upward-import constraint with two mutations.

## 2026-10-23 — share Linux cache, dependency and packaging behavior

- Remove 14 measured duplication exemptions through shared cache probes, staged Python reporting, Debian metadata and test fixtures; keep scanner thresholds and scan scope unchanged.
- Carry cache utility companions in narrow base-image mounts and preserve caller startup, version, output and failure policies.
- Preserve exact metadata bytes, fixture status and existing assertions, with mutation proofs for the new shared behavior.
- Fix reversed-path duplication diagnostics and guard unique self-pair reports without changing enforcement counts.

## 2026-10-23 — share Windows preparation and environment lifetimes

- Share compiler-rt verification, extraction and library discovery while retaining base-stage warnings and source-build failures.
- Share source cache setup, portable ZIP tools, cross-protoc preparation and DLL dependency traversal with caller-specific policies.
- Share UV interpreter probes, Linux helper lookup and literal staging-directory setup without weakening required module imports.
- Restore temporary environments after partial setup or GenieX launch failure; apply sanitizer variables only to the test child.
- Share recursive silo log read grants and fixture allocation, batch-tool setup and mutation lifetimes; retain negative controls and cleanup assertions.
- Remove 24 Windows duplication exceptions (397 to 373) and lower 13 measured budgets without relaxing scan coverage or limits.
- Raise the Windows test-discovery minimum to 2,378 after all 2,403 merged tests passed.
- Preserve portable batch byte checks and native Windows execution, and update the Linux mutation receipt for all 38 harness cases.

## 2026-10-23 — restore portable harness mutation baselines

- Preserve all native batch execution checks in their separately discovered Windows suite, sharing fixture construction and mutation lifecycle.
- Verify exact ASCII/CRLF batch bytes and real writer mutations in the shared harness suite, restoring all 28 cases on Linux without skips or command emulation.
- Retain quoted arguments, final exit and early-exit execution assertions for native Windows.

## 2026-10-23 — share Linux CLI, disk and workflow operations

- Share nonempty CLI argument handling and lint scope initialization; carry the existing CLI companion in copied library fixtures.
- Share core suffix, caller-directory, disk-probe and stage-publication operations while retaining ordering, raw values and caller failure policies.
- Share lane YAML queries and mutation fixtures without dropping cases; retain Linux multiword interpreter and Windows path policies.
- Share workflow document construction and Flatpak failure fixtures with unchanged assertions and exact generated YAML comparisons.
- Remove measured duplication exceptions and lower remaining budgets without relaxing thresholds or scan scope.

## 2026-10-23 — continue Windows source and workspace cleanup

- Remove three private ROCm suite path resolvers in favor of the shared source reader and isolated script workspace.
- Share build-log and Cargo target resolution while preserving external absolute paths and relative workspace roots.
- Share LLVM compiler identity capture across capture, baseline and candidate modes; pin real command arguments, output and status.
- Add workspace cleanup, malformed-source and path regressions; remove another resolved duplication exception without relaxing the gate.
- Raise the Windows discovery minimum to 2,318 for the expanded regression set.

## 2026-10-23 — share Linux artifact collection and probe execution

- Share WASM artifact collection and IREE Android runtime options while retaining caller build and argument policies.
- Share Ubuntu source-file enumeration without changing ordering or shell options.
- Share media artifact verdicts and paired-image probes; preserve symlink admission, empty-output guards and failure counts.
- Share Renovate rollback, logging-trap, module-shadow and ownership fixtures with unchanged assertions and mutation proofs.
- Share version-bump, provenance, lint and GenAI fixture setup; keep required worker functions distinct from optional definitions.
- Remove resolved duplication exemptions without increasing budgets or narrowing scan coverage.

## 2026-10-23 — share remaining Windows operations and fixtures

- Share Meson binaries, ARM per-file features, optional source edits, machine names, handoff transfers and sccache command lifecycle.
- Share compiler-wrapper environments, packaging cleanup, CMake diagnostics, Flutter links and lazy agentic configuration while preserving caller policies.
- Share host guards and diagnostic verdicts, rename evidence, directory rows and replay traces; retain exact streams and failure cleanup.
- Bind required module companions into each owner scope without forcing reloads; preserve cold and warm visibility and fail on missing dependencies.
- Carry diagnostic companions through narrow probe Dockerfile mounts and prove their import layout with missing-companion controls.
- Share batch-tool, child-import, source-literal and mutation fixtures; keep parse/import failures separate from assertion failures and lower only measured duplication budgets.
- Raise the Windows discovery minimum to 2,313 after a full run passed all 2,337 tests.

## 2026-10-23 — broaden Windows duplication cleanup

- Share GPU and Python probe transport, smoke scratch and verdicts, source-module lookup, TVM wheel packaging, bundle environment models and FFmpeg listing checks.
- Share host maintenance, isolation diagnostics, LLVM command plans and ONNX replay parsing; correct literal match counts and reject malformed host CIDR values.
- Share consumer timing, container transport, logging, benchmark rendering, runtime copies, path resolution and signing conversion; keep caller failure, quoting and password policies.
- Share fixture state, fake-function lifetime, populated temporary directories and AST ancestry; retain independent expectations and add cold-import, regression and mutation proofs.
- Remove resolved Windows duplication exceptions and lower remaining budgets without changing scan scope or thresholds.
- Raise the Windows test-discovery minimum to 2,252 after measuring 2,275 passing tests.

## 2026-10-23 — share Linux provenance and verification fixtures

- Share ORT and GenAI byte-verdict logic through the existing provenance owner, retaining distinct archive and exemption policies.
- Share TVM wheel and ancestry test execution while preserving failure statuses and every assertion.
- Share Ubuntu mirror error aggregation; retain all probes and prove failure propagation with mutations.
- Remove resolved duplication exemptions without changing scan coverage or frozen budgets.

## 2026-10-23 — share Linux cache, payload and lifecycle behavior

- Share side-effect-free cache policy and statistics, with explicit companions in narrow compiler mounts and media copies.
- Share the optional package payload inventory while preserving fourteen copies, five advisory observations and all three Dockerfile closures.
- Reuse Android patch dispatch, optional media stripping and production lifecycle predicates; retain guards, failure policies and child cleanup.
- Add offline characterization and mutation proofs and remove resolved duplication exemptions without relaxing gates.

## 2026-10-23 — repair portable CI fixture baselines

- Remove accidental ripgrep requirements from six Linux fixture suites and require exact no-match status in negative searches.
- Add a restricted-PATH regression with all 244 existing assertions and mutation proofs for missing search tools.
- Normalize the approved Windows harness file-tree join through the PowerShell provider; retain all nine fixture cases and three lifecycle mutation proofs.
- Preserve the Linux duplication cleanup while fixing the failing develop preflight and mutation baselines, without skips or relaxed gates.

## 2026-10-23 — share native builds and verification targets

- Share native ONNX build and wheel collection while preserving CPU retries, AMD invocation and original failure status.
- Share cross-verification target selection and normalization; preserve caller fallbacks, diagnostics, resolver failures and architecture restoration.
- Share LiteRT web vendoring and real lint-consumer fixtures with independent expected results.
- Share bounded GCC release downloads, compiler-cache help and unknown-option diagnostics while retaining caller arguments and command policies.
- Add characterization and mutation proofs; remove resolved Linux duplication exemptions without changing Windows source or gate thresholds.

## 2026-10-23 — share Linux initialization and web probes

- Share toolchain companion lookup and compiler-cache launcher fixtures while preserving per-caller precedence, fallback and source failure behavior.
- Share required framework/platform initialization with explicit build companions and narrow Dockerfile wiring.
- Share Flutter HTTP and size probes while preserving diagnostics, strict thresholds and curl exit codes; add baseline characterization and mutations.
- Remove resolved Linux duplication exemptions and two obsolete ShellCheck warning freezes without increasing budgets or changing Windows source.

## 2026-10-23 — reduce Windows behavior duplication

- Share source-archive extraction while keeping strict failures, pinned dangerous-link checks and optional tar cleanup.
- Share ORT chain file indexing while preserving each gate's recursion, filename and unreadable-file policies.
- Share Flutter plugin patching and artifact-copy lifecycle; retain idempotence, CMake-state exclusions and robocopy warnings.
- Share sccache diagnostic startup, compile/source setup and stats parsing while keeping environment choices and verdicts per mode.
- Share Python CI tool and child-driver fixtures; preserve exit status, quoting, call-log isolation and caller-specific summaries.
- Add focused regression and mutation proofs; remove resolved duplication exceptions and lower remaining budgets without relaxing the scan.

## 2026-10-23 — continue Linux quality and runtime deduplication

- Share host architecture probing with unchanged target/build precedence and failure fallbacks; reuse host Python version selection and ordered LLVM builder discovery.
- Share C++/tidy file traversal and compiler-cache fixtures while preserving configuration, exclusion, launcher and environment policies.
- Share runtime shell transport and scalar metadata lookup, retaining wrapper bytes, Python guards and required/advisory verdicts.
- Share critical-fix predicates and record parsing; preserve regression proofs through mutation retargeting and add local characterization tests.
- Share GHCR version metadata through a required standard-library companion; retain dry-run, age and kept-index protection, verified with offline fixtures.
- Remove resolved Linux duplication exemptions and lower remaining budgets; Windows source remains untouched.

## 2026-10-23 — share Linux smoke and verification behavior

- Share Android/compiler object probe lifecycle while preserving C programs and ELF verdict policies; reject allocation and cleanup failures.
- Share ONNX media probe dispatch while retaining required Runtime, optional GenAI and CPU-provider checks.
- Share argument declaration traversal and fatal reporting, retaining exact counts, pin exemptions and diagnostics.
- Share disk-guard and audit fixtures with independent inputs and rollback assertions; add regressions and mutation proofs.
- Remove resolved duplication exemptions and lower remaining budgets without editing Windows source or changing thresholds.

## 2026-10-23 — continue Linux duplication cleanup

- Share named-option dispatch across Linux build parsers while preserving aliases, raw values, nameref destinations, consumption and diagnostics.
- Share best-effort repository fetching through the existing download companion; keep generic and TVM checkout failure policies distinct.
- Share compiler ELF fallback verdicts and fatal/advisory failure handling without changing diagnostics.
- Share TVM argument fixtures and parallel-loop child setup while retaining independent expected results and failure cases.
- Add characterization and mutation proofs; shrink duplication exceptions without editing Windows source or changing scan coverage.

## 2026-10-23 — expand parallel duplication cleanup

- Share Torch wheelhouse preparation and collection; propagate previously swallowed sysconfig, wheel repair, retagging and copy failures.
- Share GStreamer cross-compiler initialization while preserving stage-only libstdc++ repair, legacy fallback and pinning.
- Share Windows formatting discovery and executable lookup, preserving distinct C/C++ and Dart policies; report missing clang-format correctly under strict mode.
- Share Windows lint traversal and diagnostics, retry fixtures, FFmpeg listings and OpenCV AST wiring checks; preserve all existing cases and platform failures.
- Share healthcheck tool probes, stage-log verdicts and warm-build fixtures; reuse directory creation for the CUDA cache diagnostic.
- Group Python requirement hashes and share lifted-module lifecycle while preserving constructor/body arguments and cleanup on failure.
- Add focused regressions and mutation proofs; remove resolved exemptions and lower remaining budgets without changing thresholds or scan coverage.

## 2026-10-23 — parallel duplication cleanup

- Share cross-Python context, directory lookup and pkg-config suffix composition while preserving staged precedence, argument forwarding and failure paths; share the foreign-target guard without changing raw comparisons or errexit.
- Share Vulkan target launch arguments and component accounting; retain command traces, required-component failures, loader WSI checks and glslang shared/static order.
- Share Windows architecture, artifact and UV test fixtures, preserving malformed binary layouts, child exit-code checks, caller-owned errors and package-specific assertions.
- Share workflow YAML fixture builders and wheel-metadata fixtures; preserve malformed cases and strengthen the metadata-header boundary proof.
- Add local regression and mutation proofs; remove resolved duplication exemptions without changing scan coverage or thresholds.

## 2026-10-23 — share compiler selection, logging and OCI fixtures

- TVM compiler validation and selection share pinned-name and fallback resolution; preserve overrides, wrapper inputs and missing-tool failures.
- Share plain and colored log-prefix formatting, retaining byte sequences, severity labels, streams, NO_COLOR precedence and fatal error behavior.
- Share parent-context and no-push guard fixtures while retaining the OCI handoff cases; remove the three resolved duplication exemptions and the obsolete ShellCheck warning freeze, and add mutation proofs.

## 2026-10-23 — share Linux bundle packaging lifetime

- Keep the three public packaging APIs and format layouts while sharing scoped facts, bundle copying, desktop/icon staging, architecture validation and the final artifact verdict.
- Preserve renderer failures and Bash errexit, including an early AppImage copy failure; prevent stale artifacts from turning failed renderers green.
- Add local dispatch, architecture and staging regressions with mutation proofs; retain existing archive and Flatpak checks, remove the packaging self-duplication exemption and lower the remaining cross-file budget.

## 2026-10-23 — share ONNX web build and codec-ratchet operations

- Share the three lockfile-exact npm retries and both JS artifact verdicts in the ONNX web step; retain directory order, diagnostics, fatal failures and extension-specific copies.
- Exercise the full step with stubbed npm, sleep and cleanup, using the real logging library; verify the same 53 assertions against the previous implementation.
- Share codec package set differences while preserving both directions of its ratchet; add mutation proofs and remove the resolved duplication exemptions.

## 2026-10-23 — share module visibility and ONNX smoke fixtures

- Re-export and build-call closure suites share a fresh-session module probe; discover declarations through parsed ASTs and retain child exit codes, diagnostics and isolation.
- Use one ONNX inference stub for generated-program and transported-program checks; both reject empty or truncated models.
- Remove resolved duplication exceptions and cover missing exports, import failures and quoted paths with local fixtures and a mutation proof.

## 2026-10-23 — share agentic phases and backlog counting

- Share command execution, log redirection and dry-run handling across build, test and quality phases; preserve their distinct failure policies.
- Share task-state counting and remove the agentic-loop self-duplication exemption; cover local execution and backlog contracts with regressions and mutations.

## 2026-10-23 — consolidate Windows source patch families

- GStreamer, IREE, LiteRT-LM, C++ keyword conversion and Ninja cleanup share the patch API's file and verdict handling; keep default warnings and caller-owned counters with an optional diagnostic-only quiet mode.
- Fix repeated OpenCV 5 header insertion by using the instance regex match-count overload; cover it with local fixtures and a replace-all mutation.
- Share patch diagnostic fixtures and index Dockerfile stages during parsing; preserve existing platform failures and remove resolved duplication exemptions.

## 2026-10-23 — share cross and Canadian GCC builder invocation

- Cross GCC and Canadian native GCC share builder argument construction and invocation, retaining environment, job counts, sysroot, caching and host distinctions.
- Fail ordinary cross builds explicitly even under conditional callers with stale installed tools; preserve the Canadian link-skip policy and fatal diagnostic.
- Fake-builder regressions and seven mutations cover the invocation contract; remove the GCC self-duplication exemption.

## 2026-10-23 — share critical source-pattern verdicts

- Twelve positive source-pattern checks share grep execution and PASS/FAIL aggregation; keep caller patterns and messages, compound conditions, negative checks and final failure propagation.
- Add local regressions and three mutation proofs for successful matches, failed probes, argument forwarding and accumulated failures; shrink the gate's duplication budget from 46 to 33 shingles.

## 2026-10-23 — share common runtime and cross CLI dispatch

- Architecture aliases, mirrors, global options and help have one dispatcher; preserve public parser signatures, nameref outputs, value validation and argument counts.
- Expand the parser suite to 81 assertions and add four mutation proofs; reduce its self-duplication budget from 43 to 21 shingles.

## 2026-10-23 — consolidate Windows test fixture families

- Windows suites share prefixed temporary-directory allocation and exception assertions through the existing harness; retain their import scope and cleanup lifecycle.
- Compare affected suites before and after the refactor; add harness lifecycle and mutation regressions. OpenCV builders let Git create checkout parents, covered by a local clone regression.
- Shrink duplication budgets and remove resolved pairs without changing detector thresholds or coverage.

## 2026-10-23 — share isolated Python CI test trees

- Four Python CI suites share temporary script-tree creation, source copying and workspace detection through the test harness; each retains its tool stubs and assertions.
- Harness regressions and four mutations cover paths, copied bytes, workspace binding and missing inputs; remove all six duplication exemptions between these suites.

## 2026-10-23 — share Android CMake target arguments

- IREE, LiteRT and OpenCV use one array builder for NDK toolchain, ABI and API arguments, preserving project flags and failure policies.
- Local argument fixtures and four mutations cover target selection and paths with spaces; remove the IREE/LiteRT duplication exemption and reduce IREE's remaining self-budget.

## 2026-10-23 — share LLVM source-cache validation

- Native and cross LLVM builds share checkout readiness and stale-generation eviction in `common.sh`, preserving their fetch methods and build-directory policies.
- Local Git fixtures and four mutations cover interrupted clones, missing LLVM trees, eviction scope and eviction failure; remove the duplication exemption between the two builders.

## 2026-10-23 — consolidate compiler identity and pinned Hailo sources

- Share Clang embedded-version parsing in `platform.sh`; preserve metadata priority,
  Debian epoch handling, CLI fallback and the validator's nonfatal probe policy.
- Share Hailo/TAPPAS exact-commit cloning and verified archive extraction; preserve
  submodule, header-copy, cache and strip-component policies. Remove both resolved
  duplication exemptions without changing detector thresholds or coverage.
- Propagate download failures explicitly before hashing; a conditional caller may
  not extract a stale cached archive after a failed fetch, even if its hash matches.

## 2026-10-23 — restore library baselines and bound runtime heartbeats

- Load shared logging from `project-env.sh` when sourced standalone, restoring the
  library census and its mutation baselines without weakening their assertions.
- Start no heartbeat for runtime dry runs. Terminate and reap the current sleep
  child directly, closing the signal window before a separate PID assignment.
- Isolate GPU graph fixtures from runner caches and registry lookups; reject any
  container CLI execution and reproduce the heartbeat race with bounded processes.

## 2026-10-23 — isolate old container-store husks during host cleanup

- Add `Clear-DiskSpace.ps1 -StoreHusksOnly`: exactly the three existing renamed-store
  directory patterns, report-only by default, with daemon calls disabled and TEMP/logs/scratch
  excluded. Refuse incomplete reparse scans and recheck each candidate before deletion.
- Exercise the actual cleanup functions with recorded operations, unreadable traversal and
  a newly unsafe tree; retain protected-root, junction and age-gate regression coverage.

## 2026-10-23 — groom the open backlogs against merged evidence

- Remove completed Omni fallback-font work and F1; retain dated closure evidence and archive
  Windows history while keeping unfinished cache and QNN-device checks open. Retire the old
  general registry decision using recorded published images and device-consumer execution.
- Separate proved default-image Python/ORT and x64 GTK results from outstanding foreign-arch,
  GPU and hardware checks. Keep the unresolved build-host Chrome HTTP stall distinct from
  its repaired cleanup race. Correct the remaining file-size queue and advisory status.

## 2026-10-23 — preserve failure paths while reducing quality freezes

- Store Windows SIMD flags, MLAS match patterns and match floors in the existing
  target fact table; retain distinct global/kernel values and isolate returned copies.
- Share Windows test AST command queries and parameter binding. Move structural
  suites onto the harness parsers so malformed input fails before declaration checks.

- Share CMake/CTest Git and Vulkan setup in a passive project-environment library;
  preserve SDK hook precedence, Git opt-out and advisory configuration failures.
- Remove GStreamer's private cross-mode fallback; require the guard already validated
  by media initialization and test native/cross decisions and incomplete closures.
- Share Renovate argument parsing, repository validation and submodule enumeration;
  preserve local/fleet dry-run differences, branch policies and recursive discovery.

- Share PowerShell fixture AST parsing for files and snippets; reject malformed inputs
  without executing build scripts and preserve function-extraction diagnostics.
- Share Windows source-patch reads and write verdicts, and OpenCV's written-source
  assertions. Retain regex/callback semantics, idempotence, caller diagnostics and
  refusal of missing files or incomplete required edits; add fixture coverage.
- Share ELF strip execution across media helpers, minimal toolchain setup and GCC;
  preserve host/target passes and carry the leaf in narrow GCC/LLVM build closures.
  Preserve filenames with spaces and avoid invoking strip for an empty selection.
- Share pin-parity site validation and default comparisons; retain environment AST
  policies, case sensitivity, stale-exception checks and distinct `v` trimming rules.

- Share shell CLI value parsing across app, CMake and CTest runners; retain argument
  policies and fail promptly on missing values. Share Windows ORT lock parsing and
  carry its module into the image. Remove the two resolved duplication exemptions.
- Require FFmpeg's existing compiler-resolution module and remove its private host
  resolver/wrapper fallbacks. Preserve isolated PATH, tool prefix and resolver failures.
- Remove private Windows smoke version/VS helper copies; require the canonical module
  already shipped in the image and live smoke mount. Test incomplete-closure refusal.
- Share stubbed-library capture and command logs between Flatpak and ownership tests,
  retaining their expected results and per-case environment overrides.
- Share pin-scanner command/default discovery and compiler smoke command cleanup;
  retain environment AST policies, object ELF checks and failure diagnostics.

- Share Windows app/test executable lookup while preserving caller-specific directory
  order and path normalization. Remove its duplication exemption; add four fixture cases
  and verify ordering, normalization and recursive-fallback mutations fail.

- Share Vulkan header/loader SDK search order, including paths with spaces.
- Share FFmpeg compile/link probe setup and cleanup; retain compile-only, debug and cross flags.
- Remove runtime path-helper copies, share Android SDK retries, lint release bootstrap
  and ancestry annotation validation. Preserve host library precedence, retry verdicts,
  per-tool PATH policies and checksum refusal; add stubbed regression coverage.

- Share ONNX/GenAI transport and verdict handling, consumer version comparisons and pin reads.
  The GenAI payload suite now executes the production wrapper.
- Preserve cache setup exports and separate diagnostics from the resolved launcher path.
- Share TVM CMake forwarding and Vulkan/SPIRV lookup, ORT dependency and GPU cache setup,
  and package/smoke artifact-context selection. Preserve their distinct flags and priorities.
- Share bounded compiler-signature scans, Python bundle/package CLI parsing and host-tool
  unknown-option diagnostics. Remove stale duplication freezes and lower remaining budgets.
- Add regression suites for these boundaries and mutation proofs for refusal and ordering paths.

- Remove the last complexity exceptions; every function meets branch and nesting limits.
- Split host storage policies and Vulkan provisioning from their drivers, and split runtime
  test cases without changing their execution order. Remove three file-size exceptions.
- Replace runtime symptom dispatch with a lookup and separate row and architecture verdicts.
  Preserve all 341 runtime assertions; add offline storage and SDK archive regression cases.
- Exclude GCC pretty-printer files before runtime library selection; quote fixture arguments
  and preserve stderr capture while removing five more ShellCheck exceptions.

- Resource monitoring preserves spaces in log paths, keeps marked-stage priority and retains
  the original exit status when summary generation fails; remove both ShellCheck freezes.

- Separate GStreamer Python flags, architecture flags, Rust configuration and plugin exclusions.
  Golden behavior checks pass against both the original and refactored functions.
- Preserve OpenCV's GStreamer library lookup order, ORT argument aliases and missing-value
  diagnostics, and native/cross Arm NN OpenMP links and ACL installation verification.
- Separate stage handoff bookkeeping, stop-command PID selection and manifest generation
  diagnostics. Lifecycle and provenance refusal suites retain their failure assertions.
- A failed TensorFlow pkg-config write now returns failure before writing the SDK completion
  stamp. A retry replaces partial SDK trees without nesting them. Complete, corrupt, partial,
  metadata-failure and retry archives have regression coverage.
