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
- **Static host verifiers wired into `linux/host-config/git-hooks/pre-commit`:** `verify-critical-fixes.sh`,
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
| TVM presence/version per arch | `smoke-torch-venv.sh` — a HARD assert on every image since `EXP_TVM` is set from `versions.env` `TVM_REF` at `smoke-torch-venv.sh:97`, not opted into | none. A media build that ships without TVM fails the per-arch wrapper smoke and **blocks the manifest**, at the end of a multi-hour chain. Dropping TVM from a lane means removing the pin, not expecting a warning |
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
(`preflight.sh:39-48`, 29 slugs), which is also the vocabulary
`PREFLIGHT_ONLY=` and `PREFLIGHT_SKIP=` accept. **That array is the authority for
both membership and run order** — the table below groups them by kind and will
drift if a slug is added without touching it.

| Slug | Script | Catches |
|------|--------|---------|
| `crlf-guard` | inline (`git ls-files --eol`) | a tracked `*.sh` materialised with CRLF endings |
| `shellcheck` | `lint-shell.sh` | classes 6, 7 — `shellcheck -S error` over 294 files; `linux/host-config`'s operator tools joined the sweep on 2026-08-27, before that seven scripts sat outside it |
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
| `stdout-returns` | `verify-stdout-returns.py` | a function whose stdout is captured by `$(...)` logging to stdout, poisoning its return value |
| `code-dupes` | `docs/scripts/verify_code_dupes.py` | token-normalised duplication across shell, Dockerfiles and non-`docs/` Markdown — it sees *renamed* clones |
| `masked-decls` | inline | `local x=$(...)` / `export x=$(...)`, where the declaration masks the command's exit status |
| `comment-size` | inline | comment blocks over 10 lines, against a frozen baseline — prose belongs in `docs/` |
| `code-size` | `verify-code-size.py` | shell/Python functions over 80 lines and shell/Python/Dockerfile files over 800, against `function-size.allow` / `file-size.allow` |
| `mutations` | `docs/scripts/verify_mutations.py` | a test that CANNOT fail: each recorded mutant neuters one guarantee and the named test must go red |

Every check with a script is runnable standalone (same command); `crlf-guard`
and `stage-graph` are inline in `preflight.sh` and have no separate entry
point. The pre-commit hook
(`linux/host-config/git-hooks/pre-commit`) runs a fast subset of the same gates —
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

#### Shipped-truth gates (2026-09-01) — measure the artefact, not the log

Two classes were invisible to every gate above because every gate above reads
what the *build* claims. These read the *shipped bytes*. Both live in
`06-packaging/smoke-runtime-image.sh` and share ONE in-image probe
(`run_shipped_truth_probe`, ~13 s per image (measured on arm64; the three gates together ~15 s), no network, no host state).

**Why one probe that only prints facts.** The probe emits `ADV`/`HAVE`/`PKG`/
`REQ`/`DANG` lines and an `RTPROBE_DONE` marker; every verdict is reached
afterwards on the host by `_advert_verdicts` and `_venv_set_verdicts`, which are
pure `text in → verdict lines out`. That split is deliberate: the judging code
can be driven from a *recorded* probe capture, so its failure paths are provable
without a doctored 27 GB image — and without a hand-copied replica of the logic,
which is exactly how a test in this repo once stayed green while the code it
guarded was gutted.

**A. Advertised env versions == actual** (`check_advertised_versions`, fail).
Every key in `_ADVERTISED_VERSION_KEYS` (`PYTHON_VERSION`,
`PYTHON_MAJOR_MINOR`, `GCC_VERSION`, `LLVM_RELEASE`, `GSTREAMER_VERSION`,
`VULKAN_VERSION`) is compared against what the image *has* — the venv
interpreter, `gcc -dumpfullversion`, `clang --version`,
`gst-inspect-1.0 --version`, the resolved `/opt/vulkan/active` path. This exists
because all three wrappers shipped Ubuntu's Python **3.14.4** while advertising
`PYTHON_VERSION=3.14.7`; an env label that contradicts the interpreter is worse
than no label, since everything downstream reasons from it. There is **no
exemption arm** — a version label that disagrees with the artefact is never a
documented state. An unset or unreadable key is a loud per-row `SKIP`, and if
*every* row skips the gate **fails** rather than printing a green it did not
earn.

