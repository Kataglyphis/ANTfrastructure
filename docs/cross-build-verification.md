# Cross-build verification & failure-class catalog

This document catalogs the classes of failure hit during the base→`:latest-cross`
rebuild campaigns and maps each to the fast check that catches it *before* a
multi-hour QEMU build. It is the reference for the pre-flight verification
workflow (see "Pre-flight" below).

The guiding principle: **every error we debugged interactively should become a
check that fails in seconds, not after a 30–60 min emulated build.**

> **Scope: this page is the LINUX cross lane.** Its failure classes come from the
> `base→:latest-cross` campaigns and its checks assume QEMU, ELF and a runnable
> target. The **Windows** arm64 cross lane is documented separately in
> [`windows-cross-builds.md`](windows-cross-builds.md), and its verification story is
> deliberately different in one decisive way: **nothing it produces can be executed at
> all.** Windows x64 has no ARM64 emulation, so there is no Windows counterpart to the
> "compile+link+RUN under qemu" half of class 4 below — only the static half. That lane's
> equivalent of the per-arch ELF/machine check is `windows/scripts/build/verify-target-arch.ps1`
> (PE `Machine` field over the whole install prefix, with a minimum-inspected floor so a
> lane that staged nothing cannot pass green), and its smoke gate runs the host-toolchain
> sections against an arm64-specific floor column (66/25, measured green 97/0/15), reporting
> only the payload-execution sections NOT APPLICABLE (since 2026-08-24 — before that the whole
> gate was reported NOT APPLICABLE).

## Failure classes (from build history)

| # | Class | Representative bug(s) | Fix commit(s) | Caught early by |
|---|-------|----------------------|---------------|-----------------|
| 1 | Script not COPY'd into a stage → sourced fn missing at runtime (`command not found`, exit 127) | `media_load_arch_flags` not found (03-media/core never COPY'd into Dockerfile.package) | `da41e19` | **sourced-scripts-present** static check (`verify-script-copy-coverage.py`) |
| 2 | Relocated native GCC/G++ can't find `/usr/include` for source builds under QEMU — C *and* C++ (`#include_next`) | `string.h: No such file` (Pillow); `<cstdlib>`→`stdlib.h: No such` (numpy) | `3c623fa`, `349e32b`, `dc93d11` | **compile smoke test** (C + C++ `#include_next` + `jpeglib.h`) in `validate-compilers.sh` |
| 3 | Missing dev headers for QEMU source builds | `jpeglib.h` missing for Pillow (`libjpeg-dev`) | `3c623fa` | same compile smoke test (header presence probe) |
| 4 | Cross toolchain artifact wrong-arch / not runnable on host | `/opt/llvm-target` clobbered by shared compiler; non-runnable `llvm-config`; missing target linker | `8e66c5f`, `fb634a3`, `b1dd72e`, `312a4d8` | **`validate-compilers.sh`** per-arch ELF/machine check (build-time) **+ compile+link+RUN under qemu** in `smoke-runtime-image.sh` (`bcbd19d`) |
| 5 | venv/wheel install collision & bad seeding | apt numpy seeded into venv without dist-info → uv install `File exists` | `9f07334` | **torch-venv integrity** smoke (`smoke-torch-venv.sh`) |
| 6 | Undefined/typo'd bash function or quoting bug | `tvm-detect` undefined; verify-parity venv quoting | (dedup passes) | **shellcheck gate** (`-S error`) in pre-commit |
| 7 | Include-flag construction bugs | bare `-I -I -I` broke Abseil C++17 probe; missing pybind11/numpy include dirs | `ab3776b`, `5412ec4` | shellcheck + compile smoke test |
| 8 | Dockerfile ARG / mirror / cache drift | apt not `-y`; cache-to 400; ARG≠versions.env | `bf49676`, `4f27634` | `verify-arg-consistency.sh`, `verify-ubuntu-mirror-consistency.sh` (exist) |

## Existing infrastructure (reuse, don't duplicate)

