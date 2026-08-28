# Changelog

> **Older entries** (2026-08-13 and before) are in
> [`docs/changelog-archive-2026-08-13.md`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete.


## 2026-08-28 — Closure window: 03-media/06-packaging backlog batch

Closed seven backlog items (LOG9, LOG21, LOG24, LOG26, LOG31-COPY'd, LOG32,
LOG35) in one commit — all touch files in the 03-media/06-packaging bind-mount
closure, so batching minimizes cache invalidation (one edit re-runs hours of
media compiles).

- **LOG31 (COPY'd half)** — `validate-media-runtime.sh`: DENIED class
  (source-built SONAME missing) now exits 1 instead of WARNING. The broader
  unresolved/unmappable classes stay advisory (vendor trees need excluding
  first). `smoke-android.sh`: ndk-build and aapt2/zipalign/apksigner now have
  fail branches.
- **LOG32** — Added Vulkan smoke to `smoke-media.sh`: vulkan.h present, active
  symlink resolves, glslangValidator runs. ~7 GB of Vulkan SDK now gated.
- **LOG35** — `verify-media-artifacts.sh`: replaced broken `verify_A || verify_B`
  lib→lib64 fallback with `verify_any_lib`. Added `libvvdec` to FFmpeg codec
  check loop. Added `/opt/cmake` functional assertion to `smoke-media.sh`.
- **LOG9** — `build-gstreamer-monorepo.sh`: arm64 cross builds now keep
  introspection ENABLED when qemu g-i wrappers exist (pre-setup.sh already
  creates them for arm64). Was 0 .typelib on arm64; should match riscv64's 38.
- **LOG21** — Documented OpenCV cross arches as headless-by-design (GTK's
  libpango1.0-dev not multiarch-coinstallable). Added smoke assertion that
  confirms `GUI: NONE` is deliberate on cross, fails on native.
- **LOG24** — OpenCV DNN ONNX Runtime backend enabled
  (`-DWITH_ONNXRUNTIME=ON -DDOWNLOAD_ONNXRUNTIME=OFF`). Added smoke assertion
  for the ORT backend via `cv2.dnn.getAvailableBackends()`.
- **LOG26** — OpenCV: added `-DWITH_AVIF=ON -DWITH_HDF5=ON
  -DOPENCV_ENABLE_NONFREE=ON` + `libavif-dev`/`libhdf5-dev` to install-deps.
  Documented riscv64-only `USE_OPENMP=0` rationale in build-app-wheelhouse.sh.
  FFmpeg: added `libpulse-dev` for PulseAudio indev/outdev.

## 2026-08-28 — Host-only backlog fixes (LOG33, LOG31-preflight, Section C)

Closed three backlog items that touched only host-only scripts (not COPY'd or
bind-mounted into any Dockerfile), so no closure window was needed.

- **LOG33** — `verify-shipped-wrapper.sh`: promoted onnxruntime .so presence
  (check 3) from advisory to HARD — the image is built around ORT, so its
  absence is always a defect. Promoted AP4 strip (check 5) from advisory to
  HARD when the sentinel lib was successfully extracted — a surviving .symtab
  means the MEDIA_STRIP pass regressed. Kept advisory only when extraction
  failed. Four hard assertions now (was two).
- **LOG31 (preflight half)** — `lint-env-knobs.sh` was advisory by default
  (exits 0 unless KNOB_GATE=1) and preflight invoked it without KNOB_GATE=1;
  also its `if [ -f ]` guard had no `else` (silent drop on missing file).
  Fixed: preflight now passes `KNOB_GATE=1` and has the FAIL-not-skip `else`
  contract. Three unowned operator knobs (BUILD_ATTEST, CROSS_DISK_GUARD_GB,
  NO_CACHE_EXPORT) added to `lint-env-knobs.allow`. `verify-runtime-paths.sh`
  was "ADVISORY ONLY — never fails" — now fails hard on infrastructure errors
  (missing reference/Dockerfiles) while keeping heuristic path-mismatch WARNs
  advisory. The COPY'd half (validate-media-runtime.sh, smoke-android.sh)
  remains open — needs a closure window.
- **Section C** — `build-cross-chain.sh`: added `_chain_no_push_guard()` that
  refuses `--no-push` for multi-stage runs on this host (BuildKit's OCI worker
  resolves FROM against the registry — two runs lost 2026-08-08). Single-stage,
  dry runs, and `CROSS_NO_PUSH_FORCE=1` escape hatch allowed. Updated AGENTS.md
  Quick Reference and usage text.

Items moved to
[`refactoring-backlog-archive-2026-08-27.md`](docs/refactoring-backlog-archive-2026-08-27.md)
§ "Closed 2026-08-28 (host-only fixes)".


## 2026-08-28 — ROCm 10.0 migration (TheRock distribution)

Migrated the AMD GPU lane from ROCm 7.2.4 to 10.0, moving from the legacy
`repo.radeon.com` apt layout to AMD's new "TheRock" distribution at
`stable.repo.amd.com`.

**Changes:**
- `versions.env`: `ROCM_VERSION` 7.2.4 → 10.0, `MIGRAPHX_VERSION` 2.14.0 → 2.17.0,
  `ROCM_GPG_KEY_SHA256` updated for the new signing key.
- `setup-rocm-repo.sh`: rewritten to deb822 `.sources` format with two repo
  stanzas (core + migraphx) at `stable.repo.amd.com`, suite "stable", for
  Ubuntu 26.04 (resolute). Package names migrated to `amdrocm-*` prefix.
  apt pin Origin changed from `repo.radeon.com` to `AMD ROCm`.
- `Dockerfile.amd`: ARG defaults updated; comment updated to reflect TheRock.
- `bump_versions.py`: `rocm_apt_latest()` now parses the TheRock Packages.gz
  instead of scraping the old directory listing.
- Docs updated: AGENTS.md GPU constraints note, linux-accelerator-images.md.
- No more noble (24.04) fallback — resolute is natively supported by TheRock.

**Not yet verified with a real build** — the post-install assertions
(`hipcc`, `migraphx.hpp`, library names in ldconfig) are carried over from
the old script and may need adjustment if TheRock installs to different paths.


## 2026-08-28 — Linux backlog maximality audit: 16 code fixes

Closed 16 open Linux backlog items (LOG10,11,15,16,20,22,23,25,29,30,36,37,38,
39,40,41) found in the 2026-08-28 maximality audit. Each fix includes the
assertion or smoke check the backlog asked for. Items moved to
[`refactoring-backlog-archive-2026-08-27.md`](docs/refactoring-backlog-archive-2026-08-27.md)
§ "Closed 2026-08-28 (code fixes)".

**Build fixes (01-core / 03-media closure — needs a rebuild to land):**
- LOG16: `CMAKE_POLICY_VERSION_MINIMUM` lifted to `versions.env`; 8 bare `=3.5`
  literals across 6 files replaced with `${CMAKE_POLICY_VERSION_MINIMUM:-3.5}`
  (or `:=3.5` in android scripts to avoid the version-forwarding tripwire).
- LOG20: FFmpeg `drawtext` filter — added `libharfbuzz-dev` + `libfontconfig1-dev`
  and `--enable-libharfbuzz`/`--enable-libfontconfig` probes.
- LOG22: FFmpeg `*_vulkan` filters — added `glslang-tools` to `install_deps_preamble`
  so `glslangValidator` is on PATH at configure time.
- LOG23: CPython readline + curses — added `libreadline-dev` (required) and
  `libncurses-dev` (optional) to `_CPYTHON_EXT_DEV_PKG_TABLE`.
- LOG11: OpenCV TBB on all arches — moved `libtbb-dev` from host to
  `target_packages` so cross lanes pull the target-arch package.
- LOG15: android OpenCV `BUILD_JAVA=ON` → `OFF` (produced no Java wrappers anyway).
- LOG10: Fixed false RVV comment in `opencv/android/build-android.sh`.
- LOG25: Added rationale comment for LiteRT GPU/NPU delegates OFF.
- LOG36: Added `libtvm*.so` to `copy-media-payloads.sh` allowlist +
  `so-package-map.txt` + `verify-media-artifacts.sh` media-inputs stage.

**Gate fixes (06-packaging / smoke):**
- LOG29: `_runtime_run_package_smoke()` in `runtime-build-fns.sh` builds the
  `--target wrapper-smoke` stage between package and wrapper (`WRAPPER_SMOKE_GATE=0`
  to skip). Unit test `test-runtime-smoke-gate.sh` (8 assertions).
- LOG30: `_smoke_optimization_level()` in `validate-compilers.sh` checks CPython
  `sysconfig.get_config_var('OPT')` for `-O0`/missing `-O`.
- LOG11/15/20/22: Added smoke assertions: TBB parallel framework, Java wrappers
  absent, `drawtext` registered, `scale_vulkan` registered.

**Doc fixes:**
- LOG37: `cross-build-verification.md` — wrapper-smoke runs as a separate
  `--target wrapper-smoke` build.
- LOG38: AGENTS.md — corrected the `PartOf` binfmt claim.
- LOG39: `linux-accelerator-images.md` — fixed all NVIDIA/AMD build recipes
  (`:sdk` → `:cross-sdk-amd64`, `--output type=image` → `-t ... --push`).
- LOG41: `overview.md` / `linux-cross-builds.md` — removed `:latest` references.
- LOG40: Verified license/SBOM gates green — no drift.


## 2026-08-28 — correction: the `/Ob1` half was NOT llvm#202716, and the census says so

**Correcting the entry below, not deleting it.** The 2026-08-27 pass credited the
`tbnz` / `/Ob1` half of #135 to
[llvm#202716](https://github.com/llvm/llvm-project/pull/202716). That
attribution is wrong.

**The argument is the patch set, not the census.** The two local patches in
`AArch64InstrInfo.cpp::getInstSizeInBytes` fix the lane on pinned LLVM 23.1.0,
a compiler that contains **no** #202716 — the release branch forked before it
and nobody backported it, which is the entry below's own finding. A fix that is
absent cannot be the fix that worked.

**The 1,869-object census is a claim, not an artifact.** It was run by hand
inside the container and left no `bk-` log; nothing in `out/windows-build-logs/`
mentions either knob or `llvm-patched`. Re-run it through the driver and keep
the log before deleting either OpenCV workaround. Corrected here the same day
it was written.

**Both OpenCV workarounds trace to the SAME under-count.** `EH_LABEL` is a meta
instruction and reports 0 bytes, but under async EH (`/EHa`, module flag
`eh-asynch`) `AsmPrinter` emits a 4-byte nop after it when the next instruction
can fault. Four bytes go missing per label. `AArch64CompressJumpTables` picks a
too-small entry from the short span; `BranchRelaxation` believes a branch is in
reach when it is not. One defect, two consumers, two different error strings —
which is why they looked like two bugs for as long as they did.

**Same inference error, third occurrence.** Each time: an upstream commit whose
description matched the symptom, credited without checking whether the compiler
under test actually contained it. The rule that catches it is cheap — name the
artifact that decides the claim, then confirm the claim is falsifiable against
it.

**What changed on disk:** the root-cause blocks in `docs/failure-modes.md`,
`docs/windows-refactor-backlog.md` § #135 and
`out/upstream-llvm-aarch64-seh-instsize.md` now say EH_LABEL, not #202716. Both
workarounds STAY in `build-opencv-from-source.ps1` until `BUILD_PATCHED_LLVM`
defaults to on — the patched compiler is opt-in, and the stock one still
miscounts.

## 2026-08-27 (second pass) — #135 was two bugs wearing one signature; one is fixed upstream and nobody backported it

**The "one defect at two sites" reading was wrong, and it cost an investigation.**
`fixup value out of range` and `value evaluated as <N> is out of range` share a
sentence — *LLVM lays a function out a few bytes short* — and nothing else.

**The `tbnz` half: root cause found, fix already exists.**
[llvm#202716](https://github.com/llvm/llvm-project/pull/202716) (`c6e184686cd7`)
creates trampoline blocks with offset **zero**, so `isBlockInRange()` decides
branch reach from offsets the code itself calls "slight underestimates". On
`main` since 2026-07-21 — but `release/23.x` forked **2026-07-14**, one week
earlier, so 23.1.0 ships without it, and no cherry-pick exists on the branch.
Checked by subject AND PR number, not just SHA ancestry: a cherry-pick carries a
different SHA, and that hole produced one wrong "not backported" claim before it
was closed properly. **Proven load-bearing rather than assumed** — reverting only
that commit and re-running its own `branch-relax-tbz.mir` changes the output: with
the fix the `TBZW` survives onto a trampoline chain, without it the branch is
inverted and the layout moves.

**The jump-table half: NOT fixed on `main`, and narrowed to one number.**
`AArch64CompressJumpTables.cpp` is **byte-identical** between 23.1.0 and `main`.
The pass is provably sound *given correct instruction sizes* — offsets are upper
bounds, the inflation accumulates in layout order, so `Span` is over-estimated,
which picks a **larger** entry. It can only fail on an instruction that reports
**fewer** bytes than it emits, and the measured `N` bound that under-count to
**4–116 bytes**.

**LLVM already ships the tool that would name it — and AArch64 never turned it
on.** `AsmPrinter` verifies reported size against emitted bytes and aborts naming
the instruction, but `getInstSizeVerifyMode()` defaults to `NoVerify` and only
AMDGPU and PowerPC override it. The AArch64 opt-in is written and committed
locally (`aarch64-instsize-verify`, `65a5bd5601fe`, unpushed). Over the **2,925**
`.ll` files in `test/CodeGen/AArch64` at `aarch64-pc-windows-msvc` (2,049 compiled):
**zero under-counts**; a separate signature scan over 3,347 files (`.ll` + `.mir`)
found **zero genuine reproductions**. So the culprit is a construct LLVM's own
tests never build — it needs the real `descriptor.cc`, in the container. The one
apparent hit was self-inflicted, a Linux/PIC test forced onto a Windows triple.

**A third bug fell out of that scan:** every `SEH_*` pseudo reports 4 bytes and
emits **0** (538 of the 2,925). Over-estimate, so it is conservative and causes
neither failure — but it inflates every Windows-AArch64 estimate.

**Decision (owner): move the Windows toolchain to LLVM `main`; do not request a
`release/23.x` backport.** A request was drafted and deliberately not filed. The
consequence to plan around: the fix reaches a tagged release only in **24.1.0**
(~Feb–Mar 2027 on the observed 6-month major cadence), so `/Ob1` stays until the
toolchain actually moves, and **`+force-32bit-jump-tables` stays regardless**.

**Also landed:** `repro-llvm-aarch64-layout.ps1`, the A/B that settles "does this
compiler retire the workaround" in seconds instead of a lane run — the real
offenders frozen as preprocessed `.i`, gated on control arms that must reproduce
the abort and then suppress it, so a stale corpus reports `INVALID` instead of a
false green. Its command-line surgery is pinned by
`Diagnostics.Llvm135Repro.Tests.ps1` against the real ninja command line; writing
those tests caught two live bugs in it, both the case-insensitive `-match` trap.
The `:lo12:` catchret PR ([llvm#219200](https://github.com/llvm/llvm-project/pull/219200))
was rebased onto latest `main`.

## 2026-08-27 — the registry gets a second tool, and Rust caching turns out to have been bare all along

**Registry: 81 -> 34 tags, 204 -> 134 versions, 0 failures.**
`ghcr-prune-package.sh` deliberately keeps every TAGGED version, which left the
other half of the mess untouched. New sibling **`ghcr-delete-tags.sh`** deletes
NAMED tags from an explicit list — it never decides what is legacy — with the
same fail-closed keep-set: abort if any kept tag is unreadable, skip a version
that shares a digest with a kept index child, carries a tag not on the list, or
is younger than `KEEP_DAYS`.

What went: 22 `*-buildcache` tags that nothing has written since the cache
self-defeat fix (`verify-critical-fixes.sh` already *forbids* their return), 19
tags from a naming scheme the chain abandoned (`media-cross-amd64` ->
`cross-media-amd64`, `latest-cross-runtime-*` -> `latest-cross-*`), and the six
long-dangling index tags. All 47 had zero references anywhere in the repo.

**`:latest` was already broken and is now gone.** Its three children had been
404 for months — `python-ci-linux.yml:118` had quietly worked around it. Worth
stating plainly: it will not come back by itself. Every orchestrator under
`linux/scripts/` is a `build-cross-*` script, so the native lane has no build
path any more; keeping it means writing one, not running one.

Both tools now source **`ghcr-common.sh`**. The thirteen byte-identical lines
were the visible half; the important half is that the Accept header is now
defined ONCE. Listing the index media types makes a multi-arch tag resolve to
its index so its children are visible — omit them and the tag collapses to one
platform manifest, which is precisely how a prune tool builds a short keep-set
and deletes something it should not.

**`setup_sccache` pointed `RUSTC_WRAPPER` at BARE sccache.** The Rust caching
reinstated in 4200f7b never took effect: `build-gstreamer-monorepo.sh` only
assigns the wrapper when the variable is UNSET, and `setup-gstreamer.sh:50`
calls `setup_sccache` first, which exported `RUSTC_WRAPPER="sccache"`
unconditionally. Measured on the live media lane — the run logged
`RUSTC_WRAPPER=sccache`. Every Rust compile in gst-plugins-rs went through the
one thing AGENTS.md forbids; an sccache hiccup would have aborted the build at
99% instead of costing cache hits. Third time this class has shipped inert, so
it now has a gate in `verify-critical-fixes.sh` rather than another comment,
mutation-checked in both directions.

A 12-agent documentation audit (every finding adversarially refuted, 71 raw ->
**40 confirmed**) is recorded in the backlog. `docs/build-cache-tiers.md` alone
carries 11 and still argues from the ccache world.

**The runtime stage died on a missing emulator, and the guard that should have
caught it sat after the builds it protects.** The 2026-08-26 nerdctl-full
upgrade restarted the rootless daemons; the QEMU binfmt registration lives in
the rootlesskit namespace and went with it. Media and android never noticed —
they cross-compile on amd64. Both foreign-arch wrappers then died with a
BuildKit step that printed nothing at all. `ensure_foreign_binfmt()` already
existed and was correct; it was called from the SMOKE block. Moved before the
build loop and upgraded from best-effort registration to a hard verify that
looks inside the rootlesskit namespace, because the host's own
`/proc/sys/fs/binfmt_misc` shows nothing even on a healthy machine.

The durable cause was one line deeper. `setup-rootless-binfmt.sh
--install-service` writes a unit with `After=`/`Wants=` only — startup ordering,
no restart propagation — and `Type=oneshot` + `RemainAfterExit=yes` makes
systemd treat it as permanently done. On this host the unit last ran
2026-08-09 while containerd restarted 2026-08-26: enabled, "successful", and
its effect gone for seventeen days. The template now sets
`PartOf=containerd.service`.

**The index was never gated for freshness.** `verify-shipped-wrapper.sh` gates
each wrapper's content and the chain runs it; the only manifest check was
`nerdctl manifest inspect >/dev/null`. New
`linux/scripts/verify-manifest-freshness.sh` asserts every index child equals
its per-arch tag and that all children share one run-id. Sensitivity-checked
against a genuinely stale live index, which showed both assertions are
individually blind: child and tag agreed because both were old, and the run-ids
matched because all three came from the previous run. Agreement is not
freshness; only `EXPECT_RUN_ID` pins it. Not yet wired into the chain.

**Gate hygiene, three findings.** The shellcheck sweep never covered
`linux/host-config` — seven scripts outside it, including the one that replaces
the container daemon and the two that delete from the registry (263 files now).
`test-compiler-cache-launcher.sh` had been inert since the day after it landed
(`_COMMON_SH_DIR` unset under `set -u`), so the suite written to catch a stdout
leak caught nothing; fixed and extended with the guarded-launcher preference
case. And the secret scan was reading 5.3 GB of gitignored build logs, where
its only nine "leaks" were one public GPG-key checksum — scoped out, 2.42 GB
and clean.

Documentation: the 40 confirmed defects from the audit are repaired (see
above), and `nerdctl compose build webserver` turned out to be broken —
`security-headers.conf` was the one COPY source without a `.dockerignore`
negation, found by running the documented command instead of reading it.

### Later the same day — the pre-rebuild sweep, and what it cost to be sure

Before committing to another multi-hour run, a 12-agent sweep plus five
targeted 42-second tvm-stage probes went looking for whatever would break it.
Seven things would have.

**TVM had not shipped on arm64 or riscv64 for some time, and four separate
causes were stacked on top of each other** — each only visible once the one
before it was fixed:
1. v0.26.0 does not compile against LLVM 23 (three files, two API redesigns).
   amd64 escaped it by linking the distro `llvm-config-21`.
2. Pinning `TVM_COMMIT` to upstream's fix exposed that the SHA clone path
   never initialised submodules — it clones without `--recursive` and the
   submodule update only fires when the checkout MOVES `HEAD`, which pinning
   the default-branch HEAD does not. CMake died on an empty `3rdparty/tvm-ffi`.
3. The target-Python sysconfigdata lookup used `-maxdepth 2` while this chain
   stages the file at depth 3. The miss is silent in effect: the wheel then
   carries the BUILD-HOST SOABI and is correctly withdrawn, so the stage
   reported "TVM build OK" and shipped an image without `import tvm`.
4. A hand-written LLVM-23 patch, tried first, fixed four of five sites in one
   of three files and logged success. Removed rather than grown — a patch that
   cannot succeed but says it did is worse than none.

Result, measured: `apache_tvm-0.26.dev1-py3-none-linux_aarch64.whl` plus its
correctly-stamped `cp314` ffi sibling, where the stage previously died at
object 334.

**Two defects would have aborted the chain outright.** `build-cross-chain.sh`
ran `du … | cut -f1` twice without `|| true`, which under `set -euo pipefail`
kills the orchestrator with a bare exit 1 right after a stage SUCCEEDS — the
identical bug was already found and fixed 86 lines above, comment and all.
And the runtime package OCI export dropped its exit status while the next line
deleted the local image, so a ~27 GB `nerdctl save | tar -x` dying on ENOSPC
was reported as a successful build with its only copy destroyed. errexit cannot
help there: `run_parallel_arch_loop` disables it for the whole call tree, which
is exactly why the base path 42 lines below already carried `|| return 1`.

**The shipped Node.js is an alpha.** `node --version` in the published amd64
image returns `26.8.0-alpha.0.0.0`, and the bundled npm 11.19.0 refuses it —
semver puts a prerelease outside `^20.17.0 || >=22.9.0`. The binary is the
official tarball, so this is an upstream stamping bug in that one release;
v26.8.1 reports cleanly. Bumped, with both SHA256s from the published
SHASUMS256.txt. The gate that should have caught it used
`grep "^v${NODE_VERSION}"`, and `^v26.8.0` matches `v26.8.0-alpha.0.0.0`
happily — the suffix being the entire point. Now an exact compare.

**Orphaned stage contexts are reclaimed.** `runtime_cleanup_local_context_chain`
only removed the workdir the current process created, so any hard kill leaked
its tree; a 3.3 GB `runtime-flow.*` from 2026-07-25 had survived 33 days on a
filesystem at 93%. The new sweep is age-based so a concurrent chain's young
workdir is never robbed, and was proven selective in isolation.

One reported defect was **refuted rather than fixed**: arm64 ships a PyPI
`iree-base-compiler 3.11.0` beside a source-built
`iree-base-runtime 3.11.0.dev0+e4a3b04`, which looks like a version skew and is
not one — `refs/tags/v3.11.0^{}` resolves to that same commit. No gate was
added; a version-equality assert would fail on a cosmetic difference. The
comment claiming "amd64/arm64 install the PyPI compiler+runtime" was the thing
actually wrong, and now describes the real per-arch split.

### And then the shipped IMAGES were audited, not just the code

A second 10-agent sweep read the shipped run's logs rather than the tree, and
every claim was re-checked against the published bytes before being acted on.
Eleven defects, one refutation.

**Four things shipped wrong.** `Dockerfile.package` set FFMPEG_PREFIX and
LIBCAMERA_PREFIX inside the same ENV instruction that consumes them, and Docker
substitutes within one instruction using the value from BEFORE it -- empty. The
published amd64 image therefore carried two phantom `/bin` entries in PATH, two
`/lib/pkgconfig`, two `/lib`, and a GST_PLUGIN_PATH pointing at
`/lib/gstreamer-1.0`, so libcamera's GStreamer plugin was unreachable through
the standard variables. The Android ONNX Runtime shipped with Microsoft's 1DS
telemetry SDK compiled in, because ORT 1.29 defaults it ON and only the native
lane passed `--no_telemetry`. amd64 alone shipped a setuid-root
`gst-ptp-helper`, since its disable was gated on `cross_build_is_active` while
its own rationale ("useless in a container image") is arch-independent -- the
cross arches got that hardening as a side effect of a link-failure workaround.
And Node.js was an alpha: the official v26.8.0 tarball self-reports
`26.8.0-alpha.0.0.0`, which puts it outside its own npm's supported range.

**Three gates reported success over things they never tested.** `check_ffmpeg`
resolved the binary as `command -v ffmpeg || echo /opt/ffmpeg/bin/ffmpeg` --
falling back to the absolute path exactly when PATH reachability, the thing it
checks, is broken. The app-wheel smoke exits 0 whenever failures==0 and counts a
missing component as a warning, so one identical PASS covered 15/15, 14/15 and
12/15; it now carries a per-arch ratchet that may only be raised. The
shipped-content byte gate shared a loop with the boot smoke and ran second, so
riscv64's smoke failure meant the riscv64 wrapper in the index was never
content-checked; the two are separate passes now, content first.

**Two silent swallows.** Provenance was resolved per arch inside the build loop,
so a commit landing between two arch builds split the index -- today's carries
two different `org.opencontainers.image.revision` values. And a riscv64 uv
exemption written for "extras that cannot resolve under QEMU" swallowed
`Timeout (300s) when waiting for lock` twice, assembling the venv with no
regenerated lock while the log said "expected".

**libvidstab needed two fixes, not one.** amd64 shipped 31 FFmpeg libraries and
arm64 30, the delta being `--enable-libvidstab`. Diagnosed against the real
cross-media image because the logs were inconclusive (the install layer was
CACHED and printed nothing): `libvidstab-dev` was never installed for the
target even though it exists for both cross arches, AND `-lgomp` has no dev
symlink there -- `libgomp1:<arch>` ships only the versioned file and the cross
toolchain carries a libgomp for the HOST only. Installing the dev package alone
still failed on `cannot find -lgomp`; both together link.

Refuted rather than fixed: "riscv64 exports ONNXRUNTIME_ROOT_ANDROID at an empty
directory". The variable is set on no arch at all, so the empty directory points
nowhere.

### Closing the day: four backlog items, one of them retracted

The highest-rated open item, "`preflight.sh` exits 0 on failure" (★★★), turned
out **not to be a bug** — and I had re-confirmed it earlier the same day, so the
retraction is mine. The summary block ends `exit 0` / `exit 1` / `exit 2` and
those propagate: an unknown `PREFLIGHT_ONLY` slug returns 2 when the script runs
directly. Both "observations" were one measurement error —
`bash preflight.sh | tail | sed; echo $?` reports SED's status, not the
script's. Demonstrated: `(exit 1) | tail -1 | sed 's/^//'; echo $?` prints 0
while `(exit 1); echo $?` prints 1. `exit 1` has been in place since 928e745.
The lesson is worth more than the entry was: **never measure an exit code
through a pipe.**

All five UNOWNED env knobs are registered in `lint-env-knobs.allow` with reader
and reason, and verified under `KNOB_GATE=1` — which is precisely the failure
the entry predicted for its first strict use. The `-nostdinc++` libstdc++ c++23
watch note moved from the LLVM block to the GCC pin, where the patch lives.

And the binfmt unit was re-installed and then **tested against the exact
failure that cost this morning 5.5 hours**: restarting containerd re-ran
rootless-binfmt.service in the same second, with both emulators answering
afterwards. `PartOf=containerd.service` works; a daemon restart no longer
strips foreign-arch emulation.

Final state: preflight 31/31 with a real exit code of 0 (measured directly,
not through a pipe), 27 unit-test suites / 678 assertions green, shellcheck
clean over 263 files.

## 2026-08-26 — host toolchain: scripted nerdctl-full upgrade, and the audit that rewrote it

`buildctl` on this host comes from the `nerdctl-full` bundle — there is no
separate BuildKit package — so bumping buildkitd means replacing the bundle.
That was a hand-run sequence of stop/extract/restart steps whose half-done
state fails much later with a confusing symptom. It is now
**`linux/host-config/install-nerdctl-full.sh`**: dry-run by default, SHA256
verified against the published `SHA256SUMS`, backup + `--rollback`, refuses
while a build is running, and a cache-mount census around the swap.

**Then a 20-agent audit against the LIVE host layout — every finding
adversarially refuted — found 13 real defects in it, and the worst were not the
expected ones.**

The host runs the rootless stack (`systemd --user`) *and* a rootful
containerd + buildkitd, all executing the same `/usr/local/bin` binaries plus
the unit files the bundle ships in `/usr/local/lib/systemd/system`. The
installer only stopped the `--user` units. Measured rather than assumed: GNU
tar 1.35 and `cp -a` **both unlink-and-recreate**, so there is no `ETXTBSY` and
no error at all — the root daemons keep executing the now-deleted inode, and
`Restart=always` then performs the real version jump unattended. One audit lens
called this a critical `ETXTBSY` abort; a running-binary experiment refuted
that, and the claim was dropped instead of shipped. The script now refuses
until the operator picks `NERDCTL_INCLUDE_ROOTFUL=1` or
`NERDCTL_IGNORE_ROOTFUL=1` — blocking the act, not the look: a dry run still
prints the plan and the choice.

Gates that could not fail, now able to:

- The cache census counted `buildctl du`'s **header row** (51 records read as
  52) and returned 0 for an unreachable daemon — indistinguishable from "caches
  gone", and a before-count of 0 made `after >= before` unfailable.
- Cache-mount **loss only warned**, so an upgrade that ate hours of
  ccache/sccache still exited 0 and printed `done.` It now fails the run.
- `systemctl is-active` on a `Type=simple` wrapper was the only BuildKit
  assertion: a daemon with no usable worker passed. Now polls `buildctl debug
  workers`.
- The version proof read **on-disk client** binaries, which only prove `tar`
  ran. Now compares **daemon-reported** versions captured before and after.
- The "already on target" early-out compared `2.3.4` to `v2.3.5` — dead code.
  Worse than a wasted re-install: a second run overwrote the backup with the
  already-new binaries, destroying the only way back.
- The refuse guard missed a `buildctl build` solve; widened, and it now honours
  the repo's own `CROSS_CHAIN_PIDFILE` (read defensively, so an empty file
  cannot become `kill -0 0` and refuse every run).

**The upgrade then ran for real** (`NERDCTL_INCLUDE_ROOTFUL=1`): nerdctl
2.3.4 → **2.3.5**, buildctl v0.31.1 → **v0.31.2**, and — the part the old script
could not have shown — the *daemons themselves* report v0.31.2 and containerd
**v2.3.3**. Cache-mount records **51 → 51**, one worker, all four services
active, both rootful daemons back on new pids (not stranded on deleted inodes),
`NeedDaemonReload=no`. The driver was moby/buildkit#6915, a
"concurrent map iteration and map write" daemon crash that reproduces under
concurrent builds — this chain runs three arch lanes at once. It does **not**
cure BKD1 session rot (no upstream fix; still stop-chain → restart), and the
parallel-build cache-miss fix (moby/buildkit#6954) is in v0.32.0, which no
nerdctl-full ships yet.

Reference run, both gotchas that bit during it, and the rootful knobs are in
[`docs/linux-host-setup.md` § B3b](docs/linux-host-setup.md).

## 2026-08-25 (eighth pass) — SBOM run for real, on both images, and documented

The SBOM machinery landed the pass before with an honest caveat: the `syft` job
had never run. It has now, locally, against both published images — and the
results correct something the previous entry asserted.

- **`docs/sbom.md` (new)** — how to generate both halves, and, the part usually
  left out, **what to do with the result**: CVE scanning with `grype` straight
  off the SBOM (seconds instead of a multi-gigabyte pull), answering a
  procurement request, diffing two releases to catch a dependency nobody chose
  to add, policy gates, Dependency-Track for the "image did not change, the
  world did" case, and CRA context. Plus what it cannot tell you.

**Linux `:latest-cross` (linux/amd64):** 4,112 packages, 2,202 distinct names —
maven 1,340, deb 1,255, cargo 1,072, pypi 228, npm 149, go 13. Breadth no human
maintains by hand. But **73 % declare no licence and 94 % conclude none**, and
for the copyleft components the scan reports the DISTRO copy at a different
version: FFmpeg as `62.x`/`7:8.0.1-3ubuntu2` rather than the source-built `n9.0`
GPLv3 build, GStreamer as Ubuntu's `1.28.2-1` rather than `1.29.2`. OpenCV, TVM,
Abseil and VVdeC are absent entirely. **A source-offer question cannot be
answered from the scanner SBOM** — which is a far stronger justification for the
curated half than the previous entry gave.

**Windows `:winamd64`:** 26,253 packages, six times the Linux count and mostly
noise — 14,014 are PE version resources read out of every DLL ("Microsoft®
Windows Repair Disc", "JP Japanese Keyboard Layout for NEC PC-9800"), i.e.
operating-system files, not chosen dependencies. **98.5 % carry no licence.**
The earlier prediction that Windows would yield FEWER packages was wrong in the
opposite direction; package count is not a quality signal.

> **The Windows scan also caught real drift.** It reports ONNX Runtime `1.27.0`,
> TVM `0.25.0` and FFmpeg `8.0.git` while `versions.env` pins `v1.29.0`,
> `v0.26.0` and `n9.0`. **The published `:winamd64` is behind the current pins**,
> so the curated SBOM and both licence pages — all generated from `versions.env`
> — describe the next build rather than the published tag. Recorded as a limit
> on the SBOM page.

- **`docs/scripts/compare_sbom.py` (new)** measures the blind spot instead of
  asserting it. Two bugs were found in it before its output was trusted: it
  conflated package count with distinct names, and it compared a Linux scan
  against the Windows and Documentation-image rows, which reported Ghostscript
  and TeX Live as "invisible to the scanner" when they are simply not in that
  image. Its name matcher also failed on `GStreamer` vs `gstreamer1.0` and
  `PyTorch` vs `torch`; letters-only containment fixes that while still
  correctly refusing to match OpenCV against anything.

Routed from `docs/INDEX.md` and the Sphinx toctree. Sphinx build warning-free;
`doc-links`, `doc-dupes`, `sbom` and `version-snapshot` green; ruff clean.

## 2026-08-25 (seventh pass) — SBOM, in two halves, because one cannot cover the image

An image scanner catalogues components that carry package METADATA: dpkg/apt,
Python site-packages, npm, Go and Rust binaries. It cannot see a C/C++ library
built from source into `/opt` — ONNX Runtime, OpenCV, FFmpeg, GStreamer and
libcamera leave no manifest behind. Those are also the components under copyleft
licences here, so a scan alone would produce an SBOM that silently omits every
entry carrying a corresponding-source obligation.

Hence two halves, both published, deliberately distinguishable by
`creationInfo.creators`:

- **`docs/scripts/generate_sbom.py` (new)** emits `docs/deps/sbom-curated.spdx.json`
  — SPDX 2.3, 97 packages, from `deps.json` + `versions.env`. Each package
  carries its SPDX licence expression, its upstream download location, and
  `licenseComments` naming the obligations it triggers, the corresponding-source
  upstream and revision, the build flags where those determine the licence, and
  any patches applied. The two coarse buckets are declared properly as
  `hasExtractedLicensingInfos` rather than smuggled in as invalid ids.
  The document is **byte-reproducible** (fixed timestamp, stable namespace, a
  digest-suffixed SPDXID so `FFmpeg` in two sections cannot collide), which is
  what lets it be gated at all.
- **`.github/workflows/sbom.yml` (new)** runs `syft` against the **published**
  image, per architecture, emitting SPDX and CycloneDX. It reads from ghcr
  directly (`registry:`), so it needs no build host, no daemon and no disk for
  the rootfs — which matters because these images are built on a workstation,
  not in this repository's pipelines. `:latest-cross` is a manifest list, so
  each arch is scanned explicitly; a scan without `--platform` silently picks
  one. A result under 50 packages fails the job rather than publishing it: that
  means a broken reference or a cataloguer regression, not a clean image.

- **Valid SPDX syntax, corrected.** `Apache-2.0-with-LLVM-exception` and
  `GPL-3.0-or-later-with-GCC-exception` are not SPDX ids. They are now
  `Apache-2.0 WITH LLVM-exception` and `GPL-3.0-or-later WITH GCC-exception-3.1`,
  and the expression splitter keeps a `WITH` pair intact — splitting it would
  look up a base id whose obligations differ from the exception-bearing one.
- **Gated** as preflight slug `sbom`, in the pre-commit hook and
  `stale-docs-check.yml`. Negative-tested: dropping a package from the committed
  document fails with the regeneration command.
- **Routed** from `docs/INDEX.md`, and the Sphinx landing page regained its
  **Third-Party Licences** card — the 2026-08-25 `index.rst` rewrite had dropped
  it, leaving the page reachable only from the toctree. It is the page a
  production or procurement question lands on first.

**Verified here:** the curated document validates structurally (unique
well-formed SPDXIDs, 97 packages, 26 flagged source-required), regenerates
byte-identically across runs, and the gate fails on drift. **Not verified here:**
the `syft` job has never run — syft is not installed on this workstation and the
published image is not present, so its first CI run is its first real test.

## 2026-08-25 (sixth pass) — the licence list now says what each licence REQUIRES

A list that names licences answers "what is in here". It does not answer the
question that matters when you publish to a public registry: **what does each
of those licences oblige me to do?** The published runtime image ships a GPLv3
FFmpeg (`--enable-gpl --enable-version3`) and a GPLv3 GCC, and carried no
corresponding-source offer at all.

- **`docs/scripts/license_obligations.py` (new)** maps SPDX id → the concrete
  things a distributor must do: keep the notice, ship the text, state changes,
  propagate NOTICE, offer corresponding source, allow relinking, AGPL section 13
  network source, same-licence for derivatives, and "this is a vendor EULA, the
  question is whether you may redistribute at all". Dual licences render as the
  UNION of both arms, not the cheaper one, because the project has not recorded
  an election — record a single SPDX id to narrow it.
- **Every one of the 97 `deps.json` entries now carries an `spdx` field**,
  mapped from the 43 free-text licence strings by a reviewed table. Free text
  cannot be turned into an obligation; an SPDX id can.
- **All 26 copyleft components now carry a corresponding-source pointer** — the
  exact upstream, the revision (resolved from the same `versions.env` pin the
  build uses, so it cannot drift), the patches applied on top, and, where the
  build configuration is what *determines* the licence, the configure flags.
  FFmpeg's entry says in as many words that `--enable-gpl --enable-version3`
  is what makes the shipped binary GPLv3 rather than LGPL. GCC's says the
  Runtime Library Exception covers programs compiled with GCC, not shipping
  GCC itself — which the runtime image does.
- **Three components are now marked as modified** (sccache, and the Windows
  FFmpeg and GStreamer builds, which carry patches). Apache-2.0 section 4(b)
  and the GPL family both require saying so. This also corrects a factual
  error: sccache was listed as coming from "Ubuntu apt" when it is built from
  source at a pinned git rev with a local patch series.
- **Both pages carry all of it** — the published website page and the repo's
  own `third-party-licenses.md`. A developer reading the repo is exactly the
  person who needs to know that shipping the image carries a source-offer duty,
  so splitting that across two pages is how it gets missed.
- **Gated.** `generate-website-licenses.py` now fails when an entry has no
  `spdx`, when an SPDX id has no obligation mapping, or when a copyleft
  component has no `source` block. It runs on `--write` as well as `--check`,
  and reaches the pre-commit hook and both docs workflows through the existing
  `version-snapshot` slug. Negative-tested: removing FFmpeg's source pointer
  fails with both its Linux and Windows entries named.

**Not addressed, and it is the bigger question.** The published `:winamd64`
image contains CUDA, Visual Studio Build Tools and Windows Server Core under
vendor EULAs. Those entries are now flagged `eula-review`, but a flag is not an
answer: whether they may be redistributed in a public image at all is a legal
question, and no amount of documentation changes it.

Still open too: licence **texts** are not yet shipped inside the images. The
obligations page now says they must be, which makes the gap visible rather than
invisible — collecting `LICENSE`/`COPYING` into `/usr/share/licenses/` during
packaging is the next step.

## 2026-08-25 (fifth pass) — the published webserver was serving a stale licence list

Asked whether the open-source licence lists are current and whether anything
keeps them current. The generated ones were current. The **served** one was not,
and nothing was watching the difference.

- **`docs/third-party-licenses.md` and
  `linux/webserver/license-assets/documents/footer/openSourceLicenses{En,De}.md`
  are generated** from `docs/deps/deps.json` + `versions.env` by
  `generate-website-licenses.py`, and they **are** gated: `sync_versions.py
  --check` shells out to it and ORs the result, so the `version-snapshot`
  preflight slug covers them — in `.githooks/pre-commit`, `build-docs.yml` and
  the weekly `stale-docs-check.yml`. That half was working.
- **The webserver image did not serve those files.** `linux/webserver/dist/`
  ships its own build-time copy of the same page, and the Dockerfile overlays
  `license-assets/` on top — but the overlay targeted `/var/www/html/assets/`,
  one directory too shallow. Flutter serves declared assets under its own
  `assets/` root, so the app fetches `/assets/assets/documents/footer/…`. The
  generated file landed at a URL nothing requests, and the image served the
  `dist/` copy: **last regenerated 2026-07-22, 142 lines against the current
  236, missing ~25 components** — Arm NN, BuildKit, CPython, Emscripten, GNU,
  Ghostscript, ImageMagick, LiteRT-LM, Meson, Ninja, Ollama, Pandoc, Pygments,
  Scoop and more.
  Nothing caught it because nothing *could*: both files existed, both were valid
  Markdown, both were tracked, and only the URL told them apart. The generator
  writes `license-assets/` only, so no amount of regeneration would have fixed
  the served page.
- **Fixed** by pointing the overlay at `/var/www/html/assets/assets/`, and
  **gated** so it cannot drift back: `generate-website-licenses.py` now asserts
  the Dockerfile's overlay target, and that every `openSourceLicenses*.md` the
  `dist/` bundle ships is one the generator owns. That check runs on `--write`
  as well as `--check`, because an overlay path is a property of the image that
  regenerating file contents cannot fix — and must not mask. Negative-tested:
  restoring the old target fails the gate with the exact remedy.
  `dist/`'s stale copy is left in place deliberately — it is a vendored build
  artifact from the app repo, and the overlay is the designed mechanism for
  superseding it. The new check is what guarantees the overlay still covers it.

**Answering the question directly:** the lists themselves were up to date and
are kept so automatically. What was not automatic — and is now — is that the
*shipped* page is the generated one.

## 2026-08-25 (fourth pass) — the gates reach the pre-commit hook; the guard stops denying prose

Clearing what the third pass left open, plus one defect the newly-runnable
PowerShell suite surfaced.

- **`doc-links` and `doc-dupes` now run in `.githooks/pre-commit`**, not only in
  CI. Both were added the same day and wired into `stale-docs-check.yml` and
  `build-docs.yml` — but a broken anchor or a copied passage still reached a
  commit locally and waited for a pipeline round trip to be noticed. They add
  ~2 s together, so deferring them bought nothing.
- **The delete guard no longer denies documentation.** `nvidia|adrenalin|radeon`
  was the only protected pattern that is not path-shaped — every other one
  carries a `\` or a drive letter — so it matched bare English anywhere in a
  text. A page saying "an ENABLED AMD RDNA4 dGPU" that also showed a
  `nerdctl run --rm` example was denied, because `--rm` matches `\brm\b`. That
  fired on six ordinary edits in one day, including the changelog entry
  describing it.
  The fix is **proximity, not same-line**: the vendor pattern now requires a
  delete verb within 200 characters. Same-line was considered and rejected —
  a real script assigns the path on one line and deletes on the next, and a
  line-scoped rule would stop seeing exactly the shape that matters. Every other
  pattern stays unscoped, and the window is measured on quote-retaining text, so
  a quoted verb nearby still denies: the conservative direction.
  Six cases pinned in `Guard.DestructiveDeletes.Tests.ps1`, which previously had
  **no coverage of this pattern at all** — including the 2026-08-21 paste-a-script
  vector, the multi-line variant, and the false positive itself.
- **The last smear tables are gone.** `windows-cross-builds.md` (14 long rows)
  and `build-cache-tiers.md` (4) got the same treatment as
  `windows-builds.md` earlier: two-column tables became linkable definition
  sections, the four-column one kept its scannable columns and moved the long
  free-text column into per-row detail. Repo-wide, rows over 400 characters fell
  from 39+18 to 8, and every remainder is a genuine multi-column row.
- **Pester installed (user scope)** so `windows/scripts/tests/Invoke-Tests.ps1`
  actually runs. It had been exiting 0 while silently skipping every test, which
  reads as green — the suite had not executed once all day, including against
  the `verify-target-arch.ps1` change that arrived with the merge. **668 tests
  now run: 667 pass.** The one remaining failure is environmental, not code:
  `Assert-ShimPatch` finds no patched containerd shim installed on this host.
- **Three patch files were CRLF in the worktree against an LF index**
  (`windows/scripts/patches/README.md`, `iree/enable-ehsc.cmake`,
  `litert-lm/cpu-affinity-rust-syslibs.cc`), failing
  `Dockerfile.EolAttributes.Tests.ps1`. Re-materialised from the index with the
  remedy `preflight.sh` already prescribes for `.sh` files. This is the class
  AGENTS.md warns about: an EOL flip busts a media layer and costs hours.

**Still open, and not ours to close:** whether `VULKAN_VERSION` should be
`1.4.357.0` (what `versions.env` says, and therefore what every doc now says) or
`1.4.357.1` (what the docs claimed before the sync). If `.1` was intended,
`versions.env` is the file to change.

## 2026-08-25 (third pass) — docs: a duplication gate, and the copies three manual passes missed

`docs/INDEX.md` opens with the reason this matters: one Dev Drive command in
three places, all three wrong the same way. That rule was written down and
enforced by nobody. Three manual de-duplication passes in one day each declared
the tree clean — and each measured **verbatim lines**, which is the wrong
instrument, because prose gets reflowed. A paragraph reworded across two pages
shares no whole line while still being the same paragraph.

- **`docs/scripts/verify_doc_dupes.py` (new) — preflight slug `doc-dupes`,**
  wired into `stale-docs-check.yml` and `build-docs.yml`. Every paragraph is
  reduced to its 8-word shingles; two paragraphs in different files sharing more
  than 12 are reported. Shingles owned by many files are ignored as shared
  vocabulary. Records (archives, backlogs, `CHANGELOG.md`) are excluded — they
  narrate the same work on purpose and must never be edited to satisfy a gate.
  Negative-tested both ways: a paragraph copied between pages fails it, and so
  does an allowlist entry whose overlap has disappeared.
- **It found 27 copied passages** on a tree that had just been declared clean.
  The largest was a **3,673-character single paragraph** in `AGENTS.md`
  § Quick Reference that also duplicated `cross-build-verification.md` in full —
  flagged as a wall of text in the very first review of this work and walked
  past three times since. It is now build logs, chain stopping, a three-row
  cache-knob table, and a two-sentence summary of the shipped-BYTES saga that
  points at the page which owns it.
- **Reduced to 9 pairs, all deliberate**, each recorded in
  `docs/scripts/doc-dupes.allow` with a budget and a reason — almost all of them
  a RULE page and a MECHANISM page naming the same script or failure. The
  allowlist is a ratchet, not an exemption: growth past a budget fails, and so
  does a stale entry.
- **What got one owner along the way:** the RDNA4 layer-lock story (the
  `windows-host-setup.md` copy ran 78 lines of superseded history; it is now a
  24-line actionable check that links to the lane doc — the same duplication a
  previous pass reported as fixed without re-measuring), the CNI
  `.conf`/`.conflist` rule, the TensorRT owner directive, the sccache wiring
  block, the containerd host-config entry, the apt-mirror advice (stated twice
  in one file), the CI trigger markers, three over-long `failure-modes.md` fix
  cells, and the twin preambles on the two reference pages.
- **`linux-build-basics.md` now opens by saying what it is** instead of with a
  build-logging admonition — it was the only page of 38 without orientation in
  its first line.

**Verified:** `doc-dupes` and `doc-links` both green; preflight green across
doc-links, doc-dupes, version-snapshot, arg-consistency, mirror-consistency,
crlf-guard, shellcheck, dockerfile-lint, workflow-lint, python-lint; Sphinx
build warning-free; ruff clean on the full ruleset; every distinctive fact from
the 55 removed lines confirmed still present in its owning page.

## 2026-08-25 (later) — docs: a gate that keeps the structure honest, plus the leftovers

The structural pass earlier today fixed the *state* and nothing kept it fixed.
This closes that, and clears the items that pass deliberately left open.

- **`docs/scripts/verify_doc_links.py` (new) — preflight slug `doc-links`.**
  Checks the four ways this tree rots silently: a relative link whose target
  moved, a `file.md#heading` deep link whose heading was renamed, the repo's own
  `file.md § Heading` prose convention (the worst of them — nothing renders
  those, so nothing complains), and index coverage against BOTH `docs/INDEX.md`
  and the Sphinx toctree. Wired into `stale-docs-check.yml` and
  `build-docs.yml`. Archives and `CHANGELOG.md` are exempt from the anchor and
  section checks by design: they are dated records, and a heading renamed later
  must not force an edit to history. Negative-tested — a renamed heading, a
  dropped toctree entry and a renamed section target each fail it; ruff-clean on
  the full ruleset.
  **It immediately earned its place**: 10 real stale references, two of them
  introduced by the morning's split (`docs/upstream/` was outside the first
  rewrite pass; two lane refs still pointed at `AGENTS.md § Isolation policy`
  after that content moved INTO the lane doc). It then rejected two references
  in prose written for this very entry.
- **The smear tables are gone.** `windows-builds.md` had 39 table rows over 400
  characters — the exact defect called out in the failure-modes table and then
  walked past in its twin. § Windows Script Reference (47 entries) is now
  grouped, linkable sections with a scan list; Component Build Matrix and Source
  Patch Policy keep their scannable columns and move the long free-text column
  into per-row subsections. 39 → 1.
- **Zero verbatim duplicate prose lines** across all non-archive docs. The last
  two were commands — a `gh --jq` recipe and a `Set-Service` line — which is the
  exact class the Dev Drive incident in `INDEX.md` is about. Each now has one
  owner and a pointer.
- **The provenance heading is gone.** `windows-build-lanes.md` carried a section
  named "Driver behaviour and lane selection (from AGENTS.md)" — named after
  where the content came from, not what it is. Now "Driver preflight gates and
  isolation policy".
- **`AGENTS.md` 1,205 → 1,110 lines** by moving reference out to the pages that
  own it: the runtime-lane and orchestrator command blocks to
  `linux-cross-builds.md`, `WindowsContainerBuild.Reuse` to `windows-builds.md`,
  the Sphinx theme package to `project-info.md`, and the build-performance
  summary down to its motivating number plus a pointer.
- **Version drift cleared** via the sanctioned `sync_versions.py --write`.
  Note two real corrections it made: `windows/Dockerfile.base`'s
  `FLUTTER_VERSION` default was 3.47.0 while `versions.env` says 3.47.1 (the ARG
  sits BELOW the VS Build Tools layer, so this costs a scoop re-run, not the
  expensive layer — the ARG-placement rule doing its job), and the docs claimed
  Vulkan 1.4.357.1 while `versions.env` says 1.4.357.0. The SSOT won. **If .1
  was the intent, `versions.env` is the file to change — not the docs.**
- **The Sphinx build is warning-free** (was 29). Four code blocks used an
  unknown `cmd` lexer; the 2026-08-21 backlog archive jumped H1 to H3 in 26
  places. The archive's heading levels were corrected and a dated editorial note
  added where it points at content this morning's split moved — the entries
  themselves are untouched, because it is the record.

**Not fixed, and why.** `AGENTS.md` is 1,110 lines, not the ~600 previously
proposed. That number was wrong: what remains is rules, not reference, and
cutting further would delete hard-won knowledge to hit an arbitrary target.
`windows-build-lanes.md` is 1,461 lines and remains the largest non-archive
page; it is one coherent topic and splitting it again would scatter a story that
reads in order. `windows-cross-builds.md` still has 14 long table rows.

## 2026-08-25 - docs: structural pass — one index, five new pages, AGENTS.md halved

A review of `AGENTS.md`, `README.md` and `docs/` found the content strong but
the containers wrong: three competing indexes that disagreed, one 3,139-line
Windows page, a 1,559-line agent file with no TOC, and the RDNA4 story told in
full five times. No knowledge was dropped — every line was moved, promoted to a
heading, or reformatted in place.

- **One index, and it is discoverable.** `docs/INDEX.md` was linked only from
  `AGENTS.md` and two reference pages — not from `README.md`, not from the
  Sphinx toctree. It is now the first card and first toctree entry on the docs
  site and the head of README's Documentation section. Its coverage gaps are
  closed: `overview`, `project-info`, `third-party-licenses`,
  `build-cache-tiers`, both refactor backlogs and every archive are listed.
  `build-cache-tiers.md` (24 KB) had been reachable from **none** of the three
  indexes. `docs/index.rst` gained six captioned toctrees; every `docs/*.md`
  now appears in exactly one.
- **`AGENTS.md`: 1,559 -> 1,202 lines (154 KB -> 84 KB, ~39k -> ~22k tokens).**
  It is loaded every session, so its size is a per-session tax. It gained a
  contents block and a charter that says what it is *for*; the circular pointer
  is gone (it claimed build commands live in README.md, while README.md pointed
  back at it — they live in its own § Quick Reference).
- **`docs/windows-build-invariants.md` (new).** The 380-line flat bullet list
  under one `###` is now 44 entries in eight groups, each individually linkable.
  Nothing was rewritten; each rule keeps its incident and date.
- **`docs/failure-modes.md` (new).** The Common Failure Modes table — rows of
  1,200-2,400 characters, unreadable on GitHub and impossible to deep-link — is
  now 34 symptom sections with Symptom / Cause / Fix, grouped by lane. Every
  entry has an anchor; README and `AGENTS.md` link into specific ones.
- **`windows-builds.md` split 3,139 -> 660 lines**, into
  `windows-build-lanes.md` (BuildKit, nerdctl, classic; isolation, preflight
  gates, RDNA4 A/B history), `windows-build-resources.md` (CPU/memory envelope,
  sccache, GPU, the 125-layer budget), `windows-stevedore-and-docker.md` and
  `windows-refactor-backlog.md`. The pseudo-sections other pages cite as
  "§ Store GC", "§ VHDX-backed checkouts" and "§ DEFECT SOLVED" were never
  headings; they now carry named anchors.
- **Duplication removed where it was drifting.** The RDNA4 layer-lock story was
  told in full in README **twice**, `AGENTS.md` twice, `windows-builds.md`
  seven times and `windows-host-setup.md` four — each copy repeating the
  superseded 2026-08-09 verdict. It now has one owner
  (`windows-build-lanes.md`), one triage row (`failure-modes.md`) and one-line
  pointers elsewhere. Same treatment for the Windows-on-ARM blockquote (README
  and `AGENTS.md` carried it near-verbatim) and README's Engineering
  Principles, which restated `AGENTS.md` § Project priorities in different
  prose.
- **`README.md`: 308 -> 226 lines, Quick Start moved from line 245 to line 25.**
  A first-time reader met a 56-line caching essay, a 1,900-character
  architecture paragraph and a generated version table before a single runnable
  command. The generated version-snapshot block is byte-identical.
- **`CHANGELOG.md`: 2,493 -> 661 lines.** Entries through 2026-08-13 moved to
  `docs/changelog-archive-2026-08-13.md`, following the backlog-archive
  pattern. Archive again past ~700 lines.
- **Scratch is now ignored by construction** (`.gitignore` + `.dockerignore`).
  One-shot helper scripts land in the repo ROOT — that is where a `uv run` or
  `bash` invocation resolves relative paths — which is exactly where `git add -A`
  sweeps them into a commit. No tracked file at the root is a script, so
  root-level `*.py`/`*.sh`/`*.ps1`/`*.psm1`/`*.tmp`/`*.bak` are ignored
  outright, plus a `.scratch/` tree for everything else throwaway. Checked
  before landing: no tracked file is shadowed, both lint gates discover from
  directory allowlists that exclude the root, `crlf-guard` reads
  `git ls-files`, and no Dockerfile COPYs a root-level script. The
  `.dockerignore` half matters on its own — an untracked probe is invisible to
  git but still rides along in the root build context that ~9 solves upload per
  full classic run. A helper that earns a second use is not scratch: it moves to
  `linux/scripts/` or `docs/scripts/` with a header and a test.
- **Verified, not assumed:** 0 broken relative links and 0 bad anchors across
  README, AGENTS and all of `docs/` (including 97 same-file TOC anchors); a
  line-level conservation check accounts for every line of the split files;
  `preflight.sh` green on `runtime-paths,crlf-guard,dockerfile-lint`.

**Known guard false positive, filed not patched.**
`.claude/hooks/guard-destructive-deletes.ps1` matches its delete verbs and its
protected-path patterns against the WHOLE text independently, so a doc that
mentions a GPU vendor anywhere and contains a container cleanup flag anywhere
is denied — the flag matches the two-letter delete verb. Editing this README
and this entry both trip it. Prose that merely mentions a vendor and a CLI flag
is not the 2026-08-21 vector. Per the repo's own rule, relaxing a guard regex
is a reviewed change with a test — so the fix is proposed, not applied: require
the verb and the protected token on the *same line*, and add a
prose-false-positive case to `Guard.DestructiveDeletes.Tests.ps1`.

**Pre-existing and untouched:** `sync_versions.py --check` reports the README
snapshot, `overview.md` inline markers, the deps table and
`windows/Dockerfile.base` ARG defaults as stale. That drift predates this pass
(the README block is byte-identical to `HEAD`) and the fix touches a Dockerfile
ARG, so it is left for a deliberate `--write` run.

## 2026-08-25 - docs: remote desktop, media/OCR — `04_Software` and `RemoteDesktop.md` retired

`docs/linux-reference.md` gains two sections, emptying the last two note folders
that still held transferable material.

**Remote desktop on a headless box.** The source had `xrdp`+GNOME Flashback and
`gnome-remote-desktop` as two disconnected walkthroughs, the second in German.
Restructured as a decision — Wayland-native vs X11, and the note that both bind
3389 so running both is a conflict, not a fallback. The system-vs-user mode
distinction in `grdctl` is called out, since picking the wrong one is the usual
first mistake on a box you dial into.

Two fixes to the source while transferring: its rollback removed
`/etc/polkit-1/rules.d/02-allow-colord.rules`, and its summary table listed that
file, but no step ever created it — the rule is now written out, attached to the
troubleshooting row for the colord auth popup it actually fixes. And step 4 read
`südöstliche mkdir -p` where it meant `sudo mkdir -p`.

**Media and document conversion.** `ffmpeg` trim/convert/frame-extract/metadata
repair and the OCR pre-processing filter, plus the `ocrmypdf` toolchain. The
source's filter read `scale=iw8:ih8`, which is not valid ffmpeg — corrected to
`scale=iw*8:ih*8`. Cross-linked both ways with `windows-reference.md`, which
keeps the genuinely Windows-specific capture side (DirectShow, `gdigrab`).

Verified command-by-command rather than by token match, after two earlier checks
returned garbage — one reported every command present because a broken `sed`
left the search key empty, making `grep -F ""` match anything. 43 of 52 source
commands match verbatim; all 9 others confirmed present as formatting variants.

## 2026-08-25 - docs: Linux Wake-on-LAN, CIFS mounts, rsync mirroring

Last transferable material from `Nextcloud\...\Debian based\Ubuntu`, all into
`docs/linux-reference.md`.

- **Wake-on-LAN (Linux)** — closes an asymmetry: `windows-reference.md` had the
  Windows side but there was no Linux equivalent. `ethtool` for the current
  boot, a oneshot unit to persist it, and the NetworkManager form, which matters
  because NM reapplies its own setting and silently undoes `ethtool`. Plus
  `tcpdump` on ether proto 0x0842 to prove the magic packets actually arrive
  before blaming the NIC. Cross-links to the Windows page for the firmware
  layer, since that part is OS-independent.
- **SMB/CIFS mounts** — credentials in a `chmod 600` file rather than inline in
  world-readable `/etc/fstab`, and `uid`/`gid` in the mount options, without
  which every file appears root-owned and a non-root build cannot write.
- **rsync mirroring** — with the two things that bite: the trailing slash on the
  source, and `--delete` emptying the target if the source path is wrong.

That folder is otherwise where this repo's exclusion list lives: two `.pfx`
private keys (one an Elster tax certificate), `.smbcredentials`, a `Save.keyx`,
a 40 MB licensed installer, and 19 zero-byte placeholder files. None of it
transferred, and the notes still referencing a NAS address, share names and a
real account are excluded with it.

## 2026-08-25 - docs: `windows-reference.md`, plus the last real gaps in both note folders

Symmetric counterpart to `linux-reference.md` from the previous entry, and a
final probe-driven pass over both Nextcloud note folders for anything still
uncovered.

**New: `docs/windows-reference.md`.** Same quarantine header as its Linux twin —
general Windows/PowerShell knowledge, explicitly *not* verified against a build
lane, with a stated promotion path if an entry turns out to be load-bearing.
Covers disk and folder-size analysis, `Set-ExecutionPolicy -Scope Process`,
exe debugging via `Tee-Object` + `$LASTEXITCODE`, LOC counting, services and
`PSWindowsUpdate`, shutdown/recovery, PATH in `cmd`, OpenSSH **server** setup on
Windows, Wake-on-LAN (the three layers that must agree, including the firmware
setting a CMOS reset takes with it), clang ABI detection, `dart format`,
orphaned-uninstall registry cleanup, `diskpart` media recovery, and ffmpeg
capture/trim recipes.

Deliberately omitted a bare recursive force-delete recipe that the source note
carried: this repo routes host reclaim through
`windows\scripts\host\free-disk-space.ps1`, which is allowlisted and report-only
by default, and a general-purpose delete-a-tree snippet in the docs would
contradict that. The page points at the script instead.

**Three gaps closed, found by probing rather than re-reading:**

- **Compose-level secrets** (`docs/build-secrets.md`). The page covered
  BuildKit `--secret` for build time but nothing for a *running* container.
  Compose mounts at the same `/run/secrets/<id>` path from a `secrets:` block —
  and the environment variable holds the **path**, not the value, which is the
  detail people get wrong on the way to putting the secret in `docker inspect`.
- **MTA setup** (`docs/linux-host-setup.md` § E2). `Unattended-Upgrade::Mail`
  was documented as needing "an MTA installed and working" with no way to get
  one; `msmtp` relay config now follows it, including the mode-600 requirement
  and the app-password caveat.
- **MSIX Developer Mode.** `windows/scripts/certificates/README.md` already owns
  certificate generation and the `TrustedPeople` import, but Windows still
  refuses to install a self-signed `.msix` until Developer Mode is on. Noted in
  `windows-reference.md` § Certificates and MSIX.

**Now confirmed exhausted.** Probes for every remaining candidate across both
folders — watchtower, CIFS mounts, VNC/xrdp, RustDesk, MQTT, Folding@Home,
`Get-StartApps`, the Group Policy scheduled task — come back either already
covered or genuinely out of scope. What is left in Nextcloud is homelab
services, desktop access, and device-specific notes, several carrying LAN
addresses, MAC addresses, a machine SID, an employer domain account, an OEM
product key and a personal mailbox. None of that belongs in a public repo.

## 2026-08-24 - docs: `linux-reference.md` — general Linux knowledge, deliberately quarantined

The notes folder still held ~20 files of ordinary Linux knowledge: disk and file
handling, log filtering with grep/awk, user and permission basics, network and
port triage, SSH key/agent handling, firmware, mounts, swap, keyboard layout on
a headless box, and general git. All correct and worth keeping; none of it
specific to this repo.

Rather than fold it into the existing pages, it goes in a **separate**
`docs/linux-reference.md` whose header states the distinction outright: every
other page records something that broke in a lane, with its incident; this page
does not, and nothing on it is verified against a build lane. The header also
names the promotion path — if an entry here turns out to be load-bearing, move
it to its owning page in `INDEX.md` and give it the *why*.

That separation is the point. `linux-host-setup.md` is trustworthy because every
line is a specific failure with a fix; mixing `uname -r` and `useradd` into it
would cost exactly the property that makes it worth reading. Keeping the general
material addressable but clearly labelled gets the reference value without
paying that.

Cross-links rather than restates: container networking and resolver failures
stay in `linux-host-setup.md` § B5/B6, build-log mining in
`build-resource-monitoring.md`, swap/zram for small hosts in
`build-parallelism-memory-tuning.md`, submodule work in
`adopting-in-a-new-project.md`.

Also closed a gap from the previous pass: the submodule conflict-resolution loop
had been transferred **without** the `git merge --allow-unrelated-histories
--no-commit -X theirs` that creates the situation, or the protected-branch push
fallback. Both now in `adopting-in-a-new-project.md`, along with
`git remote set-url`.

Scrubbed on the way in: LAN subnets, `/home/jsh/.ssh`, a board hostname, a NAS
home path, personal user paths, a `NOPASSWD` sudoers line naming a real user,
and a client project name that appeared in a sample log line. Two deliberate
omissions: the blanket wipe of everything under /tmp (the docs carry a safer
find-based form plus the mode-1777 warning), and a personal miniconda `PATH`
export. gitleaks clean.

## 2026-08-24 - docs: Windows ops notes folded in; second Linux pass

Same treatment as the Linux notes folder, applied to
`Nextcloud\Dokumente\Windows` (30 files), plus a second Linux pass that caught
what a first triage-by-directory-name had missed. +518 lines across 7 docs.

**Windows.** The Windows lane already owned long paths, `core.longpaths`,
`Optimize-VHD`, MSIX signing and `dumpbin`, so those were left alone. What was
genuinely absent:

- **`docker login ghcr.io` fails on Windows with `--password-stdin`** — the
  documented form for the registry this repo publishes to. Fix is clearing
  `credsStore` (the same helper whose SYSTEM-context failure AGENTS.md already
  lists) or writing the base64 auth entry directly. Now in `windows-builds.md`
  along with `--network=host` being Linux-only, `host.docker.internal`,
  `--memory` for heavy Windows containers, DNS via `daemon.json`, service
  recovery, and the WinGet/MSBuildTools image gotchas.
- **WSL2 setup** in `rancher-desktop-linux-containers.md`: store-less install via
  DISM + `wsl --import` from a cloud rootfs, `appendWindowsPath=false` (Windows
  binaries shadowing Linux ones inside a build script), `ext4.vhdx` reclaim, the
  VPN no-network fix, and `usbipd` passthrough including the modprobe/bind step
  that attaching alone does not do.
- **Host odds and ends** in `windows-host-setup.md`: Defender *performance mode*
  (complements the existing exclusions), `Set-ExecutionPolicy -Scope Process`,
  in-place `PATH` reload, non-interactive VS update, `winget --force --version`
  for an exact SDK pin, a WSL firewall rule, `bcdedit /bootsequence` (the
  counterpart to `grub-reboot`), and `pnputil` driver removal.
- **Git recovery** in `adopting-in-a-new-project.md`: `submodule deinit -f --all`
  for a half-initialised checkout, `core.longpaths`, `git clean -fdx`, and the
  `ssh-agent` service that a hanging `git pull` in PowerShell is waiting on.

**Second Linux pass.** Three more transfers, all previously misjudged by folder
name rather than content — the same mistake twice over:

- **UFW drops container traffic** unless `DEFAULT_FORWARD_POLICY="ACCEPT"`. This
  is the Linux twin of the Windows CNI `.conf` requirement AGENTS.md records as
  "without it RUN steps have NO network": same failure, same invisibility.
- **Host suspend kills a multi-hour chain.** `logind.conf` covers only keys and
  the lid; the sleep *targets* need masking separately.
- **APT pinning** as the other half of `Package-Blacklist` — blacklist stops
  upgrades, pinning forces the source. Carries a real trap: APT preferences need
  each field on its own line, and a single-line `echo` writes a file APT ignores
  with no error.

Plus the two stranded residues: the riscv64 `libgst*.so*` cleanup and the
prebuilt Android GStreamer tarball, both in `runtime-services.md`.

**Excluded, as before.** `ProductKey.md` holds a real OEM licence key; a
scheduled-task XML carries an employer domain account and a machine SID; several
notes carry hostnames, a device public key and personal paths. None transferred.
Verified with gitleaks (working tree, repo config: no leaks, `.gitleaksignore`
unchanged) plus a manual sweep for those identifiers, which gitleaks does not
flag. Incidental find: `Nextcloud\...\GenerateCertificateMSIX.ps1` is an older,
weaker copy of `windows/scripts/certificates/GenerateCertificateMSIX.ps1` — the
repo's is parameterized, uses a KSP provider and exports AES256_SHA256.

## 2026-08-24 - docs: personal Linux ops notes folded into `docs/` (38 of 94), two new pages

`C:\Users\jsh\Nextcloud\Dokumente\Linux` had accumulated 94 markdown notes
(~8,700 words) of Linux administration knowledge, unversioned and outside any
review. The subset that is genuinely this repo's domain is now in `docs/`,
English, deduplicated against what the repo already owns, and reachable from
`docs/INDEX.md`. +649 lines across 9 files, plus two new pages.

**New: `docs/linux-host-setup.md` (618 lines).** The counterpart to the 836-line
`docs/windows-host-setup.md`, which had no Linux equivalent — probes confirmed
`scaling_governor`, `rocm-smi`, `ubuntu-drivers`, `journalctl`,
`nvidia-container-runtime` appeared NOWHERE in the repo before this. Phases A–E:
NVIDIA driver + CUDA install and the full purge/recovery path, AMD firmware,
container runtime host config (nvidia `default-runtime`, log rotation,
`nerdctl-full` verification, resolver fixes), CPU governor + `rocm-smi`
performance mode, GCC/clang alternatives, apt mirror + unattended-upgrade
policy. Troubleshooting covers `journalctl -b -1`, the PSU-starved dual-GPU
`nvidia-smi` failure, GRUB rescue, disk and `/tmp` exhaustion.

**New: `docs/build-secrets.md`.** BuildKit `--secret` + `.netrc` for private
clones. `mount=type=secret` had zero hits repo-wide despite `secret-scan` being
an enforcing gate — the sanctioned pattern was undocumented.

**Extended:** edge accelerators (Hailo ONNX→HEF pipeline, Jetson) in
`linux-accelerator-images.md`; raw `gst-launch-1.0` pipelines and device
source-builds in `runtime-services.md`; detached containers + tmux and
bind-mount ownership in `rancher-desktop-linux-containers.md`; CPU capping and a
memory-constrained-host section (swap/zram/`-j1`) in
`build-parallelism-memory-tuning.md`; build-log failure mining in
`build-resource-monitoring.md`; submodule maintenance in
`adopting-in-a-new-project.md`.

**Two findings worth keeping.** (1) A measured incident now in § E1: `apt update`
took 107 s on a 254 Mbit/s link because `security.ubuntu.com` round-robin DNS
resolved to an unhealthy node; the regional mirror took it under 3 s. That cost
is paid on every uncached image layer, not just the host. (2) `-X theirs` on a
merge resolves file contents but leaves submodule POINTERS conflicted — a merge
can look resolved while pinning the wrong ContainerHub commit. The resolution
loop is now in `adopting-in-a-new-project.md` § Submodule maintenance.

**Nothing sensitive crossed over.** The source tree holds live secrets — two
`.pfx` private keys (one an Elster tax certificate), `.smbcredentials`, a
WireGuard config with a private key, a `Save.keyx`, a GitLab `.env` — and this
repo is public. None were transferred, referenced or quoted. Verified by the
enforcing gate (gitleaks 8.30.1, repo config, working tree: **no leaks found**,
`.gitleaksignore` unchanged) plus a manual sweep for LAN IPs, usernames, home
paths, a MAC address and personal machine names, which gitleaks does not flag.
Also scrubbed: `?utm_source=chatgpt.com` tracking params on ~8 GRUB links and
the LLM-conversation tails ("Want me to drop this into a markdown file?") that
two notes ended with.

**Deliberately NOT transferred**, per the `docs/INDEX.md` anti-duplication rule:
`buildx imagetools create` multi-arch tagging, already owned by
`linux/scripts/build-runtime-manifest.sh` and `docs/linux-cross-builds.md`. The
remaining 56 notes are homelab (NAS, Mail, RustDesk, WireGuard, WOL,
RemoteDesktop) or one-line stubs, and stay out.

**Open:** the source notes are not yet stubbed to point here, so that content
exists in two places until they are — the exact drift `docs/INDEX.md` documents.
`.claude/hooks/guard-destructive-deletes.ps1` blocks agent writes under
`C:\Users`, so this is an operator step; mapping for all 38 files was handed
over separately.

## 2026-08-24 - ghcr registry cleanup: 771 -> 167 package versions, zero failures

New operator tool `linux/host-config/ghcr-prune-package.sh` (adversarially
reviewed before first use; three found defects fixed pre-commit, including a
SIGPIPE that made the dry run exit 141 and a fail-open zero-tag path that
would have turned a collapsed keep-set into a registry wipe). First confirmed
run deleted 604 stale untagged versions — the residue of every re-pushed
moving tag since June — with 0 failures and 0 skips; afterwards the
`:latest-cross` index, all three arch manifests and every cross-stage tag
verified HTTP 200, and the concurrently running wave7b build was untouched
(its pushes sat inside the KEEP_DAYS=7 in-flight guard, visibly counted by
the tool). Incidental finding: legacy tags android/compiler/latest/media/
sdk/torch were ALREADY dangling (all 18 index children 404) before any
pruning — pre-existing damage, operator decision pending on whether to
delete or re-point them.

## 2026-08-24 - WAVE-6 SHIPPED: the gate-truth build (three blind gates now actually work)

`:latest-cross` = amd64 `a25a38c5` / arm64 `bd9953a9` / riscv64 `d3710282`,
run id `20260823-223111-d0336283`. cv2 GStreamer:YES + FFMPEG:YES holds on the
new bytes; runtime smokes 0 failures x3.

This build existed to validate the three gates the wave-5 post-audit found
INERT. All three now produce real verdicts:

1. **XC3 provenance** — `per-arch wrapper generation check: OK` with NO
   "wrapper tag(s) carry no run-id" warning; that line read 3/3 on every
   previous ship. All three wrappers carry run-id / parent-stage /
   parent-digest as image LABELS, verified by reading the REGISTRY copy's
   config blob (registry-config-label.py), not the local store. Ancestry now
   reports `android→wrapper (<arch>): OK` with real digests on 3/3 — it used
   to bail at "records no parent digest". The label saying *android* also
   confirms the XC2-STAGE fix: the writer stamped the android pin while the
   check resolved runtime_stage_parent's answer ("package"), which would have
   produced a false STALE ANCESTOR on every run the moment provenance came
   back.
2. **AP4 strip gate** — `AP4 strip verified: libavcodec.so.63.1.100 has no
   .symtab`. Every prior ship printed `check skipped (could not extract ...)`
   while the wrapper gate still said PASS, because `tar --occurrence=1` exits
   after the first match, SIGPIPEs the exporter, and `pipefail` turned the
   early exit into a failure.
3. **SMK1** — the cv2 media assert is now hard on all three arches, including
   riscv64, which used to be exempted with the printed rationale "gstreamer OFF
   by design" on the very line where the probe reported YES.

**CERB-CACHE validated the hard way.** wave6a lost all three lanes to five
freedesktop 503/404 flaps (an outage that also proved cerbero's DEFAULT_MIRRORS
path 503s unconditionally while the `/data/` primary answers 200 — the fallback
is not merely single-homed, it is always dead). But the cerbero state survived
on the cachemounts (15.7 GB / 14.5 GB), so wave6b restarted WARM
(`HIT: resuming from /var/cache/cerbero ... 13G / 20G`) and completed with ZERO
fetch failures. Before this, wave5k and 5l discarded the entire ~50-minute
bootstrap on every flap.

Also in this window (backlog sweep waves 1-3, commits ee8de5e / ece1c37 /
2276c8c): log hygiene armed by default, smoke depth (a real GStreamer pipeline
and an ONNX InferenceSession instead of string greps), per-arch component
parity, a GCC-default SSOT plus a fatal drift gate with a site floor, TS8, the
NVIDIA deb pick made deterministic and self-reporting, and eigen/cerbero
network resilience. Five mechanisms were REVERTED rather than shipped after
review proved them inert or unsafe: PAR5's live-lane divisor (a build-arg
cannot change mid-build), the cerbero seed cache (nothing mounted it), two
cargo mounts on RUNs that never invoke cargo, and S3 (it reintroduced the
`${tag}-buildcache` ref that fix7 forbids — the preflight failed on it).

Tests grew 417 -> 638 assertions across 25 suites over this window.

## 2026-08-23 - WAVE-5 SHIPPED: closure window 2 — cv2 media stack complete on all three arches

`:latest-cross` = amd64 `54ab7f01` / arm64 `7bb70a4b` / riscv64 `fb701200`.
**The window's goal is MET and verified on the SHIPPED BYTES** (local tag
digests matched against the registry-side OCI index, plus a
docker-content-digest HEAD — never the push log): cv2 5.0.0 reports
**GStreamer:YES (1.29.2) and FFMPEG:YES (avcodec/avformat 63.1.100) on
amd64, arm64 AND riscv64**. riscv64 had been stuck at wave-3 parity
(GStreamer: NO). Verification went one level deeper than the gate: real
one-frame GStreamer pipelines and an FFmpeg roundtrip were executed inside
all three shipped images, so this is runtime-proven, not string-grepped.
Runtime smokes: 0 failures x3. Wheel smokes: 13/15, 13/15, 11/15 (the
riscv64 delta is genai-absent + freetype-OFF, both documented).

What landed in this window:

1. **OCV-FF1 (FFMPEG:NO -> YES)** - true root was detect_ffmpeg's
   try_compile getting the four -l names but no link dir for the custom
   /opt/ffmpeg prefix ("Can't build ffmpeg test code"), NOT the swresample
   theory. Fix = LDFLAGS -L/-rpath-link for the ffmpeg AND gstreamer
   libdirs + a deterministic last-wins -DCMAKE_EXE_LINKER_FLAGS (the
   helpers' own -D beat the env). That exposed a second wall: opencv 5.0.0
   has no FFmpeg-8 migration (AVCodec.pix_fmts / .supported_framerates were
   removed; 4.x master has avcodec_get_supported_config, the 5.x branch does
   not) -> new backport patch
   `patches/opencv/002-ffmpeg8-avcodec-config-api.patch`, guarded by
   LIBAVCODEC_VERSION_MAJOR >= 62.
2. **riscv64 GStreamer re-lift (RV1-GST-PC largely closed)** - the
   introspection break turned out to be MESON-GI (meson 1.12 breaks
   g-i-1.84's `subproject('glib')`, reproduced on a clean sysroot, so the
   ports-.pc poison theory was falsified). Scoped pin meson==1.11.2 for the
   riscv64 cross gst build; with introspection back, /opt/gstreamer exports
   usable glib .pcs again, pass-2 gst links into videoio, and the libcamera
   gst element returns. Only freetype-OFF remains (RV1-FREETYPE).
3. **PKGCFG-MIRROR** - cerbero bootstraps pkg-config-0.29.2 from
   pkgconfig.freedesktop.org (host dead) with a src/mirror fallback that
   404s, so every COLD android bootstrap died on curl (22). Redirected to
   the macports distfiles mirror (byte-identical tarball; the recipe
   checksum still guards). **v1 of this fix was a heisenbug**: it chose the
   file to patch with `grep -rl … | grep -m1`, which is readdir-order
   dependent — inside the container it sed'd a stray .patch file and still
   echoed success, so the 404 kept happening while the host reproduced
   "correct". v2 patches the known recipe explicitly plus every other
   dead-host reference and echoes the RESULTING url line as proof.
4. **ORT version-shadow (the runtime smoke failure)** - `import cv2` died
   with `libonnxruntime.so.1.27.0: version VERS_1.29.0 not found`. The
   locally built wheel is named `onnxruntime_dnnl-*.whl` (the DNNL EP
   renames the dist) and `wheel_family()` listed gpu/migraphx/webgpu but not
   _dnnl, so `have_onnx_family` stayed false: PyPI onnxruntime 1.27 was
   neither skipped at `uv sync` nor uninstalled, and since both dists own
   `site-packages/onnxruntime/`, the 1.27 capi lib survived next to the
   1.29-linked cv2. Fix = classifier + uninstall list + skip-package on
   sync. Verified in the shipped bytes: exactly ONE ORT distribution per
   image (dnnl on amd64, webgpu on arm64/riscv64 - by design).

Mines survived (external and self-inflicted):

- **FD-OUTAGE** - a freedesktop-wide 503 window took all three android
  lanes down twice (pixman, then gst-plugins-bad). Not patchable: cerbero's
  DEFAULT_MIRRORS live on the SAME infra as its primaries. Filed with a
  cached_sources pre-seed option.
- **CERB-ICONV** - proven NONDETERMINISTIC: `undefined symbol:
  libiconv_open` killed a cold riscv64 cerbero link in one wave and passed
  in the next with no code change.
- **ENOSPC** - a runtime-stage run fell 117G -> 2G and died on a layer
  extract because nothing pruned mid-run. Cured with an auto-prune guard
  (prune-safe.sh below 55G); it fired 4x in the successful run, always with
  all 30 cachemount records surviving.

Gate-truth findings from the post-ship audit (the release is real, three
gates are not — all filed, none release-blocking):

- **AP4-SIGPIPE** - the strip gate has NEVER executed: `nerdctl export |
  tar --occurrence=1` under `set -o pipefail` returns non-zero when tar
  exits early, so the check self-reports "skipped" on 3/3 arches while the
  wrapper gate prints PASS. It hides ~1.9 GB of unstripped foreign
  cross-compiler binaries in the amd64 wrapper.
- **XC3-INERT** - run-id/parent-digest annotations are never written
  (`append_runtime_image_output` is `-t` only), so the mixed-generation gate
  cannot fail. Concretely: this manifest mixes two source revisions
  (amd64 58e6c325, arm64+riscv64 5105da8f), visible only via image labels.
- **SMK1-3ARCH** - smoke-torch-venv.sh still exempts riscv64 from the cv2
  GStreamer assert and prints "riscv64: gstreamer OFF by design" on the same
  line where the probe reports GStreamer=YES.

## 2026-08-21 - WAVE-4 SHIPPED: the 9-mine validating rebuild (closure window + 21 bumps)

`:latest-cross` = amd64 `73927a45` / arm64 `345096db` / riscv64 `da763dc3`
(manifest `98d90db6`). Byte-gate PASS x3; cv2 GStreamer:YES verified on
shipped amd64 AND arm64 bytes. The rebuild validated the entire closure
window (21 Linux version bumps, RV1, NET1 mirrors, DF1-4, AP3-correct,
PAR2/PAR4+amend, CCACHE_COMPILERCHECK=content, BT1/BT2) and flushed NINE
real defects only a live build could find:

1. VULKAN_SDK_SHA256 not in the bump tool's refresh net (killed sdk x3) -> BT1.
2. TENSORFLOW_C 2.21 is a git tag with NO artifact (2.19+ tarballs 404) -> BT2
   + the sha256('') empty-download trap, now rejected.
3. ORT 1.29 flipped telemetry DEFAULT-ON -> pulls cpp_client_telemetry whose
   vendored sqlite dies on GCC-16 -Werror (arm64) -> --no_telemetry (also a
   hygiene win: no MS telemetry SDK in shipped images).
4. PAR4-amend: the x-budget divisor over-throttled SHARED stages (compiler at
   1/3 jobs); shared stages now divisor 1. LLVM 50 min vs 11h projected after
   the ccache-content fix.
5. RV1's ports glib-2.0.pc expands prefix/libdir EMPTY in cross pkg-config ->
   poisons every glib lookup (5 distinct failure shapes) -> reverted for
   riscv64; precise root cause filed as RV1-GST-PC.
6. gobject-introspection-1.84 glib-subproject break under the new sysroot ->
   riscv64 introspection off (arm64 parity).
7. sccache rustc-wrapper server death x3 at 99% of gstreamer -> silent wrapper
   disabled (returns via controlled ENABLE_SCCACHE_RUST/SCC1).
8. opencv contrib freetype cross-links HOST harfbuzz on riscv64 -> module off.
9. buildkitd session rot after ~1-2h parallel load (grpc cancels at export,
   DeadlineExceeded) -> BKD1 filed; interim: restarts (cachemounts survive,
   proven 12x by prune-safe with ~1 TB reclaimed, zero losses).

riscv64 shipped state: wave-3 parity minus the libcamera gst element
(documented RV1-GST-PC residual). PAR1: sdk 2.9x stands; clean full-chain
timing deferred to one undisturbed run.


## 2026-08-18 - WAVE-3 SHIPPED: :latest-cross re-ship + the parallel-archs hardening saga (PAR2/PAR3/PUSH1/PAR4/CACHE1)

Fresh 3-arch `:latest-cross` (amd64 `fd0d8d74` / arm64 `6153d76b` / riscv64
`549789b8`), byte-gate PASS ×3, cv2 GStreamer:YES re-proven on shipped bytes.
The run doubled as the first real `--parallel-archs` hardening campaign:

- **CACHE1 SHIPPED+PROVEN**: `linux/host-config/prune-safe.sh` (filtered
  buildctl prune) + buildkitd gcpolicy pair applied live. 5 mid-run prunes,
  ~350G reclaimed total, **0 cachemount losses** (proven before/after each);
  ccache persistence confirmed (7.3 GB after mount release).
- **PAR2 SHIPPED+VALIDATED**: cache-mount ids split per ${TARGET_ARCH} (the
  ${TARGETARCH}=amd64 collision serialized all lanes on locked apt mounts —
  onnxruntime deps+fetch held them ~90 min). Post-fix: all 3 lanes compiled
  simultaneously (load 27-35 vs 4).
- **PAR4 INCIDENT+FIX**: removing PAR2's accidental serialization exposed the
  divisor's blind spot — 3 lanes hit IREE simultaneously, OOM-killed cc1plus
  ×2. Root cause: BUILD_MEM_DIVISOR ignored buildkitd max-parallelism
  intra-build steps. Fix: divisor ×= PAR_INTRA_STEP_BUDGET (default 2) under
  --parallel-archs (3-way → 6). Fully documented (tuning doc § second-order
  trap, AGENTS.md recipe note).
- **PAR3 SHIPPED**: PARALLEL_STAGES=all|csv per-stage parallelism control.
- **PUSH1 SHIPPED+MEASURED**: zstd layer compression on cross-stage pushes —
  media pushes ~10 min (vs 23-30 min gzip class).
- **OCV-FF1 RESOLVED**: shipped /opt/ffmpeg/lib HAS libswresample.so+.pc →
  opencv-5.0.0 FindFFMPEG probe quirk (fix on opencv side, next window).
- Ops lessons hardened into memory/docs: registry-cache DeadlineExceeded
  flake class (NO_CACHE_EXPORT=1 recovery), `nerdctl system prune` removes
  TAGGED non-container images (registry-pinned handoffs saved the run),
  wrapper smokes (SMK1-3) live-gated all three shipped wrappers.

## 2026-08-17 - BATCH-2 BIG WAVE SHIPPED: full 3-arch rebuild, opencv two-pass proven, GPU-lane fixes

Full base→:latest-cross rebuild (owner-chosen "everything incl. TG1 in one
rebuild") shipped FRESH digests amd64 `0cba6b61` / arm64 `ebc7562` / riscv64
`6a87341d`. Byte-gate PASS ×3 (libtensorflow absent). Manual byte-verification
of the shipped amd64 wrapper:

- **opencv ⇄ gstreamer TWO-PASS PROVEN**: `cv2.getBuildInformation()` reports
  **GStreamer: YES** — the shipped OpenCV links the source-built GStreamer
  (new `opencv-gst` pass-2 stage). Follow-up OCV-FF1: FFMPEG backend still NO
  (pre-existing, now visible) — likely opencv-5.0.0 vs ffmpeg n9.0.
- **AP2**: /opt/venv byte-compiled (.pyc present) — no more per-start re-parse.
- **AP4 complete**: media libs stripped across all prefixes (.symtab=0 verified).
- **AP1**: cross wheels stripped (RECORD-safe). **AP5**: CPython --with-lto.
- **TG1 (bounded)**: cmake/vulkan lazy + toolchain mounts trimmed — survived the
  full compiler stage; a cmake/vulkan edit no longer re-runs the 3655s GCC build.
- **Guard-helper wiring** live in both common.sh lanes.
- Regressions held: S2 (TF absent), GST1 (dev surface resolves), RP6 (PATH clean),
  torch 2.13.0 intact.
- **AP3 REVERTED mid-run** (80a81eb): the wheelhouse bind-mount sat in the wrong
  RUN — Dockerfile.torch (FROM package) is where setup-torch-venv reads
  /opt/wheels and it has no artifact-source stage → all 3 wrappers failed;
  reverted + runtime stage re-run. Re-filed with the correct approach.

Same day, GPU lane (opt-in, commit e51a0da): **GPU7** — broken `_trt_deb`
substitution (`|| true` OUTSIDE `$()`) made the default no-EULA-deb nvidia build
die at deb staging; **GPU1** TensorRT silent-skip fixed (apt-get update before
the NVIDIA-repo path; the shared apt-lists cache had been wiped by an earlier
RUN); **GPU2/3** verification now CUDA_STACK_STRICT=1 (was fail-open with ALL
components missing); **GPU4** in-cache-mount lists-rms dropped; **GPU5** ROCm
amd64 guard enforced; **GPU6** COPY --link. Awaiting one nvidia/amd lane build.

Also: backlog deep-look additions from the first GPU-lane sweep, shipped-image
posture sweep (POS1 app .git ships in image, PROV1 empty OCI labels), build-log
mining (LOG1-7 incl. libfuse3-3 absent on resolute + onnxruntime-web missing
webgpu JS), PAR1 measured (--parallel-archs ready: media 8.5h sequential vs
~3.5h parallel, divisor wiring verified), and smoke-gap self-review (SMK1-3).

## 2026-08-16 - FULL 3-ARCH REBUILD: Batch-2 subset shipped; :latest-cross re-shipped (fresh digests); 2 real bugs flushed

A full base→:latest-cross rebuild (all 3 arches) validated the 2026-08-15 staged
Batch-2 subset and re-shipped `:latest-cross` with FRESH per-arch digests amd64
`509027696e16` / arm64 `bdb46c953954` / riscv64 `28e3ded96f72` (all differ from
the prior d92cc0fb/99531bbe/252ca5e8). Byte-gate PASSED 3/3 (`libtensorflow
absent`); a manual pull of the amd64 wrapper confirmed libtensorflow gone,
ffmpeg 9.0 intact, GST1 `multiarch -> lib/x86_64-linux-gnu` resolves (no
self-link), `/root/.local/bin` gone from PATH, stripped prefix sizes.

- **DONE + LIVE**: AP7 media-half (per-prefix size report), RP6 (dropped dead
  `/root/.local/bin` from the shipped PATH), GST1 root fix (configure-runtime
  resolves the real gstreamer libdir — "dev surface resolves" 3/3), AP4 strip
  (ffmpeg/gstreamer/libcamera), TS1 (appimagetool pinned to 1.9.1).
- **Bug flushed — smoke-media cv2/numpy** (`0b2b306`): the native cv2 import test
  hard-failed because numpy is absent in the media BUILD sandbox (it is a
  /opt/venv packaging dep). Gated on `import numpy`; absent → defer to the
  runtime torch-venv smoke, exactly like the onnxruntime test. Killed media-amd64
  first — invisible to the runtime-lane validations because they skip smoke-media.
- **Bug flushed — GST1 self-referential multiarch symlink** (`22fb812`):
  `configure-runtime.sh` runs a SECOND time in the package stage on a payload
  that already carries `lib/multiarch`; the resolver glob matched it and
  re-pointed multiarch at itself, and the fail-loud assert killed riscv64 before
  the repair net could act. Fixed: rm the stale link + skip it in the resolver +
  downgrade the assert to WARN (the pkg-config gate is the fail-loud authority).

## 2026-08-15 - VALIDATING REBUILD: RP1/RP2/RP3/AP7 proven live; :latest-cross re-shipped (fresh digests)

A full runtime-lane rebuild (build-runtime-manifest.sh on the TF-less android
pins) validated this session's staged runtime-hygiene changes against a real
3-arch build + on-target smokes, and re-shipped :latest-cross with FRESH per-arch
digests amd64 `d92cc0fb` / arm64 `99531bbe` / riscv64 `252ca5e8`.

- **RP1 (setuid-sudo purge)** — `check_setuid_inventory` reported "no setuid sudo
  in the shipped image" on all 3 arches; pulling the amd64 wrapper confirmed
  `/usr/bin/sudo` + `/usr/local/bin/sudo` are ABSENT. Security win proven live.
- **RP2 (apt cache-mount guards)** — the package + torch builds succeeded on all
  3 arches with the `mountpoint -q` guards in place.
- **RP3 (HEALTHCHECK 5s→30s)** — the shipped wrapper reports `Timeout:30`.
- **AP7 (size observability, runtime half)** — `check_size_observability` emitted
  the per-prefix `du` breakdown on all 3 arches.
- **Regression checks held**: the RTCACHE3 `-t` fix produced three FRESH wrapper
  tags again (no stale reuse); the byte-gate PASSed on all 3 (content matches
  toggles); S2 held (libtensorflow still absent from the pulled wrapper); all
  on-target smokes 0 failures.

RP1/RP2/RP3 + AP7-runtime-half are now closed. AP7 media-half remains open.

## 2026-08-15 - backlog: gate/dead-code hardening (A1, forensic#3, TS6, cross-wheel SOABI, litert-web integrity)

Static-validated code-only fixes (no rebuild), each verified against the failure
it addresses:

- **litert-web npm dist.integrity verification (install-litert-web.sh)**:
  `_fetch_npm_package` downloaded the @litertjs/* tarballs with NO integrity
  check. It now fetches the registry packument's published `dist.integrity`
  (sha512) and verifies the downloaded tarball against it — a MISMATCH refuses
  the package (return 1), and since litert-web vendoring is already non-fatal the
  image ships WITHOUT a tampered/corrupted dependency instead of installing it;
  metadata-unavailable warns + proceeds (no worse than before). Validated against
  the live registry: real @litertjs/core@2.5.3 matches, a 1-byte-tampered tarball
  is refused.

- **cross-wheel SOABI/default-triple assert (verify-wheels.sh)**: the filename-tag
  loop only checks the Python tag (cp314), which is host==target — so it cannot
  catch a native extension stamped with the wrong arch SOABI (a cross build that
  leaked the host BUILD_PYTHON's `.cpython-314-x86_64-linux-gnu.so` into a riscv64
  wheel), which installs fine and only fails at `import` on-target. Added a pass
  that reads each wheel (python zipfile — no unzip) and checks native
  `.cpython-*.so` members against the expected `.cpython-XY-<target-triplet>.so`.
  Crucially derives the triplet from TARGET_ARCH, NOT the running interpreter's
  EXT_SUFFIX (this script runs on the amd64 host during a cross build, so the host
  suffix would falsely reject every correct cross wheel). abi3 + pure-python +
  bundled non-extension .so are skipped. Advisory (WARN) by default so a wrong
  triple map can never break an un-revalidatable build; WHEEL_SOABI_STRICT=1 makes
  it fatal. Unit-tested: correct/wrong-arch/abi3/pure-py/generic all classified
  right; triplet map matches test-arch-mapping.sh.

- **A1 (dead-alias)**: removed the never-set, undocumented `${UBUNTU_PORTS_MIRROR_URL:-}`
  inner fallback at cross-env.sh:17 (only the `FAST_`-prefixed variant is a real
  operator knob). ARCHITECTURES was found NOT dead (documented alias + live 3rd
  fallback in resolve_arch_list) and kept — the backlog premise was wrong.
- **forensic#3 (smoke-media)**: the opencv cv2-import else-branch no longer PASSes
  unconditionally. It now `cross_build_is_active`-gates — cross build → legitimate
  PASS-with-caveat (foreign-arch extension can't import on the host), NATIVE build
  → `fail` with the real import error surfaced. The old "import failed in build
  sandbox — will work at runtime" masked a genuinely-broken native cv2 as green.
- **TS6 (vulkan cross-targets)**: `_build_vulkan_targets` now tracks attempted/built
  per component (loader/SPIRV-Tools/glslang), logs an "N/M component(s) built"
  summary, and on ALL-attempted-failed WARNs loudly (an env-shaped cause — broken
  cross toolchain — that used to exit 0 silently); `VULKAN_CROSS_STRICT=1` promotes
  it to fatal. The arch-independent header-staging cp guards were split so a cp
  that fails with the source dir PRESENT warns instead of being masked as "source
  absent" by the old `2>/dev/null || true`. Success path byte-unchanged
  (conservative: no default hard-die on a load-bearing toolchain fn with no build
  to validate against).

## 2026-08-15 - S2 SHIPPED: libtensorflow removed from ffmpeg (−~500MB), :latest-cross re-shipped with FRESH digests after root-causing a 5× stale-ship bug

- **`:latest-cross` re-shipped with genuinely fresh per-arch wrappers** — manifest
  now indexes amd64 `f1a205a6`, arm64 `d5ae1470`, riscv64 `6024f28a` (the stale
  `35c1f1df`/`e677e4f8`/`5002954385` are GONE; 0 stale refs in the index). All 3
  on-target smokes 0 failures.
- **S2 verified live**: pulled the shipped amd64 wrapper and confirmed
  `opt/ffmpeg/lib/libtensorflow.so.2` + `libtensorflow_framework.so.2` are ABSENT
  (−~500MB), ffmpeg (`libavcodec.so.63`) intact, onnxruntime still present.
  `FFMPEG_ENABLE_TF=0` is the default (versions.env + Dockerfile.media ARG).
- **ROOT CAUSE of the 5× stale-ship saga — RTCACHE3** (`runtime-build-fns.sh`
  `append_runtime_image_output`): the runtime lane tagged the wrapper with the XC2
  provenance exporter `--output type=image,name=<tag>,annotation.*`. On this
  rootless nerdctl+containerd host that exporter builds the image into buildkit's
  content store but **creates NO local containerd tag** (proven with a minimal
  busybox repro: `--output type=image,name=X` → X absent; `-t X` → X present). So
  the freshly built wrapper was invisible — `runtime_push_tag` (`nerdctl push`)
  and `nerdctl manifest create` both resolved the STALE pre-existing tag from a
  prior run, shipping byte-identical every time. It only ever "worked" because the
  first-ever build had no stale tag to be stuck on. The annotations never reached
  the registry either (the perennial "carry no run-id annotation … provenance
  unverifiable" WARN was the visible symptom). **Fix**: use plain `-t` on both
  paths (reliably creates AND overwrites the local tag); inert annotations dropped.
- **Red herring corrected**: the earlier RTCACHE1 diagnosis (runtime wrapper
  registry-cache-hit) was WRONG — the fresh media (`f3c64fbb`) and android
  (`dee9049d`) were pulled and found already TF-less; the problem was purely the
  tag never moving. Lesson reinforced: **verify the shipped BYTES (pull+inspect),
  never trust "manifest pushed" = "fresh shipped"** — this manual check caught all
  five stale ships.
- **New escape hatch — `RUNTIME_NO_CACHE=1`** (`runtime-build-fns.sh`): gates
  `--no-cache` on the runtime package+wrapper builds as a hard guarantee against
  BuildKit worker-cache reuse of a stale `COPY /opt/ffmpeg` layer. Distinct from
  `NO_CACHE=1` (whole chain) and `CROSS_NO_LOCAL_CACHE_EXPORT=1` (write-only).
- **New automated byte-gate — `verify-shipped-wrapper.sh`** wired into
  `build-runtime-manifest.sh`'s per-arch loop BEFORE the manifest is assembled.
  It lists each wrapper's rootfs (`nerdctl export | tar -t` — arch-agnostic, no
  qemu) and asserts the shipped `/opt/ffmpeg` lib set matches the versions.env
  toggles: `FFMPEG_ENABLE_TF` ⇒ `libtensorflow` present/absent, ffmpeg intact
  (`libavcodec`). A toggle-mismatched or stale wrapper now aborts before
  `:latest-cross` goes live — the manual pull+grep that caught all five stale
  ships, automated. Tested: PASS on the fresh f1a205a6, FAIL on a synthetic
  TF-present-with-toggle-off image and on an empty-ffmpeg image.
  `WRAPPER_CONTENT_GATE=0` downgrades it to advisory.