**B. Venv package set vs the app's own declared graph**
(`check_venv_package_set`, fail). Measured live, the shipped venvs held
amd64 = 153, arm64 = 165, **riscv64 = 66** distributions; 99 packages were simply
gone on riscv64 and nothing noticed, because ARCH-PARITY only conforms a fixed
*name table* of `/opt` prefixes and component wheels and never compares the venv
set at all.

The gate does **not** carry a checked-in list of 165 names and does **not** carry
a count anybody can lower. The expected set is derived from the image's own
metadata: the app distribution's `Provides-Extra` requirement edges, with
environment markers evaluated *inside the image*. Upstream already encodes the
legitimate riscv64 divergences as markers
(`mlflow; platform_machine != "riscv64"`), so those are honoured for free and
never need a local exception. Which extras count is a two-line **contract**, not
a threshold: `_VENV_CONTRACT_EXTRAS="ml-ai docs"` (what `assemble-torch-app.sh`
always requests) plus whichever `pytorch-*` extra the image itself advertises in
`PYTORCH_EXTRA` — reading the image's own advertisement is what keeps a
`pytorch-cpu` wrapper from being asked for the ROCm extra's wheels. A second arm
needs no configuration at all: any **dangling edge** — an unconditional
requirement of an installed distribution that is not installed — fails, which is
what covers the transitive tail the extras graph cannot see.

Documented divergences go in `_venv_pkg_exempt`, keyed `<arch>:<extra>:<pkg>`
(`DEP` for a dangling edge) and following `_parity_exempt`'s contract exactly:
listed = reviewed, and an arm whose package turns out to be **present** fails and
names the line to delete, so the table cannot rot in place. Today it holds two
real facts — `cv2` is the source-built `/opt/opencv5` binding rather than the
PyPI `opencv-python` wheel, and `onnxruntime` ships under its flavour name
(`onnxruntime_dnnl` / `_webgpu`), which `_parity_ort_flavor` asserts. An extra
that yields **no** requirement edges fails (renamed upstream, or truncated
metadata) and so does a run that asserted nothing: an empty set is not a pass.

**What these two do NOT cover.** They still see one image at a time, so a
component present on *every* arch but wrong on all of them is invisible; a
package installed at the right name but the wrong *version* remains the ML
version-pin assertion's job; anything the app does not declare as a requirement
(a transitively-pulled tool nobody depends on) is outside the graph; and the
advertised-version table covers the 17 keys in `_ADVERTISED_VERSION_KEYS` — a new
version-carrying `ENV` in `Dockerfile.package` is unguarded until it is added to
`_ADVERTISED_VERSION_KEYS`.

**Mutation record (both gates proven red, then green).** Against the real
locally-built `latest-cross-arm64`/`-riscv64` wrappers:

| mutation | result |
| --- | --- |
| none (as shipped) | A **fails** on the live `PYTHON_VERSION` 3.14.7-vs-3.14.4 defect on both arches; B green on arm64 (18 edges), **10 fails** on riscv64 (`optuna`, `pandas`, `scikit-learn`, `scipy`, the four `docs` packages, `flatbuffers`, `protobuf`) |
| advertise `PYTHON_VERSION=3.14.4` (the corrected label) | A **green**, 6/6 |
| advertise `GSTREAMER_VERSION=9.9.9` | A fails on that key too — a second, independent row can red |
| `pip uninstall captum scipy`, image re-committed | B goes **red**: 2 extra-requirement fails + 3 dangling-edge fails; unmutated image green |
| recorded probe, `RTPROBE_DONE` stripped | both gates **fail** ("a gate that cannot run is not a pass") |
| recorded probe, every `ADV` value blanked | A **fails** the vacuous-pass guard after six loud `SKIP`s |
| recorded probe, `PKG opencv-python` added | B **fails**: the documented exemption no longer applies, message names the arm to delete |
| recorded probe, `REQ docs …` removed | B **fails**: refuses to assert an empty extra |
| recorded probe, `VENV ABSENT` injected | B prints a loud `SKIP` (never a pass) |

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

