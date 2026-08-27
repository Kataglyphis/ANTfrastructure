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

### In-image verification gates & their escape hatches (audit round 2)

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
| litert / genai / opencv-core produce real artifacts | `verify-media-artifacts.sh` | none — these verify stage-specific files now; genai mirrors its producer's legitimate cross-build skip |
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
`build-runtime-manifest.sh`'s per-arch loop BEFORE the manifest is assembled —
it lists each wrapper's rootfs (`nerdctl export | tar -t`, arch-agnostic, no
emulation) and asserts the `/opt/ffmpeg` lib set matches the versions.env
toggles (`FFMPEG_ENABLE_TF` → `libtensorflow` present/absent, ffmpeg intact).
A mismatch aborts before `:latest-cross` goes live; `WRAPPER_CONTENT_GATE=0`
makes it advisory. To spot-check by hand: pull the wrapper and grep for the
expected lib set. **`:latest-cross` was re-shipped 2026-08-16** (fresh amd64
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
| `shellcheck` | `lint-shell.sh` | classes 6, 7 — `shellcheck -S error` over 262 files; `linux/host-config`'s operator tools joined the sweep on 2026-08-27, before that seven scripts sat outside it |
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
  (`Dockerfile.package:344-356`), and host-side `smoke-runtime-image`
  (in `build-runtime-manifest.sh`, `RUNTIME_IMAGE_SMOKE=0` to skip).
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
