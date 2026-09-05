<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Common failure modes — symptom lookup

**Start from the error message.** Every entry below is keyed by what you
actually see, then names the cause and the fix. All of them were hit live in
this repo; the dates are when.

Two neighbours, so you land on the right page:

- **A rule you must not break** while editing the Windows chain →
  [`windows-build-invariants.md`](windows-build-invariants.md).
- **A host that was never set up correctly** (rather than one that broke) →
  [`windows-host-setup.md`](windows-host-setup.md) for Windows,
  [`linux-host-setup.md`](linux-host-setup.md) for Linux.

> Several rows here point at *deeper* write-ups in
> [`windows-builds.md`](windows-builds.md) and its sibling pages. This page is
> the triage index: enough to recognise the failure and act, with a link when
> the full history matters.

## Contents

**Linux and cross-lane**

- [`exec format error` on a foreign-arch build](#exec-format-error-on-a-foreign-arch-build)
- [`no space left on device`](#no-space-left-on-device)
- [Stale downstream images](#stale-downstream-images)
- [`no active session` / `grpc: the client connection is closing` mid-chain](#no-active-session--grpc-the-client-connection-is-closing-mid-chain)
- [`registry_pin_ref` fails on a fresh push](#registry_pin_ref-fails-on-a-fresh-push)
- [Terminal freeze during a long build](#terminal-freeze-during-a-long-build)
- [LiteRT configure: `fatal: expected flush after ref listing`](#litert-configure-fatal-expected-flush-after-ref-listing)
- [`logging.sh: line NNN: action: unbound variable` instead of the real error](#loggingsh-line-nnn-action-unbound-variable-instead-of-the-real-error)
- [A fault-injection test passes and proves nothing (`grep` is ugrep)](#a-fault-injection-test-passes-and-proves-nothing-grep-is-ugrep)
- [`GENAI-BIND SKIP` reported green while the native binding is broken](#genai-bind-skip-reported-green-while-the-native-binding-is-broken)
- [The documented `GENAI_ALLOW_RISCV64` back-out does not reach the smoke](#the-documented-genai_allow_riscv64-back-out-does-not-reach-the-smoke)
- [An unresolved `NEEDED` in a library that nothing scans](#an-unresolved-needed-in-a-library-that-nothing-scans)
- [A prune step deletes the wheel a later step requires](#a-prune-step-deletes-the-wheel-a-later-step-requires)
- [The disk guard aims at the wrong number](#the-disk-guard-aims-at-the-wrong-number)
- [A renamed or dropped distro package kills a stage hours in](#a-renamed-or-dropped-distro-package-kills-a-stage-hours-in)
- [A from-source CPython silently drops an extension module](#a-from-source-cpython-silently-drops-an-extension-module)
- [The delete guard denies its own legitimate work](#the-delete-guard-denies-its-own-legitimate-work)
- [OpenCV: `std::complex` breaks on a shadowed `complex.h`](#opencv-stdcomplex-breaks-on-a-shadowed-complexh)
- [A smoke that never passed and always excused itself](#a-smoke-that-never-passed-and-always-excused-itself)
- [A trailing conditional fails the whole script](#a-trailing-conditional-fails-the-whole-script)
- [The copied Rust toolchain is the builder's arch](#the-copied-rust-toolchain-is-the-builders-arch)
- [A packaging script dies with no message](#a-packaging-script-dies-with-no-message)
- [A callee invoked in an `if !` condition runs with errexit off](#a-callee-invoked-in-an-if--condition-runs-with-errexit-off)
- [A checksum probe that cannot reach the server reads as "nothing to verify"](#a-checksum-probe-that-cannot-reach-the-server-reads-as-nothing-to-verify)
- [A soname with no map entry is resolved by an `apt-cache` prefix guess](#a-soname-with-no-map-entry-is-resolved-by-an-apt-cache-prefix-guess)

**Windows: the layer store (hcsshim)**

- [`hcsshim::ActivateLayer 0x20` on an AMD Radeon host](#hcsshimactivatelayer-0x20-on-an-amd-radeon-host)
- [`ExportLayer 0x3`, spawn flakes, `ExportLayer 0x70` — disk exhaustion in costume](#exportlayer-0x3-spawn-flakes-exportlayer-0x70--disk-exhaustion-in-costume)
- [`ExportLayer 0x3` at finalize of a heavy media layer, disk is fine](#exportlayer-0x3-at-finalize-of-a-heavy-media-layer-disk-is-fine)
- [Every RUN step reports `DONE 2841.2s` — the same number, whatever it runs](#every-run-step-reports-done-28412s--the-same-number-whatever-it-runs)
- [`hcsshim::ActivateLayer failed (0x20)` during build](#hcsshimactivatelayer-failed-0x20-during-build)
- [`ActivateLayer 0x20 "file used by another process"` on commit](#activatelayer-0x20-file-used-by-another-process-on-commit)
- [`ImportLayer ... (0xb7) "already exists"` — deterministic, burns the retry budget](#importlayer--0xb7-already-exists--deterministic-burns-the-retry-budget)
- [`ImportLayer ... (0xb7)` on the SAME chain-IDs across retries](#importlayer--0xb7-on-the-same-chain-ids-across-retries)
- [`failed to reimport snapshot` / `failed to write compressed diff` — the hcs-temp flake family](#failed-to-reimport-snapshot--failed-to-write-compressed-diff--the-hcs-temp-flake-family)
- [Finalize dies `unknown stream ID 9` on a Windows Update `.msu`](#finalize-dies-unknown-stream-id-9-on-a-windows-update-msu)
- [`exporting layers` prints nothing for 20+ minutes](#exporting-layers-prints-nothing-for-20-minutes)
- [A stage fails instantly with `exit code: 1` and zero container output](#a-stage-fails-instantly-with-exit-code-1-and-zero-container-output)

**Windows: container networking**

- [`Could not resolve host: github.com` seconds into the first downloading RUN](#could-not-resolve-host-githubcom-seconds-into-the-first-downloading-run)
- [`The remote name could not be resolved` — CNI nat subnet drift](#the-remote-name-could-not-be-resolved--cni-nat-subnet-drift)
- [nerdctl DNS failure in build](#nerdctl-dns-failure-in-build)

**Windows: buildkitd and the store**

- [A BK compile step freezes silently after `[output clipped, log limit 2MiB reached]`](#a-bk-compile-step-freezes-silently-after-output-clipped-log-limit-2mib-reached)
- [`buildctl prune` returns `Total: 0B` no matter what you pass](#buildctl-prune-returns-total-0b-no-matter-what-you-pass)
- [`buildctl` local export dies `file already closed` on a Windows rootfs](#buildctl-local-export-dies-file-already-closed-on-a-windows-rootfs)

**Windows: Stevedore and the docker service**

- [`cannot access containerd socket ... Zugriff verweigert` (non-admin)](#cannot-access-containerd-socket--zugriff-verweigert-non-admin)
- [`runtime "com.docker.hcsshim.v1" binary not installed`](#runtime-comdockerhcsshimv1-binary-not-installed)
- [`failed to create TTRPC connection`](#failed-to-create-ttrpc-connection)
- [Stevedore service won't start (1053 timeout)](#stevedore-service-wont-start-1053-timeout)
- [`error getting credentials - err: exit status 1`](#error-getting-credentials---err-exit-status-1)
- [`failed to extract layer ... failed to find link target` pulling servercore](#failed-to-extract-layer--failed-to-find-link-target-pulling-servercore)

**Windows: build content and toolchain**

- [Windows media build crawls; `Building with ninja -j2`](#windows-media-build-crawls-building-with-ninja--j2)
- [Rust smoke test: "rustup could not choose a version of cargo/rustc"](#rust-smoke-test-rustup-could-not-choose-a-version-of-cargorustc)
- [A GitLab download "succeeds" with HTTP 200 but is a few KB](#a-gitlab-download-succeeds-with-http-200-but-is-a-few-kb)
- [`TVM: llvm-config.exe not found on PATH`](#tvm-llvm-configexe-not-found-on-path)
- [`TVM: no member named 'matchIntrinsicSignature' in namespace 'llvm::Intrinsic'`](#tvm-no-member-named-matchintrinsicsignature-in-namespace-llvmintrinsic)
- [`lld-link: error: undefined symbol` for template instantiations after a green compile](#lld-link-error-undefined-symbol-for-template-instantiations-after-a-green-compile)
- [meson cross: `Summary section 'Build environment' already have key 'host cpu'`, then `Subproject "subprojects/glib" required but not found`](#meson-cross-summary-section-build-environment-already-have-key-host-cpu-then-subproject-subprojectsglib-required-but-not-found)
- [Windows base: scoop cannot install a pinned tool, 404 on the installer](#windows-base-scoop-cannot-install-a-pinned-tool-404-on-the-installer)
- [AArch64 cross compile aborts with `error: fixup value out of range`](#aarch64-cross-compile-aborts-with-error-fixup-value-out-of-range)
- [A source build produces UNPATCHED sources and says `SKIP: ... (already applied)`](#a-source-build-produces-unpatched-sources-and-says-skip--already-applied)
- [`atlbase.h` not found when building LLVM in the container](#atlbaseh-not-found-when-building-llvm-in-the-container)
- [A build script dies with `The term ... is not recognized`, in the container only](#a-build-script-dies-with-the-term--is-not-recognized-in-the-container-only)


---

## Linux and cross-lane

### `exec format error` on a foreign-arch build

**Symptom.** `exec format error`

**Cause.** QEMU/binfmt not registered after host reboot

**Fix.** `linux/scripts/setup-rootless-binfmt.sh` — NOT the tonistiigi container: that installs into the wrong namespace under rootless nerdctl (see *Host prerequisite: QEMU/binfmt* in `docs/linux-cross-builds.md`; this row prescribed exactly that dead-end until 2026-08-24)

### `no space left on device`

**Symptom.** `no space left on device`

**Cause.** Disk full from cached images/artifacts

**Fix.** In order: (1) `linux/host-config/prune-safe.sh` (spares compile caches), (2) `nerdctl rmi` of specific already-pushed tags, (3) `nerdctl system prune -a -f` ONLY with no chain running — it deletes ALL non-container-referenced images INCLUDING tagged cross-stage locals (bit us mid-run 2026-08-18; registry-pinned handoffs survived via re-pull)

### Stale downstream images

**Symptom.** Stale downstream images

**Cause.** Base image rebuilt but downstream not refreshed

**Fix.** Use `--verify-chain` or rebuild from replaced stage

### `no active session` / `grpc: the client connection is closing` mid-chain

**Symptom.** `no active session` / `grpc: the client connection is closing` / `DeadlineExceeded` mid-chain (cache reads, layer export, pushes)

**Cause.** buildkitd session rot after ~1-2 h of parallel load (BKD1, bit 6× on 2026-08-19/20)

**Fix.** Let the worker retries absorb one-offs; on a repeat: stop chain → `systemctl --user restart buildkit.service` → relaunch (cache mounts provably survive; builds fast-forward)

### `registry_pin_ref` fails on a fresh push

**Symptom.** `registry_pin_ref` fails on fresh push

**Cause.** Registry hasn't propagated the new manifest

**Fix.** Now uses `retry()` with 5 attempts; wait a few seconds and retry

### Terminal freeze during a long build

**Symptom.** Terminal freeze during long build

**Cause.** Build output overwhelms terminal

**Fix.** Use `setsid` / `disown` for very long builds

### LiteRT configure: `fatal: expected flush after ref listing`

**Symptom.** Every LiteRT/TFLite cmake configure fails cloning eigen; all three android lanes down inside one window (2026-08-21)

**Cause.** `tools/cmake/modules/eigen.cmake` declares a single `GIT_REPOSITORY` (`gitlab.com/libeigen/eigen`), so a momentary gitlab outage is a total outage

**Fix.** Already handled by `linux/scripts/03-media/build/litert/android/litert-eigen-fetch.sh`, sourced by both LiteRT build scripts. It sets two knobs of upstream's `OverridableFetchContent` and pins no commit of its own (the tag stays upstream's):

- `GIT_REPOSITORY_AND_TAG_TO_URL_eigen=ON` turns the clone into an archive download of the *same* pinned commit — how the C-API/wheel configure paths already fetch it;
- `<content>_MATCH`/`_REPLACE` rewrite that archive URL. A `;` in the replacement makes it a cmake **list**, which `ExternalProject` downloads "in turn until one succeeds".

The second URL is TensorFlow's own mirror of the same gitlab path (the `tf_mirror_urls()` rule in `third_party/eigen3/workspace.bzl`), verified byte-identical on 2026-08-23: both URLs for commit `ea13a98d…` returned sha256 `35c6126e…`, 2870994 bytes. It degrades safely — if the regex ever stops matching, the URL is left untouched and the fetch behaves as it does today.

### `logging.sh: line NNN: action: unbound variable` instead of the real error

**Symptom.** A build stage dies and the only diagnostic in the log is
`.../01-core/logging.sh: line 119: action: unbound variable`. The command that
actually failed is nowhere. Hit on 2026-08-30, where it stood in for a
parallel-GCC apt-lock failure.

**Cause.** `_install_trap` defined `on_err` as a NESTED function that read its
reporting action (`err` or `warn`) out of the installer's own `local action` —
i.e. through **dynamic scope**, which only resolves while `_install_trap` is
still on the call stack. An ERR trap fires long after the installer has
returned, so under `set -u` the handler aborted on its first line. Two things
were lost, not one: that abort **replaced** the real error text, and the action
it existed to run never ran — `install_err_trap` never exited 1 and
`install_warn_trap` never printed. Every script that sources `logging.sh`
inherited it.

**Fix.** Fixed 2026-08-31. `on_err` is a top-level function, and `_install_trap`
bakes the resolved action into the trap string with `printf -v '%q'` so it is
expanded AT INSTALL TIME, while `LINENO` and `BASH_COMMAND` stay escaped and
expand AT FIRE TIME (reverse that escaping and every failure is reported at the
install site's line number, forever). `_LOG_TRAP_ACTION` keeps the two-argument
call working for `build-gcc.sh`, which tears the trap down and re-arms the bare
string by hand around its configure step. Regression cover:
`linux/scripts/tests/test-logging-err-trap.sh`. **Behaviour note:** inside a
`set +e` window `install_err_trap` now exits 1 where it used to print noise and
carry on. No caller has such a window today; a new one would feel it.

### A fault-injection test passes and proves nothing (`grep` is ugrep)

**Symptom.** A regression suite is green — and stays green when you break the
very thing it guards. Its fault-injection arm (a stub that fails when its argv
matches a pattern) never fires, and nothing reports that: a pattern matching
nothing looks exactly like a run with no fault injected.

**Cause.** The pattern began with `--` and was handed to `grep` positionally.
`grep` on this host is **ugrep**, which parses a leading-`--` pattern as a
command-line option instead of as the pattern. Found 2026-08-31 in
`linux/scripts/tests/test-iree-wheelhouse-stages.sh`, whose header claimed five
`|| return 1` call sites were covered when two were.

**Fix.** Pass the pattern behind `-e`: `grep -qE -e "$pat"`. The general rule —
a regression test has to be SHOWN to go red before it counts, and its header
must say what it does not cover — is in
[`cross-build-verification.md`](cross-build-verification.md#the-linuxscriptstests-suites),
along with the second half of this same incident: with injection finally
working, the obvious `rc == 1` assertion still passed on every mutation.

### `GENAI-BIND SKIP` reported green while the native binding is broken

**Symptom.** The runtime-image smoke prints
`GENAI-BIND SKIP: onnxruntime_genai is not installed` and the run stays green —
on an image where that wheel IS installed and only its native library refuses to
load.

**Cause.** The smoke collapsed two unrelated situations into one exit code
(3 = skip): "this arch ships no genai wheel", which is benign and is the
ARCH-PARITY table's business, and "the distribution is installed but importing
it raises", which is a defect. Nothing else in the chain can see the second one:
`smoke-torch-venv.sh`'s `installed_version()` falls back to
`importlib.metadata` when the import raises, so it cheerfully reports the pinned
version of a package that cannot be imported, and the ARCH-PARITY table reads
only dist-info directory names. A riscv64 binding with an unresolved
`__atomic_*` or a missing `NEEDED` would have shipped behind three green gates. The
lane this was found on is written up in
[`gen1-riscv64-genai.md`](gen1-riscv64-genai.md).

**Fix.** Fixed 2026-08-31 in `smoke_genai_py` (`06-packaging/smoke-common.sh`):
on an import failure the program asks `importlib.metadata` whether the
DISTRIBUTION is present. Present → exit 1 with
`GENAI-BIND FAIL: … is INSTALLED but not importable`, pointing at the `.so`'s
NEEDED/undefined symbols; absent → the SKIP. Transferable form: an exit code
meaning "there was nothing to test" must not be reachable from a state meaning
"the thing under test is broken".

### The documented `GENAI_ALLOW_RISCV64` back-out does not reach the smoke

**Symptom.** A lane toggle is set in `versions.env`, the build honours it, and
the runtime-image smoke still reddens by asserting the component the toggle
switched OFF. Exporting the variable in the host shell before running the smoke
changes nothing.

**Cause.** Two boundaries, and the value crossed neither of them. As far as the
host shell is concerned a `nerdctl run` begins with an empty environment, so
exporting the toggle before the smoke is invisible inside the container. And the
ARG/ENV that carries it is declared on a BUILDER stage, while the final stage of
`Dockerfile.media` descends from a different parent — so the shipped image holds
no copy of it either. The baked `smoke-torch-venv.sh` therefore read the toggle
as unset every time and took its default arm: the escape hatch the docs promised
had never once worked. Depth on this particular toggle:
[`gen1-riscv64-genai.md`](gen1-riscv64-genai.md).

**Fix.** Fixed 2026-08-31: `smoke-runtime-image.sh` reads the value host-side
out of `versions.env` (`_rt_versions_env_pin`, empty on a miss = "not asserted")
and forwards it with an explicit `-e` on the `nerdctl run`, so the smoke asserts
the policy the build was configured with. **A new toggle has to be checked on
both hops** — build ARG into the SHIPPED stage, host env into the container —
and a verifier should read a marker the producer actually wrote rather than
re-derive the decision: a producer defaulting `:-false` against a verifier
defaulting `:-true` disagrees in the failing direction.

### An unresolved `NEEDED` in a library that nothing scans

**Symptom.** Nothing at all, which is the point. A shipped `.so` carries a
dependency that cannot be resolved, every gate is green, and the failure surfaces
as an import or `dlopen` error on the target.

**Cause.** `03-media/runtime/validate-media-runtime.sh` hunts unresolved
`NEEDED` entries over `ARTIFACTS` (the gst / libcamera / ffmpeg binaries) plus
the GStreamer plugin directory. Its `LIB_DIRS` sweep is a DIFFERENT check — ELF
**machine** only, and advisory. An install prefix in neither list is scanned by
nobody; `/usr/local/lib/onnxruntime-genai/lib` was in neither until 2026-08-31.
The concrete thing that hid behind it: GenAI's CMake, unlike upstream
onnxruntime's, carries no libatomic probe, so a riscv64 build can need
`-latomic` and only say so at load time. That lane:
[`gen1-riscv64-genai.md`](gen1-riscv64-genai.md).

**Fix.** Fixed 2026-08-31 — the prefix joined `LIB_DIRS` (resolution root plus
the advisory arch sweep) AND its `lib/` is now walked by `scan_plugin_directory`
(misnamed but generic, so it was reused rather than copied), feeding the
existing missing-soname machinery. A `[ -d ]` guard makes it a no-op when the
lane is off. **The check to carry away:** when an image gains an install prefix,
ask which scanner covers it — and remember that an ELF-machine sweep is not a
dependency scan.

### A prune step deletes the wheel a later step requires

**Symptom.** Again nothing yet — the step that would have broken was disarmed by
an unrelated accident. `install_project_environment` prunes conflicting wheels
before `build_uv_sync_args` goes looking for the local ones, and one prune glob
matched a wheel the later step requires.

**Cause.** `03-media/runtime/assemble-torch-app.sh`'s
`prune_conflicting_onnx_wheels` carried a `*genai*.whl` glob on its DEFAULT
`ONNX_PACKAGE=onnxruntime` arm. Far too broad: it also names the plain CPU genai
wheel this media lane now produces for every architecture, which the uv-sync
step and the ARCH-PARITY table both rely on being present. Had the deletion
succeeded, the earlier GENAI-DRIFT bug would have returned — absent a local
wheel, the resolver quietly prefers the app lock's PyPI build. It survived only
because `/opt/wheels` happens to be mounted read-only, so the removal errored and
`|| true` discarded that error; flipping the mount to writable would have broken
all three architectures at once. Full narrative:
[`gen1-riscv64-genai.md`](gen1-riscv64-genai.md).

**Fix.** Fixed 2026-08-31 by narrowing the glob to the GPU-flavoured variants
the arm actually means (`*genai_cuda-*`, `*genai_rocm-*`, `*genai_directml-*`),
beside its `*_gpu-*` / `*_migraphx-*` neighbours. **The lesson is about `|| true`
on a destructive step:** it hides the failure AND the fact that the step was
wrong, so the bug sits latent until something unrelated arms it — here, a
read-only mount becoming writable.

### The disk guard aims at the wrong number

**Symptom.** The chain prunes at 40G free between stages, reports success, and the
NEXT stage refuses anyway: `[ERROR] runtime lane refused: 56G free, ~120G needed`
(2026-09-02: six manual prunes; 2026-09-03: the Flutter ship build, attempt 1).

**Cause.** Two different numbers. `CROSS_DISK_GUARD_GB` (40) is a floor for *this*
stage; the runtime lane needs `CROSS_RUNTIME_LANE_GB` (120) per wrapper build, and
`--only runtime` additionally pulls the three `cross-android-<arch>` images
(~40G uncompressed each) as its artifact source. A guard that reclaims to a fixed
floor is therefore satisfied exactly when the lane is not.

**Fix.** `_chain_stage_disk_guard` in `build-cross-chain.sh` reclaims to what
comes *next* (`_chain_runtime_lane_need_gb`), and the launch-time preflight warns
when the run will enter the lane with less than stage cost + lane need.

**When the guard reclaims nothing.** `buildctl du` showing every regular record
`Reclaimable: false` is not a full cache — it is killed chains' leaked *leases*
(2026-09-03: 351 records / 251 GB pinned, `prune-safe.sh` freed 0). Leases die
with the daemon: `systemctl --user restart buildkit.service` (no build running),
then `PRUNE_KEEP_GB=<N> linux/host-config/prune-safe.sh`. `--keep-storage` bounds
the WHOLE store, and the non-candidates (cache mounts ~166G + `source.local` ~10G)
count toward it, so N below ~180 prunes every regular record. Local
`:latest-cross-<arch>` images are re-pullable and not build inputs; `nerdctl rmi`
them last. Restarting the daemon is the BKD1 remedy above wearing a disk costume.

### A renamed or dropped distro package kills a stage hours in

**Symptom.** A media or toolchain stage dies four hours into a rebuild with
`E: Unable to locate package <name>` — or, worse, does not die: an
`install_target_packages ... || true` swallows it and the feature silently
vanishes from the shipped image.

**Cause.** Ubuntu renames and drops binary packages between releases, and this
tree pins a rolling one (`UBUNTU_CODENAME` in `versions.env`). 26.04 renamed
`libfreetype6-dev` to `libfreetype-dev`, replaced `libopenexr-3-dev` with
`libopenexr-dev`, and `libvvdec-dev` never existed on ports at all. Nothing
noticed for months because warm apt caches still answered for the old names —
the tree was un-buildable from scratch and no one knew, because nothing ever
built from scratch.

**Fix.** `linux/scripts/verify_package_names.py`, wired into `preflight.sh` as
the `pkg-names` check. It extracts every distro package name **`linux/scripts/**`**
asks for and resolves each against the live Ubuntu indices for the pinned codename —
`archive.ubuntu.com` for amd64, `ports.ubuntu.com` for arm64/riscv64 — before a
build starts rather than four hours in.

What it reads, and how a verdict is reached:

- Sources: `install_target_packages` / `install_optional_target_packages` /
  `install_host_packages` / `install_deps_preamble` / `apt_install` call sites,
  bare `apt-get install` lines, `*_packages` and `*_pkgs` array literals,
  `append_unique_packages` / `append_available_packages` in
  `01-core/package-lists.sh`, the `_CPYTHON_EXT_DEV_PKG_TABLE` rows in
  `01-core/cpython-dev-packages.sh`, and the soname map at
  `03-media/runtime/so-package-map.txt`. Names occur one-per-line AND
  several-per-line; a per-line assumption is how an earlier audit reported the
  wrong count, so `--list` prints exactly what was extracted.
- **UNGUARDED** requests FAIL the gate: a missing name aborts the whole apt
  transaction and kills the stage. **GUARDED** ones (`|| true`, a `||`
  fallback chain, a self-filtering helper, an enclosing apt probe) only WARN —
  the cost there is one wasted apt round-trip per run, not a dead build.
- A name apt can still install through `Provides:` counts as present but is
  reported: a virtual name disappears the next time the provider is renamed.
- Names from a non-Ubuntu repo (NVIDIA/ROCm/TensorRT) are UNVERIFIABLE, never
  dead; that file list lives in the script.
- An array no installer ever consumes is reported as unchecked, not silently
  dropped — that is what keeps sdkmanager component lists out of the verdict.
- **Not covered:** package names written directly in a `Dockerfile` RUN
  (`Dockerfile.toolchain`'s `binutils-dev` is the only one today), and anything
  a script assembles at runtime rather than spelling out.

**Offline is a SKIP, never a pass.** Indices are cached per codename with a
6h TTL (`PKG_NAMES_TTL`, `PKG_NAMES_CACHE_DIR`): ~13s cold, ~1.5s warm. With no
network and no cache the check says so loudly and exits 0; with a stale cache it
verifies anyway and says the cache was stale.

**The transferable lesson.** The gate carries its own extraction self-check —
known package names that MUST be found (a several-per-line array row, a
backslash-continued call, a `package-lists.sh` helper) and decoys that must NOT
be (an sdkmanager component, a table column, a word from an `echo` string). Break
the extractor and the check exits 2 before it ever reports green. A gate whose
input extraction can silently degrade to nothing is the failure this repo keeps
re-learning; a scanner has to prove it is still scanning.

### A from-source CPython silently drops an extension module

**Symptom.** `import ssl` / `import sqlite3` / `import lzma` raises
`ModuleNotFoundError` inside a shipped image, or an interactive `python3` has no
line editing. The toolchain stage was green: `make -k || true` skips an extension
whose dev header was missing at configure time and says so only in passing.

**The 2026-08-09 incident** was `libsqlite3-dev`: the host closure got sqlite
transitively through GUI dev packages, the cross-target install list forgot it,
and half the Python ecosystem imports `sqlite3` on the way to something else.

**One table, two consumers.** `01-core/cpython-dev-packages.sh` holds every row
as `<dev-package> <required|optional> <ext-module>...`, and nothing else may keep
a second list:

| consumer | reads | verdict |
| --- | --- | --- |
| `package-lists.sh base_image_os_packages` | `cpython_ext_dev_packages` | the HOST closure installs the same set |
| `build_python.sh _python_cross_stage_target_dev_pkgs` | `cpython_ext_dev_packages` + `cpython_ext_dev_packages_required` | one atomic apt install, then a per-package `dpkg-query`; a missing REQUIRED package is **fatal** |
| `build_python.sh _python_cross_fixup_libdynload` | `cpython_ext_modules` | audits the staged `lib-dynload`; a missing `.so` **warns**, on every row |

The class column therefore governs the *package*, not the `.so`. The audit is
warn-only on purpose: promoting the required rows to fatal there flips all three
arches at once and only a cross rebuild can price that, so the decision stays
open rather than being smuggled in with a refactor. Until 2026-09-05 the audit
carried its own hand-written array instead — seven modules that had never gained
`readline` after LOG23 added it to the table, which is the same desync in
miniature.

**The parsing trap.** `build_python.sh` runs under `IFS=$'\n\t'`, where an
unpinned `read` does not split on spaces: a row naming two modules
(`libssl-dev required _ssl _hashlib`) would arrive as one word and the audit
would look for an extension called `_ssl _hashlib`. Every accessor in the table
file pins `IFS=' '` on its `read` for exactly that reason, and
`tests/test-cpython-ext-table.sh` runs each one under both values of `IFS`.

**What only a real build shows.** Whether the five modules the audit gained on
2026-09-05 (`_zstd`, `readline`, `_curses`, `_uuid`, `_decimal`) actually land in
`lib-dynload` on arm64 and riscv64. They are `optional` rows: a warning there is
information, not a failure, and the toolchain smoke's own stdlib battery is what
turns a genuinely broken interpreter red.

### The delete guard denies its own legitimate work

`.claude/hooks/guard-destructive-deletes.py` matched a delete VERB and a
PROTECTED PATH independently, anywhere in the command. So any command that both
deleted something harmless and merely *mentioned* a system path was denied:

```
rm -rf scratch && cc -o x /opt/gcc-16.2.0/bin/gcc     # denied: "a system directory"
```

The `/opt` here is a compiler, not a delete target. This fired five times on
2026-09-02 against a scratch directory under the job tmpdir, each time costing a
tool call and a rewrite. Two earlier variants of the same shape are recorded in
the file's own header: `--rm` matching `\brm\b`, and `sed 's/^/  /'` reading as
the filesystem root.

**The fix.** Split the command on `;`, `&&`, `||`, `|` and newlines, and run the
protected-path patterns only on the segments that actually carry a delete verb.
A preceding `cd` target is carried into later segments, so `cd /usr && rm -rf *`
still denies — the relative delete cannot escape the directory it was given.

**The transferable lesson.** A guard whose two halves are matched independently
across a whole command is not checking a relationship, it is checking
co-occurrence. Co-occurrence guards look strict and behave randomly: they deny
safe work and, worse, teach the operator to phrase commands to avoid the guard
rather than to be safe. Bind the dangerous verb to its own argument. Both
directions are mutation-tested in `test-delete-guard.sh` — widening the scope
back to the whole command turns the allow-cases red, and dropping the `cd`
tracking turns the deny-cases red.

### OpenCV: `std::complex` breaks on a shadowed `complex.h`

The riscv64 `opencv-gst` stage dies compiling `modules/core/src/hal_internal.cpp`:

```
error: expected unqualified-id before '_Complex' [-Wtemplate-body]
  540 |     int ldsrc1 = (int)(src1_step / sizeof(std::complex<fptype>));
```

The caret sits on `complex` inside `std::complex`, because `complex` is a macro
by then. `hal_internal.cpp` includes the **C** header at line 50, under
`HAVE_LAPACK`, and `precomp.hpp` has already pulled in `<complex>` — so the class
is declared correctly and only later *uses* of the token expand.

In C++, `<complex.h>` is supposed to reach libstdc++'s wrapper, which includes
glibc's header and then removes the damage:

```c
# include_next <complex.h>
# ifdef _GLIBCXX_COMPLEX
#  undef complex          // <- the guarantee
# endif
```

glibc's own `/usr/include/complex.h` has `#define complex _Complex` with no
`__cplusplus` guard, so whoever wins the lookup decides whether C++ still works.
CMake passes OpenCV `-isystem /usr/include`, and `-isystem` is searched before
the compiler's C++ directories — so glibc's header wins and the `#undef` never
happens. Measured with the riscv64 cross g++:

| flags | `<complex.h>` resolves to | `complex` macro |
| --- | --- | --- |
| none | `…/riscv64-linux-gnu/include/c++/16.2.0/complex.h` | not defined |
| `--sysroot=/ -isystem /usr/include` | `/usr/include/complex.h` | `#define complex _Complex` |

Reproduced in three lines — `#include <complex>`, `#include <complex.h>`, then
one `std::complex<float>` — and it fails on every target compiler once the flag
is present, so this is not architecture-specific in nature.

**The fix.** `build-opencv.sh` writes a two-branch `complex.h` shim next to the
source tree and prepends it with `-I`. GCC searches every `-I` before every
`-isystem`, so the shim wins regardless of what CMake appends — the same
precedence trick the file already uses to pin our FFmpeg prefix. The shim
restores libstdc++'s behaviour in C++ and is a transparent pass-through in C,
which matters because the same flag string is handed to both `CMAKE_C_FLAGS` and
`CMAKE_CXX_FLAGS` (OpenCV compiles C third-party code such as openjp2 that
legitimately wants the `complex` macro).

**Why it surfaced only now.** It is not a regression. The previous run never
compiled this file: libcamera failed earlier on an unrelated link error, and
BuildKit builds those stages in parallel, so the whole lane died first. Fixing
libcamera let the build get far enough to reach a defect that was always there.

**Still open:** *which* CMake package contributes `-isystem /usr/include` on
riscv64 and not on the other lanes. `ZLIB_INCLUDE_DIR=/usr/include` is passed on
every cross arch and all three resolve zlib identically, so that alone does not
explain it. The shim makes the build immune either way; the injector is worth
finding so the flag can be removed at the source.

### A smoke that never passed and always excused itself

`validate-media-runtime.sh` carried a "QEMU Cross-Arch Binary Smoke" that ran
each built binary under qemu-user and, on failure, printed:

```
WARN: /usr/bin/qemu-riscv64 gst-launch-1.0 --help failed
      (may be expected for cross builds without full sysroot)
```

Three things were wrong with it at once, and each alone would have been enough:

- **Both branches were `echo`s.** No counter, no variable, no exit code — there
  was no path from that loop to a failure. The ELF block directly above it does
  it properly: it counts `core_mismatches` and `exit 1`s.
- **The excuse covered every case it could ever see.** The block only ran under
  `cross_build_is_active`, so "may be expected for cross builds" applied to
  100% of its invocations. That is not a diagnosis, it is a blanket.
- **The failure was mechanically guaranteed.** qemu-user needs the target's
  `ld.so` and libraries via `-L` or `QEMU_LD_PREFIX`; neither was passed, and
  `QEMU_LD_PREFIX` appears nowhere in the repo. Every binary died in the dynamic
  loader before `main` — exactly the "full sysroot" the message names, which
  makes it a fixable bug, not an expected condition.

Final score before removal: **7 failures, 0 passes**, across arm64 and riscv64
in one run.

**Removed rather than repaired, 2026-09-02.** Repairing it needs a multi-hour
media build to prove the sysroot prefix actually works, and shipping an
unproven-but-now-fatal gate is how you lose the next run. Functional coverage
already exists where it belongs: the runtime-image smoke boots the real per-arch
image and gates the manifest on it — that is what caught the riscv64 venv gap
the same day.

**The transferable lesson.** A check whose failure branch is always excused
teaches its readers that WARN lines are noise, which is worse than having no
check: it costs attention on every run and buys nothing. When you find one, the
question is not "how do I make this pass" but "what would it take to make this
able to fail" — and if you cannot answer that today, delete it and say where the
real coverage lives.

---

### A trailing conditional fails the whole script

The 2026-09-03 runtime build died on amd64 in `setup-torch-venv.sh` with
`exit code: 1` and no error text — the last lines were a healthy
`uv pip install --no-deps ml_dtypes` / `Checked 1 package in 2ms`. The cause was
one line at the END of `reconcile_local_wheels` in `assemble-torch-app.sh`:

```bash
  [ "${have_torch_family}" = "true" ] && _backfill_torch_runtime_deps
}
```

A function returns the status of its last statement. With no local torch wheel
(every amd64/arm64 build — torch comes from `uv sync` there) the test is false,
the `&&` list is `1`, so the function returns `1`; the caller runs under
`set -euo pipefail` and exits. Nothing printed anything, because nothing had
failed in the ordinary sense. riscv64, the only arch WITH a local torch wheel,
was the only arch that would have passed.

Two things let it through:

- **`set -e` is not tripped by the list itself.** `a && b` is exempt from
  `-e`, which is why the idiom feels safe; the trap is only that its status
  becomes the function's status, and the bare call `reconcile_local_wheels`
  in the caller is NOT exempt.
- **The characterisation test ran without `set -e` and never looked at `$?`.**
  It pinned the sequence of `uv` calls the function makes (its stated purpose)
  and so proved the refactor behaviour-preserving for every path — including
  the path that now returned `1`, because a return status is not a `uv` call.

Fix: an `if ... fi` (or `|| true` when the right-hand side is genuinely
optional). The test harness now runs the function under `set -eu` and asserts
`0` for a non-torch wheel set; against the broken revision that case fails
(`expected '0', got '1'`).

**Where else this hides.** A census of `cond && cmd` as the last statement
before a closing brace finds 17 sites in the tree; almost all are deliberate
*predicates* (`[ -n "${_t}" ] && [ "${_t}" != "${_b}" ]`) whose callers use them
in `if`/`||`. The bug shape is narrower: an *action* on the right-hand side and
a *bare* call site under `set -e`. A regex on the function alone cannot tell the
two apart, which is why this is a call-site check
(docs/code-quality-tooling.md, planned gate `trailing-and`), not a pattern ban.
Until it exists: a function-level test must assert the exit status on the
"nothing to do" path, not only the calls it makes.

### The copied Rust toolchain is the builder's arch

**Symptom.** The arm64 package stage dies with `exit code: 127` and *no*
`command not found` line — the last output is `Keeping existing
/usr/local/cargo/bin/rustup (rustup toolchain wins over PATH lookup)`
(2026-09-03). In the shipped `:latest-cross-arm64` of 2026-09-01:

```
$ rustc --version
bash: /usr/local/cargo/bin/rustc: cannot execute: required file not found
$ ls /usr/local/rustup/toolchains
1.98.0-x86_64-unknown-linux-gnu  nightly-2026-06-28-x86_64-unknown-linux-gnu
$ du -sh /usr/local/rustup      # 2.0G
```

**Cause.** `Dockerfile.package` COPYs `/usr/local/{rustup,cargo}` from
`artifact-source`, and artifact-source is the **amd64 host** image of the
cross chain (`--platform=${ARTIFACT_PLATFORM}`). Everything else it copies is a
*target* tree (a cross-built `/opt/gcc-<v>`, `/opt/llvm-target`, `/opt/opencv5`),
but the Rust toolchain there is the builder's own x86_64 install with
`aarch64`/`riscv64gc` *targets* added — that is what a cross-compiler needs and
exactly what a native arm64 image cannot run. Every arm64/riscv64 runtime image
shipped 2 GB of dead x86_64 binaries at the front of `PATH`
(`/usr/local/cargo/bin` precedes `/usr/bin`), so `cargo` was broken rather than
falling back to Ubuntu's.

**Why nothing caught it.** Three layers, each blind in its own way:

- `wire_cargo_symlinks` checked `-x` (true for a foreign ELF) and kept the shims.
- `report_rust_provenance`'s hard gate reads `RUST_VERSION`, which did not reach
  the script until 7eca29c6 (2026-09-03) — the day it started running was the
  day it failed. Before that: `NOTE: RUST_VERSION unset; cannot verify`.
- The runtime smoke's ADV/HAVE table (`_advert_verdicts`) turned an *unreadable*
  actual value into `SKIP`, so `rustc --version` failing under `2>/dev/null` was
  reported as "could not read", not as a mismatch. That arm is fatal since
  2026-09-04 (`UNREAD`); see docs/cross-build-verification.md, gate A.

**Why 127 with no message.** `_got="$("${CARGO_HOME}/bin/rustc" --version
2>/dev/null | awk …)"`: the loader's `cannot execute` goes to `/dev/null`,
`pipefail` propagates rustc's 127 through `awk`, and `set -e` exits on the
assignment. The pattern is fine for a probe whose result is *tested*; it is not
fine when the probe's failure is itself the fault.

**Fix.** `setup-package-image.sh` `ensure_native_rust_toolchain` (before
`wire_cargo_symlinks`): if `${RUSTUP_HOME}/toolchains/` holds no
`*-<own triple>` dir, wipe both trees and run the same `install-rust.sh` the
toolchain stage uses, with `BUILD_MODE=native` and `RUST_INSTALL_CARGO_C=0`
(compiling cargo-c under QEMU would cost an hour; the `cargo-c` apt package is
what `wire_cargo_symlinks` links in that case — one minor version behind the
pin, an accepted skew). amd64 is a no-op: the copied toolchain *is* native
there. The native install downloads the pinned stable + clippy + rustfmt +
`wasm32-unknown-unknown` and the pinned nightly, same set as amd64, so the
three arches ship the same toolchain surface.

**Guards.** `check_rust_toolchain` in `smoke-runtime-image.sh` executes
`rustc --version` in the shipped image, requires the `RUST_VERSION` pin, reads
the active toolchain's host triple (`rustup show active-toolchain`) and requires
`cargo-cbuild` — it fails on the 2026-09-01 image
(`tests/test-runtime-image-gates.sh`). The same class applies to any *host*
tree copied from artifact-source: `/opt/flutter` on arm64 is the x86-64 SDK
too (`setup-flutter.sh`), which `check_flutter` exercises the same way. The
general audit for that class is `check_manifest_tree_arch`: it reads the ELF
machine of everything under every tree in `runtime-artifacts.manifest` and fails
when a foreign image carries builder-arch objects —
docs/artifact-copy-completeness.md#the-shipped-trees-must-carry-the-images-own-arch

---

### A packaging script dies with no message

**Symptom.** A `Dockerfile.package` / `Dockerfile.torch` RUN ends with
`did not complete successfully: exit code: N` and the last line of output is an
ordinary progress line. Nothing names a command, a line, or a reason. Seen
twice in the 2026-09-03 18:13 run: the arm64 package stage (`exit code: 127`,
last line `Keeping existing /usr/local/cargo/bin/rustup`) and the amd64 torch
stage (`exit code: 1`, last line `Checked 1 package in 2ms`).

**Cause.** `set -e` exits silently by design. The three image-side scripts —
`setup-package-image.sh`, `setup-torch-venv.sh`, `assemble-torch-app.sh` — are
several hundred lines of small functions, so the failing command can be any of
them, and the usual suspects say nothing on the way out:

* a command substitution under `pipefail` whose stderr is discarded
  (`_got="$(rustc --version 2>/dev/null | awk …)"` — an unrunnable foreign-arch
  `rustc` produces exit 127 and not one byte of output);
* a helper whose last command is a failed test, which becomes the helper's own
  return value (see *A trailing conditional fails the whole script*);
* any `uv`/`git` call that fails with its diagnostics already consumed.

**Fix.** The three scripts run `set -Eeuo pipefail` and `install_err_trap`
(`01-core/logging.sh`), so a `set -e` death now prints
`[ERROR] Command failed (line N): <the command>` before it exits. `-E` is the
load-bearing flag: without `errtrace` the trap is not inherited by shell
functions, which is where all the work happens. `Dockerfile.torch` COPYs
`logging.sh` into `/opt/scripts/core/` for this.

The probe that produced the arm64 127 also names its own failure now: an
unrunnable `${CARGO_HOME}/bin/rustc` reports `does not execute` and points at
`ensure_native_rust_toolchain`.

**Reading it.** The trap reports the line of the *failing command*, not of the
caller. Match it against the script in the image
(`nerdctl run --rm <image> sed -n '<N>p' /opt/scripts/packaging/…`), because the
line numbers move with every edit to the file.

### A callee invoked in an `if !` condition runs with errexit off

**Symptom.** A multi-hour builder fails, the chain carries on, and the stage
reports success. Nothing in the log says the exit code was thrown away.

**Cause.** Bash suspends `errexit` for the entire **dynamic extent** of a
command used as a condition — the callee's body, and everything it calls. So a
function written to rely on `set -e` for its aborts raises nothing when it is
reached through `if ! f …`, `f && …`, `f || …` or a condition-context
substitution. `gcc.sh:386` reaches `build_canadian_native_gcc_for` exactly that
way, and inside it the invocation of `build-gcc.sh` was a plain command: its
non-zero exit was discarded, and the missing native GCC only surfaced arches
later.

**Fix.** Inside such a function every failure has to be raised **explicitly**.
The builder invocation now ends `|| die "Canadian native GCC build FAILED for
…"`, and the two `[ -x … ]` checks on the produced `gcc`/`g++` die on their own
rather than through `errexit`. `tests/test-gcc-errexit-contract.sh` holds both
halves: one characterisation case that runs a real `bash -c` and records that
`if ! f` really does suppress `errexit` inside `f` — the mechanism, not our code
— and contract cases over `gcc.sh` itself asserting the explicit raises are
still there.

**The check to carry away.** Before trusting `set -e` inside a helper, grep for
how the helper is *called*. A guard that only works in the default context is
not a guard; it is a coincidence.

### A checksum probe that cannot reach the server reads as "nothing to verify"

**Symptom.** The build prints `No sha512.sum found on server; continuing.` and
goes green. The tarball it just unpacked was verified by nothing.

**Cause.** The GCC tarball is fetched **mirror-first** (`ftpmirror`) for speed,
while both proofs — `sha512.sum` and the detached `.sig` — exist only on
`gcc.gnu.org`. Verification was gated on a `wget --spider` probe of that host,
so *any* non-200 answer — outage, 5xx, DNS — took the "the server has no
checksum" branch and returned 0. The one event the mirror exists to survive was
also the event that silently disarmed the integrity check on the mirror's bytes.

**Fix.** In `build-gcc.sh`, an unreachable *or* absent `sha512.sum` now goes
through `_gcc_sha_unverified_or_die`, as does a `sha512.sum` that downloads but
carries no entry for this tarball; a `sha512.sum` that probes but fails to
download was already fatal. The `.sig` path routes through
`_gcc_gpg_require_or_warn`, so `GCC_REQUIRE_GPG=1` makes a missing signature
fatal too. `tests/test-gcc-tarball-verification.sh` extracts the helpers —
`build-gcc.sh` is a top-level script, so they cannot be sourced — and drives
each branch with the probe stubbed.

**The check to carry away.** "The proof was not reachable" and "there is no
proof" are different answers to different questions. Any verifier that maps the
first onto the second has stopped being a verifier at the moment it matters
most.

### A soname with no map entry is resolved by an `apt-cache` prefix guess

**Symptom.** Nothing visible. `validate-media-runtime.sh` reports a missing
soname as resolved, the media runtime installs *a* package, and the wrong (or
wrongly versioned) library ships.

**Cause.** Three hand-maintained truths claim to say which apt package provides
a media runtime library, and only one of them is reachable at build time:

1. the codec-lib baseline in `06-packaging/setup-torch-venv.sh` ::
   `_install_cv2_runtime_apt` — the torch stage's fallback install list when the
   ffmpeg manifest is absent;
2. the SONAME→package map `03-media/runtime/so-package-map.txt`, which
   `validate-media-runtime.sh` uses to resolve a missing soname deterministically;
3. `/opt/ffmpeg/runtime-apt-packages.txt` (`emit_runtime_apt_manifest` in
   `build-ffmpeg.sh`) — the ground truth, which exists only *inside* a built
   image, so no static check can reach it.

Where (2) has no entry, resolution degrades to `dpkg-query` and then to
`apt-cache search "^${base}[0-9]" | head -1` — an arbitrary first hit. And
`known_so_packages_load` is last-wins, so a duplicate soname naming a
*different* package is a silent override rather than an error. A baseline bump
(`libx265-215` → `libx265-2xx`) that forgets the map degrades exactly that one
library to guessing, and says nothing.

**Fix.** `tests/test-codec-so-map-convergence.sh` freezes the statically
checkable convergence of (1) and (2): the map is well-formed
(`SONAME<TAB>package`, `*` family keys allowed), no soname maps to two different
packages, and every versioned runtime lib package hardcoded in the baseline
appears as a mapping target. `KNOWN_UNMAPPED` is a **ratchet**, not an excuse
list — it records the divergence that already existed on 2026-08-24, because
inventing map entries would mean inventing sonames, and it fails in both
directions so the list can only shrink honestly. Truth (3) stays out of a static
test's reach; that is stated rather than papered over.

## Windows: the layer store (hcsshim)

### `hcsshim::ActivateLayer 0x20` on an AMD Radeon host

**Symptom.** Windows-container layer commit/finalize dies `hcsshim::ActivateLayer 0x20` on an **AMD Radeon host** (buildkit `failed to import/reimport snapshot`, on ANY layer writing into an existing parent dir; docker-classic legacy dies `mkdir \\?\Volume{<GUID>}\C:.` invalid dir name) — BOTH lanes, process AND Hyper-V isolation

**Cause.** **RESOLVED 2026-08-10: an ENABLED AMD RDNA4 dGPU (RX 9xxx + Adrenalin) locks freshly-written container layers** (upstream docker/for-win#14977, open; same-boot A/B-proven). Failed finalizes additionally WEDGE hcs state until a REBOOT (survives service bounces + vmcompute restart).

**Fix.** Probe with `probe-build-copy.ps1 -Heavy` (only a `-Heavy`-green verdict counts), then build inside the `toggle-rdna4-gpu.ps1 -Disable` window — `build-buildkit.ps1` enforces that via `Assert-NoActiveRdna4Gpu`. **After ANY red finalize, reboot before testing anything else**: a wedged host falsifies every later experiment. Full A/B history and the superseded 2026-08-09 verdict: [`windows-build-lanes.md`](windows-build-lanes.md#rdna4-dgpu-layer-lock-ab-history-and-diagnostics).

### `ExportLayer 0x3`, spawn flakes, `ExportLayer 0x70` — disk exhaustion in costume

**Symptom.** ANY weird hcsshim failure on the BK lane: `ExportLayer 0x3` (path not found) at finalize, spawn flakes (`'cmd.exe' is not recognized`), `ExportLayer 0x70` (disk full)

**Cause.** **Disk exhaustion in costume** — the bk image generations stack 30–40 GB per rebuild cycle; only 0x70 names the disease (all three hit on 2026-08-03)

**Fix.** Check free disk FIRST. `buildctl prune --all` + `docker image prune -f` (non-admin); bk-* image generations need admin. Full playbook: docs/windows-build-lanes.md § Store GC.

### `ExportLayer 0x3` at finalize of a heavy media layer, disk is fine

**Symptom.** BK lane, disk is FINE: `failed to reimport snapshot: hcsshim::ExportLayer ... (0x3)` at finalize of a heavy media layer (GenAI/OpenCV class) — deterministic, every fresh snapshot, both finalize paths, survives host reboot

**Cause.** **ROOT CAUSE FOUND & FIXED 2026-08-06: the runhcs shim's hardcoded `tearDownTimeout = 30s`** (`cmd/containerd-shim-runhcs-v1/task_hcs.go`) terminates the heavy-churn silo teardown mid-hive-flush (real duration: **117 s measured** for OpenCV), permanently poisoning the scratch vhdx. Calm exits (ONNX ninja, cpython, LiteRT, torch) finish teardown under 30 s and never tripped it.

**Fix.** Solved at the root by a patched runhcs shim, already deployed. **The part to remember is the maintenance:** every Stevedore/containerd update overwrites it, so `deploy-shim-patch.ps1 -ReportOnly` belongs in your post-update routine — `Assert-ShimPatch` gates the BK lane on it by SHA256 — and one OpenCV canary should follow any update. `0x3` is deliberately excluded from the driver's transient-retry pattern: it must fail loudly. Root cause, constants and the rollback path: [`windows-build-lanes.md`](windows-build-lanes.md#defect-solved).

### Every RUN step reports `DONE 2841.2s` — the same number, whatever it runs

**Symptom.** BK lane, since the 2026-08-31 15:12:59 boot: every RUN step on a `servercore` base finishes GREEN but takes **2841.2 s**, byte-identical across independent solves and independent of what the step does — `RUN echo probe > C:probe.txt` costs exactly as much as a real build step. Everything else in the solve is normal (COPY 5.1 s, export 1.7 s, unpack 5.2 s). Host is idle throughout: 4 % CPU, disk queue 0, no I/O.

**Cause.** **The container's shutdown/exit notification is lost, so the shim waits out its whole teardown timeout.** 2841.2 = ~141 s container boot + **2700 s = the 45 min `tearDownTimeout`** this repo patches in (`local-45min-deployed.patch`). The RUN itself *succeeds*: on a stuck container `docker logs` prints the command's own output and `docker top` shows no `cmd.exe` — the process ran and exited. Reproduced straight through **dockerd** (no shim, no buildkit), so it sits below both lanes in hcs/vmcompute — the Windows-Containers#547 family the entry above is about, but escalated from "filesystem-heavy containers only" to *every* container. `nanoserver:ltsc2025` starts and exits in ~2 s; only the servercore service stack is affected. Same shape of step took **7.7 s / 9.2 s** on 2026-08-31 03:53, so it is a ~350× regression, and a reboot does not clear it. **It needs ltsc2025 AND process isolation together**, measured on the same host and day with the same Dockerfile: `servercore:ltsc2025` 441.3 s · **`servercore:ltsc2022` 1.8 s** · ltsc2025 under `--isolation=hyperv` 3.5 s · `nanoserver:ltsc2025` ~2 s. An older user-mode image on the identical 26200 kernel is fine, so "process isolation is broken here" is not the shape of it. That fits the silo-only artefacts — the `WcSandboxState\Hives\*_Delta` flush failures logged as Kernel-General 6, and the orphaned `bindflt` instances `ISSUE.md` already counted — and it is diagnosis only, not an escape: `buildkitd` v0.32 has no Hyper-V isolation option, and Hyper-V isolation is capped at 2 CPUs on this host.

**The 141 s half is named.** Inside the container, SCM logs `7022 The LSM service hung on starting` exactly 140.07 s after `RpcSs` comes up, and every other service starts within the same second afterwards. `LSM` (Local Session Manager) then sits in `START_PENDING` **forever** — a scan of all 121 services in a live container finds it as the *only* one not in RUNNING or STOPPED — and it reports `NOT_STOPPABLE, IGNORES_SHUTDOWN`. Under `--isolation=hyperv` the same image has LSM `RUNNING`. **But disabling LSM does not help:** an image committed with `LSM Start=4` (verify with `sc qc LSM`, not just `reg query` — a quoted key path passed through PowerShell to `reg.exe` silently creates a key named `LSM"`) published its output and then still sat in teardown for **>13 min** before that run was cut short by an unrelated force-remove — so the bound is ">13 min", not a completed 2841 s, but it is already 100× the 7.7 s baseline. LSM is a co-symptom, and it is not worth chasing economically: **2700 of the 2841 s are the timeout, so the teardown is the only lever that matters** — removing the whole 141 s boot stall would save 5 %.

**Fix.** UNRESOLVED as of 2026-09-01 — but do not spend the day re-falsifying what is already falsified: Defender RTP (reproduces with RTP off), the Defender platform (unchanged on disk since 2026-08-05), CNI/HNS (ADD succeeds, IP+gateway match the host nat adapter; `--network none` stalls identically), disk space (515 GB free), disk health (`disk` event 51 fires only on *successful* teardowns), the RDNA4 dGPU (cleanly disabled, Code 22), the shim patch (SHA256 matches), the buildkitd GC policy (active — buildkitd reads `C:\ProgramData\buildkitd\buildkitd.toml` by default, so a missing `--config` in the service ImagePath is a non-issue), and any new KB or driver (nothing was installed that day). Post-mitigation falsifications (2026-09-01): a Defender engine/SIU change (engine constant `1.1.26070.7` across good and bad periods; SIU updates landed just as frequently during the good window, the fast 03:53 build ran right after one), and **in-container Windows Update** (a layer with `wuauserv`+`UsoSvc` `Start=4` — reg output confirmed applied — still burns the full teardown cap on the next RUN); disabling `LSM` was falsified above. **The 141 s boot hang is NAMED (2026-09-02, wait-stack captured).** LSM's service-start thread in the silo's `svchost -k DcomLaunch -p` sits in:

```
ntdll!NtWaitForSingleObject                                  <- never signalled
KERNELBASE!WaitForSingleObjectEx
lsm!CEventDispatcher::CEventListEntry::WaitForSessionEvent
lsm!CEventDispatcher::WaitForSessionState
lsm!CService::Start
lsm!ServiceMain
```

Two dumps 30 s apart carry the **byte-identical** stack and the thread reports **0.000 s user time** — a fully static wait, not slow progress. So LSM never completes `CService::Start` because a *session-state event* inside the silo is never signalled; SCM then times it out (event 7022) and the rest of the boot proceeds. Reproduce with `windows/scripts/diagnostics/capture-lsm-waitstack.ps1` (elevated; it grabs the next container start and dumps twice). Two notes from doing it: the script must find the silo through the process TREE (a new `wininit.exe` → its `services.exe` → their `svchost`s) because `Win32_Process.ExecutablePath`/`CommandLine` are empty for silo processes even elevated; and the dumps land SYSTEM-owned, so `icacls <dir>\*.dmp /grant <user>:R` before analysing them unelevated. `cdb.exe` ships inside the WinDbg store package (`…\Microsoft.WinDbg_*\amd64\cdb.exe`). **The event object is NOT identified** — and one wrong way to try is recorded here because it looked convincing: reading the FIRST `KERNELBASE!WaitForSingleObjectEx` in the process names the **SCM dispatcher's own idle wait** (`sechost!ScDispatcherLoop`), which every service process has, not LSM's. Everything derived from that handle (`HandleCount 2`, "exactly one holder") described the wrong object and was retracted 2026-09-02. `kb`'s argument columns are home-space reconstructions and untrustworthy for a blocked wait; read **R10** of the thread whose stack actually shows `lsm!CService::Start` (the x64 syscall stub does `mov r10,rcx`, so R10 still holds argument 1). Silo handles also resolve as `Name <none>` from outside, so the `lsm!CEventDispatcher` frames stay the reliable pointer. This is the concrete, reportable core for microsoft/Windows-Containers#547, which so far only describes the symptom — ready-to-file draft: [`upstream/windows-containers-lsm-session-event-hang.md`](upstream/windows-containers-lsm-session-event-hang.md).

**Recurrence playbook — decode the timing before debugging anything.** The signature is *identical* RUN durations regardless of what the step does. On the current 5 min knob: **~10 s** healthy · **~180 s** the shim is env-configurable but the containerd `Environment` value is gone (a Stevedore update wiped it — silent stock 30 s; redeploy below) · **~450 s** knob active, defect present · **~2841 s** the 45 min constant build is back. Re-mitigate with `deploy-shim-patch.ps1 -ShimPath out\shim-builds\containerd-shim-runhcs-v1-fork-19251429.exe -ServiceEnvironment CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m` (rebuild recipe if the binary is lost: fork branch `feature/configurable-teardown-timeout`, `go build .\cmd\containerd-shim-runhcs-v1`). Confirm a suspected hang cheaply with `docker logs`/`docker top` on the stuck container — output present + no process = lost notification, not a hung command. And never conclude "wedge" from a killed probe: give any timing probe ≥15 min. Diagnose the rest with admin: `Get-ComputeProcess`, `fltmc instances -f bindflt` (the orphaned-instance signature from `hcsshim-teardown-timeout/ISSUE.md`), `ctr -n buildkit tasks ls`, the Hyper-V-Compute logs. **Do not judge a step by its console silence and kill `buildctl`** — that manufactures the `0xb7` debris two rows up; a 240 s timeout is what made this look like a hard wedge for a day. **The practical lever is the timeout, and 45 min was never the requirement:** the measured *legitimate* worst-case teardown on this host is **117 s** (`hcsshim-teardown-timeout/ISSUE.md`, OpenCV), so 2700 s is 23× the number it was raised to cover. Deploying the **`upstream-env` shim variant** — `deploy-shim-patch.ps1 -ServiceEnvironment CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m` — keeps ~2.5× headroom over the real worst case while capping the pathological case at 5 min, taking a RUN step from ~47 min to ~7 min without rebuilding the shim for every retune. **The value is a Go duration string and a bare number is not one:** `=300` fails `time.ParseDuration`, and the patch treats an unparseable value as unset, so it would silently give you the stock 30 s. The task-close timeout is then derived automatically to `2*5m+30s`. Force-terminating at the cap is known to be safe *here*: `docker stop` on a hung container returns in 91 s and the layer still exports (`exporting layers 1.7s`, `unpacking 5.2s`). Still an owner decision — it trades against the `ExportLayer 0x3` corruption the 45 min was raised to prevent. **Do not conclude the patch itself is obsolete:** checked 2026-09-01, upstream `main` (56195bbd) still hardcodes every 30 s constant, hcsshim#2855 sits unanswered, and Windows-Containers#547 is closed without a fix — dropping to stock re-opens the 0x3 A/B of 2026-08-06 the moment the host is healthy again. Build the shim from the fork branch (`Kataglyphis/hcsshim@feature/configurable-teardown-timeout` — owner directive; code-identical to the in-tree patch, current-main base incl. the e6580439 leaked-layer-reader deadlock fix), not from the in-tree patch file.

### `hcsshim::ActivateLayer failed (0x20)` during build

**Symptom.** `hcsshim::ActivateLayer failed (0x20)` during build

**Cause.** Windows Defender scanning new layer files + containerd snapshot contention

**Fix.** Exclude `C:\ProgramData\containerd`, `C:\ProgramData\nerdctl` from Windows Defender. Or use `docker.exe` instead of `nerdctl` for builds (Docker's layer manager is more resilient).

### `ActivateLayer 0x20 "file used by another process"` on commit

**Symptom.** `hcsshim::ActivateLayer failed ... 0x20 "file used by another process"` on commit

**Cause.** `--isolation process` was used for a `docker build` — it cannot commit layers on this host

**Fix.** Never pass `--isolation process`. Use Hyper-V (the default) for `docker build`; for CPUs use the `docker run --cpu-count N` + `docker commit` path. Not Defender/Search/SysMain (all ruled out).

### `ImportLayer ... (0xb7) "already exists"` — deterministic, burns the retry budget

**Symptom.** BK lane: `failed to commit … during finalize: failed to reimport snapshot: hcsshim::ImportLayer failed in Win32: cannot create a file when that file already exists` (**0xb7**), DETERMINISTIC — identical snapshot IDs on every attempt, burns the driver's whole retry budget

**Cause.** **A half-committed snapshot is in the way.** Prime cause, measured 2026-08-07: **killing `buildctl` mid-finalize leaves exactly this debris** (a chain was aborted deliberately at 23 GB free to escape the disk danger band, and the next run died three times on the same IDs). `prune` does NOT clear it — it is not a reclaimable BK cache record (495 MB returned, nothing relevant); the transient-retry engine cannot help either, because the failure is deterministic, not a flake.

**Fix.** **`-NoCache` on the affected stage only** — e.g. `.\windows\build-buildkit.ps1 -Gpu -Stages sdk -NoCache`. Re-running the RUN yields a NEW layer digest (its output is not bit-identical), hence fresh chain IDs downstream, and the poisoned snapshot is simply no longer in the path. **Verified 2026-08-07:** the stage that had failed 3× exported cleanly, `Done in 00:17:10`. Prefer this over the in-file `CACHE-BUST` comment technique (`setup-scoop-tools.ps1`, `build-toolchain-all.ps1`): same effect, costs one stage re-run, leaves NO trace in the source. Only reach for a source-level cache-bust when the debris sits in a layer you cannot isolate with `-Stages`. Corollary: **prefer letting a doomed solve fail cleanly over killing it** — a clean finalize failure leaves no debris, a kill does.

### `ImportLayer ... (0xb7)` on the SAME chain-IDs across retries

**Symptom.** BK lane: `hcsshim::ImportLayer failed ... (0xb7) "already exists"` on the SAME chain-IDs across retries

**Cause.** Persistent snapshotter debris from an earlier low-disk finalize failure — NOT transient, `buildctl prune` cannot reach it (0B reclaimable)

**Fix.** Non-admin sidestep: cache-bust the layer above (any content change to the COPY'd/mounted file → new chain-IDs; live example in `setup-scoop-tools.ps1`'s 2026-08-05 header). Admin fix: prune/GC under the active gcpolicy.

### `failed to reimport snapshot` / `failed to write compressed diff` — the hcs-temp flake family

**Symptom.** BK lane: `failed to reimport snapshot` / `failed to write compressed diff` at finalize/export

**Cause.** hcs-temp flake family (2026-08-05): realtime scanner racing `C:\WINDOWS\SystemTemp\hcs*` scratch, and/or low disk (<~25 GB free makes hcsshim "weird" before disk-full)

**Fix.** Auto-retried by the BK driver's transient pattern. Root remedies (applied 2026-08-05): Defender exclusions for buildkitd/containerd + their ProgramData dirs; keep ≥40 GB free; gcpolicy active. ALWAYS check free disk first — disk-full mimics the same message.

### Finalize dies `unknown stream ID 9` on a Windows Update `.msu`

**Symptom.** BK lane: a RUN finishes, then finalize dies `failed to reimport snapshot: Files/Windows/SoftwareDistribution/Download/<id>/Windows11.0-KB…-x64.msu: unknown stream ID 9`, byte-identical on every retry (same snapshot IDs — the RUN result is cached, only the finalize re-runs)

**Cause.** **Windows Update ran INSIDE the build container** (servercore ships `wuauserv` + `UsoSvc`, trigger-started, and the container has network) and dropped an `.msu` into the update spool during the RUN; BuildKit's Windows layer writer cannot carry that file's alternate stream. Measured 2026-08-25 on the amd64 `media-core-onnx` stage (150 s RUN, KB5120233)

**Fix.** **Prevention, not cleanup:** `Disable-ContainerWindowsUpdate` (Common.psm1) stops + disables both services and sets `NoAutoUpdate=1` as the first step of every build script (`Initialize-SourceBuildEnvironment`) and reports the spool count — an entry inherited from the parent image (1 item at RUN start on every media stage) is harmless, only a file written during the RUN lands in the diff. Nothing under `C:\Windows` is deleted by any script (protected-root rule). A layer that already carries a download is fixed by re-running its RUN with the guard in place (any module edit re-keys it); retrying the same cached RUN cannot help.

### `exporting layers` prints nothing for 20+ minutes

**Symptom.** BK lane: `exporting layers` (or the following `unpacking to …`) prints NOTHING for 20+ minutes after a heavy amd64 layer (the LiteRT-LM Bazel output is the measured case) — or the merge fan-in `COPY --from=media-core C:\runtime C:\runtime` sits silent for 10–15 minutes on a step that took 5 s the run before — and every daemon — buildkitd, containerd, vmcompute, wcifs — sits at 0.00 s CPU, no shim/container process is left, and `buildctl debug workers` still answers in <1 s

**Cause.** **Not a hang — a slow, mostly kernel-side layer export/unpack.** Measured 2026-08-24/25: `exporting layers 1216.3s done` after 20 idle-looking minutes, then `unpacking … 1277.0s done`, and the stage went `OK` at 58:08 (17 min of actual build); arm64 run 12 (2026-08-25): the fan-in COPY finished `DONE 847.4s` after 14 idle-looking minutes (run 11: 5.1 s), no eventlog entry, nothing written under the buildkitd root

**Fix.** **Wait.** Killing `buildctl` here is exactly the "mid-finalize" kill that manufactures the 0xb7 debris two rows up and costs a `-NoCache` re-run. Bound the wait (a watcher on the log's mtime) instead of judging by CPU: the export shows no user-mode activity by design.

### A stage fails instantly with `exit code: 1` and zero container output

**Symptom.** BK lane: a stage fails instantly with `exit code: 1` and **ZERO container output** — no script banner, no stderr, deterministic across retries

**Cause.** **Two solves racing on the same freshly-invalidated ancestor stage.** Measured 2026-08-07: a second `build-buildkit.ps1` was started while the main chain ran, right after a change to the `common` stage invalidated it for BOTH. Each solve tried to build the same new snapshot chain; one died before its process ever started, hence no output. NOT a script bug — a probe running the identical mounts, module import and `Initialize-SourceBuildScript` against the same base passed cleanly.

**Fix.** Do not run a second solve that shares an ancestor stage you just invalidated. `-ConcurrentAux` is safe because its two branches sit on an ALREADY-BUILT common ancestor. Wait for the running chain, then start the second build. If you must parallelise, first build the shared ancestor once on its own.

---

## Windows: container networking

### `Could not resolve host: github.com` seconds into the first downloading RUN

**Symptom.** BK lane, seconds into the first downloading RUN: `Could not resolve host: github.com` / `git clone failed (exit 128)`

**Cause.** **The CNI `.conf` is missing** — buildkitd then gives the container NO NETWORK ADAPTER AT ALL (not a DNS fault). Confirm in 30 s with a probe RUN: `ipconfig` prints nothing and a raw TCP connect to a literal IP fails *"unreachable network"*; the containerd debug log shows the `HcsCreateComputeSystem` spec with no networking block. Usual cause: someone "converted" `0-containerd-nat.conf` → `.conflist` to fix nerdctl (2026-08-07, cost a launched chain). The subnet-drift guard does NOT catch this and stays green.

**Fix.** Restore it (admin): `Copy-Item '…\0-containerd-nat.conflist' '…\0-containerd-nat.conf'`, edit to the single-plugin form, `Restart-Service buildkitd -Force`. **Keep BOTH files** — buildkitd needs `.conf`, nerdctl needs `.conflist`. `build-buildkit.ps1` now fail-fasts (`Get-CniConfFormIssue`) and `verify-host-setup.ps1` FAILs on a missing `.conf`.

### `The remote name could not be resolved` — CNI nat subnet drift

**Symptom.** BK RUN steps: `The remote name could not be resolved` (and even direct-IP queries time out)

**Cause.** **CNI nat subnet drift**: dockerd restarts recreate the `nat` HNS network on a new subnet; the static CNI conf then hands out IPs whose gateway doesn't exist

**Fix.** Update `ipam.subnet`/`GW` in `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` to match the live `vEthernet (nat)` adapter (`ipconfig`), then `Restart-Service buildkitd -Force` (admin). `build-buildkit.ps1`'s preflight guard detects this and prints the fix.

### nerdctl DNS failure in build

**Symptom.** nerdctl DNS failure in build

**Cause.** BuildKit container can't resolve hostnames on Windows without a CNI nat CONFIG (`--dns` and `--network host` unsupported)

**Fix.** Fixed 2026-08-03: install `0-containerd-nat.conf` into `C:\Program Files\containerd\cni\conf\` (nat.exe was already in ...\cni\bin) — buildkitd RUN steps then have full NAT+DNS. docker.exe remains the fallback.

---

## Windows: buildkitd and the store

### A BK compile step freezes silently after `[output clipped, log limit 2MiB reached]`

**Symptom.** BK compile step freezes silently minutes in (0 % CPU, zombie ninja, no log growth) right after `[output clipped, log limit 2MiB reached]`

**Cause.** **buildkitd step-log clip deadlock** (Windows buildkitd v0.32): after the 2 MiB clip the stdio pipe stops being drained; every process blocks on its next write. ONNX's warning flood hits the clip in ~3 min

**Fix.** Set service env `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `BUILDKIT_STEP_LOG_MAX_SPEED=-1` on buildkitd (registry MultiString `Environment`), `Restart-Service buildkitd -Force`. See docs/windows-build-lanes.md § Getting it going, step 3b.

### `buildctl prune` returns `Total: 0B` no matter what you pass

**Symptom.** `buildctl prune` returns `Total: 0B` no matter what you pass

**Cause.** **CHECK `du -v` FOR `Shared: true` FIRST — that is almost always the answer.** `Shared` records are pinned by containerd IMAGE TAGS and NO prune flag can take them; prune only ever gets the `Private` slice, and `Reclaimable` describes the LEASE state, not what prune will hand back. **`reservedSpace` is a red herring for this symptom.** Otherwise: refs pinned by BUILD HISTORY (every record incl. failed attempts pins its refs indefinitely) and/or by named `bk-*` image generations

**Fix.** In order: **(1)** `buildctl du -v` and look for `Shared: true` — those records are pinned by containerd image tags and no prune flag can take them, so the lever is an admin `nerdctl --namespace buildkit rmi` of dead stage tags. **(2)** Non-admin and safe mid-build: `buildctl prune --free-storage <MB>` — a minimum-free *target*, not an amount to delete. **(3)** `prune-histories` second, never first. **(4)** Look for a superseded lineage, the big hidden reclaim. The full decision procedure with every measurement: [`windows-build-lanes.md`](windows-build-lanes.md#store-gc).

### `buildctl` local export dies `file already closed` on a Windows rootfs

**Symptom.** `buildctl` local export of a Windows image dies `error from receiver: write ...\Boot\Fonts\<font>.ttf: file already closed` (nondeterministic file; every layer had already committed)

**Cause.** The `type=local` exporter cannot receive a full Windows rootfs client-side — NOT a host/commit defect (measured 2026-08-10 on a host whose `type=image,...,unpack=true` export of the same solve was green)

**Fix.** Export `type=image` (what `build-buildkit.ps1` and, since 2026-08-10, `probe-build-copy.ps1` do) or the tar-stream `type=docker,dest=<file>` (`-FinalTar`); never judge host health from a `type=local` export of a Windows image.

---

## Windows: Stevedore and the docker service

### `cannot access containerd socket ... Zugriff verweigert` (non-admin)

**Symptom.** `nerdctl ...`: `cannot access containerd socket ... Zugriff verweigert` (non-admin)

**Cause.** containerd's pipe is admin-only (its service lacks `--group docker-users`, unlike dockerd/buildkitd)

**Fix.** Use `docker.exe` (dockerd pipe) or `buildctl` (buildkitd pipe) — both are docker-users-accessible. nerdctl needs an elevated shell.

### `runtime "com.docker.hcsshim.v1" binary not installed`

**Symptom.** Stevedore docker build: `runtime "com.docker.hcsshim.v1" binary not installed`

**Cause.** Service default runtime uses `hcsshim-v1` shim which isn't shipped

**Fix.** Change to `runhcs-v1`: `sc config stevedore binPath="..." --default-runtime=io.containerd.runhcs.v1"` (see docs/windows-stevedore-and-docker.md § Fix 2)

### `failed to create TTRPC connection`

**Symptom.** Stevedore docker build: `failed to create TTRPC connection`

**Cause.** Shim binary mismatch (runhcs copied as hcsshim)

**Fix.** Remove the bad shim copy: `del "C:\Program Files\Stevedore\bin\containerd-shim-hcsshim-v1.exe"`. Apply Fix 2 instead.

### Stevedore service won't start (1053 timeout)

**Symptom.** Stevedore service won't start (1053 timeout)

**Cause.** Windows Defender blocking dockerd.exe OR stale daemon.json from Docker Desktop

**Fix.** `Add-MpPreference -ExclusionProcess "dockerd.exe"` AND delete `C:\ProgramData\docker\config\daemon.json`

### `error getting credentials - err: exit status 1`

**Symptom.** `error getting credentials - err: exit status 1`

**Cause.** wincred credential helper fails because dockerd runs as SYSTEM without interactive session

**Fix.** OK to ignore for public images (MCR, GitHub). Use `nerdctl pull` instead for images that need auth, or set `"credsStore":""` in docker config.

### `failed to extract layer ... failed to find link target` pulling servercore

**Symptom.** `failed to extract layer ... failed to find link target` when pulling servercore

**Cause.** containerd windows snapshotter can't handle certain Windows reparse points in the layer

**Fix.** Use `docker.exe pull` instead of `nerdctl pull`. Docker Engine's layer extraction handles reparse points correctly.

---

## Windows: build content and toolchain

### Windows media build crawls; `Building with ninja -j2`

**Symptom.** Windows media build crawls; `Building with ninja -j2` in the stage log (`out\windows-build-logs\bk-<runid>-Dockerfile.media-builder-media-core-*.log`)

**Cause.** `-j2` is the FLOOR of `Get-BuildJobCount` (`max(2, min(cores, MEMORY_LIMIT_GB/4))`), so the container resolved a near-zero memory budget — BK RUN steps are process-isolated with all host CPUs, so this is memory-bound, not a CPU cap. *(Historical: on the classic lane the same line meant media-core had fallen back to a 2-CPU `docker build` instead of `Invoke-RunCommitStage`; that driver went on 2026-08-31.)*

**Fix.** Check the driver's `preseed: memory-limit-gb=<N> published` line and that the stage carries `SCCACHE_WEBDAV_ENDPOINT` — #51 publishes the budget to the WebDAV rather than as an ARG/ENV (both are cache keys), and a container that cannot read it falls back to CIM host RAM. Worked numbers: [`windows-build-resources.md`](windows-build-resources.md) § Media fan-out and memory budgeting.

### Rust smoke test: "rustup could not choose a version of cargo/rustc"

**Symptom.** Rust smoke test fails: "rustup could not choose a version of cargo/rustc"

**Cause.** A **toolchain-less** rustup (proxy shims in `CARGO_BIN` that resolve no toolchain) — e.g. `rustup-init --default-toolchain none`, or an image from before the Cargokit fix

**Fix.** rustup WITH a stable default toolchain IS the sole provider (`setup-rust-toolchain.ps1`); `CARGO_BIN` on the rustup path is by design. Fix with `rustup default stable`; never add a second provider (no scoop rust) ([`windows-build-invariants.md`](windows-build-invariants.md) § Windows Build Invariants).

### A GitLab download "succeeds" with HTTP 200 but is a few KB

**Symptom.** A download from gitlab.freedesktop.org / code.videolan.org "succeeds" (HTTP 200) but is a few KB and extraction fails — e.g. GStreamer wraps "downloaded but extraction into X failed"

**Cause.** **Anubis anti-scraper**: browser User-Agents without JS get an HTML challenge page as a 200 (the shared `Invoke-DownloadWithRetry` sends a browser UA). Second variant: `.git` left in a GitLab `/-/archive/` URL serves HTML even to curl. Both burned a merge run on 2026-08-17.

**Fix.** Both halves live in `Invoke-GstWrapProvisioning` (in `WindowsMeson.Common.psm1` since 2026-08-31 — the merge-lane leaf mounted by `Dockerfile.media-merge-builder` only, so editing it costs the GStreamer layer and not the whole media chain): it fetches via `Invoke-WrapDownload` (curl-native UA + gzip/bzip2 magic-byte check) and strips `.git` from GitLab archive URLs in both branches. Diagnosis in 10 s: read the first bytes — `<!doctype html>` = challenge page, not a corrupt archive.

### `TVM: llvm-config.exe not found on PATH`

**Symptom.** tvm stage: `TVM: llvm-config.exe not found on PATH` (#47 gate)

**Cause.** Scoop LLVM never ships llvm-config or dev libs — TVM was silently USE_LLVM=OFF (no CPU codegen) until 2026-08-17. NOT a broken PATH.

**Fix.** The self-heal in `build-tvm-from-source.ps1` builds a pinned minimal LLVM from source ([`windows-build-invariants.md`](windows-build-invariants.md) § Windows Build Invariants). If the gate throws, check the heal's download/SHA pin for the current `LLVM_WINDOWS_VERSION` — do NOT fall back to the official /MT dev tarball or USE_LLVM=OFF.

### `TVM: no member named 'matchIntrinsicSignature' in namespace 'llvm::Intrinsic'`

**Symptom.** amd64 TVM compiler build: `codegen_llvm.cc(1119): error: no member named 'matchIntrinsicSignature' in namespace 'llvm::Intrinsic'` plus 7 more errors on `MatchIntrinsicTypes_*`, then `ninja: build stopped`. The arm64 lane is unaffected (runtime-only, no compiler).

**Cause.** TVM 0.26's `codegen_llvm.cc` uses `llvm::Intrinsic::matchIntrinsicSignature` / `MatchIntrinsicTypes_*` which were removed or renamed in LLVM 23.1.0. The forced `LLVM_WINDOWS_VERSION` bump from 22.1.8 to 23.1.0 (scoop reshaped the artifact, #135) broke the TVM compiler's LLVM API surface. The `llvm_module.cc` `LLJITBuilderState::ObjectLinkingLayerCreator` conversion also fails (API change).

**Fix.** Not yet fixed. Either patch TVM 0.26 for the LLVM 23.1.0 Intrinsic API, or revert `LLVM_WINDOWS_VERSION` for the TVM compiler build only. The arm64 lane needs no fix — it builds runtime-only and never compiles `codegen_llvm.cc`. Tracked in `docs/windows-refactor-backlog.md` #134.

### `lld-link: error: undefined symbol` for template instantiations after a green compile

**Symptom.** Compile fully green, then `lld-link: error: undefined symbol` for template instantiations (`QkvToContext<...>`, `BiasSoftmaxImpl<double>`) at the DLL link — identical on every retry AND on a fresh cache mount

**Cause.** **the sccache nvcc path produced objects lacking arch/define-guarded instantiations during REAL compiles** — runs 10+11 with launcher failed identically, runs 5+12 bare-nvcc linked green. Poisoning is excluded on BOTH levels (run 11: fresh L0 mount; L2 turned out to hold only 9 probe entries — the chain's write-through never fed it). Minimal wrapped-vs-bare nm-diff repros (define-guard + arch-guard shapes; plain, ORT-ish and `--options-file` command lines, fresh disk-only cache) are all CLEAN — the loss needs real-ORT invocation complexity (untested: `-MD/-MF` depgen, `-forward-unknown-to-host-compiler`, quoted rsp defines, client concurrency). Same machinery also crashed the server on fused_moe (10054, upstream family #1098) and produced the `Severity::k0` phantom; arch-guard×preprocessing has upstream history (#2299)

**Fix.** CUDA is bare BY DEFAULT since 2026-08-10 night — the launcher is OPT-IN at the wiring site (`Invoke-CmakeConfigure` adds `CMAKE_CUDA_COMPILER_LAUNCHER` only under `SCCACHE_CUDA_LAUNCHER=1`; the earlier per-script opt-out env var leaked process-wide on the classic lane, review find). NEVER export that opt-in on a new sccache without all THREE canaries: verify-cuda-cache.ps1 + fused_moe compile + a full providers_cuda LINK (the miscompile is invisible until link). C/CXX launcher stays safe.

### meson cross: `Summary section 'Build environment' already have key 'host cpu'`, then `Subproject "subprojects/glib" required but not found`

**Symptom.** arm64 GStreamer merge (cross file + native file): `glib-2.86.3/meson.build:2777:0: Exception: Summary section 'Build environment' already have key 'host cpu'` right after glib's build-machine configure reached its summary, then `gstreamer| Subproject subprojects\glib-2.86.3 is buildable: NO (disabling)`, dozens of `Dependency 'libpcre2-8' is required but not found` re-tries, and finally `libnice-0.1.23/meson.build:214:4: Exception: Subproject "subprojects/glib" required but not found` → `gst-libs/gst/webrtc/nice/meson.build:16:14: ERROR: Subproject "subprojects/libnice" required but not found` (arm64 run 25, 2026-08-26). The host glib configured fine minutes earlier.

**Cause.** Three meson bugs around "build-only" subprojects (1.12.0 and `master`, checked 2026-08-26). Nothing in the monorepo asks for a build-machine glib; meson's gnome module does (`mkenums_simple` → `find_tool` → `dependency('glib-2.0', native: true, required: false)`), so under forcefallback glib's `meson.build` runs a second time for the build machine. (1) `Interpreter.summary` is keyed by NAME and shared across interpreters → the second run throws at its `summary({'host cpu': …})`. (2) `do_subproject`'s failure paths call `disabled_subproject(subp_name, exception=e)` without `for_machine` (default HOST) → the failed build-machine holder **overwrites the healthy host glib holder** — that is the poison: libnice's anonymous `dependency('', fallback: ['glib', 'libglib_dep'])` reaches glib by NAME and inherits the failure (the `gio-2.0` lookup survives through the override table), and every later `native: true` request re-runs the whole failing configure because the BUILD key never got the disabled entry. (3) `configure_file` writes to the unprefixed `self.subdir` while targets/include dirs of a build-only subproject live under `build.<subdir>` → the build machine's `glibconfig.h`/`config.h`/`fficonfig.h` overwrite the host's, and a build-machine compile cannot find them (run 27). Not a toolchain problem — the build-machine sanity checks link x64 via `/vctoolsdir`+`/winsdkdir` and its libffi assembles with the x64 `cl`/`ml64` named in the native file (backlog #128 runs 23–27 for the earlier costumes of this chain).

**Fix.** `Invoke-MesonBuildSubprojectPatch` (in `WindowsMeson.Common.psm1` since #134, 2026-08-26 — a merge-lane leaf module mounted by `Dockerfile.media-merge-builder` only, so editing it costs the GStreamer layer and not the whole media chain; it lived inside `build-gstreamer-from-source.ps1` until then because the only module home was the shared `buildmods` six) patches the pip-installed `mesonbuild/interpreter/interpreter.py` before `meson setup`: `for_machine=for_machine` at both `disabled_subproject` failure sites, and the project prefix on `configure_file`'s output path and returned File. Bug (1) is deliberately left alone — a build-machine glib that configures is one that compiles (5772 targets) into more unprefixed paths, and nothing consumes it; with (2) fixed its failure is recorded under BUILD only, with (3) fixed it clobbers nothing, gnome's `find_tool` falls through to the host override as designed, and libnice/webrtc configure against the host glib. Idempotent by marker; THROWS when a site count is off so a newer meson cannot silently skip it and resurface as the libnice error two hours later. Fixture test `SourceBuild.MesonBuildSubprojectPatch.Tests.ps1`; upstream draft `out/upstream-issue-meson-summary-build-subproject.md` (all three). If you see this on a meson newer than 1.12.0, check whether upstream fixed it before re-anchoring the regexes.

### Windows base: scoop cannot install a pinned tool, 404 on the installer

**Symptom.** `Dockerfile.base` dies in the scoop layer, ~14 minutes in (i.e. after the Visual
Studio Build Tools layer), with `The remote server returned an error: (404) Not Found.` naming an
installer URL, then `Where-Object: Cannot bind argument to parameter 'AppName' because it is an
empty string` — scoop's own follow-on error, not the cause. Both halves of this hit on 2026-08-26,
twenty minutes apart.

**Cause.** The pin names a version whose WINDOWS artifact does not exist. Two distinct ways in:

- **The upstream reshaped the artifact.** LLVM changed its Windows packaging at 23.1.0 from `.exe`
  to `.msi`, and the scoop `main/llvm` manifest followed within the hour. `scoop install app@<ver>`
  synthesises its URL from the CURRENT manifest's autoupdate template, so the still-valid 22.1.8
  pin began asking for `LLVM-22.1.8-win64.msi`, which was never published. Measured:
  `LLVM-22.1.8-win64.exe` 206 / `.msi` 404; `LLVM-23.1.0-win64.exe` 404 / `.msi` 206. **A pin can
  go uninstallable without the pinned version changing.**
- **The upstream versions per platform and the key is shared.** LunarG publishes the Vulkan SDK per
  platform and Windows lags: `https://vulkan.lunarg.com/sdk/latest.json` read
  `{"linux":"1.4.357.1","mac":"1.4.357.1","windows":"1.4.357.0"}`. `VULKAN_VERSION` feeds the linux
  base/sdk AND the windows scoop layer, and the bump tool resolved it from `latest/linux.txt`.

**Fix.** Check the artifact, not the version number:
```bash
curl -sS -o NUL -w '%{http_code}' -L --max-time 30 -r 0-0 <installer-url>   # 206 = there, 404 = not
curl -s https://raw.githubusercontent.com/ScoopInstaller/Main/master/bucket/<app>.json | grep -A2 autoupdate
```
`spec_vulkan` in `bump_versions.py` now reads `latest.json` and pins the OLDEST platform this repo
installs — a shared key can only carry a version that exists on every lane consuming it — and
prints the disagreement. `build-buildkit.ps1`'s Vulkan preseed probes the installer URL before any
solve and throws on 404 ONLY (403/5xx/timeouts stay fail-open, so a LunarG outage cannot block a
build the container could still complete). Note the preseed had ALREADY warned "host download
failed (exit 22)" and fallen through by design; a 404 is a wrong pin, not an outage.

### AArch64 cross compile aborts with `error: fixup value out of range`

**Symptom.** A cross TU aborts with `error: fixup value out of range`, or with
`error: value evaluated as <N> is out of range.` — no source location, no fixup kind, no
instruction. Appeared with clang-cl 23.1.0; 22.1.8 compiled the same tree. Observed in OpenCV's
CPU-dispatch TUs and in the bundled protobuf.

**Cause — ONE defect, reaching two passes that both pick an encoding from an ESTIMATE of block
offsets and are then contradicted by the assembler.** Under async EH (`/EHa`, which OpenCV passes)
`AsmPrinter` emits a NOP after an `EH_LABEL` whose next instruction can fault, but
`getInstSizeInBytes` reports `EH_LABEL` as a zero-size meta-instruction — so every MIR-level
block-size estimate is 4 bytes short per label. `AArch64CompressJumpTables` then picks a 1-byte
jump-table entry for a span that does not fit (1), and `BranchRelaxation` leaves a branch that
cannot reach its target (2).

**This entry has now been wrong twice, in opposite directions; both corrections are kept because
each wrong version was acted on.** 2026-08-27 it said "one signature at two sites" with a shared
cause — refuted, and the investigation split. Later the same day it said the two were *unrelated*,
that (2) was [llvm#202716](https://github.com/llvm/llvm-project/pull/202716) and that only a
toolchain move to LLVM `main` would retire `/Ob1` — **also wrong**. A census is recorded as settling it — 1,869 objects
green with BOTH workarounds off, on pinned 23.1.0 plus only the two `getInstSizeInBytes` patches,
a compiler containing no llvm#202716 — but it was run by hand and **left no log**, so it is a
claim, not evidence. Re-run it through the driver before acting on it. Full evidence in
[`windows-refactor-backlog.md`](windows-refactor-backlog.md), backlog item #135.

1. **Jump-table entry width** → `value evaluated as <N> is out of range`.
   `AArch64CompressJumpTables` selects 1-byte entries whenever `span>>2` fits in 8 bits — a
   ceiling of 255×4 = 1020 bytes. Every `N` measured here sits JUST past it: 256 (= 1024 B, four
   bytes over), then 258, 259, 260, 262, 272, 281, 284. Offender class: the bundled libprotobuf
   (descriptor.cc, generated_message_reflection.cc, wire_format.cc), which is known-fragile on
   windows-arm64 — but **read that citation carefully**
   ([protobuf#24758](https://github.com/protocolbuffers/protobuf/issues/24758) is a LOOSER match
   than it looks: Ruby/upb, not `descriptor.cc`, and its symptom is
   `Failed to evaluate function length in SEH unwind info`, i.e.
   [llvm#47432](https://github.com/llvm/llvm-project/issues/47432) — the same bug this page already
   warns about under `-align-all-*`, and NOT the jump-table overflow). It was closed as an LLVM
   bug with nothing to fix in protobuf, which is the useful precedent: **the offender library is
   the trigger, not the defect.**
   **Root cause, FOUND 2026-08-28 — FIXED by the patched toolchain (llvm#219275 +
   #219276, `BUILD_PATCHED_LLVM=1`, now the default).** `EH_LABEL` under `/EHa`
   emits a 4-byte nop counted as zero by `getInstSizeInBytes`; the pass is sound
   *given correct instruction sizes*. The workarounds (`+force-32bit-jump-tables`
   and per-TU `/Ob1`) have been REMOVED from `build-opencv-from-source.ps1`. The
   stock scoop clang-cl still has the bug — use `-StockLlvm` only for patch
   debugging.
2. **Branch relaxation** → `fixup value out of range`. In `median_blur.dispatch.cpp`, `/O2`
   collapses the whole baseline median filter into ONE function — `cv::cpu_baseline::medianBlur`,
   8,465 instructions ≈ 33,860 bytes — and inside it

   ```asm
   tbnz  w9, #31, .LBB546_847
   ```

   has to reach a block ~32,916 bytes away (counted from the emitted listing, instructions × 4).
   `tbz`/`tbnz` carry a 14-bit displacement: ±32,768 bytes. **It misses by roughly 150 bytes** —
   a hair, not an order of magnitude. LLVM's `BranchRelaxation` pass exists to catch exactly this
   and rewrite the branch; it did not, because its layout estimate came out short.
   **Root cause: the same EH_LABEL undercount as (1)** — ~150 bytes is 37 labels at 4 bytes each.
   Retired by the same two patches on pinned 23.1.0; measured 2026-08-28, `/Ob1` off, this TU
   compiles clean.
   *Superseded claim, kept because it was acted on:* this once read "root cause FOUND, fixed
   upstream by [`c6e184686cd7`](https://github.com/llvm/llvm-project/pull/202716), only a toolchain
   move to `main` retires `/Ob1`". The census compiler contains no such commit, so #202716 is not
   the cause here. What the earlier `branch-relax-tbz.mir` revert actually showed was that the
   commit is load-bearing for *upstream's own test* — never evidence about
   `median_blur.dispatch.cpp`.

**Fix — two settings, one per site, both cross-lane only.**

* **(1)** `-Xclang -target-feature -Xclang +force-32bit-jump-tables`, whole build. This
  **disables the compression pass** — `if (ST.force32BitJumpTables() && !MF->getFunction().hasMinSize()) return false;`
  (AArch64CompressJumpTables.cpp, 23.1.0) — so every table keeps 4-byte entries:
  `.word .LBB0_2-.Ltmp0` / `ldrsw`, ±2 GB, instead of `.hword (.LBB0_2-.LBB0_2)>>2` / `ldrh`.
  Cost on a reproducer: 4522 → 4650 bytes of object, ~2.8 %, all of it jump-table DATA; full
  `/O2` retained.
* **(2)** `/Ob1` on the two offending TUs — `median_blur.dispatch.cpp` and
  `multiview_calibration.cpp` — appended to their `build.ninja` FLAGS lines by
  `build-opencv-from-source.ps1`. It does **not** lower the optimisation level: every kernel keeps
  `/O2`, vectorisation and unrolling. It stops the inliner from gluing file-static helpers into
  one oversized function; on `median_blur` the largest function drops 33,860 → 10,620 bytes, i.e.
  3.1× headroom under the ceiling instead of a 148-byte miss. `-mllvm -inline-threshold=100` and
  `=25` do NOT achieve this (measured, both still fail): those helpers have a single call site and
  are inlined regardless of threshold.

  **Get the list by census, not one rebuild at a time.** `NINJA_KEEP_GOING=1` (honoured by
  `Invoke-NinjaBuildWithRetry`) turns the stage into `ninja -k 0`, so one run compiles all 1,870
  objects and reports EVERY offender instead of stopping at the first. That is how the list above
  was closed at two. Re-run it that way after an OpenCV bump: the ceiling is a property of what
  the inliner produces, so a new offender is one source change away, and the per-TU floor only
  catches the reverse (a TU that vanishes or is renamed).

**`+force-32bit-jump-tables` and `-mllvm -aarch64-enable-compress-jump-tables=false` are the same
thing** — byte-identical `.asm` from clang-cl 23.1.0, verified locally on 2026-08-27. An earlier
version of this page claimed the feature "keeps the pass enabled with its `adr` check intact"
while the `-mllvm` flag removes it, and used that difference to explain (2). Both halves were
wrong. With the pass off, the `adr` that materialises a table base is self-relative (`.Ltmp0:`
sits on the `adr` itself, displacement 0) and cannot go out of range. The target feature is
preferred only because it is a supported spelling where `-mllvm` is a debug knob.

**Do NOT** reach for these — each one cost a run:

* **`-fno-jump-tables` for (2)**: no jump table is involved; it fails identically (measured).
* **`-align-all-*`** to nudge an estimate: the padding makes the function length unevaluable for
  the Windows SEH unwind writer and clang-cl dies with `Failed to evaluate function length in SEH
  unwind info` ([llvm#122707](https://github.com/llvm/llvm-project/issues/122707), a duplicate of
  [llvm#47432](https://github.com/llvm/llvm-project/issues/47432)).
* **`/Od` or `/O1`** to dodge a pass: they move the failure to the next TU (measured three times)
  and cost code quality on a lane whose point is a real build. A 148-byte miss flips on ANY
  perturbation, which is exactly why blunt flags keep appearing to "work".
* **`-max-jump-table-size`**: caps the entry COUNT while the ceiling is a BYTE SPAN. Accepted by
  the driver, no effect.

**Diagnose it in minutes, not in build-hours.** The message carries no location because it comes
from the MC layer, after codegen. `/FA` makes clang-cl assemble its own listing, which puts a
`file:line` and the offending instruction on the error:

```pwsh
clang-cl.exe --target=aarch64-pc-windows-msvc /O2 /c /FA /Fat.asm /Fot.obj t.cpp
```

**One trap on 23.1.0: that listing does not round-trip.** A catch funclet's block address prints
as `add x0, x0, .LBB0_903` with the `:lo12:` specifier MISSING, so LLVM's own assembler stops
there with `expected compatible register, symbol or integer in range [0, 4095]` — before reaching
the fixup you are chasing. Direct object emission is unaffected (it gets the specifier right), so
repair the listing and assemble that instead:

```pwsh
(Get-Content t.asm) -replace '^\s*add\s+(x\d+),\s*(x\d+),\s*(\.L\S+)\s*$', "`tadd`t`$1, `$2, :lo12:`$3" | Set-Content t2.s
clang.exe --target=aarch64-pc-windows-msvc -c t2.s -o t2.obj    # the error now has a line number
```

That printing bug reproduces in 15 lines — one `try`/`catch` with a body big enough to push the
continuation block past 4 KB — and deserves its own upstream report.

Work against a LOCAL toolchain, not the container: it turns 4-minute lane runs into 2-second
experiments.

```pwsh
curl -sSfL -o llvm.tar.xz https://github.com/llvm/llvm-project/releases/download/llvmorg-<ver>/clang+llvm-<ver>-x86_64-pc-windows-msvc.tar.xz
tar -xf llvm.tar.xz
```

Then read the listing: `.byte`/`.hword`/`.word` says which jump-table width was chosen, `adr` vs
`adrp` says how a base is reached, and the instruction count between a branch and its target
label — ×4 for bytes — says whether relaxation failed and by how much.

**Deciding whether a new compiler retires these two settings.** Do not answer that from a lane
run, and do not answer it from a synthetic reproducer — a 148-byte miss flips on any perturbation,
so a hand-written test case proves nothing about these TUs.
[`repro-llvm-aarch64-layout.ps1`](../windows/scripts/diagnostics/repro-llvm-aarch64-layout.ps1) is
the A/B: it freezes the five real offenders as preprocessed `.i` files (`-Capture`, once per
OpenCV bump) and then compiles them with the workaround OFF against any candidate `clang-cl`.
Because a frozen `.i` has no `#include`s left, the run phase needs no OpenCV tree, no VsDevCmd and
no container — only a compiler that can target `aarch64-pc-windows-msvc`.

It **gates every verdict on its own control arms**: the stock compiler must still reproduce the
abort with the workaround off, and must still compile clean with it on. If either fails the run
reports `INVALID` and exits 2, because a green candidate under a broken control is not evidence —
it is a stale corpus. A `FIXED` verdict is necessary and **not sufficient**: the frozen set is a
census taken at one commit, and the ceiling is a property of what the inliner produces, so
removing anything from `build-opencv-from-source.ps1` still requires the full
`NINJA_KEEP_GOING=1` run over all ~1,870 objects. Its command-line surgery — in particular that
*both* spellings of the jump-table workaround are stripped, so the "off" arm is genuinely off — is
pinned by `windows/scripts/tests/Diagnostics.Llvm135Repro.Tests.ps1` against the real ninja
command line.

### A source build produces UNPATCHED sources and says `SKIP: ... (already applied)`

**Symptom.** `Invoke-SourcePatch` reports `SKIP: <patch> (already applied)` for every
patch on a fresh source tree, the build succeeds, and the artefact behaves as though
no patch was ever applied. No error anywhere.

**Cause.** `Invoke-SourcePatch` falls back to `patch.exe` when the source tree is not
a git repo, and until 2026-08-27 it passed the patch file as a POSITIONAL argument.
To GNU `patch` a bare path is the file *to be patched*, not the patch — so it read an
empty patch from stdin, changed nothing and **exited 0**. The helper's reverse-check
reads exit 0 as "already applied" and skips. Measured against a file containing only
the word `placeholder`: both the forward and the reverse dry-run returned 0 and
printed nothing. With `-i` the same call returns 1 and prints `Hunk #1 FAILED`.

Only non-git trees were affected. OpenCV and opencv_contrib are git clones and take
the `git apply` path, where the positional form is correct — which is why this sat
undiscovered until the LLVM release tarball became the first non-git consumer.

**Fix.** Already applied: the three `patch.exe` scriptblocks in
`WindowsSourceBuild.Patches.psm1` now pass `-i $PatchFile`.

**The transferable lesson.** This was caught only because
`build-llvm-from-source.ps1` asserts on the PATCHED CONTENT afterwards
(`if ($text -notmatch 'eh-asynch') { throw ... }`), not on the patch step's exit
code. A source build whose patch silently vanishing would matter should check the
result, not the return value — otherwise you ship a compiler that reports the right
version, passes the provenance gate, and still has the bug you patched out.

### `atlbase.h` not found when building LLVM in the container

**Symptom.** `DIASupport.h(25): fatal error C1083: ... "atlbase.h"` partway through an
LLVM source build.

**Cause.** LLVM's PDB/DIA support needs ATL, which the container's VS Build Tools
installation does not include.

**Fix.** `-DLLVM_ENABLE_DIA_SDK=OFF` (already in `build-llvm-from-source.ps1`). DIA
only powers PDB symbolisation in the LLVM tools; the compiler itself needs none of it.

### A build script dies with `The term ... is not recognized`, in the container only

**Symptom.** A build script dies with `FATAL ERROR: The term 'Resolve-BuildMachineMsvcTool' is not
recognized as a name of a cmdlet, function, script file, or executable program.` — well into a
compile stage, on the build host only. The same script runs fine on a dev box.

**Cause.** The function exists and is exported by its owning module, but the script reaches that
module INDIRECTLY through `WindowsSourceBuild.Common`'s re-export list, and the name was never
added there. Module-internal use never needs an export entry; a direct script call does. On a dev
box the whole modules directory is on disk and earlier imports pollute the session, so nothing
fails. `Export-ModuleMember` also silently ignores names with no matching function, so the reverse
mistake is equally quiet. This class has cost two incidents (#113/verify12, and #134 two hours into
arm64 run 37).

**Fix.** Exporting is TWO edits: `Export-ModuleMember` in the owning module AND the re-export list
in `WindowsSourceBuild.Common.psm1`. `Modules.ScriptCallClosure.Tests.ps1` proves in a fresh pwsh —
importing only what the script itself imports — that every module function a build script CALLS
resolves; `Modules.ReExport.Tests.ps1` checks the other direction. Neither replaces the other, and
the check takes seconds where the build takes hours.

### A declaration that masks its command's exit status

`local x="$(cmd)"` returns **`local`'s** status, not `cmd`'s. Under `set -e` the
failure is invisible and `x` silently holds `""`.

Live example, fixed 2026-09-01 — `_gst_monorepo_install`
(`03-media/build/gstreamer/common/build-gstreamer-monorepo.sh`):

```sh
local gst_stage="$(mktemp -d "/tmp/gst-stage.XXXXXX")"
```

`/tmp` is a tmpfs on every `Dockerfile.media` RUN, so a full tmpfs makes `mktemp`
fail. With `gst_stage` empty the whole staging design inverts:

| line | intended | with an empty value |
| --- | --- | --- |
| `meson install --destdir "${gst_stage}"` | stage into a temp tree | `--destdir ''` → installs into the **live root**, running target post-install scripts there |
| `[ -d "${gst_stage}${GSTREAMER_PREFIX}" ]` | is anything staged? | `[ -d /opt/gstreamer ]` → always true |
| `[ -d "${gst_stage}/usr/local" ]` | as above | `[ -d /usr/local ]` → always true |
| `rm -rf "${gst_stage}"` | drop the staging tree | `rm -rf ''` → no-op |

The sting: the only line reaching the build log is the same
`WARNING: GStreamer cross-install had errors` a healthy cross run prints, so the
broken run is **indistinguishable in the log**.

**The gate.** `verify_masked_assignments.py` (preflight slug `masked-decls`)
fails on any NEW `local`/`export`/`declare`/`readonly` declaration containing a
command substitution; 54 pre-existing sites are frozen in
`masked-assignments.allow`, keyed by file+variable so a site does not re-flag
when something above it moves. Fixing one means deleting its line.

Two reasons shellcheck alone was not enough: SC2155 does **not** fire on
`local x="${y:-$(cmd)}"` (verified), and `lint-shell.sh` gates at `-S error`,
where a warning can never fail the build.

**The fix shape:**

```sh
local x
x="$(cmd)" || return 1
```

### RV1-FREETYPE: riscv64 OpenCV freetype/harfbuzz

RV1-FREETYPE — FIXED (2026-08-24); the coming rebuild is the
final validator. History (2026-08-23 investigation, still true):
riscv64 had no TARGET harfbuzz dev surface at configure time —
pass-2 (FROM gstreamer, libfreetype-dev pre-satisfied) got only
the RUNTIME libharfbuzz0b — so ocv_check_modules(HARFBUZZ
harfbuzz) resolved a HOST harfbuzz (find_library fall-through
under CMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH) → "file in wrong
format" at link. The ports dev package stays banned
(libharfbuzz-dev:riscv64 → Depends: libglib2.0-dev = RV1-GST-PC
poison), so install-deps.sh now stages a PIC STATIC target
harfbuzz (HB_HAVE_FREETYPE=ON, hb-ft glue included) at
/usr/<triplet> with a cmake-generated absolute-prefix
harfbuzz.pc whose freetype dep is promoted to Requires: pkg-config
then emits `-lharfbuzz -lfreetype`, so HARFBUZZ_LIBRARIES becomes
[libharfbuzz.a, target libfreetype.so] and the module link
(<objects> FREETYPE_LIBRARIES HARFBUZZ_LIBRARIES) still resolves
the archive's FT_* refs under -Wl,--no-undefined — a DSO BEFORE
the archive alone does NOT (proven by a local link experiment
2026-08-24: objects+ft.so+hb.a fails; +ft.so after the archive
links clean). Determinism, both passes:
* our pkgconfig dir is prepended to PKG_CONFIG_PATH, which
outranks PKG_CONFIG_LIBDIR — pass-2 puts /opt/gstreamer
first in PKG_CONFIG_PATH and its meson-subproject harfbuzz
may export a competing harfbuzz.pc; ours must win;
* the pkgcfg_lib_* cache vars FindPkgConfig/ocv_check_modules
resolve libraries through are pre-seeded with absolute
TARGET paths, so no find_library ever runs, let alone falls
through to a host lib (OCV-FF1's determinism discipline,
pinned by file path instead of -L ordering).
Static harfbuzz keeps the runtime surface: the only new NEEDED
is libfreetype.so.6, which validate-media-runtime's
so-package-map already resolves to libfreetype6 (and the
gstreamer stack pulls it in on riscv64 today anyway). If
install-deps could NOT stage the static harfbuzz, keep the
module hard-OFF rather than let detection wander back to host
libs — absence then still surfaces as the wheel smoke's
riscv64-only opencv-freetype warning, and after a green rebuild
that warning's "expected on riscv64" status is STALE (parity
follow-up for the orchestrator).

### A half-fetched dependency that every retry inherits

`ONNX Runtime CPU build failed after 3 attempts` on media-riscv64, 2026-09-02,
with the same CMake error each time:

```
add_subdirectory: The source directory
  .../_deps/dawn-src/third_party/spirv-headers/src
does not contain a CMakeLists.txt file.
```

Dawn's dependency fetch was interrupted, leaving the directory present but
EMPTY. `_deps` is in the image layer, not a cache mount, so a fresh run recovers
— but the three retries inside one RUN all inherited the ruin, so the retry
bought nothing. amd64 and arm64 passed the identical build; only the riscv64 run
hit the transient failure.

`30-build-native.sh` now drops any `*-src/third_party/*/src` that carries no
`CMakeLists.txt` before each attempt. A retry that inherits the state that broke
the previous attempt is not a retry.

### RVV changed what the optimizer can prove

media-riscv64 failed on 2026-09-02, after the RVA23 switch, in vvdec:

```
thirdparty/simde/x86/ssse3.h:370: error: 'r_.simde__m128i_private::i8'
may be used uninitialized [-Werror=maybe-uninitialized]   → vvdec_x86_simd
```

SIMDe emulates x86 intrinsics on non-x86, so a riscv64 cross build really does
compile that header. `-Wmaybe-uninitialized` is optimization-dependent, and
enabling vector plus Zba/Zbb changes what the optimizer can prove — a diagnostic
that did not fire before the ISA change now does, in upstream third-party code.

`install-vvdec.sh` waives it exactly where the same file already waives
`-Wno-error=unused-but-set-variable`. The waiver is scoped to vvdec, not global:
this is a false-positive class in one dependency, not a reason to stop treating
warnings as errors elsewhere.

Expect more of this shape as the vector baseline lands. Waive per component,
never tree-wide, and record why here.