### Advertised version keys (`advert-keys`)

`linux/scripts/verify-advertised-keys.py` globs `linux/Dockerfile.*` for every
version-shaped `ENV`/`ARG` and fails when one is neither checked by the smoke's
advertised-vs-actual gate (`_ADVERTISED_VERSION_KEYS`) nor listed in `EXCUSED`
with a reason. A stale excuse fails too, so the table cannot rot.

The smoke's HAVE side must be an *independent* measurement, never a re-read of
the value the image advertises. `VULKAN_VERSION` used to fail this: it parsed
the version out of `/opt/vulkan/active`, a directory named by the very ARG being
checked, so the row could never disagree. It now reads the loader
(`vulkaninfo`), falling back to `VK_HEADER_VERSION` in the SDK header.

Both sides are normalised before comparison: a leading `v` is stripped from the
advertised git tag, and the measured value is cut to its numeric prefix so a
`.dev0+<sha>` trailer (as `iree-base-runtime` carries) still compares equal.

### Distro package names (`pkg-names`)

`linux/scripts/verify-package-names.py` resolves every package name the tree
asks apt for against the live Ubuntu indices. Two properties matter:

- A **partial** index fetch is not a pass. If any component (`main`,
  `restricted`, `universe`, `multiverse`) fails to download, the truncated name
  set is discarded and not cached — otherwise a mirror hiccup would report live
  packages as dead.
- The vendor-repo exemption applies to vendor-shaped **names**, not whole files.
  `setup-rocm-repo.sh` installs `curl`, `gpg` and `ca-certificates` from plain
  Ubuntu before it adds the vendor repo; those stay failable.

Offline is a `SKIP`, never a pass.

### Runtime image push retries

`01-core/runtime-build-fns.sh` retries a runtime image push, because a ~8 GiB
wrapper upload can reset mid-transfer. Only the upload repeats:
`PUSH_MAX_ATTEMPTS` (default 4) and `PUSH_RETRY_BASE_SECS` (default 15 s).

A **permanent** failure is not retried. An unpushable `not found` — the build
never created the tag — once burned all four attempts and buried the real cause
in retry noise. The classification comes from the cross lane's
`_cross_stage_push_error_is_transient` (`01-core/cross-stage-build.sh`); when
that helper or the temp log is unavailable, every failure is retried as before.

### cross-apt: pkg-config libdir resolution

DUP1: was a hand-rolled uname->triplet case here. platform.sh's
arch_deb_multiarch_triplet_for is the SSOT. Mount/bake map independently
RE-AUDITED 2026-08-24 (grep of every RUN/COPY block referencing this
file — do not re-litigate without re-running that grep): platform.sh is
co-mounted in ALL 5 Dockerfile.toolchain RUNs that mount this file
(blocks at 70/124/187/245/266) and in both Dockerfile.media litert RUNs
(per-file mounts @414, whole-01-core mount @432). Dockerfile.sdk is the
ONLY image that bakes this file (COPY block @91) and bakes platform.sh
beside it (:60). Dockerfile.android and Dockerfile.torch do NOT ship
cross-apt.sh at all (an earlier note listed them; that was vacuous —
torch bakes cross-env.sh WITHOUT this file, so sourcing cross-env.sh
there dies loudly at its `source cross-apt.sh`, never reaching this
fallback silently). Plus cross-env.sh:10 and 01-core/common.sh:22 both
source platform.sh before this file, and the missing-helper branch below
still warns loudly if a future RUN forgets the co-mount.
(Only apt_sources_set_architectures is contracted to work when cross-apt.sh
is sourced STANDALONE — see 02-toolchain/android-sdk.sh:8 — and it stays
dependency-free.)

The two ways this lookup can come back empty are NOT the same failure and
must not degrade the same way. A single `... 2>/dev/null || true` collapsed
both into silence:
* helper MISSING (rc 127, command not found) = a WIRING bug — platform.sh
was not co-mounted/sourced. Every host-arch pkgconfig dir silently
vanishes from PKG_CONFIG_LIBDIR and host tools (xcb & friends) start
failing to configure with no hint as to why. Say so, loudly.
* helper present, arch UNRECOGNISED (rc 1) = expected degradation. The
candidate is skipped and we stay quiet, exactly as before.

