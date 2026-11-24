# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-11-10 … 2026-11-17`](docs/changelog-archive-2026-11-17.md) ·
> [`2026-11-06 … 2026-11-12`](docs/changelog-archive-2026-11-12.md) ·
> [`2026-11-05`](docs/changelog-archive-2026-11-05.md) ·
> [`2026-10-23 … 2026-11-04`](docs/changelog-archive-2026-11-04.md) ·
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

## 2026-11-24 — the Linux torch stage checks out OrchestrANT's hub submodule

- Since OrchestrANT 3abd84e (CON289) its `setup.py` copies hub modules from `third_party/ANTfrastructure`, and a clone
  without that submodule fails `uv sync` ("verify_ort_profile.py is missing"). The Windows torch stage hit it first
  and checks the submodule out since this hub's windows-torch commit; `assemble-torch-app.sh`'s `fetch_app_tree` does
  the same now, `--depth 1` and not recursive, before its next app ref reaches the error. One case, one mutation.

## 2026-11-24 — the no-push runtime wrapper finds its wheelhouse again

- The local wheel context keeps the stage name `runtime_wheels` instead of a digest-pinned image
  reference, which BuildKit sent to the registry. The fix existed on an unmerged branch since
  2026-11-14 and is now on the main line.
- `launch-normal-runtime.py --runtime-source` accepts a later commit on a verified Android parent
  when only host-only runtime files differ among the base-to-Android inputs.

## 2026-11-23 — build ROCm Media from a reviewed newer source on the same GPU parent

- `launch-normal-media.py --media-source/--media-source-proof` accepts a later commit when it
  descends from the GPU source, has its own complete preflight and leaves every compiler, SDK
  and GPU input byte-identical. The Media export recomputes that review.

## 2026-11-23 — fetch ONNX Runtime sources by verified commit with fork fallback

- Microsoft's ONNX Runtime, GenAI and onnxruntime-extensions repositories return 404.
  Linux Media and Android now fetch each source through `source-fetch.sh`: the upstream tag
  first, then the pinned commit from fork networks, and every checkout must match its pin.
- GenAI builds against the verified extensions checkout instead of cloning it in CMake.
  The Windows lane still clones the Microsoft URLs and remains blocked.

## 2026-11-23 — refresh SDK fallback fonts for Flutter 3.50.1

- Pin every Noto Color Emoji v39 and Noto Sans Symbols 2 v25 chunk requested by
  the built Flutter SDK, with SHA-256 verified against the original font downloads.

## 2026-11-23 — IWYU's fatal errors are unread units