- **Shared helper for class 2/3:** `01-core/common.sh` → `append_cross_idirafter <triplet>`
  already appends `-idirafter /usr/include{,/<triplet>}` to `CPPFLAGS/CFLAGS/CXXFLAGS`.
  Used by `build-libcamera.sh`, `build-gstreamer-monorepo.sh`. (The torch-venv fix
  should adopt this — see task #16.)
- **Compiler validation (class 4):** `06-packaging/validate-compilers.sh` emits
  `ARTIFACT COMPILER VERIFICATION PASSED for <arch>`; validates the
  `versions.env`-pinned GCC/Clang chain and per-arch ELF machine type. The
  versions are *not* baked into the script — it reads `GCC_VERSION` and
  `LLVM_RELEASE` from the environment, which the wrapper-smoke stage passes in
  as build ARGs (`Dockerfile.package:339-346`); the `${LLVM_RELEASE:-…}`
  fallback literal at `validate-compilers.sh:189` is dead in the build path.
  Extend here for the compile smoke test.
- **Smoke framework:** `06-packaging/smoke-common.sh` (`pass`/`fail`/`FAILURES`);
  smoke tests are `06-packaging/smoke-<thing>.sh` and `source smoke-common.sh`.
- **Static host verifiers wired into `.githooks/pre-commit`:** `verify-critical-fixes.sh`,
  `01-core/verify-arg-consistency.sh`, `sync_versions.py --check`, `bash -n`. The hook is
  the home for the new shellcheck gate and the sourced-scripts-present check.

## Pre-flight

Run **`linux/scripts/preflight.sh`** before `build-cross-chain.sh`. It runs every
fast (no-build) check in seconds/minutes so whole failure classes are caught
before a multi-hour QEMU rebuild. All checks run even if one fails; the script
exits non-zero if any did.

Since 2026-08-08 preflight also validates the stage graph itself (slug
`stage-graph` — parent refs, dockerfile existence, tag resolution, cycles);
previously that ran only at build kickoff. The script-tests slug now prints an
assertion aggregate (`<N> suites, <M> assertions`, `run-tests.sh:36`) — a
sudden drop in those numbers is the alarm it looks like: the harness fails
suites that run zero assertions, and the aggregate makes shrinking coverage
visible. The current figures are deliberately not restated here — they grow
with every suite that lands, so a stale baseline in this doc would make a real
collapse read as growth (`run-tests.sh:34-35` picks a deliberately absurd
"24 suites, 3 assertions" as its own example for that reason). Read them with
`bash linux/scripts/tests/run-tests.sh`.

### The `linux/scripts/tests` suites

Conventions for the bash unit suites behind the `script-tests` slug. They exist
so a decomposition or a flag rewrite is provably behaviour-preserving in
seconds, on a lane where the alternative evidence is a multi-hour QEMU build.

**Discovery is a glob, not a registry.** `run-tests.sh` runs every
`linux/scripts/tests/test-*.sh` in its own `bash` process (nothing leaks between
suites) and skips `test-harness.sh` by name. Adding a file adds a suite; there
is nothing to register — and deleting one removes coverage quietly, which is
exactly what the assertion aggregate above is for.

**The harness is the whole API.** `source test-harness.sh`, then `t_case <name>`
to label the assertions that follow, `t_assert_eq <expected> <actual> [msg]`,
`t_assert_contains <haystack> <needle> [msg]`, `t_assert_ok <cmd…>`,
`t_assert_fails <cmd…>`, and `t_summary` as the last line. `t_summary` exits
non-zero when an assertion failed **and when the suite ran none at all** — a
gutted suite must not read as a pass.

**Scripts that end in `main "$@"` cannot be sourced.** Several subjects are
executables, not libraries. The idiom is to cut the region under test out with
`awk` and `eval` it: `test-vulkan-target-decomposition.sh` extracts each
`_vulkan_target_*` helper by name, `test-iree-wheelhouse-stages.sh` takes the
block from `_iree_check_prereqs` through `build_iree_wheels`. Always assert that
the extraction caught what it claims (both suites do) so a rename degrades into
a failing assertion instead of an empty one.
`test-base-image-parse-options.sh` shows the two-mode variant: real
`bash base-image.sh …` processes for the error paths — every parse error dies
before `main` dispatches, so nothing touches apt, the network or the host — plus
the extracted parser with a stub `die()` for the paths whose only observable
effect is a variable assignment. Where the subject *is* a library
(`llvm-cross.sh`, `tvm-config.sh`) source it directly and stub its
collaborators.

**Stub EXECUTABLES on PATH vs shell-function stubs.** A collaborator invoked as
a plain word can be a shell function. One invoked through `env` — IREE's host
stage runs `env -u … cmake …` — or through any other exec cannot see a shell
function at all, so it needs a real file, `chmod +x`, on a PATH the suite
prepends. Get this wrong and the stub is silently bypassed while the host's real
tool runs.

**A failing `set -e` is only observable across a PROCESS boundary.** `set -e` is
disabled for the whole dynamic extent of a command whose status is tested, and
`t_assert_ok` / `t_assert_fails` test status with `if` — so a subject that fails
*only* through errexit cannot fail inside a subshell the harness calls. Drive it
in a fresh `bash` process instead. `test-base-image-parse-options.sh` needs this
for one arm: a trailing flag with no value at all reaches a `shift 2` that runs
out of arguments, which is a failure through errexit and nothing else.

**Mutation coverage is the rule.** A new regression test must be *demonstrated*
to go RED when the thing it guards is broken, and its header must state honestly
what it does and does not cover. The IREE suite is the worked example, and it
failed this twice on 2026-08-31 before it passed:

1. Its fault-injection stub matched nothing, so every "failure" case was really
   a success case. The pattern started with `--` and was passed positionally to
   `grep`, which here is **ugrep** and read it as an option. `grep -qE -e "$pat"`
   is the portable spelling; the symptom entry is in
   [`failure-modes.md`](failure-modes.md#a-fault-injection-test-passes-and-proves-nothing-grep-is-ugrep).
2. With injection working, `rc == 1` STILL did not discriminate. Deleting
   `|| return 1` from a build-stage call site let execution fall through into
   `_iree_package_wheels`, which bailed at its own missing-project-directory
   guard and returned 1 anyway — **the right answer for the wrong reason**, and
   with a misleading "produced no runtime/ wheel project" line standing in for
   the real configure failure and its log. The cases therefore also assert the
   packaging diagnostic is ABSENT, which is what actually pins the early abort;
   all five call sites are now verified to fail at least one assertion when
   their `|| return 1` is removed.

A suite nobody has watched fail is documentation with a green tick on it.

Per suite, what the assertions actually pin (so each file needs only a one-line
header):

| Suite | Subject | Pinned |
|-------|---------|--------|
| `test-logging-err-trap.sh` | `01-core/logging.sh` ERR trap | Every case runs a real `bash -c` under `set -Eeuo pipefail`, the only place the dynamic-scope bug reproduces. warn reports and lets the script finish; err reports and exits 1; neither dies on an unbound variable; the reported line is the FAILING one, not the install site; the command survives spaces, quotes and `$`; a trap installed inside a function still fires after that function returned and from inside another; the last install wins; and `build-gcc.sh`'s hand-re-armed two-argument `on_err` keeps err semantics. |
| `test-tvm-cmake-args.sh` | `05-frameworks/tvm-config.sh` `append_tvm_cmake_args` (15 positionals → named options) | Golden argv captured from the pre-refactor implementation byte for byte, including `-D` ORDER (a later flag overrides an earlier one) and the exact `${CMAKE_*:+ …}` suffix handling; the Vulkan / cross-linker / `LLVM_DIR` / `CMAKE_IGNORE_PATH` / CUDA-OpenCL normalisation arms; `resolve_qnn_sdk` exporting `TVM_QNN_HOME` non-locally, which `tvm.sh`'s post-install staging depends on; and that an unknown, missing or value-less option is a HARD error rather than a silently wrong feature set. |
| `test-vulkan-target-decomposition.sh` | `02-toolchain/vulkan.sh` `_build_vulkan_targets` + `_vulkan_target_*` | A golden trace of the cmake argv per component, the headers→loader→SPIRV-Tools→glslang order, the attempted/ok counter wording, the env-shaped all-failed verdict and its `VULKAN_CROSS_STRICT=1` promotion to fatal, the `source/glslang-main` checkout fallback, the `/usr/local/bin` alias plumbing (recorded through a stub `SUDO`, never run) — and that `_vulkan_target_link_glslang_aliases` keeps its explicit `return 0`, since the helpers are called as plain statements and its final false `[ -e ]` test would otherwise trip errexit and kill the SDK stage. |
| `test-llvm-cross-stanza.sh` | `02-toolchain/llvm-cross.sh` helpers split out of `_llvm_cross_setup_and_build` | One `-Wl,-rpath-link` per EXISTING directory in order, an out-array reset rather than appended to, a failing resolver tolerated; both compiler launchers or neither; the superset shape (projects/runtimes, `LLVM_USE_HOST_TOOLS`, `CLANG_TABLEGEN`) not regressing to the core-only one that leaves `libLLVMSupportLSP.a` unbuilt; the nested `CROSS_TOOLCHAIN_FLAGS_NATIVE` string with and without a launcher; the three injected arg groups landing at their original insertion points in the configure argv; and exactly four build/install calls — including the explicit `--target llvm-config` (TVM reads it out of `/opt/llvm-cross`) and `--strip` on both installs. |
| `test-iree-wheelhouse-stages.sh` | `05-frameworks/torch/build-app-wheelhouse.sh` `_iree_*` stages | The dynamic-scope couplings a refactor can silently sever — `ccache_cmake_args` / `_iree_launcher` reaching BOTH build steps, the `CCACHE_*`/`SCCACHE_*` exports surviving the helper boundary, `wheel_platform` reaching the retag, `iree_wheel_projects` reaching packaging so the cross lane ships the runtime wheel only, the target-python sysconfig export surviving into wheel-packing — plus the native and cross flag sets, the QNN arm, and the five mutation-covered `|| return 1` call sites described above. |
| `test-base-image-parse-options.sh` | `01-core/base-image.sh` `parse_options` (116-line nest → data table) | The asymmetries a "harmonising" rewrite would eat: `--archive-url` rejects an empty value while `--ports-url` accepts one verbatim; both also flip `USE_FAST_UBUNTU_MIRROR=true` while `--rewrite-security` does not and validates through `parse_bool_flag`; `install-vulkan-runtime-files` is the ONLY command taking positionals (stopping at `--` or the first non-flag, remainder into `REMAINING_ARGS`, and it alone sets that variable); a repeated flag keeps the LAST value; and the per-command, no-arg and catch-all arms each die with their own message verbatim. |

### In-image verification gates & their escape hatches (audit round 2)

**Retiring a transitional branch: probe, don't TODO.** A compatibility arm that
exists only for artifacts built before some fix should decide by *probing the
artifact* for a marker of the post-fix version (e.g. `grep -q STV_REQUIRE_GENAI`
in the image's baked smoke), never by a "delete me later" comment. Only a
POSITIVE probe may flip the verdict, so a probe that cannot run stays tolerant
rather than failing an image it simply could not inspect. Lesson recorded when
the riscv64 GenAI transitional arm was removed, 2026-08-31.


The 2026-08-08 audit closed a set of gates that previously could not fail.
Each hard gate has ONE explicit, documented escape hatch — set it only for a
deliberately reduced image, never to "get the build green":

| Gate | Where it runs | Escape hatch / opt-in |
|------|---------------|----------------------|
| riscv64 app-wheelhouse must contain real `*.whl` (a `.placeholder`-only dir fails) | `verify-media-artifacts.sh app-wheels` (Dockerfile.media) | `ALLOW_EMPTY_APP_WHEELS=1` |
| `/opt/venv` must exist in the package wrapper image (even torch-less images ship a venv with a `.torch-missing` sentinel) | `smoke-torch-venv.sh` via wrapper-smoke | unset `STV_REQUIRE_VENV` (only stages that legitimately ship no venv) |
| CUDA/cuDNN/TensorRT/NCCL completeness | `verify-cuda-stack.sh` (Dockerfile.nvidia) | default is warn-only; `CUDA_STACK_STRICT=1` is the OPT-IN hard gate for images that claim a complete stack |
| TVM presence/version per arch | `smoke-torch-venv.sh` (report only — TVM is best-effort by design) | `EXP_TVM=<version>` turns the report into a hard pin assertion |
| ELF architecture of shipped binaries | `validate-media-runtime.sh` — runs on EVERY scan since 2026-08-08 (a clean dependency scan used to `exit 0` before it) | `MEDIA_ELF_MISMATCH_FATAL=0` downgrades to warning |
| litert / genai / opencv-core produce real artifacts | `verify-media-artifacts.sh` | none — these verify stage-specific files now; genai mirrors its producer's legitimate cross-build skip, which since GEN1 (2026-08-31) covers only NON-arm64/riscv64 cross targets and a riscv64 lane switched off with `GENAI_ALLOW_RISCV64` |
| `onnxruntime_genai`'s native binding really works — version == the versions.env pin, the loaded pybind `.so` is TARGET-arch ELF (read from its own `e_machine`), and native code RUNS (`og.Tensor` numpy round-trip, the capability predicates, `og.Config` rejecting a non-model path from C++) | `smoke-runtime-image.sh` `check_genai_binding` (payload: `smoke-common.sh` `smoke_genai_py`) | none — but an absent wheel is a SKIP, not a failure (presence is the ARCH-PARITY table's assertion). Set `GENAI_MODEL_DIR` to a real model directory to arm the fourth tier, which calls `generate()` and asserts on TOKEN CONTENT; no model ships in these images, so that tier reports UNPROVEN by default |
| Vulkan cross-components (loader / SPIRV-Tools / glslang) — all three failing at once is an env-shaped toolchain cause | `vulkan.sh` | default is advisory (WARN); `VULKAN_CROSS_STRICT=1` is the OPT-IN promotion to fatal |
| Vendored-wheel SOABI vs target triple — a native `.cpython-*.so` carrying a SOABI for a different arch than the target triple is a host-SOABI leak that only fails at `import` | `verify-wheels.sh` (triple derived from `TARGET_ARCH`, **not** the running interpreter) | default is advisory (WARN); `WHEEL_SOABI_STRICT=1` is the OPT-IN promotion to fatal |
| Clean stop of a running chain — reaps the orphaned nerdctl/buildctl child subtree; **never `pkill` the orchestrator, that orphans them** | `bash linux/scripts/stop-cross-chain.sh` (finds the run via its pidfile, falling back to a bracket-trick pgrep) | n/a — operational tool, not a gate |

<a id="verify-the-shipped-bytes"></a>

**Verify the shipped BYTES, never the push** (backlog RTCACHE3; 2026-08-15 →
2026-08-16). The 2026-08-15 S2 saga shipped `:latest-cross` STALE five times
with every static gate and all smokes GREEN — the manifest, smokes, and push
were all byte-identical to a prior run. The real cause was the
`--output type=image` tagging bug (see
[`linux-cross-builds.md` § versions.env feature toggles](linux-cross-builds.md#versionsenv-feature-toggles-linux-lane),
"Why the explicit `RUNTIME_NO_CACHE`"), NOT a cache; media+android were always
fresh. This is now GATED automatically: `verify-shipped-wrapper.sh` runs in
`build-runtime-manifest.sh` in its OWN pass over every arch, before the boot
smokes and before the manifest is assembled —
it lists each wrapper's rootfs (`nerdctl export | tar -t`, arch-agnostic, no
emulation) and asserts the `/opt/ffmpeg` lib set matches the versions.env
toggles (`FFMPEG_ENABLE_TF` → `libtensorflow` present/absent, ffmpeg intact).
A mismatch aborts before `:latest-cross` goes live; `WRAPPER_CONTENT_GATE=0`
makes it advisory. To spot-check by hand: pull the wrapper and grep for the
expected lib set.

The two-pass order is load-bearing and was learned the hard way. Both checks
used to share ONE loop with the boot smoke first, so a smoke failure on arch N
skipped the content gate for arch N *and every arch after it*. On 2026-08-27
riscv64's smoke failed on an ARCH-PARITY arm, and the riscv64 wrapper that then
shipped in the index had never been content-checked at all. Content gate first
is also simply cheaper: `verify-shipped-wrapper.sh` is a tar listing — no boot,
no emulation — so it runs anywhere, while the smoke needs QEMU for foreign
arches.

That gate covers each wrapper's CONTENT. The INDEX went ungated until
2026-08-27: the only manifest check in the chain is
`nerdctl manifest inspect >/dev/null` (`build-runtime-manifest.sh:149`), which
proves existence, not freshness — so an index can be created, pushed and
reported green while one child still points at a previous run.
`linux/scripts/verify-manifest-freshness.sh` closes that, registry-only (no
pull, no emulation): it asserts each index child equals the digest its per-arch
tag resolves to, and that all children share one `org.kataglyphis.run-id`.
Run it with `EXPECT_RUN_ID` — measured on a live stale index, neither
assertion suffices alone, because a wholesale-stale ship is perfectly
self-consistent: child and tag agreed (both old), and all three run-ids
matched (all from the previous run). Only pinning to the run that just built
distinguishes the two. It is deliberately NOT yet wired into preflight or the
chain. **`:latest-cross` was re-shipped 2026-08-16** (fresh amd64
`509027696e16` / arm64 `bdb46c953954` / riscv64 `28e3ded96f72`) carrying the
Batch-2 fixes; that full-media rebuild flushed out two bugs the runtime-lane
validations miss because they skip smoke-media — (1) smoke-media's native cv2
import must be gated on numpy being importable (numpy is a `/opt/venv`
packaging dep, absent in the media BUILD sandbox → defer to the runtime smoke,
like onnxruntime), and (2) `configure-runtime.sh` runs a SECOND time in the
package stage, so its gstreamer-multiarch resolver must drop/skip the
pre-existing `lib/multiarch` symlink before resolving or it re-points it at
itself — and its dev-surface check must be a WARN, not a fail-loud exit (a
script that runs twice must not carry a build-breaking assert; the pkg-config
`verify_consumer_dev_surface` gate is the authority).

`preflight.sh` keeps its check list in one place — the `KNOWN_SLUGS` array
(`preflight.sh:60-63`), which is also the vocabulary `PREFLIGHT_ONLY=` and
`PREFLIGHT_SKIP=` accept. That array is the authority; the table below is its
contents in run order.

| Slug | Script | Catches |
|------|--------|---------|
| `crlf-guard` | inline (`git ls-files --eol`) | a tracked `*.sh` materialised with CRLF endings |
| `shellcheck` | `lint-shell.sh` | classes 6, 7 — `shellcheck -S error` over 263 files; `linux/host-config`'s operator tools joined the sweep on 2026-08-27, before that seven scripts sat outside it |
| `copy-coverage` | `verify-script-copy-coverage.py` | class 1 — a referenced `/opt/scripts` path never COPY'd/mounted into its image |
| `critical-fixes` | `verify-critical-fixes.sh` | classes 2, 3 (+ prior fixes; incl. fix6 native-GCC system paths) |
| `patch-integrity` | `verify-patch-integrity.sh` | a malformed unified diff, or an orphaned patch nothing references |
| `artifact-parity` | `verify-artifact-copy-parity.sh` | `Dockerfile.package`'s artifact-COPY lane — missing artifact-source stage, undocumented src/dst relocation |
| `arg-consistency` | `01-core/verify-arg-consistency.sh` | class 8 — ARG names/values vs `versions.env`, plus their forwarding |
| `version-snapshot` | `docs/scripts/sync_versions.py --check` | class 8 — version snapshots / inline markers / deps table out of sync |
| `doc-links` | `docs/scripts/verify_doc_links.py` | broken relative links, dead anchors, `file.md § Heading` refs, missing `INDEX.md`/toctree coverage |
| `doc-dupes` | `docs/scripts/verify_doc_dupes.py` | a passage copied into a second page; deliberate overlap is budgeted in `docs/scripts/doc-dupes.allow`, which itself fails when an entry goes stale |
| `sbom` | `docs/scripts/generate_sbom.py --check` | the committed curated SBOM drifting from `deps.json` + `versions.env` |
| `env-knobs` | `lint-env-knobs.sh` | a consumed `${VAR:-}` knob with no owner; advisory unless `KNOB_GATE=1` |
| `mirror-consistency` | `01-core/verify-ubuntu-mirror-consistency.sh` | class 8 — a Dockerfile missing the canonical Ubuntu mirror ARGs |
| `runtime-paths` | `04-runtime/verify-runtime-paths.sh` | class 8 — `PATH`/`LD_LIBRARY_PATH`/`PKG_CONFIG_PATH` drifting from `runtime-paths.env` |
| `dockerfile-lint` | `lint-dockerfiles.sh` | hadolint findings (policy in `.hadolint.yaml`; bootstraps a pinned, SHA-verified binary when none is on PATH) |
| `workflow-lint` | `lint-workflows.sh` | actionlint findings in workflows and composite actions |
| `python-lint` | `lint-python.sh` | ruff — hard-fails on the real-error classes (syntax, undefined names); the full ruleset is advisory |
| `secret-scan` | `lint-secrets.sh` | gitleaks over the working tree (`detect --no-git`), ENFORCING — triaged false positives are value-pinned allowlist entries in `.gitleaks.toml`, each carrying a written justification (`.gitleaksignore` is a superseded, deliberately empty stub: its `file:rule:line` fingerprints stopped matching on the first unrelated edit) |
| `android-parity` | `01-core/verify-android-stage-parity.sh` | the five parallel Android library stages diverging beyond `ANDROID_LIB` |
| `script-tests` | `linux/scripts/tests/run-tests.sh` | unit-test regressions in the tag/build-arg/disk-guard logic; prints the assertion aggregate above |
| `stage-graph` | inline `cross_stage_validate_graph` | bad parent refs, missing dockerfiles, unresolvable tags, cycles |

Every check with a script is runnable standalone (same command); `crlf-guard`
and `stage-graph` are inline in `preflight.sh` and have no separate entry
point. The pre-commit hook
(`.githooks/pre-commit`) runs a fast subset of the same gates —
`PREFLIGHT_ONLY=version-snapshot,arg-consistency,critical-fixes,copy-coverage,doc-links,doc-dupes,sbom`
(`:102-103`) — plus four checks of its own scoped to the STAGED content: an
unresolved merge-conflict-marker scan (`:69-85`), `bash -n` (`:109`), the
shellcheck gate restricted to staged `.sh` files (`:112`), and hadolint on
staged Dockerfiles (`:122`). It closes with a Sphinx `-W` docs build (`:137`),
which skips when the repo `.venv` has no `sphinx_kataglyphis`.

### In-image smoke tests (need a built image, not part of preflight)

These validate a built/pulled image and also run during the build to fail fast:

> **Two-environment semantics of `smoke-media.sh` (since 2026-08-10):** the
> suite runs TWICE — once inside the media build sandbox (Dockerfile.media,
> loader NOT yet wired: `/opt/ffmpeg` libs and `/opt/venv` are unreachable
> there) and once at the packaging stage (Dockerfile.package, loader fully
> configured). In the sandbox run, three gates deliberately DEFER instead of
> failing: the `onnxruntime_genai` Python import (its wheel installs into
> `/opt/venv` only at packaging; `smoke-torch-venv.sh` is the functional
> gate), the gst `libav` plugin load (links the source-built ffmpeg libav*
> — gated on ffmpeg-executability; libtensorflow is bundled only when
> `FFMPEG_ENABLE_TF=1`, which defaults OFF since S2, 2026-08-14), and
> ffmpeg's own execution. Auditing coverage by the media-stage log alone
> therefore UNDER-counts what is enforced — the packaging-stage run is the
> strict one.

- **Native source-build header preflight** — inside `setup-torch-venv.sh`
  (`verify_native_source_headers`): compiles tiny C / C++ / jpeglib probes with
  the same compiler+flags the pip build uses, so a header/sysroot regression
  (classes 2/3) aborts in <1s instead of after a ~9-min numpy/pillow compile.
- **Torch venv integrity** — `06-packaging/smoke-torch-venv.sh`: imports
  numpy/torch/torchvision/PIL/cv2/contourpy (+ torch↔numpy ABI bridge) from
  `/opt/venv` (class 5). Wired into `the wrapper-smoke target's smoke set (validate-compilers, smoke-media, smoke-torch-venv, smoke-cross-all-arches)`; skips cleanly if no venv.
  Run standalone: `VENV=/opt/venv smoke-torch-venv.sh`.
- **Runtime-image boot + functional smoke** — `06-packaging/smoke-runtime-image.sh
  <image> <arch>`, run per-arch by `build-runtime-manifest.sh` against the freshly
  built wrapper. Boots the actual published image and, under **binfmt/qemu for the
  cross arches**, runs real workloads *on-target*:
  - ML imports (`onnxruntime`, `numpy`, `torch`) + `ffmpeg -version` (pipefail-guarded
    so a missing `.so` can't pass silently); torch-less sentinel flagged.
  - **ML version-pin assertion** (fail) — not just *importable* but the *correct
    versions*. Delegates to `smoke-torch-venv.sh` (assert-only). Two authorities,
    but since GENAI-DRIFT (2026-08-23) they are **no longer unioned** — whichever
    one OWNS the package decides (`smoke-torch-venv.sh:73`, implemented at `:254`
    as `allowed = pin_set(build_pin) if build_pin else set(from_lock)`). A
    versions.env **build pin** wins outright for everything we build or
    force-reinstall from a **local wheel** (riscv64 torch/vision, the source-built
    onnxruntime, ai-edge-litert, onnxruntime-genai) on every arch that builds it;
    the lock's opinion is printed (`[uv.lock says …; build pin wins]`) but not
    accepted. uv.lock governs only what uv resolves and we do not build
    (numpy/pillow/contourpy + the amd64/arm64 torch/vision/onnx wheels when
    unpinned). The comparison uses each module's `__version__`, which for the
    source-built onnxruntime intentionally differs from its pip dist metadata —
    the build pin (`ONNXRUNTIME_VERSION` in `versions.env`) is what governs. The
    old union is exactly how arm64 shipped onnxruntime-genai 0.14.0 (from the
    lock) against a `v0.15.2` build pin and still printed OK. One carve-out
    survives: `KNOWN_DRIFT` (`smoke-torch-venv.sh:178-180`) is a dated, exact
    `(dist, arch, installed, expected)` quadruple, printed as a loud `!!` and
    counted in the summary; anything that is not that exact quadruple still
    FAILS, and a new version on either side re-arms the assert by itself.
    Also checks the `+cpu`/`+cu130` build variant vs `PYTORCH_EXTRA` and the OpenCV
    major. Catches a wrong version silently slipping in (lock drift, a stale local
    wheel, a floated index) — the class a presence/import check can't see.
  - **Native `/opt` `.so`-closure gate** — `ldd` over the ffmpeg/opencv5/libcamera/
    vulkan payload; any unresolved soname fails the gate. Generalises the ffmpeg
    check to the whole native stack (the class that shipped libopencore-amrwb.so.0-
    broken ffmpeg). Venv Python extensions are excluded (import-time lib paths defeat
    bare `ldd`; the import checks are their gate).
  - **ARCH-PARITY table** (fail) — `smoke-runtime-image.sh` sees ONE image at a time
    (`build-runtime-manifest.sh` invokes it per arch), so this is **table
    conformance, not a cross-arch diff**. Every `/opt` prefix and component wheel
    NAMED in `_PARITY_PREFIXES`/`_PARITY_WHEELS` must be present on this arch unless
    `_parity_exempt` documents its absence; exactly one `onnxruntime` distribution,
    the flavour `_parity_ort_flavor` names, may be installed. The **blind spot** is a
    one-sided EXTRA: a component present on one arch and absent from the table is
    invisible to the loop, so the untracked `/opt` prefixes are printed (INFO) every
    run and a human diff of the three per-arch logs is what catches it — putting a
    component under the gate means adding it to the table. A documented exemption
    whose component turns out to be PRESENT **fails**, and so does a
    `_PARITY_GST_KNOWN_BROKEN` entry whose plugin starts loading again (two
    independent signals must agree: absent from the scanner's failure list AND
    `gst-inspect-1.0` loads the file directly). Warning there instead would let the
    table rot underneath a green run; failing makes it self-correcting, since the fix
    is the one-line deletion the message names.
  - **GStreamer plugin health** (warn) — lists plugins whose runtime `.so` is absent
    (they degrade gracefully); surfaces app-critical regressions like
    `webrtcbin2`→`librice-proto.so.0`. **GStreamer core pipeline** (fail) —
    `videotestsrc ! videoconvert ! fakesink`.
  - **onnxruntime inference** (fail) — runs a tiny embedded Add model and asserts the
    output (proves the CPU EP executes, not just imports). **cv2 encode/decode**
    roundtrip. **Application import** — the shipped venv must `import orchestr_ant_ion`.
  - **Native compiler battery compile+link+RUN** — an 8-case battery with the image's
    `gcc`/`g++`, each running the resulting binary on-target: C hello (stdout),
    pthreads, libm, libatomic; C++ hello (libstdc++), **exceptions+STL** (throw/catch +
    `std::sort`), std::thread, and `-flto`. This is what upgrades class 4 from a static
    ELF/machine check to genuine **execution** proof: a cross arch's binary can't run
    on the x86_64 build host, so the shipped native GCC (esp. the riscv64
    `--with-isa-spec` toolchain) was previously never actually executed — under qemu
    here it is. The **exceptions+STL** case is the regression guard for the
    `swap-native-gcc.sh` **wrapper** fix (`c46da5f`): the compiler reaches the runtime
    image's system headers via command-line `-idirafter` wrappers, *not* an installed
    `specs` file — a specs file silently drops `-lgcc_s`/`--eh-frame-hdr` and makes
    every throwing C++ program terminate at runtime. Gate `RUNTIME_COMPILER_SMOKE=0` to skip just this;
    `RUNTIME_FUNCTIONAL_SMOKE=0` skips all functional checks; `RUNTIME_IMAGE_SMOKE=0`
    (in `build-runtime-manifest.sh`) skips the whole runtime-image smoke (e.g. a host
    without a qemu handler for a foreign arch).

### Foreign-arch execution needs QEMU binfmt — registered **without sudo**

The foreign-arch smokes above only mean something if the image's binaries can
actually *execute* on the build host. That requires a `binfmt_misc` QEMU handler.
**`build-runtime-manifest.sh` registers it automatically, with no sudo**, before the
smoke loop (`ensure_foreign_binfmt` → `linux/scripts/setup-rootless-binfmt.sh`).
Opt out with `RUNTIME_REGISTER_BINFMT=0` (e.g. a rootful/CI host where qemu is
already registered via `docker run --privileged tonistiigi/binfmt` or
`update-binfmts`).

Two dead-ends to know about, because both *look* like they work and don't:

- **`nerdctl run --privileged tonistiigi/binfmt --install …` (rootless)** registers
  binfmt inside the throwaway container's own user namespace, which `--rm` destroys.
  It prints "arch OK" but never reaches the namespace where builds/runs happen.
- **BuildKit's embedded `/dev/.buildkit_qemu_emulator`** only wraps the *top-level*
  process of a `RUN`. The shell starts, but its first *child* exec
  (`uname`, `mktemp`, `gcc`, `python`, `ffmpeg`) dies with **`Exec format error`** —
  so it cannot run any real multi-process smoke.

`setup-rootless-binfmt.sh` is the working no-sudo path on a rootless
containerd/BuildKit host: buildkitd runs `nsenter`'d into containerd's rootlesskit
namespace, so `nerdctl run` and `nerdctl build` **share one persistent namespace**.
The script extracts the static `qemu-<arch>` emulators from `tonistiigi/binfmt`,
enters that shared namespace via `containerd-rootless-setuptool.sh nsenter` (where
the mapped uid-0 *does* hold `CAP_SYS_ADMIN` over its own mounts — no host sudo), and
registers each with flags **`POCF`**. The **`F` (fix-binary)** flag is the crux: the
kernel opens the interpreter fd at registration time, so emulation is inherited into
the nested build/run namespaces where the qemu path isn't even mounted — which is
exactly what makes *child* execs work. Register once per boot (or install the
`systemd --user` unit with `--install-service`); verify with `--verify`.

## Dedup & factoring notes (2026-07)

The tree has been through several dedup passes already; remaining duplication is
largely **deliberate** and should not be "fixed":

- `cross_build_is_active` / `install_host_packages` etc. are re-defined as
  **fallbacks** in several modules so each can be sourced standalone. Removing
  them breaks isolated use.
- `build-libcamera.sh`'s inline `-idirafter /usr/include` (generic) plus its
  `append_cross_idirafter` call is a **native/cross fallback pair**, not a copy.
- The `-idirafter` logic in `setup-torch-venv.sh` + `swap-native-gcc.sh`
  duplicates the canonical helper `append_cross_idirafter` (`01-core/common.sh`).
  It is **inlined on purpose**: the torch/android stages do not COPY `common.sh`
  (nor its `load-versions-env.sh` chain), and pulling that in for six flag lines
  is not worth the surface on a verified critical path. The copies are
  cross-referenced to the helper and kept in sync by `verify-critical-fixes.sh`
  **fix6** — the pattern for necessary duplication: guard it, don't hide it.

## Hardening pass (2026-07) — landed + residuals

**Landed** (see `verify-critical-fixes.sh` **fix7** for the regression guards):

- **Build cache** — replaced the self-defeating registry `-buildcache` (whose
  `--cache-to` was gated out by `NO_CACHE_EXPORT`, so nothing ever cache-hit)
  with a **local** buildkit cache + inline cache on push. This is why full base
  rebuilds no longer recur on the same host.
- **Base cache scope** — base RUNs bind-mount only `01-core` (+ `02-toolchain`
  for shared tooling), so editing a media/android script no longer busts the
  base image.
- **Supply-chain** — the sole floating external base (`ubuntu:26.04`) is now
  digest-pinned by its multi-arch manifest-**list** digest (`UBUNTU_DIGEST`).
- **Non-root runtime** — `/workspace` is `chown`ed to `kataglyphis`;
  `PYTHONDONTWRITEBYTECODE=1`; the build-only fake `sudo` shim is stripped from
  the shipped image.
- **Robustness** — image-wide `apt` retries (`80-retries`); real-pipe +
  `PIPESTATUS` so a failing build's log tail is flushed and its true exit code
  returned; `parallel-loop.sh` names the failed arch.
- **Smokes** — every previously-orphaned smoke now runs: `smoke-toolchain`
  (toolchain, `Dockerfile.toolchain:314`), `smoke-android` (android,
  `Dockerfile.android:361`), the wrapper-smoke set `validate-compilers` +
  `smoke-media` + `smoke-torch-venv` + `smoke-cross-all-arches`
  (`Dockerfile.package:346`, `FROM package AS wrapper-smoke`). The wrapper-smoke
  stage is a separate `--target wrapper-smoke` build run by
  `_runtime_run_package_smoke` in `runtime_build_chain`, between the package
  and wrapper builds (`WRAPPER_SMOKE_GATE=0` to skip) — it is NOT reached by the
  package build's own `--target package`, which prunes everything after `package`.
  Also host-side `smoke-runtime-image` (in `build-runtime-manifest.sh`,
  `RUNTIME_IMAGE_SMOKE=0` to skip).
  The one deliberate exception is `smoke-vulkan`, which is wired into **no**
  stage: it probes the full Vulkan *SDK* (`/opt/vulkan/active`,
  `vulkan/vulkan.h`, `libvulkan.so`) while this cross build installs only the
  Vulkan *runtime* (`libvulkan.so.1` + ICD/layer JSONs), so it can never pass
  here. `verify-critical-fixes.sh:262-265` hard-fails preflight if any
  Dockerfile RUNs it; it is retained as a standalone host tool for image
  variants that DO ship the SDK (see the tail note in `Dockerfile.package:357`).
- **Reproducibility (opt-in)** — `clone_or_update_repo` and `build-ffmpeg.sh`
  accept a 40-hex commit SHA; `OPENCV_COMMIT`/`OPENCV_CONTRIB_COMMIT`/
  `FFMPEG_COMMIT` (empty by default = track the bleeding-edge branch) freeze
  those sources to an immutable commit for a release build.
- **Attestations (opt-in)** — `BUILD_ATTEST=1` attaches SLSA provenance + SBOM
  to pushed images.

**Residual supply-chain gaps** (tracked, not yet closed — each is a known
`curl`/`wget` without a checksum; the fix is to route it through
`download_verified_file` with a new `*_SHA256` in `versions.env`):

| Source | Site | Note |
|--------|------|------|
| Flutter SDK tarball | `flutter/setup-flutter.sh` | per-arch sha; large |
| Android cmdline-tools zip | `android-sdk.sh` | NDK/build-tools are sdkmanager-verified |
| freetype source | `opencv/install-deps.sh` | swallows failure with `\|\| true` — tighten too |
| GStreamer-Android universal | `android/build-gstreamer.sh` | published sha256 available |
| `rustup-init` / NodeSource | `install-rust.sh`, `onnxruntime/build/10-deps.sh` | `curl \| sh` — pin the bootstrap binary by sha |

**Deliberate keep:** the `-dev` header packages in `setup-torch-venv.sh` land in
the final image. This is a cross-**dev** container that compiles Python wheels
from source under QEMU at build time, so the headers are load-bearing; splitting
build-deps from runtime-deps would risk the source-build path for marginal size
savings. Left as-is by design.