### Rust version parsing across toolchain spellings

Resolve the version a CI run should stamp, from the sources every consumer
has: a VERSION.txt at the repo root, else the ref name, else the run number.

Lifted out of a consumer (Kataglyphis-RustProjectTemplate's
scripts/compute_version.sh) because every repo with a CI lane needs exactly
this and had to reimplement it around the primitives above.

The guards are load-bearing, in this order:
* only the FIRST NON-EMPTY line of VERSION.txt counts, CR-stripped and
trimmed - a file written on Windows otherwise yields "2.3.4\r", which is
not a valid version anywhere downstream;
* a leading "v" is dropped, so a v-prefixed tag works as a ref source;
* anything that still does not START WITH A DIGIT falls back to the run
number, which keeps a branch name like "feature/x" from becoming a
version. That guard is also why normalize_version's own "v" handling is
unreachable from here.

One deliberate behaviour change from the consumer version this replaces:
`read` returns non-zero on a final line with no trailing newline, so a plain
`while IFS= read -r line` DROPS it. A VERSION.txt written without a trailing
newline was therefore ignored outright and the run number stamped instead -
silently, since the fallback looks like a normal result. The
`|| [[ -n "$line" ]]` guard below reads that last line.

### 03-media module bootstrap

Data-driven per-arch skip flags --------------------------------------------

The repeated boolean per-arch skip decisions in the media install/build
scripts (e.g. "skip target Csound packages on riscv64/arm64 cross") are
consolidated into declarative flag files next to this one:
arch-flags-{amd64,arm64,riscv64}.env — KEY=value lines only (MEDIA_SKIP_*;
1 = skip, 0/unset = do not skip), with the per-flag justifications kept as
comments in those files.

media_load_arch_flags resolves the effective target arch — cross_target_arch
when a cross build is active, otherwise the native amd64 defaults — and
sources the matching flag file if present. A missing file simply leaves
every MEDIA_SKIP_* flag unset (= do not skip), matching the old
is_cross_*-style helpers which only ever skipped on active cross builds.

Consumers:
- Scripts using media_common_init get the flags automatically (called at
the end of media_common_init, after cross-env.sh is loaded).
- install-deps-preamble based scripts source this file (container path
/opt/scripts/03-media/core/common.sh first, repo layout second) and call
media_load_arch_flags themselves; the preamble has already provided the
cross_build_is_active / cross_target_arch helpers by then.

### smoke-torch-venv: what the venv assertions cover

Assert installed ML-stack versions match their pins. Two authorities, but NOT
unioned (GENAI-DRIFT, 2026-08-23): whichever one OWNS the package decides.
- versions.env build-pin -> packages we BUILD or force-reinstall from a
LOCAL wheel (riscv64 torch/vision, source-built onnxruntime,
ai-edge-litert, onnxruntime-genai). The pin WINS outright, on every arch
that builds it; the lock's opinion is printed but not accepted.
- uv.lock -> everything uv resolves and we do not build (numpy/pillow/
contourpy, the amd64/arm64 torch/vision/onnx wheels when unpinned).
The old union accepted either, which is exactly how arm64 shipped
onnxruntime-genai 0.14.0 (from the lock) against a v0.15.2 build pin and
still printed OK.
That tightening exposes a drift whose PRODUCER-side fix is still open, and
this assert is a hard release gate, so the known case is carried in
KNOWN_DRIFT below: an exact (dist, arch, installed, expected) quadruple,
dated, naming its backlog item, printed as a loud `!!` on every run and
counted in the summary. Anything that is not that exact quadruple still
FAILS. It uses each module's __version__ (the actual runtime
version) -- which for onnxruntime intentionally differs from its pip dist
metadata (source-built lib vs locked wheel; the build pin governs). Also
asserts the torch/vision build VARIANT (+cpu/+cu130/+rocm7.1) matches
PYTORCH_EXTRA and that OpenCV's major matches OPENCV_VERSION, and runs the
cv2 media backends for real (SMOKE-DEPTH a).