- `code_quality_run_iwyu` counted only `: error:`, but IWYU writes `: fatal error:` for a missing header, so a
  planted one stayed green in BeschleunigerBallett (found by its CI track). It counts both; one case, one mutation.
  `failure-modes.md` explains why GCC still warns in a SYSTEM header at an LTO link (spdlog's 8
  `-Wstringop-overflow` in BeschleunigerBallett's profiling job), and CON299 queues a shared check that refuses
  build-time files in an install tree.

## 2026-11-23 — RustDesk on a Windows host: Chocolatey updates, direct IP access, the permanent password

- `docs/windows-host-setup.md` gains Phase F, the Windows counterpart of the Linux page's RustDesk phase.
  winget has no RustDesk package and Scoop's is the portable exe without a service, so
  `Install-RustDesk.ps1` installs and updates Chocolatey's `rustdesk.install` (the official MSI) and
  registers the weekly SYSTEM task `RustDesk Update (choco)`. It backs up both config directories first,
  refuses while a session is open, and runs Chocolatey's installer only with a valid Chocolatey Software
  signature. `Set-RustDeskDirectAccess.ps1` turns on direct IP access and proves a RustDesk listener on
  the port; `Set-RustDeskPassword.ps1` sets the permanent password, which RustDesk never shows again.
- `WindowsRustDesk.Common.psm1` holds the CLI calls: `rustdesk.exe` is a GUI-subsystem binary that
  prints only into a pipe, `--option` reads every value back, and the missing-admin reply becomes an
  error. `Host.RustDesk.Tests.ps1` adds ten cases against a fake CLI; nine mutations all go red. Proven
  on one host: 1.4.6 → 1.5.3 kept its config, and 1.5.3 listened on `[::]:21118` without a restart.

## 2026-11-23 — an IWYU report is green only when every unit was read (CON295 (a))

- `code_quality_run_iwyu` read only the log's error lines, so a missing driver (status 127), a driver that stopped
  on a compile-DB failure, and a unit absent from the compile DB each reported green with every unit "read"
  (found by the Windows session in issue #249, confirmed with the official IWYU 0.23 `iwyu_tool.py`: 0 of 1 and
  1 of 2 units ran). Under `set -e` the same function aborted on the driver's suggestion status or on a log
  without errors. Each requested unit must now appear in the log with an include list or as correct, matched by
  path suffix; the driver status is captured and only reported. `CODE_QUALITY_IWYU_TOOL` and its `env-knobs`
  allowlist entry are gone: the driver comes from `PATH`, as the fixture already supplied it. Five new cases in
  `test-code-quality-iwyu.sh`, four mutations.

## 2026-11-23 — workflow_run filters are graded as GitHub patterns

- `verify_workflow_conventions.py` gains its sixth check, `run-filter`, armed from the start: each
  `on.workflow_run.workflows` entry is read with GitHub's filter grammar (`*`, `**`, `?` and `+` repeating the
  character before them, `[...]` with only a-z, A-Z and 0-9 ranges, `\` escapes) and must match a workflow's name
  in the tree. Every consumer's `retry-disk-refusal.yml` named its lanes as `"... build + test"`, where `+` repeats
  the space, so the filter never matched and a disk refusal on those lanes was never retried; BeschleunigerBallett's
  `[ci <lane>]` was no valid pattern and started a phantom run on every completed workflow (found by its CI track,
  fixed there in e6832053). The hub's own `'Docs · build \+ publish'` is escaped; the consumers escape theirs at
  their next pin (OxidANT 4, AccelerANTgine 3, OmniAccelerANT 4, OrchestrANT 3, WebDavClient 2 filters). The
  README says the names are patterns. `test-workflow-run-filters.sh`, three mutations.

## 2026-11-23 — hardening's PIE reaches a target from any scope (CON297)

- `myproject_enable_hardening` set `CMAKE_POSITION_INDEPENDENT_CODE` in the caller's scope: called from a function,
  such as BeschleunigerBallett's `myproject_enable_local_hardening`, it stayed in that function and reached no target,
  so BeschleunigerBallett's executables were PIE only through clang's default (found by its CI track). A real target
  now gets `POSITION_INDEPENDENT_CODE` itself, and an INTERFACE target hardened from a function warns that its PIE
  reaches nothing; at the project's scope the variable is set as before. Three cases in
  `test-cmake-hardening-linux.sh`, two mutations.

## 2026-11-23 — the quality report skips agents-drift without a docs table (CON298)

- `quality-report.sh` called a consumer without a `[docs]` table "incomplete": the `agents_drift` collector ran
  `verify_agents_drift.py`, which refuses such a repo, and turned the refusal into a failed metric, so
  `code-quality-report.yml` with `quality-report: true` failed though agents-drift is scoped to the AI consumers
  (found by BeschleunigerBallett's CI track, which declared a table to get past it). The collector now reports the
  metric as not collected, "no [docs] build_list and source", as it does for a repo without `AGENTS.md`; one test
  and one mutation. CON295 records AccelerANTgine's IWYU wiring (0126297) and BeschleunigerBallett's SYSTEM
  includes (a9333e7e); CON297 records that the hardening module's PIE reaches no target from a function.

## 2026-11-23 — IWYU reports on the units without modules (CON295 (a))

- IWYU never ran: `myproject_apply_iwyu` set the property on the INTERFACE target `myproject_options`, which reaches
  no compile, and the image's `include-what-you-use` 0.23 is built on clang 19, so it cannot load the clang 23
  build's module files ("PCH file uses a newer PCH format"). The owner chose a report on the plain units:
  `code_quality_find_iwyu_files` lists the units that neither declare nor import a module (5 of AccelerANTgine's 37,
  35 of BeschleunigerBallett's 121), and `code_quality_run_iwyu` runs `iwyu_tool` over them and counts the files
  with suggestions. Suggestions stay green; a unit IWYU could not read is red. `myproject_ENABLE_IWYU` is now OFF.
  `test-code-quality-iwyu.sh` covers the selection and the verdict, with three mutations.

## 2026-11-23 — CON288 done: every contract case replays in its bindings

- **CON288 is done.** Each shared case file the oxidation roadmap asked for exists and replays where it belongs: the
  D8 stream cases and whole answers (OxidANT c10095f, OrchestrANT 9c3882b, OmniAccelerANT 20c940a), the think split
  (OxidANT 5bf5639, OrchestrANT 3abd84e, OmniAccelerANT 2620136), the fixture's refusals (OxidANT 5bf5639, OrchestrANT
  3abd84e, AccelerANTgine 5207eb7), and ModelANT's full-size frames by tensor digest and raw-head cases (ModelANT
  b47ed40 and f845b60). All three detectors match the four frames bit for bit (OrchestrANT 2d82f87, OxidANT c881224,
  AccelerANTgine cedb886); OrchestrANT and AccelerANTgine replay the raw heads, and AccelerANTgine's suppression now
  sorts stably, so equal scores keep the lower candidate (D6). OxidANT decodes no raw head. AccelerANTgine's think
  split rides its text pilot, OxidANT's roadmap step 4.

## 2026-11-23 — CON289 done; CON288's cases replayed in every binding

- **CON289 is done:** no consumer keeps its own ORT-profile count. OxidANT dropped its copy earlier (56865c4), and
  OrchestrANT's `setup.py` now copies `shared/python/verify_ort_profile.py` into `orchestrant/_hub` at build time,
  where Cython compiles it into the wheel, while a checkout reads the hub's file itself (OrchestrANT 3abd84e; ce48210
  keeps the copy in a wheel built from the sdist, which carries no `third_party`). Its bundle's
  `ort_profile.operator_counts` calls the hub's rule.
- **CON288:** every binding replays the new cases of (a) to (c): the D8 stream cases in OxidANT, OrchestrANT and
  OmniAccelerANT, the think split in all three, and the fixture's refusals in OxidANT, OrchestrANT and
  AccelerANTgine, whose C ABI gains status 11 for `context_length_exceeded`. (e) is in ModelANT b47ed40:
  four full-size frames compared by tensor digest and seven raw-head decode cases under D6.

## 2026-11-23 — the think split, the fixture's refusals and an importable ORT count (CON288 (b), (c); CON289)

- `shared/contracts/think-split.json` maps a reply's text pieces to `shown`, `answer` (OxidANT's per-block rule),
  `final` (the lab's text after the last `</think>`), the thinking count and the late closes, owner decision D5.
  `final` stops at a `<think>` that opens after the last close and never closes (owner, 2026-11-23): the lab graded
  `X<think>b` for such a reply, against its own comment that an unclosed block holds no answer. A late close inside
  one piece hides the text before it, as the web shows it. `test-think-split.sh` replays the 11 cases through a
  reference splitter, and two recipes guard the cut and the hidden text.
- The tiny-model fixture gains five cases refused before GenAI runs: a role outside the four, a NaN temperature, the
  prompt and the budget over the context (`context_length_exceeded`, D7), and a NUL byte in a message and in a stop
  string. JSON holds no NaN, so the case writes `"temperature": "NaN"` and each binding's replay turns it into a
  float NaN (owner, 2026-11-23).
- `shared/python/verify_ort_profile.py` exports `model_nodes` and `operator_counts` (CON289), which its `main` uses
  and a test imports; `packaging.ort-profile-require-operator` points at the function's indentation.
- **Consumers:** the bindings fail the new fixture cases and the think-split file at their next pin until they map
  `context_length_exceeded`, pass `temperature` and `stop`, and follow the split; OrchestrANT copies the ORT count in
  at build time (owner, 2026-11-23).

## 2026-11-22 — continue the local NVIDIA Android export through runtime and FINAL

- Launch the amd64 and arm64/SBSA runtime from the verified same-target Android
  export. Use the NVIDIA GPU ORT and CUDA Torch packages, the amd64 Android
  wheelhouse export and the target runtime wrapper.
- Bind the original Android, Media and runtime receipts in local FINAL. Check
  the recorded runtime environment and worker closure before the complete
  consumer plan. Actual builds and consumer acceptance remain pending.

## 2026-11-22 — carry NVIDIA Linux Media through the Android stage

- Use the same-target NVIDIA Media receipt to launch Android on amd64 and
  arm64/SBSA. The OCI exporter checks inherited accelerator settings and all
  Media ancestor layers and requires a target-suffixed runtime context.

## 2026-11-22 — bind NVIDIA Linux GPU and WebGPU Media to the target SDK

- Add local amd64 and arm64/SBSA GPU and Media launch/export profiles. Bind
  the exact SDK source, target-specific image config, immutable native OCI
  ancestry, both required Media Wasm modes and the 300-GiB Media floor.
  Ordinary ROCm Media now uses the same launch floor.
- Synthetic OCI tests cover the launcher and export contracts. Fresh builds,
  downstream runtime/FINAL acceptance and physical GPU tests remain pending.

## 2026-11-22 — continue default Linux Android through runtime and local FINAL

- Launch the existing runtime chain for default amd64, arm64 and riscv64 from
  same-target stopped Android receipts. Local wheel exports use the artifact's
  build-host platform and the runtime build uses the target platform.
- Retain exact parent/source bindings through the six-consumer local FINAL
  entry and use the same 300-GiB runtime admission. Synthetic transport and
  receipt tests exercise these paths. Fresh builds and acceptance are pending.

## 2026-11-22 — continue default Linux Media through native Android handoffs

- Extend the existing OCI export and ordinary Android launch entries to the
  default amd64, arm64 and riscv64 chains. Bind target-specific receipts, baked
  cross environment, immutable SDK/Media parent, both Media Wasm modes and all
  ancestor layers. Keep the ROCm command defaults and current disk admission.
- Test all three command and receipt paths with synthetic OCI data. Actual
  foreign Media/Android builds, runtime and FINAL acceptance remain open.

## 2026-11-22 — qualify arm64 and riscv64 SDKs for default Media

- Bind the foreign SDK receipts to the matching producer, Linux amd64 image,
  target LLVM drivers and C/C++ QEMU smokes in both shell modes. Reuse the
  compiler OCI ancestry checks and the ordinary Media launcher's disk guard.
- Add fixture and mutation controls for target selection and receipt coverage.
  The actual foreign SDK builds, Media exports and factory replays remain open.

## 2026-11-22 — replay the delivered WebGPU Wasm factories

- After JS staging, strict Linux Media builds run the Asyncify and JSPI factory
  checks against the delivered modules. The replay also runs on shared output
  cache hits. Preserve ordinary receipt-only checks and the explicit
  disabled-flavor path.

## 2026-11-22 — retain live OpenCV cache diagnostics

- Add an OpenCV Media phase to the shared read-only cache log reader. Require the
  outer build command and its final cache drain before allocating evidence.
- Test both Dockerfile RUNs and reject the inner build command, dependency setup
  and a missing drain. The full OpenCV compiler-cache measurement remains open.

## 2026-11-22 — keep the shared Python registration protocol valid under dead-code grading

- Mark the unused positional-only library parameter in the runtime-binding protocol explicitly
  unused. Preserve its argument order, types and positional-only contract; registration behavior
  and owning-binding state remain unchanged.
- The ordinary consumer Vulture gate exposed the defect at its existing 100-confidence bound.
  Retain that bound and the shared-asset equality check; a real-analyser consumer regression
  checks the mirror rather than adding a private copy or quality exception. This proves no
  native loading, compiled consumer package or GPU inference.

## 2026-11-22 — assemble closed direct-wrapper source receipts

- Preserve complete direct-wrapper preflight receipt assembly with exact suite/mutation evidence, canonical runner library exclusions and regular-file discovery, original cleanup identity and fresh absence queries. Never reconstruct driver metadata, re-seal a stopped unit or repeat exclusive cleanup.

## 2026-11-22 — keep native file-status fallback compatible with consumer guards

- Compare the already queried file-status enum when distinguishing optional absence from a broken bundle link. This preserves resolution and native error behavior while exact C++ consumer mirrors retain their conservative no-throw source guard. Re-key the existing broken-link mutation to the new expression; no quality threshold or exclusion changes.

## 2026-11-22 — explicitly reuse externally registered native plugin devices

- Add an append opt-in for a device another library already registered in the owning ORT environment. Preserve module checks, registry-owned path bindings, exact device selection and raw failures; external factories do not enter the owned-registration report. Default append and explicit registration retain their existing behavior.
- Add compiled fake-API controls and mutation recipes for the opt-in, strict defaults, failed enumeration and external ownership. These checks do not authenticate an external factory or prove a native consumer, package or GPU.
- Validate that every new native variant compiles and links before it fails a policy assertion or independent count. Preserve compiler, linker and abnormal-exit refusals and mutation-test the validator itself; separate object compilation makes the fixture compiler cache usable.

## 2026-11-22 — verify packaged image source originals byte for byte

- Add a shared finished-file checker for staged original trees and their original manifest, preserving exact bytes, selected scope and raw verifier failures.
- Keep empty sources forbidden by default; allow explicitly selected empty members and forward that permission through native AppImage extraction only for recorded source patches.
- Share Flatpak's private import/checkout between text and binary checks; the fixture declares its actual defaults and omits unused controls. Share exact member-name validation and drive empty-source CLI cases through one Python fixture. Preserve default ZIP/TAR/DEB/MSI verdicts and native architecture/path checks.
- Add synthetic archive, real DEB, controlled native-extraction and conditional real Flatpak controls. Actual rebuilt images and application packages, complete binary/source licences and GPU inference remain separate requirements.

## 2026-11-22 — transport selected image source originals

- Add a reusable consumer stager for the reviewed GCC and GStreamer original trees, retaining exact notices, source records, working context and patches. Validate selected inputs before fresh output allocation.
- Share bounded file validation and fresh writes with the GStreamer producer; retain its narrow Dockerfile companion mount and required API checks. Copy the two media smoke siblings together without increasing the frozen Dockerfile size.
- Add synthetic transport/refusal and mutation controls. Actual rebuilt images, consumer integration, finished packages and complete native licences and corresponding sources remain open.

## 2026-11-22 — the OpenAI contract cases of owner decisions D7 and D8 (CON288 (a), (d))

- `shared/contracts/openai-stream-lines.json` gains 11 cases for D8: any non-null `error` fails the stream (`false`,
  `""`, `{}` and an object without a message among them, matched by the error's JSON text), and so does a chunk that
  is not an object; a `null` error is none; nothing after `[DONE]` is read; the finish reason keeps its raw value
  (`content_filter`); usage counts prompt and completion alone, beside `total_tokens` and `reasoning_tokens`; a
  whole-number float counts, and a negative count is missing, which leaves the usage null.
- The sibling `shared/contracts/openai-chat-answers.json` holds 10 whole, non-streamed answers under the same rules:
  content and reasoning under either name, a raw finish, usage, error objects, and bodies that are not an object or no
  JSON. `test-openai-stream-lines.sh` checks the shape of both files and now allows a raw finish reason;
  `lib.openai-stream-lines-shape` mutates a count negative instead, as its old `truncated` finish is legal now, and
  `lib.openai-chat-answers-shape` drops an outcome field.
- `docs/language-ai.md` states the D8 rules and lists `context_length_exceeded` among the text-contract failures
  (D7), which `orchestrant-serve` answers with HTTP 400.
- **Consumers:** OxidANT's `endpoint.rs`, OrchestrANT's `answers.py` and OmniAccelerANT's `endpoint_reply.dart`
  replay every stream case, so the new ones fail each at its next pin until its reader follows D8.

## 2026-11-22 — shared immutable native-helper packaging

- Add explicit byte-preserving Linux helper launchers with private library paths on both loader branches, unchanged arguments and raw worker exit statuses. Refuse legacy RPATH, linked or escaping inputs, existing payloads and mismatched launcher policies.
- CMake accepts installed-relative `IMMUTABLE_HELPERS`, protects their native payloads during ELF closure, checks their hashes after closure and composes helper and ORT protection in one AppImage patcher. Literal paths and unique basenames prevent ambiguous staging.
- Real ELF, relocation, TGZ and DEB fixtures exercise the shared transport. Finished consumer packages, actual AppRun, hardware inference and complete licence closure retain their separate proof requirements.

## 2026-11-21 — preserve selected GStreamer source notices before cleanup

- Retain distinct original monorepo and Rust-plugin notices, source commits, tracked patches and the GTK4 package's own version under the GStreamer prefix.
- Require reviewed release/commit/hash bindings and unchanged original Git bytes; missing, linked or reused paths and native/cross staging failures abort before cleanup.
- Add real-Git synthetic byte/refusal and conditional-call controls. Actual rebuilt images, finished packages and complete native/transitive licence and corresponding-source closure remain required.

## 2026-11-21 — preserve original GCC runtime notices before source cleanup

- Require the original GPL and runtime-exception texts to match the same build's source archive, then retain both under the installed GCC prefix with the archive SHA512 and canonical source URL.
- Preserve raw staging failures before cleanup, including conditional callers; reject missing, empty, rewritten or linked inputs and linked output paths.
- Add synthetic transport and refusal controls. Actual rebuilt images, consumer package staging and the complete native licence closure remain required.

## 2026-11-21 — retain repository origins in independent source copies

- Preserve locally configured origin URLs, their order and literal values when copying committed, recursive or staged sources from local objects. Workflow checks retain the original repository identity instead of the local source folder name.
- Add real local-Git controls for recursive/working copies, absent origins, multiple values and fatal configuration failures. This metadata does not authenticate sources or prove workflow/build acceptance.

## 2026-11-21 — admit default amd64 WebGPU Media from its SDK

- Add a dedicated owned launcher using the canonical default Media command and existing native SDK/OCI qualifier, exact source proof, compiler ancestry and shared bounded admission.
- Retain both required Wasm modes, explicit accelerator flags and a 300 GiB durable-storage minimum, including stricter caller reserves. Bind SDK/source/parent and launcher bytes; reject optimized Python before shared parent assertions.
- Add synthetic positive/refusal and mutation controls. Other foreign/NVIDIA profiles, actual Media builds, factory replay and FINAL acceptance remain open.

## 2026-11-21 — isolate cache diagnostic defaults and derive gate counts

- Keep the compiler-cache report fixture's automatic address independent of inherited socket/port settings, and prove an explicit caller socket still appears in the report. The production capture environment is unchanged; a new mutation must break the isolated default case.
- Refresh quoted manifest and dead-function figures with the existing measured updater; stale documentation cannot supply a green baseline for its mutation controls.

## 2026-11-21 — retire closed copied package staging

- Add a preview/apply worker restricted to a closed producer's three copied package trees. Bind fresh unit/container/mount observations, exact staging identity and snapshots, and all three retained archive hashes; preserve sources, targets, home caches and receipts. Temporary fixtures and require-removal mutations cover refusals without asserting host authenticity or archive validity.

## 2026-11-21 — exact binary checks for finished Linux packages

- Extend the shared streaming binary verifier to extracted directories, TAR and DEB payloads. Retain exact member names, duplicate/case/alias refusals, regular-file requirements and complete hashes; one conventional TAR root prefix is accepted without accepting duplicate aliases. Share the checked dpkg stream with the text verifier and preserve failed native transport status.
- Add a native AppImage binary entry point using the same architecture, selected-path, extraction and cleanup helper as licence checks. Synthetic fixtures cover large payloads, final-byte changes, symlinks, duplicates, malformed paths and raw extractor failures; byte equality alone does not establish provenance, executable mode, loader behavior or complete licence coverage.
- Keep extraction state initialization in the shared helper, removing redundant entry-point declarations reported by the complete ShellCheck warning gate; no warning budget is raised.

## 2026-11-21 — the PE twin of the ELF hardening gate (CON294)

- `Assert-PeHardening` (`windows/scripts/modules/WindowsPeHardening.Common.psm1`) reads each PE's DllCharacteristics
  and throws naming every file without DYNAMIC_BASE, NX_COMPAT, HIGH_ENTROPY_VA (PE32+ only) or GUARD_CF, the bit
  BeschleunigerBallett's binaries lacked before CON290; `-NoCfg` waives CFG by leaf name for a third-party DLL. Its own
  module, as `WindowsTargetArch.Common.psm1` sits near the 800-line limit. `New-OrtTestPe` takes
  `-DllCharacteristics`, and `PeHardening.Tests.ps1` holds the check on synthetic PEs.

## 2026-11-21 — Linux release hardening for every C++ repo, and its ELF gate (CON294)

- `Hardening.cmake` turns on PIE and links with `-z relro -z now` for GCC and Clang on Linux; BeschleunigerBallett
  had linked with neither ("Hardening Linker Flags:" was empty), while AccelerANTgine set them itself. Its global mode
  joins each flag list with spaces: the semicolons of a list had gone into `CMAKE_CXX_FLAGS` and
  `CMAKE_EXE_LINKER_FLAGS`, where they end the command line.
- `06-packaging/verify-elf-hardening.sh` checks shipped ELFs for PIE, `GNU_RELRO`, BIND_NOW, the stack protector
  and `_FORTIFY_SOURCE`, from AccelerANTgine's package gate made generic. `test-cmake-hardening-linux.sh`,
  `test-verify-elf-hardening.sh` (compiled fixtures, one per missing property) and ten recipes hold both.

## 2026-11-21 — an exact skip list for staged gtest entries (CON292)

- A `tests.json` gtest entry of `Invoke-StagedTests.ps1` may carry `allowed_skips` (owner decision D2): a skip not on
  the list, and a listed test that passed, failed or did not run, each count as a failure and are named, so the list
  stays exact. An empty list refuses every skip; the field on a cargo, pytest or exitcode entry is refused before the
  binary runs. Two cases in `StagedTests.Tests.ps1`; AccelerANTgine (seven tests) and BeschleunigerBallett (none) opt
  in next.

## 2026-11-21 — the filesystem recipe leaves current_path(ec); a debugger probe for windows-11-arm

- The exception-free filesystem recipe in `code-quality-tooling.md` read `current_path(ec)`, the non-throwing getter,
  as a throwing one-argument call: BeschleunigerBallett's `Src/` showed five such false matches. It now catches the
  one-argument throwing overloads, the iterator declaration and a bare `current_path()`, and says that a
  two-argument throwing call is not caught. AccelerANTgine's and BeschleunigerBallett's rows follow it.
- `windows-arm-debugger-probe.yml` (by hand) reports which debugger windows-11-arm offers for a fail-fast's stack:
  `cdb` under the Windows Kits, winget's WinDbg, and the WER settings that keep `LocalDumps` empty there.
  OxidANT's arm64 abort (0xC0000409) needs one.

## 2026-11-21 — a failed gate names itself on GitHub (CON293); the filesystem pattern recipe (CON295)

- `gates.sh` writes `::error title=<batch>: <gate>::<gate> failed (exit N)` for each failed gate, with `:` and `,`
  escaped in the title, and a row into `$GITHUB_STEP_SUMMARY` where that is writable. A host step has
  `GITHUB_ACTIONS=true`; `run-in-linux-container` passes `GATES_GITHUB_ANNOTATIONS=1` into its container, since
  `GITHUB_ACTIONS` would also change the tools' own behaviour there. `test-gates-annotations.sh` and two recipes
  hold it; `shared-script-libraries.md` describes the named-parts lane pattern (owner decision D7).
- `code-quality-tooling.md` § Pattern limits gains the recipe for exception-free `std::filesystem` calls that
  AccelerANTgine binds (457b753): it matched exactly that tree's three throwing sites.

## 2026-11-21 — Windows images get the CFG bit (CON290); ctest fails on a logged critical (CON291)

- `cmake/Hardening.cmake` linked `/NXCOMPAT` alone and passed `/DYNAMICBASE` and `/guard:cf` only to the compiler,
  whose `/guard:cf` instruments but cannot set the image's CFG bit: BeschleunigerBallett's Windows binaries shipped
  without it (none of the 13 lld-link lines of job 136406090876). Every MSVC link now gets `/NXCOMPAT /DYNAMICBASE
  /guard:cf`, `/CETCOMPAT` still off ARM64; `test-cmake-windows-arch.sh` and a recipe hold it.
- `ctest-run.sh --fail-on-log-pattern REGEX` (env `CTEST_FAIL_ON_LOG_PATTERN`) fails a run in which a test's output
  has a matching line, naming each such test, and keeps ctest's own failure status. It reads this run's
  `Testing/Temporary/LastTest*.log`, not the JUnit report, which cuts a passed test's output to 1 KiB, and only the
  output section, as a test's `Command:` line holds its own echo text. A real ctest's log is the fixture; a real-ctest
  case and three recipes cover the gate.

## 2026-11-21 — CON99 measured; two corrections; the oxidation and C++ decisions recorded

- CON99: three probe runs pulled the published gzip image in 387, 515 and 235 s and the zstd copy in 290, 227 and
  294 s on fresh runners (median -25 %, a quarter of the spread). The probe's comment and CON99 claimed both legs
  print the same image id; Docker's containerd store names an image by its manifest digest, so they differ, and the
  copy's source digest ties them. The owner chose zstd from the next chain: `runtime_push_tag` now converts a
  runtime tag's gzip layers with `nerdctl image convert --zstd --oci` before the push (`CROSS_LAYER_COMPRESSION`,
  default `zstd`, the cross stages' knob), and a failed conversion pushes nothing; `test-runtime-push.sh` covers both
  with two mutation recipes.
- Correction to 2026-11-20's staged-runner entry: WER does not log OxidANT's arm64 fail-fast abort late, it logs none:
  run 44804439631 waited the full 15 s and found no event 1000, while an access violation is named at once. The wait
  stays for a record written late; `windows-cross-builds.md` and the script's comments now say what is known.
- The owner decided the oxidation review (D1 to D17) and the comparison with BeschleunigerBallett's C++ setup (D1 to
  D12), all as recommended. New: CON288 (the contract cases, ModelANT's among them) and CON289 (one ORT-profile
  counter) here, CON290 to CON296 for the shared C++ gates (the CFG bit, `--fail-on-log-pattern`, an exact Windows
  skip list, gate annotations, Linux release hardening, analyzers and warnings, a bridge import helper); the consumer
  steps went into OxidANT's, AccelerANTgine's, OmniAccelerANT's and OrchestrANT's BACKLOGs.

## 2026-11-21 — required native cache setup propagates failures explicitly

- Retain the required environment owner's raw status before resolving the native fixture compiler; validate its two exports explicitly. The hosted launcher-policy suite correctly rejected the new unguarded call after the original Rust/Dart suite passed again.
- Add an environment-failure control that requires no cache/compiler command to run. Keep the existing cache retry, raw compiler failure, clock and real Rust/Dart checks.
- Canonicalize the launcher-policy scan root before excluding tests. Guarded/bare fixtures through `tests/..` and a missing-root refusal prevent the production scan from passing with every path accidentally filtered out; keep the original exclusions and explicit caller failure policies. Isolate the fake subshell-loss control from inherited real socket/port values, with an explicit inherited-setting regression.

## 2026-11-21 — native fixture compiles use the guarded compiler cache

- Resolve the shared C/C++ fixture launcher through the canonical cache owner after publishing its parent-shell environment. Bare sccache bypassed infrastructure-error recovery and made the hosted Rust/Dart suite fail on temporary-file errors.
- Retain optimized/fatal-warning C compilation, ASAN C++ flags, raw import/resolver/compiler failures and command/cache statistics. Real compiler errors remain fatal; the canonical launcher owns cache retries and direct fallback.
- Add fake cache-infrastructure controls for both real compiler paths and mutation guards for imports, exports, parent environment, resolver and status propagation. Real clock, Rust/Dart, hosted CI and finished consumer checks retain their separate scope.

## 2026-11-20 — preserve separate Cargo release metadata for native helpers

- Add paired optional JSON outputs to the shared Rust release driver, retaining its full-workspace build and explicit CLI build. Each file records one complete unfiltered Cargo call, suitable for the existing strict native-helper selector; no extra release builds or combined-message exception are introduced.
- Validate distinct regular output paths and invalidate both before the shared wrapper runs. Stub controls cover argument boundaries, stale streams, path aliases, nonregular outputs and raw wrapper/build failures; actual module/helper staging and finished consumer packages remain separate evidence.
- Keep Cargo at its original source-level call sites: the added alias regression rejects the unpublished function-based prototype, and controls cover both wrapper-selected aliases and an alias changed between the two phases.

## 2026-11-20 — isolated worker clock failures remain errors under optimization

- Share the native supervisor's monotonic-clock error boundary before launch and during its wait loop. Preserve nonzero errno and report `EIO` when a failing clock leaves errno zero, avoiding an unset elapsed value that GCC 16.2 rejects under `-O3 -Werror`.
- Compile shared native fixture objects with optimization and fatal warnings. Add real child controls for initial/elapsed clock failures, exact error preservation and kill/reap behavior; retain the existing timeout, Rust and Dart ownership tests. These source controls do not establish finished consumer packages or GPU acceptance.
- Normal commit hooks also exposed a missing logging-bootstrap import in the recently added host-red helper. Add its canonical import and a removal mutation; keep the existing unmutated library controls fatal and retain the original rejected commit attempt.

## 2026-11-20 — shared hook diagnostics load the canonical logger

- Import `log-bootstrap.sh` from `hook-host-red.sh` so standalone library checks see the real logging API. The missing import made the hosted preflight fail three library assertions and invalidated twelve mutation baselines in run 44819008926.
- Add a removal mutation against the existing library suite; retain failed-positive-control refusals and normal hook scope. Local source checks remain separate from the subsequent hosted CI result.

## 2026-11-20 — a probe for zstd layers (CON99); CON283 names OxidANT's Pester suites

- `zstd-pull-probe.yml` (dispatch only, owner OK for a scratch package) recompresses `:latest`'s amd64 image to zstd
  in `ghcr.io/kataglyphis/antfrastructure-zstd-probe`, times a serial `docker pull` of the published gzip image and
  of the copy on two fresh runners through `prepare-linux-ci-host`'s `pull-seconds`, and deletes the package with
  `GHCR_TOKEN` whatever the legs did. The copy fails unless its layers are `tar+zstd`. Its first run (44812697921)
  read the tag's multi-arch index as the amd64 image and stopped before the pulls; the copy now takes the amd64
  manifest out of the index, and the cleanup's delete answered 204.
- CON283: OxidANT's Pester suites speak 3.4 too; AccelerANTgine, OmniAccelerANT and OxidANT each record the migration
  as blocked on the chain that brings Pester 6.2.0.

## 2026-11-20 — the staged test runner waits for WER's record of a fail-fast abort

- `Invoke-StagedTests.ps1` looked for Windows Error Reporting's event 1000 once, right after a binary died. That
  works for an access violation (run 44739816593 named `d3d10warp.dll`), but WER logs a fail-fast abort
  (`0xC0000409`) only after the process has exited, so OxidANT's two arm64 aborts in the traced renderer tests (runs
  44759227422 and 44782412041) named no module. A crash now looks again each second for up to
  `-CrashEventWaitSeconds` (default 15); a green run never waits. `StagedTests.Tests.ps1` covers a record that turns up
  on the second look and one that never does.

## 2026-11-20 — CON287 (slangc), CON283 notes CON273, a stale lint-tools recipe re-pointed

- New BACKLOG CON287: the image's slangc (Vulkan SDK, Slang 2026.17) cannot emit WGSL binding arrays; OxidANT's
  bindless textures need 2026.22 through a separate pin. CON283 records that CON273 put Pester 6.2.0 into the image
  source on 2026-11-15, so only the chain is left.
- `lint-tools.contract-wants-no-hadolint-on-riscv64` follows CON222's riscv64 line, which stopped the hub push as
  stale, and `lint-tools.contract-wants-no-gitleaks-on-riscv64` holds gitleaks off riscv64 the same way.

## 2026-11-20 — Flutter 3.50.1 in source; CON150's cause named

- `FLUTTER_VERSION` 3.47.9 to 3.50.1 (owner OK; `bump_versions.py --write --only FLUTTER_VERSION`, with
  `FLUTTER_SDK_SHA256` and `FLUTTER_COMMIT` from `releases_linux.json`; `sync_versions.py --write` and the curated
  SBOM follow). 3.50.1 fixes multi-threaded skwasm (flutter/flutter#196127), the source of CON150's worker
  `TypeError` on jonasheinle.de, which jotrockenmitlocken 80f5716 works around with `forceSingleThreadedSkwasm`
  until the image carries 3.50.1. Images change with the next chain.
- The pre-commit hook proves a sample in the image when every failing recipe's test is red before any mutation on
  this host (`baseline test already fails unmutated`), as it already does for a missing pwsh: three hub tests trip
  over Debian 13's bash 5.2.37 (`pop_var_context: head of shell_variables not a function context`) and pass under the
  image's bash 5.3.9, so they said nothing about a mutation here. A real survivor beside them still stops the commit.
  The pre-push hook does the same (it rejected the push of these commits for exactly those four tests); both read
  `linux/scripts/lib/hook-host-red.sh`, and `test-prepush-hook.sh` covers the push side.

## 2026-11-20 — gitleaks in the image for an offline secret scan (CON222, in source)

- `install-lint-tools.sh` installs gitleaks at `GITLEAKS_VERSION` on amd64 and arm64 beside shellcheck and hadolint,
  SHA-verified, and fails unless it reports the pin and finds a GitHub-shaped token planted at run time (owner decision:
  offline consumer linting belongs to the image contract). The smoke's `FACT lint-tools` and the `lint-tools` contract
  row carry it; riscv64, with no upstream binary, ships none. A real arm64 run reported 8.30.1 and found the token.

## 2026-11-20 — retain the mutation companion in consumer hook fixtures

- Copy the mutation workspace module with the real runner into isolated consumer-hook fixtures. Clean pushes and stale-recipe refusals continue through the actual hook pair; a missing module cannot replace the intended verdict.
- Clear inherited per-command Git configuration before creating fixture repositories, including runs started by the real hook. Regression mutations remove the companion or either configuration guard; local Git remotes and linter doubles do not qualify downloaded linters or public pushes.

## 2026-11-20 — deduplicate reviewed immutable OCI archives

- Add a default preview and digest-bound apply helper for explicitly selected immutable OCI blobs. Require matching content, ownership, modes and timestamps; exclude identity-bound receipts, parent directories and outside hardlinks.
- Recheck candidate inputs, authorization, receipt protections and idle engines before atomic per-path replacement. Retain partial-operation journals and verify original paths and receipt bytes before reporting success. This is neither receipt authentication nor a lock against concurrent writers.
- Scan complete quoted tokens once to bound large escaped source payloads. Detect identity-bearing JSON keys without mistaking unrelated strings in source manifests for identity records; retain their byte fingerprints and refusal of malformed identity receipts.
- Reuse the qualified native OCI hashing and identity helpers and the additive full-ID host-command query. Container fixture and mutation checks cover refusal paths without touching real archives.

## 2026-11-20 — restore digest-bound consumer source archives

- Restore a parent snapshot from a local base bundle, staged binary patch, index, file/mode manifest and exact original shallow metadata. Check caller-selected archive digests, restored bytes/index and independent Git objects before writing a receipt.
- Restore original shallow boundaries before checkout; never invent boundaries or claim complete history. Preserve recursive dependencies separately. The archive format and temporary materialization do not establish source authenticity, builds or hardware acceptance.
- Extend the existing source-preservation suite with real archive round trips, shallow history, changed inputs, exact index/working bytes, required object checks and refused outputs.

## 2026-11-20 — preserve private mutation worker paths

- Add opt-in `verify_mutations.py --workspace-root` for stable worker paths in fresh container-private roots. Keep source copies, baseline controls, isolated workers and existing parallelism/disk caps.
- Refuse existing paths, source overlap, symlinked parents and in-place combinations. Require root identity and successful cleanup; filesystem and child-process controls do not establish compiler hits, native Windows behavior or build acceptance.

## 2026-11-20 — consolidate the Linux proof work with current develop

- Preserve both explicit ORT census loader-path interfaces and their exemption arguments. Keep the platform grouping in the shared ISA module so the runtime smoke stays within its existing size limit.
- Preserve both histories and their mutation recipes; rebase archived changelog links and keep all original entries.

## 2026-11-20 — the contract follows `ort` 2.0.0-rc.15 (CON95 step 2)

- OxidANT f76b7f9 pins `ort` 2.0.0-rc.15. The consumer contract's Rust registration names the one `Environment` a
  consumer builds with `ort::init_from(dylib)?.build()?`, keeps alive (rc.15 holds only a weak reference) and passes
  to every `Session::builder`; the `ort-sys` build-script rules it quotes are re-read from rc.15 and unchanged.

## 2026-11-20 — CON148 closed: jotrockenmitlocken checks both dev domains live

- jotrockenmitlocken a80c562 runs `check-live-site.py` after each develop upload (the WASM domain before the CanvasKit
  build replaces `build/web`, then the dev domain), with the URLs from the owner's new `DEV_WASM_SITE_URL` and
  `DEV_SITE_URL` secrets; run 44716391170 passed both checks.

## 2026-11-20 — the chain names an absent asset mirror; stale GPU texts fixed (CON153, CON256 h, CON260)

- `append_asset_mirror_secret` prints `[INFO] asset mirror: none (<file> is missing)` once per chain: a missing env file
  was silent and hid an absent mirror for two rounds (CON153 closed). `test-asset-mirror.sh` holds the once-only line.
- CON256 (h): the accelerator page names `/usr/local/lib/onnxruntime-gpu` instead of the undefined `${ORT_GPU_DIR}` and
  the runtime gate's real plugin-EP checks instead of a provider list; the consumer contract sends only NVIDIA consumers
  to `onnxruntime-gpu/lib`; `AGENTS.md` says which gate fails which in-tree provider.
- CON260: the FFmpeg OpenVINO probe drops its stale `2026.2.1` literal and takes the passed pin.
- `test-deepstream.sh` and `test-gpu-variant.sh` pin the amd64 target and build host their fixtures model; on an arm64
  host they failed unmutated (8 assertions), which turned the commit hook's mutation sample vacuous there.

## 2026-11-20 — CON237 closed: every binding replays the shared text cases

- `fixture.json`'s `cases` are replayed by AccelerANTgine 7f8cb17 (C++ and Python), OxidANT 9e0f589 and OrchestrANT
  585f40c, which now names a schema object llguidance cannot compile `generation_failed` as C++ and Rust do. The stream
  lines reach Dart too: OmniAccelerANT e6b1898's `endpoint_reply.dart` replays them and fails on an `error:` line.

## 2026-11-20 — the test model's `fixture.json` lists its cases (CON237 item 4)

- `tiny-genai-model.py` writes `cases`: seven requests with their answer or their error kind (`invalid_options`,
  `generation_failed`), measured on the image's GenAI: greedy to the budget (`defg`, `length`), the schema case
  (`7`, `stop`), a schema that is an array or a number, an object the grammar compiler refuses, no messages and no
  budget. Owner decision 2026-11-20: all three bindings replay it.

## 2026-11-19 — remove approved unused QA environments reproducibly

- Preserve a default-preview cleanup helper for explicitly reviewed ignored QA virtualenvs under the owner's standing authorization. Reuse canonical environment/inode validation, require fresh usage observations and exact source/input snapshots, and retain empty mountpoints and per-path receipts.
- Preserve sources, caches, images, packages, archives, logs and the current shared QA environment. Add disposable-tree and fake-host regressions and actual refusal mutations; supplied authorization is not authenticated and usage observations do not lock concurrent writers or establish build/runtime acceptance.

## 2026-11-19 — `ctest-run.sh --fail-on-skipped REGEX`: a skip is not a pass (BeschleunigerBallett X2)

- BeschleunigerBallett's llvmpipe lane counted its hardware ray-tracing `GTEST_SKIP`s as passes. After ctest,
  `ctest-run.sh` now reads ctest's JUnit report and fails the run on each test matching REGEX that was skipped,
  printing its name and ctest's reason; ctest's own failing status wins. Disabled tests never count. The report is
  the caller's `--output-junit` or a temporary one, and a missing one fails; `CTEST_FAIL_ON_SKIPPED` sets the pattern
  from the environment. The suite reads a report ctest 4.4.3 wrote and runs the host's ctest too. See
  [`ctest-run.sh`](docs/shared-script-libraries.md#ctest-runsh--run-a-cmake-projects-test-suite-in-a-container).

## 2026-11-19 — the Cargo license stager gates the crate graph it stages (BeschleunigerBallett X4)

- Only a comment in a manifest kept wgpu out of BeschleunigerBallett's C++ bridge. `stage-cargo-licenses.py` gains
  `--forbid-package PATTERN`, a repeatable case-sensitive glob over the selected graph's names that fails with each
  match's shortest dependency path, and `--max-runtime-packages N`, which counts live `cargo tree --edges normal` and
  fails above N with the count. Both run before staging and stay off by default. On 2026-11-19 OxidANT's
  `kataglyphis_cxx_bridge` staged 129 to 130 packages and held 55 in its normal tree on all three of its targets. See
  [`third-party-licenses.md`](docs/third-party-licenses.md#checking-delivered-package-licences).

## 2026-11-19 — one file of OpenAI stream lines for every binding (CON237 item 3)

- Rust and Python read stream lines differently: a chunk that is no JSON failed Rust's stream and was skipped by
  Python, and an `error:` line failed Python's and was ignored by Rust. `shared/contracts/openai-stream-lines.json`
  holds eleven cases with their events or error; owner decision 2026-11-19: both fail the stream.
  `test-openai-stream-lines.sh` holds its shape.
- OxidANT 2afd994 reads an `error:` line as the server's error and OrchestrANT 985c0d6 fails a chunk that is no JSON;
  both replay all eleven cases.

## 2026-11-19 — Home Assistant keeps the cat cams' model time (CON253, in source)

- `configuration.yaml` reads each cam's `/healthz` `stats` as Modellzeit, Bildrate and CPU sensors with
  `state_class: measurement`; `packages/catcam_performance.yaml` adds each cam's median model time over a day and a
  week and `catcam_model_time_rise`, which notifies when the day's median stays about 25 % above the week's for an
  hour; the 21:00 summary names each cam's day median. `check_config` of `home-assistant:stable` passes. The live
  instance takes it when its owner deploys it.

## 2026-11-19 — the three detectors' golden tests read the same pixels (CON234)

- ModelANT bd4094a carries `contracts/fixtures/two_cats.png`, the lossless decode of `two_cats.jpg`, its digest in
  `fixtures/NOTICE`. OxidANT (d518ad4), AccelerANTgine (30ba9a8) and OrchestrANT (d926992) read it at that pin.
  AccelerANTgine's `jpegdec` and `videoconvert` had given the second cat 0.721 where OpenCV gave 0.564; on the PNG
  both give 0.564, and its recording is redone. Fleet-health's contract rows read 0 on 2026-11-19. CON234 is done.

## 2026-11-19 — CON218 is done: the perf baselines record the shipped text default

- OxidANT, AccelerANTgine and OrchestrANT build their perf model with `genai-model-threads.py --threads text`, the
  owner's text rule of 2026-11-17, so a baseline quotes the default the apps ship. OxidANT's Raspberry Pi 5 baseline
  (e893433) measured 115 tok/s and a 171 ms first token with it. `fleet-health.md` now says that a lane run through
  `on-request.yml` counts its debt from its last direct run.

## 2026-11-19 — the text contract's schema case is typed once, and the page names each binding's backends (CON237 items 1, 2)

- `tiny-genai-model.py` writes `schema_case` into `fixture.json`: the schema `{"enum": [7]}` and its answer, which the
  successor rule never predicts, so only a live guidance mask yields it. `genai-guidance-smoke.py` reads it from
  there in place of its own copy; it printed `genai-guidance-schema-ok 7` in `:latest` on 2026-11-19.
- `language-ai.md`: `:winamd64` ships llguidance (its smoke gate runs the schema case), LAI-H2 is done, and a table
  names each binding's backends; AccelerANTgine's C++ and C have no endpoint client.
- `verify_mutations.py` without `--delegate-chrome` names a selected recipe whose test starts `pwsh` on a host
  without it (`FAIL: pwsh is not on PATH, so …`) instead of running it into exit 127, a vacuous bite. The commit hook
  reruns its sample in the image on that line (CON279), but now proves the rest on the host (`--delegate-chrome`)
  and sends only the named pwsh tests to the image: a host-only test, such as the process-tree kill of
  `test-mutation-gate.sh`, fails in the container for the container's reasons.

## 2026-11-19 — what CON269 left: the `--index` refusal's recipe and two commits through the hook pair

- `lint-gates.index-needs-staged` proves that `run-lint-gates.sh` refuses `--index` without `--staged`. Its mutant ran
  the downloaded linters inside `test-lint-gates.sh`; `test-consumer-hooks.sh` holds the case now, over its hub copy's
  stub linters, so the mutant ends in seconds. The same suite commits through the hook pair: a staged CRLF script
  stops the commit, and an unstaged deletion beside a clean commit does not. CON269 is done.

## 2026-11-19 — fleet-health shows lane debt, reruns and contract drift (CON247 items 1 to 3)

- `lane.<workflow>.commits_since_green`: develop commits after the head of each workflow's newest green develop run,
  so debt from a lane that runs on request shows. `ci.<workflow>.rerun_rate`: the share of the last 20 runs that
  needed a second attempt, without the reruns `retry-disk-refusal.yml` starts on purpose.
- `shared_facts.contract_inference_v1` and `shared_facts.contract_text_generation_v1`: ModelANT's two contracts as
  OxidANT, AccelerANTgine and OrchestrANT see them (lock row, tracked copy or gitlink blob), distinct digests minus
  one. All three agreed on 2026-11-19.
- Items 4 to 6: `sibling_pin.<repo>.lag_commits` for OmniAccelerANT's OxidANT and AccelerANTgine gitlinks;
  `bench_history.<artifact>.days_since_sample`, `stale` above 14 days; and `image_lag.lanes_without_run`, the lanes
  whose newest develop run is older than the image tag they pull, from the package versions (`fleet-health.yml`
  gains `packages: read`). CON247 is done.
- Found by the first record with these rows (run 44558849413): in OxidANT, AccelerANTgine and OrchestrANT the newest
  green run's head comes from before a history rewrite, so `compare` answered 404 and took every `ci.*` row of the
  repo with it. The refusal stays in that lane's debt row now, not collected, and the other rows stand.

## 2026-11-19 — what CON248 and CON249 had left: a real auto-commit suite and uv's floor

- My BACKLOG removals of CON248 and CON249 had left their last paragraphs behind, and those named two parts not yet
  built. `windows/scripts/tests/AgenticLoop.Commit.Tests.ps1` runs `Invoke-GitAutoCommit` against a real repository:
  a 1 MB binary, a small binary and a 501 KiB file stay out and are logged, and a commit a hook refuses returns
  `$false`, each with a fault control. `consumer_pins.py` reads `[tool.uv] required-version`: a lower bound at or
  below `UV_VERSION`; an exact pin or a higher floor fails. OrchestrANT and AccelerANTgine (`>=0.11.3`) pass.

## 2026-11-19 — a consumer documents its local test step through `run-in-ci-image.sh` (CON242)

- OrchestrANT's AGENTS.md names `run-in-ci-image.sh . --volume orchestrant-uv-cache:/root/.cache/uv -- bash
  scripts/linux/ci_tests.sh` (a0cff92) in place of a commented `nerdctl run`. It ran once on 2026-11-19 in the same
  image and volume, through the Raspberry Pi's capped runner: 3410 passed, 37 skipped, 579 s.

## 2026-11-19 — a read-only doctor names what is stale in a dev checkout (CON249)

- A month-old local image, a uv older than the lock format and a tree about 100 commits behind each cost an hour of
  wrong debugging, and nothing said so. `linux/scripts/dev-doctor.sh <repo-root>` prints one line each for origin's
  develop (by `git ls-remote`, nothing fetched), the submodules, `core.hooksPath`, the local CI image's age and uv
  against `versions.env`, and exits 1 on any. On the Raspberry Pi dev host on 2026-11-19 it named a 10-day-old
  image and uv 0.11.3 against the pin 0.13.7. See [`dev-doctor.sh`](docs/shared-script-libraries.md#dev-doctorsh--what-is-stale-in-a-dev-checkout).

## 2026-11-19 — `cargo_test.sh` records every test as JUnit (CON250 item 2)

- `cargo_test.sh` ran `cargo test` and wrote no result file, so only OxidANT, through its own converter, recorded test
  counts and failures. Its `cargo-test-junit.py` moved to `02-toolchain/rust/`, and `cargo_test.sh` writes
  `logs/test-results/cargo-test.txt` and `cargo-test.xml` for every Rust consumer (`CARGO_TEST_RESULTS_DIR`, empty
  writes neither). The status is cargo's; a log with no test binary in it fails. Stable libtest prints no per-test
  time, so each binary keeps only its total.
- OxidANT calls it since d1bcd2c and deleted its own converter, so CON250 is done.

## 2026-11-19 — a hung C++ test ends named (CON250 item 1)

- `ctest-run.sh` set no per-test limit, so a hung test ended at the lane's 60 to 150 minutes without a name. It passes
  `--timeout 1500` (CTest's own default) unless the caller sets one: `--timeout`, `CTEST_TIMEOUT`,
  `CTEST_RUN_DEFAULT_TIMEOUT` or a `--timeout` after `--`; `0` sets none.

## 2026-11-19 — the agentic loop reads git's exit code and stages by rule (CON248)

- `invoke_git_auto_commit` and `Invoke-GitAutoCommit` ran `git add -A` and `git commit` and read neither exit code,
  so a refused commit was silent and a core file or test output would have gone in. Both stage tracked changes
  (`git add -u`) and new text files of at most 500 KiB (the large-files limit), log each file they leave out, and
  return a refusal: the queue drain stops with exit 1 before the build. Nothing to commit is no failure. The
  executor prompt says to stage changed files by name, never `git add -A`.
- `git.commitGate` (CON248 item 3) is a command both twins run before each auto-commit, for example
  `bash scripts/linux/run-lint-gates.sh`. A failure keeps the task uncommitted, and
  `intervals.maxConsecutiveGateFailures` (3) failures in a row stop the queue with exit 1, like the build cap.
- `verify_stdout_returns.py` read a one-line function (`f() { …; }`) to the next column-0 brace, so a later function's
  log lines counted as its own; a one-line body now ends on its line, and the loggers' own definitions are exempt.

## 2026-11-19 — the consumer hooks path is absolute (CON269 item 5)

- A relative `core.hooksPath` resolves inside each working tree, so a linked worktree without the hub submodule ran
  no hook and git said nothing; a 1 MB binary went in that way. Owner decision: the adoption page's line is absolute
  (`"$PWD/third_party/ANTfrastructure/shared/linux/templates/git-hooks"`), and every local gate run warns a clone
  that still has the relative line, naming the absolute one.

## 2026-11-19 — a consumer's shell line endings are a gate (CON269 item 1)

- The hub's `crlf-guard` was a function of `preflight.sh` over the hub's own files, so no consumer hook checked line
  endings. `linux/scripts/verify-shell-eol.sh [<root>] [--staged]` holds it; preflight calls it, and
  `run-lint-gates.sh` runs it in the full gates (git's `w/` column) and in the staged checks (`i/`, the bytes the
  commit carries). Every consumer passed on 2026-11-19.

## 2026-11-19 — retain ORT loader identity with internal HIP probes

- Accept unrelated fork-child runtime records in a profiled process's loader trace. The current Rust CLI's internal HIP probe produces these records before the parent loads the MIGraphX plugin.
- Keep every selected ORT core and requested plugin bound to the profile PID and package origin, including duplicate records. Add regressions for foreign and malformed selected PIDs and missing required libraries; this does not authenticate traces or prove loaded bytes, a single session, clean hosts or licences.

## 2026-11-19 — select an explicit mirror for isolated source proofs

- Add an optional Ubuntu mirror URL to the isolated runner, record it and forward exactly one bootstrap value. Use the existing Ubuntu mirror rewriter before apt; the default retains the image's source configuration and signed metadata. Refuse malformed or credential-bearing URLs before output allocation.
- Retain closed, ignored quality environments on existing tmpfs through a repository-owned relocation helper. Preserve canonical GNU tar bytes, refuse shared cache inodes and retain an empty original mountpoint. This does not preserve volatile tools across reboots or qualify builds; sources, locks, persistent caches and original outputs remain separate.
- Add actual prefix/command fixtures for mirror ordering, defaults and raw failure, plus isolated environment-retention controls and mutations. The Media control driver includes these preserved suites; they do not replace a full preflight or image/hardware acceptance.

## 2026-11-19 — prepare the six WebGPU Media command profiles

- Share canonical stage argument construction while retaining the existing ordinary launcher's ROCm/amd64 refusals. Add explicit default amd64/arm64/riscv64, ROCm amd64 and NVIDIA amd64/SBSA arm64 Media profiles, immutable local parents and absolute paths.
- Require the correct SDK/GPU parent selection, both WASM modes and the amd64 build platform. Check every profile against independent expected argv and the actual shell stage graph. Prepared commands do not launch builds, verify parent ancestry or establish image/hardware acceptance; the remaining owned launch and handoff profiles still need qualification.
- Clear inherited accelerator flags during canonical tag lookup and select both accelerator toggles explicitly in prepared environments. This prevents a tool image's default AMD/NVIDIA setting from turning a default Media command into a different variant.
- Reuse the existing source-check protocol for Media controls. Its fake S3 startup children clear an inherited cache-chain setting; an explicit inherited-environment regression retains the original fallback assertions without changing the real compiler-cache setup.
- Preserve proof-driver input and source checks with isolated command fixtures and mutations. Refuse missing inputs before bootstrap, retain existing evidence, propagate raw child/Git failures and reject patch, index or worktree drift before success.

## 2026-11-19 — combine all WebGPU media factory proofs

- Add a shared media acceptance entry requiring delivered enabled native/GIL/FT products and both compiled Asyncify/JSPI factory replays at one explicit ORT ref and Git revision. Preserve the narrower existing media replay and its CLI failure policy through shared parsing and dispatch.
- Reject missing flavors, disabled products, mismatched source/configuration, failed or duplicate fresh replay verdicts and changed input receipts. Keep native partial evidence and raw child statuses without publishing an overall receipt on failure. Synthetic fixtures and mutations test these refusals; actual image builds, device inference and final consumer acceptance remain separate requirements.

## 2026-11-19 — preserve append-only operational memory updates

- Add one repository-owned memory appender with explicit expected bytes/SHA256, live-controller refusals, nonblocking file locking, append-only writes and exclusive original-prefix/append backups. Changed prefixes, file identities, unknown observations or failed I/O cannot produce a passed receipt.
- Add independent controller/file fixtures and mutations, including concurrent suffixes, symlinks, hardlinks, short writes and failed proof writes. Expand strict Python coverage by all four new Python files and retain positive and negative scope controls. The helper does not authenticate writers or provide a crash-atomic transaction; it grants no build, GPU or goal acceptance.
- Include shared Python test siblings in the type checker's search roots. Extend the independent import chain and prove removal fails, retaining every existing root and file scope.
- Reverify both saved snapshots after writing as well as before it. An independent red control showed the first version accepted either post-write corruption; two mutations remove the separate checks. The memory prefix remains preserved when a later snapshot check fails.

## 2026-11-18 — the large-files gate grades the index, not the working tree (CON269 item 4)

- `verify_large_files.py --root` refused a tracked file missing from disk, so a deletion not staged yet stopped every
  commit until it was (AccelerANTgine's clone, 2026-11-12). The size already came from the blob; the NUL sniff now
  reads the blob too, so the gate grades the index alone and a missing working-tree file is no partial tree.

## 2026-11-18 — the consumer hook templates are linted (CON269 item 2)

- `lint-shell.sh` without arguments swept `linux/` only, so `shared/linux/templates/git-hooks/*` and the copied
  `antfrastructure.sh`, which every consumer runs, were linted by hand. The default sweep takes `shared/linux`;
  the files were clean and the warning ratchet holds at 35.

## 2026-11-18 — the Windows detector parity run is one hub copy (CON252)

- OxidANT's and OmniAccelerANT's `scripts/windows/check_gpu_detector_parity.py` shared about 110 lines, the
  photo's hash typed into each. `shared/python/check_detector_parity.py` holds the run: three clean child
  processes, their profiles and the pairwise comparisons, the photo digest, the confined runtime and the
  DirectML adapter. The launcher command is an argument. See
  [detector parity](docs/gpu-artifact-receipts.md#detector-parity).
- Both consumers call it: OxidANT `16890ff` and OmniAccelerANT `85eddd8` keep only their launcher and model check.

## 2026-11-18 — a new oversized Rust, Dart or C++ function reads `regressed` (CON246)

- `functions_over_80_lines_extra_languages` was class `report`, so `quality-report.sh --compare` never graded it and
  fleet-health showed a rise as `moved`. It is graded now (class `code`). A Dart `main()` in a `*_test.dart` file
  (`lang_units.is_test_body`) is counted apart as `oversized_test_bodies`: about 22 of the 76 oversized functions in
  OxidANT, AccelerANTgine and OmniAccelerANT were such bodies, whose length is the number of tests. The scanner's own
  exit status does not change. See
  [extra-language readers](docs/code-quality-tooling.md#extra-language-readers-report-only).

## 2026-11-18 — a `quality-report.toml` pattern row with `max` fails the lint gates (CON245)

- A `kind = "pattern"` row was counted and reported only, so an AGENTS.md rule that is one pattern held by habit.
  `verify_pattern_limits.py` fails when a row with `max` matches more often and prints `file:line` of each match;
  `run-lint-gates.sh` runs it as its ninth gate. A `max` that is no whole number of zero or more fails too.
  See [pattern limits](docs/code-quality-tooling.md#pattern-limits-pattern-limits).
- The two sampled consumer rules bind: OxidANT `ef2cad1` (no `[features]` table) and
  AccelerANTgine `bee101b` (no direct stdout diagnostic in `Src/`), each with a row, a planted-tree test and a recipe.

## 2026-11-18 — a workspace Cargo license is staged under its file name alone

- `stage-cargo-licenses.py` copied a `workspace` policy text to `<name@version>/workspace/<its repo path>`.
  OxidANT's `profiling` texts sit at `packaging/licenses/cargo/aclysma-profiling-8271551172eb/`, which put
  BeschleunigerBallett's NSIS source path at 268 characters and stopped makensis on Windows. The text now lands
  at `<name@version>/workspace/<file name>`; two workspace texts of one package with the same name fail.

## 2026-11-18 — pytest-timeout in the arm64 wheel store (CON238, step 2, in source)

- The `:winarm64` wheel store's pinned pytest stack gains pytest-timeout 2.4.0 (`PYTEST_WINDOWS_ARM64_PYTEST_TIMEOUT_*`,
  the version OrchestrANT's lock runs on x64, PyPI's SHA256). `Copy-Arm64TorchWheels.ps1` stores it and
  `Test-Arm64Bundle.ps1` installs and imports it offline, so a consumer's pytest timeout works on the device. A
  `:winarm64` publish carries it.

## 2026-11-18 — the patch-drift gate tells a vanished upstream from a drifted patch (CON280)

- `Test-PatchesApplyClean.ps1`: when a clone fails and the upstream page answers 404, the patch is `NOT CHECKED
  (upstream answers 404)` and the job prints a warning naming the repos, instead of failing; a reachable upstream
  that refuses the clone, and every patch that does not apply, still fail. Since 2026-11-17 22:20Z
  `github.com/microsoft/onnxruntime` answers 404, which turned every hub commit's Windows lane red (owner decision
  2026-11-18). `Patches.ApplyClean.Tests.ps1` covers both cases.

## 2026-11-18 — the pre-commit mutation sample runs in the image on a host without pwsh (CON279)

- The hook's sampled `verify_mutations.py` run is teed; when it fails because the host lacks the `pwsh` or
  `bash` a mutant is parsed with, and `git config kataglyphis.imageRunner` names a runner, the same sample runs
  once more through it and that run decides, as pre-push does since CON277. `test-precommit-hook.sh` covers
  the runner's pass and fail, a clone without it and a real survivor.

## 2026-11-18 — resolve real package loader parent segments

- Accept a traced `$ORIGIN/../lib` path only with explicit live root resolution, a normalized expected package directory and actual file containment. Canonical CLI roots, missing-file and symlink-escape refusals remain strict; receipts preserve the original trace paths.
- Synthetic live-file controls and mutations cover valid parent segments, missing files, absent resolution and symlink traversal. This does not authenticate traces or library bytes, prove a session or GPU inference, or repair the original failed C++ hardware receipt.

## 2026-11-18 — preserve the exact staged consumer index

- Restore the optional working-source copier on the current tooling branch. Generate its overlay from the index, preserving staged gitlinks even when both the selected base and actual child checkout differ. Regular-file staging, complete index, copied bytes/modes/links, source-race and independent-object checks remain required; committed recursive acceptance stays strict.
- Real temporary Git fixtures cover three distinct base/index/child revisions and independently corrupted destination indices. Mutations restore working-tree selection or omit gitlinks; these controls do not authenticate pins, materialize child sources, build a consumer or prove inference.

## 2026-11-18 — preserve escaped mutation recipe data

- Serialize merged registries as ASCII-safe JSON while preserving every decoded value. Intentional corrupt strings in encoding mutations no longer contaminate the clean registry source.
- Add round-trip, existing-entry and repeated-write controls plus a mutation that restores literal Unicode output. These checks cover registry serialization, not consumer encoding coverage or complete mutation acceptance.

## 2026-11-18 — refresh derived quality documentation

- Run the canonical doc-number updater after the package and loader mutation additions. Preserve the computed totals, family counts and census values; repeat the previously invalid doc-number and registry baselines and their existing mutation recipes.

## 2026-11-18 — repair full-preflight documentation and recipe namespaces

- Keep the loader-origin pointer in the existing GPU bundle bullet, restoring the README's unchanged 100-line limit.
- Move the nine AMD provenance recipe IDs from the unregistered `ort` family to the existing `packaging` family. Keep every target, edit, test and reason unchanged and preserve a one-to-one ID map with the proof; the registry retains all 6,922 recipes.

## 2026-11-18 — share profiled ORT loader-origin checks

- Add a shared parser and CLI for bundle and AppImage loader paths. Profile mode validates the original profile bytes with the canonical provider/run verifier, then requires the matching PID trace and every requested plugin beside ORT.
- Refuse foreign origins, lexical escapes, missing evidence and mismatched PIDs. Optional live resolution rejects symlink escapes; trace-only callers retain an explicitly weaker origin check.
- Synthetic controls and mutations cover these refusals. Loader paths do not prove file hashes, one ORT session, clean-host inference or complete licence closure.

## 2026-11-18 — retain original AMD plugin package provenance

- Extend shared AMD package staging and verification with an optional provenance path outside the exact license tree. Original image bytes, regular files, package containment and fresh stage targets are required; existing three-argument callers retain their behavior.
- Synthetic refusal cases and mutations cover missing, changed, linked, escaping and overwritten files plus raw copy failures. These checks do not prove linkage, full licence closure or GPU inference.

## 2026-11-18 — package the selected Linux TAR bundle

- Make Linux TAR use the shared bundle resolver, including `APP_PACKAGING_BUNDLE_DIR`, instead of the raw Flutter tree. This retains the prepared runtime closure and ORT notices in Omni packages.
- Preserve default paths, empty overrides, Android APK selection and legacy output copies; fail on an invalid selected tree or resolver error. Real TAR fixtures and mutations cover selection and argument boundaries, not native inference or full licence closure.

## 2026-11-18 — preserve consumer command seals

- Add a reusable terminal command/cleanup sealer for cache-captured consumer jobs. It reuses the existing unit parser and terminal verdict, retains input hashes and raw statistics, and refuses an existing exclusive cleanup. Caller markers are not artifact, cache or GPU acceptance.
- Mocked positive/refusal controls and 15 mutations cover identity, status, markers, evidence, stopping, cleanup and preserved scope.

## 2026-11-18 — check ordinary Android commands before local FINAL

- Derive a missing Android stage label from the exact unpublished Android driver, lane, literal transport and hash-bound complete source proof; preserve original producer bytes and reject explicit incorrect labels.
- Share producer-unit matching across Runtime and Android, and extend independent command, duplicate-flag, launch and source-refusal fixtures across all six supported Linux lane schemas. These fixtures do not establish actual FINAL or GPU acceptance.

## 2026-11-18 — bind local FINAL acceptance to canonical runtime exports

- Accept the existing image and verified export wheelhouse modes without changing required runtime gates, original source/Android evidence or the complete six-consumer plan.
- Match explicit runtime unit lanes to their declared variant and bind the original host checkout through its complete selected worker mapping. Separately located owned wrappers must retain every selected companion byte, a clean source tree and exact invocation ownership flags.
- Extend synthetic producer, receipt and companion refusal controls across all six Linux lane schemas and both delivery modes. These controls do not establish actual FINAL consumer, GPU, clean-host or legal acceptance.