### smoke-media: GTK/pango expectations per arch

Mandatory-plugin gate (smoke-depth R1): meson `enabled` guards CONFIGURE,
but a plugin that ships and then fails to dlopen was only a WARN-count.
A present-but-unloadable plugin is exactly the observed class
(webrtcbin2→librice-proto, gtk4→vkCreateWaylandSurfaceKHR).
The `libav` plugin is special: this project's gst-libav links the
source-built FFmpeg libav* (incl. libavfilter, which NEEDs the bundled
libtensorflow.so.2). Those resolve only once configure-runtime.sh has wired
the loader — the SAME reason the ffmpeg binary itself is deferred in the
build sandbox below. So gate `libav` on ffmpeg executability HERE: if ffmpeg
cannot run in this environment (sandbox), a libav load failure is that same
deferral (INFO; re-tested by the packaging-stage smoke, Dockerfile.package,
where the loader is wired); if ffmpeg DOES run here but libav still fails,
that is a real defect.
opencv/onnx have the SAME class of build-sandbox issue, not a link to ffmpeg:
the opencv plugin links pass-2 OpenCV, which links the source-built GStreamer
(a circular dep the build sandbox can't close); the onnx plugin links
libonnxruntime.so which transitively needs libstdc++.so from the source-built
GCC (a path the flat NEEDED scan in validate-media-runtime.sh doesn't catch
but the dynamic linker hits at dlopen). Both pass validate-media-runtime's
NEEDED scan and the runtime/packaging smoke (Dockerfile.package) where the
loader is fully wired. Gate on the ffmpeg-executability proxy: if ffmpeg
can't run here (build sandbox), defer opencv/onnx just like libav.

### slang-compile: shader compilation contract

Caches the subdirectories under the source tree in SLANG_COMPILE_SUBDIRS,
reused for every -I expansion.

ORDER IS LOAD-BEARING and was previously whatever `find` happened to emit -
i.e. filesystem order, which differs between a developer's ext4 checkout and
the CI runner's overlayfs. `import <name>` resolves to the FIRST <name>.slang
on the -I list, so any two modules sharing a basename resolved differently on
different machines. BeschleunigerBallett has exactly that: common/noise.slang
(simplex noise + fbm) and compute/noise.slang (a noise-volume kernel). On CI
the compute/ one won and tests/noise_test.slang, which wants the common/ one,
failed to build every clang lane with
error[E30015]: undefined identifier 'snoise'
while the same tree built fine locally.

Two rules, both deliberate:
1. sort, so the answer is reproducible anywhere;
2. hoist a top-level common/ ahead of the rest, because "shared module
lives in common/" is already this driver's assumption (see the comment
on the -I expansion below) and is the documented contract on the
consumer side too - BeschleunigerBallett's buildIntegritySuite.cpp
resolves imports with an explicit "then a common/ preference".
Alphabetical order happens to give the same answer for common/ vs
compute/, which is precisely why this must not be left to luck.

The generated output tree is excluded: it holds no .slang sources, and
feeding a build directory back in as an include path can only add
ambiguity.

### apt retry and mirror fallback

── update-alternatives install + select ──────────────────────────────────────
Register an alternative and immediately select it. Runs privileged via
run_priv (honors ${SUDO}). The --set is tolerant: a --set of the path just
--installed effectively never fails, and a spurious failure must not abort a
build running under `set -e`.

Usage: alt_install_and_set <name> <link> <path> [priority] \
[--candidate <path>]...            # extra paths to search for the binary
[--slave <link> <name> <path>]...  # slave alternatives (multi-binary groups)

Backward compatible with the historical `<name> <link> <path> [priority]`
form. Extensions (so the 02-toolchain scripts can converge onto this helper):

--candidate <path>  Add <path> to the search list. The FIRST executable among
{<path>, candidates...} is the one registered. When one or
more --candidate are given and NONE (including <path>) is
executable, the function is a no-op (nothing to register).
With no --candidate, <path> is registered verbatim exactly
as the original 3/4-arg form did (no executability check).
--slave L N P       Pass a `--slave L N P` group through to --install, so one
call can register a multi-binary group (e.g. clang + its
clang++/clang-format/… slaves).

### Swapping the native GCC in the shipped image

--- Make the foreign-arch native GCC search runtime system headers ---
The relocated Canadian-cross GCC keeps its compile-time --native-system-
header-dir (/usr/${triplet}/include) baked in; that path is absent in the
runtime image, so a bare `gcc hello.c` cannot find <stdio.h>. The profile.d
block above only helps make-style builds -- a bare `gcc`/`g++` reads
neither CFLAGS nor CPPFLAGS, and CPATH cannot satisfy the C++
`#include_next`.

We fix this with thin WRAPPER scripts that prepend the system include dirs
on the *command line* (-idirafter, appended AFTER all built-in dirs so it
never shadows libstdc++'s own headers and satisfies both C `<...>` and C++
`#include_next`). This is NOT done with an installed `specs` file: any
installed specs file RESETS the driver's dynamically-computed link specs
-- it silently drops `-lgcc_s` from `*libgcc` and `--eh-frame-hdr` from the
EH link spec -- which makes every C++ program that throws terminate at
runtime (rc=134, catch never fires) even though it links. Restoring those
specs by hand is whack-a-mole and fragile under QEMU. Command-line
-idirafter leaves the link specs untouched: validated on riscv64 that a
bare `gcc hello.c`, simple C++, AND exception-throwing C++ (throw/catch,
STL sort) all compile, link, and run correctly. amd64 never reaches this
block (host GCC, no swap).

### Runtime stage context and ancestry annotations

Append the image target for a runtime build to the nameref array.

RTCACHE3 (root cause of the 2026-08-14 stale-ship saga): this used to emit the
annotated `--output type=image,name=<tag>,annotation.*` exporter on the push
path, on the assumption (see the now-corrected runtime_image_output_arg note)
that it was "equivalent to -t <tag>". It is NOT. Verified with a minimal
busybox repro on this rootless nerdctl+containerd host:
nerdctl build --output type=image,name=X   → X is NOT in the local image store
nerdctl build -t X                          → X IS in the local image store
The exporter builds the image into buildkit's content store but never lands a
local containerd tag. So the freshly built wrapper was invisible: the
subsequent `nerdctl push <tag>` (runtime_push_tag) and `nerdctl manifest
create <tag>` both resolved the STALE pre-existing local tag from an earlier
run, and :latest-cross shipped byte-identical every time (amd64 stuck at
35c1f1df across five rebuilds). The annotations never reached the registry
either — every run logged "wrapper tag(s) carry no run-id annotation …
provenance unverifiable" — so nothing of value is lost by dropping the
exporter. Use plain `-t` on BOTH paths: it reliably creates AND overwrites the
local tag, which is what runtime_push_tag + the manifest step consume.
(Re-embedding ancestry provenance via a locally-tagging method is tracked
separately; correctness of the shipped bytes comes first.)

### Host-side env scrubbing for native sub-builds

cross_compile_cmake_lib_from_source NAME URL[|MIRROR...] INSTALL_PREFIX SENTINEL [EXTRA_CMAKE_ARG...]

URL may list '|'-separated fallback mirrors, tried in order until one lands
(guards against a single-host outage silently disabling the lib). Each mirror is
either a plain https tarball or a `git+<repo>#<ref>` spec (shallow git clone —
reliable where the buildkit RUN can git-clone github.com but curl fails).

Fetch a source tarball and cross-cmake build+install a small library into the
target sysroot. For libraries whose Ubuntu Ports dev package is missing/broken,
or whose OpenCV-vendored copy can't cross-build (freetype, libpng). No-op if
SENTINEL already exists (e.g. an apt package already provided the lib).

Behaviour-preserving extraction of the freetype/libpng blocks that were copy
-pasted in 03-media/build/opencv/install-deps.sh: same cross toolchain
(${triplet}-gcc/g++), same find-root scaffold. Per-library flags (FT_DISABLE_*,
PNG_STATIC/PNG_HARDWARE_OPTIMIZATIONS, ZLIB_*, and any MODE_LIBRARY/INCLUDE
override) are passed as trailing EXTRA_CMAKE_ARGs. Fetch goes through
download_and_extract for curl --retry + temp-file hygiene (a hand-rolled
`curl | tar` had neither). Never hard-fails: a download/build failure logs a
WARN and returns 0 so the caller can degrade (e.g. OpenCV falls back to
WITH_<lib>=OFF) instead of aborting the whole media stage.

### uv venv creation and the experimental-Python path

Pin the interpreter for the SAME reason uv_pip_install_requirements does,
and it is just as load-bearing here: uv honours UV_PYTHON OVER the activated
venv. The CI images export UV_PYTHON=/opt/venv/bin/python and run as the
non-root user `kataglyphis`, so `--active` alone still resolves to that
root-owned system venv and the sync dies with
error: failed to remove file `/opt/venv/lib/python3.14/site-packages/...`:
Permission denied (os error 13)
Observed on both arches in Orchestr-ANT-ion's lane on 2026-08-11, right after
the extras fix let the resolve get this far. --python forces the writable
local environment.

Consult _CURRENT_VENV_PATH FIRST and VIRTUAL_ENV only as a fallback. The
other order made the pin fire backwards: the images ALSO export
VIRTUAL_ENV=/opt/venv, and `uv venv` only prints "Activate with: source
.../activate" — it does not activate — so a caller that creates
.venv_static_analysis never overwrites the inherited VIRTUAL_ENV. The pin
then resolved to the very system venv it exists to avoid, logged
"uv sync pinned to /opt/venv/bin/python", and died 2.5 minutes later with
the exact permission error above (WebDavClient x64, 2026-08-12).
_CURRENT_VENV_PATH is set by uv_venv_create/uv_venv_ensure/uv_venv_activate,
so it names the venv THIS script owns — which is the one to sync into.

### cmake-build: argument assembly

The :latest-cross image runs as uid 1001 with CARGO_HOME=/usr/local/cargo
owned by root, so the Corrosion/cargo half of the configure dies with
"failed to create directory /usr/local/cargo/registry" - which took the
whole Linux lane down when combined with the tee exit-code masking in
Linux.yml (fixed there with shell: bash / pipefail). Redirect cargo to a
writable home rather than requiring the image to hand us its own.

Checked in order:
1. --cargo-cache-dir  (CLI arg, survives container restarts when backed
by a docker named volume or host bind mount)
2. $CARGO_CACHE_DIR   (environment variable override)
3. $CARGO_HOME        (image default; /usr/local/cargo, usually read-only)
4. $TMPDIR/cargo-home (fallback, lost when container exits)
Probe registry/, not CARGO_HOME itself. /usr/local/cargo is writable in the
cross image while /usr/local/cargo/registry underneath it is root-owned
(populated by `cargo install cargo-c` during the image build), so the
shallow `-w` test PASSED and the build then died anyway with
error: failed to create directory `/usr/local/cargo/registry/cache/...`
Caused by: Permission denied (os error 13)
Same mkdir-then-test idiom the sccache/ccache loop below already uses.

### Which shared library a consumer actually gets

`/etc/ld.so.conf.d` is read in **sort order**, and several of our `/opt` trees
have a distro package exporting the SAME soname. Measured in the shipped arm64
image on 2026-09-01:

```
libgstreamer-1.0.so.0 => /usr/lib/aarch64-linux-gnu/libgstreamer-1.0.so.0   (1.28.2, distro)
libgstreamer-1.0.so.0 => /opt/gstreamer/lib/libgstreamer-1.0.so.0           (1.29.2, ours)
```

The distro copy won. It is not installed by us — `libgtk-4-1` pulls
`libgstreamer1.0-0` back in *after* `03-media/runtime/install-deps.sh` purges it
— so a consumer linking `-lgstreamer-1.0` got 1.28.2 while all 287 shipped
plugins were 1.29.2. A core/plugin version split fails at runtime in confusing
ways.

`configure-runtime.sh` therefore writes `000-gstreamer.conf`,
`000-ffmpeg.conf`, `000-opencv.conf` and `000-libcamera.conf`, the same
convention `000-llvm-target.conf` already used. Verify after any change with
`ldconfig -p | grep -e <soname>` **in the shipped image** — the build log cannot
show this.
