# Refactoring backlog

A living list of refactoring / hardening / efficiency candidates observed while
operating the cross build. Each item: **what**, **why it matters**, and a rough
**effort·impact**. Not a commitment — a triage queue. Newest observations at the
bottom under "Harvested during runs".

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ (nice) … ★★★ (high).

---

## Build efficiency / speed

- **onnxruntime WebAssembly target — RESOLVED (commit 63fd9d3): now build-once,
  ship-to-all.** Was: compiled amd64-only AND orphaned (never COPY'd anywhere — the
  original "gate it off" note assumed it wasn't wanted). User wants onnx-web shipped
  on ALL arches. Since the WASM is arch-independent, it's now compiled ONCE on amd64
  (~45min emscripten) and shared to arm64/riscv64 via a version-keyed cross-arch cache
  mount (id=onnxruntime-web-shared-${ONNXRUNTIME_VERSION}); the assets are COPY'd into
  the final image + carried by copy-media-payloads; smoke-media validates the .wasm
  magic bytes. Single-compile wall-clock cost (not ×3), and it actually ships now.
- **`01-core/parallelism.sh` is bind-mounted into ~21 media RUN steps.** Any edit to
  it (even behaviour-preserving, e.g. the 2026-07-11 refactor) changes the mount
  content and cache-misses **every** framework build (opencv/onnx/litert/gstreamer/
  torch), turning a 1-stage change into a full media rebuild. Consider splitting the
  rarely-changing job-math from the frequently-read helpers, or passing job counts
  as build-args so the script isn't on every RUN's cache key. — M · ★★★
- **Android NDK/SDK re-downloaded per arch.** Each android arch pulls the full NDK
  (r29, ~1 GB+) with no shared download cache → 3× the same download. Share via a
  common cache mount or a pre-fetch stage. — M · ★★
- **`--parallel-archs` is unusable in practice.** The 3× wall-clock lever exists but
  the orchestrator doesn't inject `BUILD_MEM_DIVISOR` (added 2026-07-11), so N
  concurrent per-arch builds each size against full RAM → OOM. Wire the divisor
  (build-arg → ENV) so parallel-archs is safe. See docs/build-parallelism-memory-tuning.md. — M · ★★★

## Build robustness / correctness

- **`verify-runtime-paths.sh` is toothless.** `errors=0` never increments, so it
  always exits PASSED; its `${VAR:-default}` escaped templates also defeat envsubst
  (false `/opt/gcc-\/` warns). Either make it a real gate or drop it — a green check
  that can't fail is worse than none. — S · ★★
- **`csound-sys` uses failure-then-patch-then-retry.** The first compile is *expected*
  to fail (signed-char array initialisers) before `patch_csound_sys_char_signedness`
  rewrites it and retries. Noisy in logs and relies on catching a build failure;
  pre-apply the patch instead. — S · ★
- **`PYTORCH_EXTRA="none"` is a stringly-typed sentinel.** Passing it straight into
  `--extra "${PYTORCH_EXTRA}"` caused the 2026-07-11 amd64 torch-missing outage
  (`--extra none` → uv sync fails → whole tree incl torch dropped). Fixed for that
  one call site, but the "none means no extra" convention is fragile — prefer empty
  string / an explicit boolean, and audit other `${PYTORCH_EXTRA}` / sentinel uses. — S · ★★
- ~~**The riscv64 native-GCC smoke can't actually validate A2.**~~ **DONE (bcbd19d).**
  The android-stage smoke runs on the x86_64 host → `Exec format error` → benign
  "cross-build host limitation", so the native riscv64 gcc was never executed.
  Fixed by adding a compile+link+**RUN** check to `smoke-runtime-image.sh`, which
  already boots each per-arch wrapper under binfmt/qemu — the native gcc/g++ now
  actually compiles, links AND runs a C and C++ binary on-target (riscv64 included,
  C++ exercising libstdc++). The android-stage ELF-only smoke remains as a cheap
  early check.
- **ffmpeg runtime-lib list is doubly-maintained.** `setup-torch-venv.sh` now installs
  the auto-derived `/opt/ffmpeg/runtime-apt-packages.txt` manifest, but the hardcoded
  codec baseline (lines ~158-170) remains and can drift. Once the manifest is proven
  across a few runs, collapse to manifest-only (keep a tiny always-present core). — S · ★

## Observability / tooling

- **`resource-monitor.sh` rewrites its CSV on start.** A mid-run restart wipes
  history; safe for from-scratch runs but a foot-gun. Consider timestamped run-ids
  or append-with-resume. — S · ★
- **Managing background helpers via `pgrep`/`pkill` self-matches** the managing
  command (kills own shell, exit 144). A small `scripts/procctl` that filters by
  recorded PID files would remove the foot-gun. — S · ★
- **Log dir accumulates stale per-run logs.** Old `android-*.log` / `media-*.log`
  caused a false-positive smoke-watcher match (stale riscv64 log). The orchestrator
  could namespace logs under `<run-id>/` or truncate per-run. — S · ★★

---

## Harvested during runs

- **Pinned-tarball downloads have no per-download retry → one truncated fetch fails
  the whole stage.** 0711f runtime/package: `base-image.sh install-shared-build-tooling`
  fetched the cmake 4.3.3 GitHub release asset, got a truncated download → checksum
  mismatch → the entire package-image build failed (recovered only by the
  orchestrator's build-level retry, which redoes the whole image). The pin is
  correct (verified: independent download matched byte-for-byte); it was pure
  GitHub truncation. Refactor: wrap the pinned downloads in `curl --retry N
  --retry-all-errors` (or the repo's existing download-with-retry helper) so a
  transient truncation costs one re-fetch, not a full-stage rebuild. Cheap, ★★.

_(build-log signals collected while 0711f runs — triage into the sections above)_

- **`install_optional_target_packages` installs the whole batch atomically, so one
  missing package can drop them all.** It resolves N opencv codec deps and passes
  them to `install_target_packages` in a single `apt-get install A B C …`. If any
  one (e.g. arm64 `libopenexr-3-dev`, absent in Ubuntu Ports) is uninstallable,
  apt rejects the *entire* transaction — the available codecs (jpeg/png/tiff) can
  go down with it, silently reducing opencv features with only a "continuing" log.
  Observed 0711f media-arm64 (libopenexr-3-dev + libvvdec-dev missing; build
  correctly continued, but the blast radius is wider than intended). Refactor:
  install optional deps one-by-one (or retry-without-the-missing) so a single
  ports outage doesn't drop the whole set. Also: the `install_target_packages:
  FAILED — missing` line reads as fatal but isn't when wrapped — worth a
  gentler wording (`optional: skipped …`) so log scans don't false-alarm. — M · ★★
- **Media parity-check line `INFO: torch not installed (only in :latest-cross-<arch>
  wrappers)` is confusing + trips log scanners.** It's benign (torch is added in the
  runtime wrapper, not the media image), but the literal string `:latest-cross`
  false-matched a completion watcher, and reads like a warning. Reword to something
  like `INFO: torch deferred to runtime wrapper (expected in media)`. — S · ★
- **External-source pinning relies on forge auto-archives that aren't byte-stable.**
  (fixed 9f4a3ce for one case) android cerbero fetched `soundtouch 2.4.1` from
  `codeberg.org/soundtouch/soundtouch/archive/2.4.1.tar.gz`; Forgejo regenerated
  the archive → sha256 drift → all 3 android stages died. This is a *class*: any
  recipe/download pinned to a GitHub/GitLab/Codeberg `/archive/<tag>.tar.gz` can
  break the same way at any time. Refactor: prefer release *assets* or a
  git-clone-at-tag (byte-stable) over auto-archives, and/or maintain a small
  vendored mirror for the handful of upstreams that pin auto-archives. Also the
  current re-pin is a hardcoded hash in build-android-from-source.sh — fine as a
  point fix, but a small `patches/cerbero/checksums.env` override table would
  scale better if more recipes drift. — M · ★★

### 0711f (full no-cache, launched 2026-07-11 17:58)

- **Stale-log false positives, confirmed twice.** The A2 smoke-watcher matched a
  prior run's `android-riscv64.log` (mtime hours before this run's `base` even
  started), reporting "A2 fired" when the fresh run was still in the compiler
  stage. This is the same log-namespacing gap already listed under Observability —
  now upgraded to ★★★: it produces *false green*, not just clutter. The orchestrator
  should write logs under `<run-id>/` (or truncate/rotate on start) so watchers and
  humans can't confuse runs. Interim mitigation: stale logs moved to
  `kata-rebuild-logs/stale-0711e/`. — S · ★★★
- **`base` stage: ~24 `update-alternatives: warning: skip creation of …man…` lines**
  (fakeroot/lzma/sudo/nano/vim man-page link groups). Pure noise — a real warning
  in this stage would be buried. Low value, but a `2>/dev/null` on the alternatives
  calls or a noise-filter in the log tee would help signal-to-noise. — S · ★
- **`compiler` stage: repeated `configure: WARNING: *** Makeinfo is missing`** across
  each GCC/binutils configure. Harmless (we don't ship GCC info docs) but printed
  N times. Install `texinfo` in the toolchain base *or* pass `MAKEINFO=true` to
  silence — trivially removes a recurring scary-looking warning. — S · ★
- _base + compiler: no real defects. A2 (riscv64 GCC `--with-isa-spec`) built
  clean end-to-end (GCC+LLVM+Rust, no `invalid -march`)._
- **REAL BUG (fixed 7f10bfe): `${SUDO:-} <sudo-flag>` collapses to a bad command
  when SUDO is empty.** `vulkan.sh:322` ran `${SUDO:-} --preserve-env=... ./vulkansdk`;
  on root cross containers SUDO is empty → `--preserve-env` became the command →
  exit 127, killing sdk-arm64 + sdk-riscv64 (amd64 had SUDO set, survived). Added
  today in 7e6d627, masked by sdk cache until this no-cache run. **Refactor angle:**
  the `${SUDO:-}` prefix idiom is only safe when the next token is a real command;
  a bare flag after it is a latent bug. Worth a lint rule / a `run_priv()` helper
  that appends `--preserve-env` *only* when actually invoking sudo, instead of the
  raw `${SUDO:-}` sprinkle (24+ call sites in this one file). — M · ★★
  Reinforces the standing lesson: **cache-bust exposes latent bugs** — a from-scratch
  no-cache run is the only thing that exercises foreign-arch-only code paths.
- **REAL BUG (fixed e3ffb0a): `uv venv --clear` seeded from the venv it deletes.**
  `Dockerfile.media:140` ran `uv venv --clear /opt/python/.venv` while the base
  image ENV had `UV_PYTHON=/opt/python/.venv/bin/python`; `--clear` deletes that
  interpreter, so uv had nothing to seed from → "No interpreter found" (exit 2),
  killing all media arches at [base 14/15]. Cached until this no-cache run. Fixed
  by seeding from the source-built `/usr/local/bin/python3` with `env -u UV_PYTHON`.
  **Refactor angle:** every OTHER `uv venv` in the tree passes explicit `--python`
  (setup-package-image, tvm-python, android, python_uv) — this one was the lone
  outlier. A lint/CI grep for `uv venv` without `--python` would have caught both
  this and prevented the class. Also: the base-image `UV_PYTHON` pointing at a
  not-yet-created venv is a footgun for any `uv` call before the venv exists. — S · ★★

## Harvested 2026-07-12 — foreign-arch runtime defects (no-sudo QEMU unmasked)

Registering QEMU binfmt without sudo (setup-rootless-binfmt.sh, wired into
build-runtime-manifest.sh) made the arm64/riscv64 runtime smokes actually EXECUTE
for the first time — amd64's all-green smoke had hidden four real foreign-arch
breakages. All four now fixed:

- **RESOLVED c46da5f (toolchain): foreign-arch native GCC C++ exceptions.** The
  Canadian-cross GCC-16 for riscv64/arm64 linked a `try/throw/catch` program that
  then terminated at runtime (rc=134, catch never fired). The earlier RESIDUAL note
  here mis-diagnosed this as a binutils ld-2.46 duplicate-DSO issue; the TRUE root
  cause was self-inflicted: the header fix in 2500d60 installed a `*self_spec` file,
  and installing *any* specs file RESETS the driver's dynamically-computed link specs
  — it silently drops `-lgcc_s` (from `*libgcc`) and `--eh-frame-hdr` (from the EH
  link spec). Restoring them by hand is fragile whack-a-mole under QEMU (restoring
  `*libgcc` got `-lgcc_s` back but runtime unwinding still failed — `--eh-frame-hdr`
  also gone). Fix: drop the installed specs file entirely and instead wrap
  gcc/g++/cpp/cc/c++/gfortran with thin scripts that prepend `-idirafter
  /usr/include/<triplet> -idirafter /usr/include` on the *command line* (honouring
  `-nostdinc`, skipping symlinks). Command-line injection fixes header search for C
  AND C++ (`#include_next`) while leaving the link specs untouched. Validated on
  arm64+riscv64: bare `gcc hello.c`, simple C++, exception-throwing C++ (throw/catch
  + STL sort), std::thread, libm, libatomic, and `-flto` all compile+link+run. The
  RUNTIME_COMPILER_SMOKE battery (d2da044) regression-guards all of these.
- _Fixed 2500d60: riscv64 torch libsleef.so.3 (USE_SYSTEM_SLEEF wheel, runtime lib
  never installed → add libsleef3); ffmpeg libopencore-amrwb.so.0 (silent best-effort
  codec install → add a fail-loud `ldd` closure gate in setup_torch_deps); foreign-arch
  gcc <stdio.h> (baked cross sysroot header dir → superseded by the c46da5f wrapper)._
- **Class lesson (★★★): amd64-green ≠ shipped-green for a multi-arch manifest.** Every
  one of these shipped inside a "validated" `:latest-cross` because the foreign-arch
  smokes silently no-op'd on `exec format error` (no host qemu) and were read as a host
  limitation. The durable countermeasures: (1) register binfmt with no sudo before the
  smokes (done), (2) make foreign-arch verification FAIL LOUD not skip (the ffmpeg ldd
  gate is the template — assert the property natively in the torch stage under qemu,
  independent of the runtime-image smoke's binfmt gating), (3) the in-build
  verify_torch_import_or_fail must not fail-open when its `import torch` exec can't run.

## Harvested 2026-07-12 (cont) — new runtime smokes found a GStreamer-plugin gap

Adding the native `.so`-closure gate + functional runtime smokes (commit 19a86a5)
immediately surfaced a real class the old smokes missed, on ALL three arches:

- **GStreamer plugins ship but can't load — their runtime `.so` deps aren't installed.**
  Confirmed via `gst-inspect-1.0` (the element genuinely fails to load), not just a
  dangling file. Most-relevant offenders:
  - **`webrtcbin2` -> `librice-proto.so.0`** — the Rust `gst-plugins-rs` WebRTC element
    (a deliberate cross-build feature this session: rice-proto/openssl-sys work) does
    NOT load at runtime because `librice-proto.so.0` was never packaged into the image.
    `webrtcbin` (the C element) loads fine; only `webrtcbin2` is dead. Likely a real
    regression to fix (copy the Rust-built `librice-proto.so.0` into the runtime image,
    or static-link it into the plugin) — same shape as the libsleef fix but the lib is
    Rust-built, not an apt package.
  - **`openh264enc` -> `libopenh264.so.8`** (apt `libopenh264-8`? verify) and the tail:
    `libgudev-1.0.so.0` (breaks gl/v4l2/gtk/va/nvcodec/hip/uvch264 plugins),
    `libv4l2.so.0`, `libwavpack.so.1`, `libsrtp2.so.1`, `libcsound64.so.6.0`,
    `libcdda_{paranoia,interface}.so.0`, and (arm64) `libgstlibav.so`.
  Triage: decide which of these the app actually needs. The apt-satisfiable ones
  (libgudev-1.0-0, libopenh264, libv4l2-0, libwavpack1, libsrtp2-1, …) are a cheap
  `setup_torch_deps` add (like the ffmpeg codec libs); `librice-proto.so.0` needs a
  copy-from-build-stage or static-link. The new smoke's "GStreamer plugins that cannot
  load: N" line makes the count visible every run; promote specific app-critical
  elements (webrtcbin2?) to a fail-loud curated list once their deps are fixed. — M · ★★

## Harvested 2026-07-12 (cont) — app wheel smoke caught broken LiteRT

Building `orchestr_ant_ion.smoke` (the app-owned wheel smoke that the runtime
image now delegates to) surfaced a real packaging defect:

- **LiteRT interpreter can't load its native wrapper (amd64).** The source-built
  `ai-edge-litert` 2.1.6 wheel installs its module as `tflite_runtime` (per
  `top_level.txt`), but `import tflite_runtime.interpreter` dies with
  `ImportError: cannot import name '_pywrap_litert_interpreter_wrapper' from
  'tflite_runtime'`. The shipped `.so` is `tflite_runtime/_pywrap_tensorflow_interpreter_wrapper.so`
  — a NAME MISMATCH: interpreter.py imports `_pywrap_litert_interpreter_wrapper`
  but the build produced `_pywrap_tensorflow_interpreter_wrapper.so`. So LiteRT
  imports at the dist level (metadata present, version 2.1.6) but its Interpreter
  API is unusable. build-litert.sh packages the wrong wrapper soname (or the
  interpreter.py expects the newer litert name while the build still emits the
  tflite_runtime one). The smoke treats LiteRT as OPTIONAL (WARN, not a gate
  fail) so it surfaces without blocking, but this is a real fix: align the
  built wrapper `.so` name with what `tflite_runtime/tflite_runtime.interpreter`
  imports, then verify `Interpreter` instantiates. — M · ★★

- **Runtime manifest cleanup: `nerdctl rmi` of intermediate `latest-cross-<x>-<arch>`
  tags conflicts with stopped containers.** Observed 2026-07-13 (run 0712a resume,
  runtime stage): build-runtime-manifest.sh tears down each intermediate tag
  (`latest-cross-base-amd64`, ...) with `nerdctl rmi`, which emits
  `level=fatal msg="conflict: unable to delete ... image is being used by stopped
  container <id> (must be forced)"`. BENIGN — the build proceeds to the next
  `--target package` step — but it (a) prints an alarming `level=fatal` line that
  reads like a hard failure in logs/monitors, and (b) leaks the intermediate image
  + its stopped container (never reclaimed → disk creep over repeated runs). Fix:
  `nerdctl rm` the stopped build container (or `rmi -f`) before/instead of the plain
  rmi, or skip the intermediate-tag rmi entirely and let a final prune reclaim them.
  Guard so a real rmi failure still surfaces. — S · ★

## Refactoring pass 2026-07-14 (post-riscv64-green audit)

Three parallel audits (DRY/reuse, complexity, smoke coverage) after the 3-arch
`:latest-cross` went green. Done this pass (all shellcheck-clean; build-path items
validated by the 0717 media→android→runtime rebuild unless noted):

- **DONE (438ac45): freetype/libpng cross-build dedup.** Extracted
  `cross_compile_cmake_lib_from_source` (01-core/cross-env.sh) reused by both
  opencv/install-deps.sh source-build blocks; adopts `download_and_extract`
  (retry + temp-file hygiene). install-deps.sh 172→124 lines.
- **DONE (26bf2b7): litert platform-tag dedup + verify-parity data-driven dispatch
  + configure-gcc-env decomposed** into 5 `_gcc_env_*` helpers.
  (configure-gcc-env is TOOLCHAIN-stage → validates only on a full from-scratch
  rebuild.)
- **DONE (5354c9c): swap-native-gcc `main` decomposed** (guard clauses + 5 helpers,
  nest 4→1; fix6 -idirafter invariant re-verified) **+ setup_torch_deps decomposed**
  into `_install_cv2_runtime_apt`/`_install_ffmpeg_runtime_codecs`/
  `_assert_ffmpeg_so_closure`.
- **DONE (52ee5b9): build_python multiarch-apt bootstrap extracted** from
  `_python_cross_configure`. (TOOLCHAIN-stage → full-rebuild validation.)
- **DONE (52b9618): runtime-image smokes** — HEALTHCHECK now EXECUTED not just
  parsed (gated); WebRTC signalling-server binary + Vulkan loader probes (WARN).
- **DONE (app v0.0.26, afbca10): wheel smokes** — JPEG imencode + onnxruntime-EP
  asserts (gated); optional cv2 dnn / tiff-webp-exr codecs / freetype-text checks.
  ContainerHub APP_REF v0.0.24→v0.0.26 (a1e8236).

**DEFERRED — `setup_gi_cross_wrappers` decomposition (C1, gstreamer/common/
pre-setup.sh:190, ~221 lines, M·★★★).** The single largest complexity win, but the
highest-risk mechanical lift: ~30 implicitly-global vars shared across the block +
FIVE `cat <<EOF` wrapper heredocs whose `\$`/`${}` escaping cannot be validated by
shellcheck/`bash -n` (they check the outer script, not the generated wrapper
semantics), and — unlike swap-native-gcc — there is NO verify-critical-fixes check
that greps the generated content. A silent heredoc-escape slip would only surface
deep in a media rebuild (broken g-ir-scanner wrapper). Do it as a dedicated pass
with a content-diff of the generated wrappers before/after, not inside a batch.
Split into `_gi_resolve_paths` / `_gi_detect_qemu_runner` / `_gi_detect_qemu_sysroot`
/ `_gi_write_ldd_wrappers` / `_gi_write_scanner_wrappers` / `_gi_write_pc_metadata`,
keeping every var global (no `local`) to preserve the shared-state behaviour.

**Audit-surfaced items NOT yet actioned (triage):** the ffmpeg install-deps
`NV_CODEC_HEADERS_REF:-n12.2.1` script default still drifts from versions.env
(n13.0.19.0) — advisory-only in verify-arg-consistency, worth aligning.

## Harvested 2026-07-17 — full from-base 3-arch rebuild retrospective (cp314 IREE campaign)

Observations from running the cp314-IREE integration end to end: three per-arch
validation builds (`--from-stage media`, 0714r/u/v — all green) followed by a full
`--target-arches amd64,arm64,riscv64` from-base rebuild that ENOSPC-failed once,
then succeeded after freeing 151G. Prioritised by time-saved.

### P1 — Disk (by far the biggest time sink; caused a whole wasted 10h+ run)
> **Status 2026-07-18: pre-flight disk gate DONE (commit 08c7161)** —
> `_chain_disk_preflight` refuses to launch below ~60G/arch (base) / ~40G/arch
> (media+), with a kata-buildcache prune hint; FORCE_LOW_DISK=1 overrides. The
> kata-buildcache unbounded-growth item stays OPEN (the gate only *hints* to prune;
> no automatic cap — an eviction policy would still help). Stage-barrier failure
> isolation stays OPEN but is now LOWER value: the disk gate removes its main
> trigger (ENOSPC mid-run), so a barrier-abort is far less likely.
- **Pre-flight disk gate in build-cross-chain.sh (S·★★★).** The full from-base
  rebuild launched with only ~140G free and ENOSPC-died 2h in at amd64 litert
  (`cmake -E tar: ZIP decompression failed (-5)` = truncated extract on a full
  disk). Add a launch-time check: require ~`70G × n_arches` free for a from-base
  run (less for `--from-stage media`), else refuse with a prune hint. Fail-fast at
  t=0 beats failing 2h in. The "prune if <150G" rule lives only in memory today.
- **`kata-buildcache` grows unbounded (S·★★★).** The `--cache-to type=local,mode=max`
  export (cross-stage-build.sh:~140) ballooned 77G→151G across the campaign with no
  eviction — it was the single biggest SAFE reclaim (clearing it freed 151G,
  114G→265G, and a clean from-base rebuild doesn't need it). Add a size cap / prune
  of stale per-stage dirs, or drop to `mode=min`, or a `make clean-buildcache`.
- **Stage BARRIER wastes cross-arch work on one failure (M·★★★).** amd64's media
  ENOSPC failed the media stage and aborted ALL arches — arm64/riscv64 media had
  already built fine but 0 arches reached android/runtime ("[ERROR] stage media
  failed for one or more arches", 0 "Cross chain complete"). Either continue the
  other arches past a single-arch stage failure and report at the end, or (simpler)
  document/auto-select **sequential single-arch full builds** on disk-constrained
  hosts (`--target-arches <one>` ×3, prune between): lower peak disk + failure
  isolation. See [[rebuild-disk-management]].
- **buildkit state (~/.local/share/buildkit) hit 289G (M·★★).** Holds the ccache
  cache-mounts (valuable) AND step cache. Needs a GC policy that keeps ccache warm
  but trims stale step cache between campaigns; `buildctl prune --keep-duration`
  alone reclaimed 0B because everything was recent-or-referenced.

### P2 — Speed (reach the goal faster)
> **Status 2026-07-18: `--no-push` DONE (commit 08c7161)** — CROSS_NO_PUSH builds
> every stage locally and skips the ghcr uploads that dominated each validation
> run's ~1.5-2h tail; the chain resolves via the local image store. The
> `--from-stage media` fast-path guidance below stands (it's guidance, not code).
> P4 log-namespacing: ALREADY DONE — `--log-dir` writes per-arch/stage logs
> (media-<arch>.log, android-<arch>.log) alongside the interleaved orchestrator.log.
- **`--no-push` / local-only validation mode (M·★★★).** The final ~2h was almost
  entirely PUSHING three ~9GB images to ghcr at ~5 MiB/s (`push=true`,
  `--cache-to type=registry`). For validation-only runs, output `type=docker`
  locally and skip publishing intermediates+finals — saves ~1.5–2h/run. Push only
  on an explicit `--publish`/release flag.
- **Fast path is `--from-stage media`, not from-base (doc·★★★).** The functional
  goal (cp314 IREE on 3 arches) was proven by the per-arch `--from-stage media`
  runs HOURS before the from-base rebuild even finished. base/compiler/sdk hadn't
  changed (edits were media/package/runtime only), so the from-base pass mostly
  re-validated unchanged stages. Guidance: use `--from-stage media` to validate
  media/runtime changes; reserve full from-base for toolchain/base/compiler/sdk
  changes or a release cut. Consider a "highest-unchanged-cached-stage" auto-start.
- **CCACHE_MAXSIZE for concurrent 3-arch (S·★★).** 64G held one arch's host+target
  LLVM object sets warm; a barriered 3-arch build wants all three arches' sets —
  confirm the cap isn't thrashing across `ccache-{amd64,arm64,riscv64}` ids.

### P3 — Correctness (the two arm64 IREE bugs were a single class)
- **Cross-wheel SOABI + default-triple preflight (M·★★★).** Both arm64 IREE defects
  (fixed c1ce2f1) were "cross-build introspected the x86_64 build host, not the
  target": the nanobind ext shipped as `_runtime.cpython-314-x86_64-linux-gnu.so`
  (unimportable on aarch64) and iree-compile defaulted to `embedded-elf-x86_64`.
  Add a post-build assertion per cross wheel: the compiled `.so` SOABI matches the
  target arch, and (compiler wheels) the default target triple is the target.
  Would have caught both instantly instead of a full rebuild cycle each.
- **Runtime IREE gating smoke didn't run inline in the full-chain flow (M·★★).**
  The `--from-stage media` runs ran the native `iree-compile`+run and `import iree`
  gating smoke (smoke-runtime-image.sh) per arch; the full base→runtime run showed
  no such lines. The gating smoke must run in EVERY flow that produces a runtime
  image — investigate & unify so a full rebuild can't publish an unsmoked image.
- **Shared apt-source/mirror include (S·★★).** Dockerfile.package lacked the
  ports.ubuntu.com→mirror rewrite that Dockerfile.media had (fixed 7593ccb). Factor
  the deb822 mirror-rewrite into one include sourced by every Dockerfile that
  apt-installs (media/package/nvidia/amd/android) so the outage-resilience is
  uniform and this class of gap can't recur.

### P4 — Observability
- **Per-arch / per-stage log namespacing (M·★★★, already listed above).** Monitoring
  the single interleaved orchestrator.log across 3 arches × 6 stages was painful —
  stage numbers differ per arch, "Built IREE wheels" only logs on cache-miss, arch
  is inferable only from `ccache-<arch>` mount ids. Split logs per arch+stage (or
  tag every line) so progress/failure is greppable. Reiterates the ★★★ item above.
- **Build-integrated disk monitor with ENOSPC preempt (S·★★).** External disk-guard
  loops are fragile (got killed mid-run). resource-monitor.sh already samples disk;
  give it a hard threshold that WARNs early and can auto-prune stale buildcache
  before ENOSPC, instead of relying on a babysitter.

### P5 — Observable defects harvested from the v2 build log (concrete, evidence-based)
> **Status 2026-07-17: ALL P5 items FIXED (commits 1305426 + d3815e7).** The
> non-GStreamer six: libgudev + libcdparanoia added, libvvdec.pc COPY added,
> python3-ml-dtypes on riscv64, cache-from-local guarded on index.json, auditwheel
> NOTE collapsed to one/stage, riscv64 uv-lock message → INFO.
> **GStreamer runtime libs — real root cause found (my first "soname mismatch" guess
> was WRONG):** libopenh264/libsrtp2/libwavpack/libcsound64/libv4l/libgudev were ALL
> absent because `install_host_packages` is ONE atomic `apt-get install`, and resolute
> renamed the libxml2 runtime pkg → `libxml2-16`; that single bad name failed the whole
> transaction and `|| true` silently dropped every other lib. Fixes: (a) cross-apt.sh
> install_host_packages now falls back to per-package installs so one bad name can't
> nuke the rest (systemic — prevents the whole class); (b) libxml2 → libxml2-16;
> (c) rice-proto (webrtcbin2) mirrored into ${GSTREAMER_PREFIX}/lib by
> install-rice-proto.sh (tolerant, no build-break). **Verify on next rebuild's runtime
> smoke that the degraded-plugin list is empty/minimal.**

### P6 — Optional python-binding WARNs from the runtime smoke (triaged)
- **ai-edge-litert `_pywrap_litert_interpreter_wrapper` — FIXED (commit after d3815e7).**
  Real defect: LiteRT v2.1.6's pip build ships the pybind ext FILE as
  `_pywrap_tensorflow_interpreter_wrapper.so` but its PyInit_ symbol + all importers use
  the litert name, so `import` couldn't find the file (fails on ALL arches incl. native
  amd64 — so NOT a cross/SOABI issue). Ground-truth: importing the ext under the
  tensorflow name errors "no PyInit__pywrap_tensorflow…", i.e. the binary IS the litert
  module, just misnamed. build-litert.sh now unpacks each staged wheel, renames the ext
  to match its symbol, and repacks (recomputes RECORD).
- **tvm — amd64 WIRED (commit 0a7d99e); arm64/riscv64 cross = OPEN follow-up.** Root cause:
  tvm.sh was only COPY'd, never RUN — TVM was never built (0 tvm wheels in the v2 log).
  Added a native `tvm` build stage (FROM base) that runs tvm.sh on amd64 → wheel to
  /opt/tvm-wheels (collect-artifacts → /opt/wheels → runtime venv installs WITH deps) +
  libtvm.so → /usr/local/lib. Best-effort so it can't break the media build. **NEEDS a
  rebuild's `import tvm` smoke to validate** (first-pass; may need a lib-path/deps cycle
  like IREE). **STILL OPEN:** arm64/riscv64 — TVM's LLVM cross-build is a 2-stage host/
  target cross like IREE (the cross path in tvm-python.sh exists but has NEVER run in the
  pipeline); the tvm stage currently no-ops on those arches. Also weigh the base-image
  size cost of shipping TVM on all arches.
- **BY-DESIGN (not defects):** `pyav` (av) — only a `PYAV_VERSION` pin exists, NO build;
  app-extra (dead pin = minor cleanup). `onnxruntime-genai` python — ships as a native
  binding (media smoke PASSes "native binding present"); the python import is optional.
  `libatlas-base-dev` — deliberate OpenBLAS/LAPACK fallback (candidate checked first).
  `iree` ml_dtypes on riscv64 — fixed (python3-ml-dtypes).
- **`libgudev-1.0.so.0` missing breaks ~9 GStreamer plugins at once (S·★★★).** The
  runtime smoke logs `degraded: libgstvideo4linux2.so`, `libgstuvch264.so`,
  `libgstgtk.so`, `libgstgtk4.so`, `libgstva.so`, `libgstnvcodec.so`,
  `libgstopengl.so`, `libgsthip.so`, `libgstv4l2codecs.so` — ALL failing on the same
  `libgudev-1.0.so.0: cannot open shared object file`. Adding one runtime dep
  (libgudev-1.0-0) to the package image likely un-degrades that whole cluster.
  Highest value-per-effort media fix. Remaining single-plugin gaps (lower priority):
  `libopenh264.so.8`, `libsrtp2.so.1`, `libwavpack.so.1`, `libv4l2.so.0` (also needs
  gudev), `librice-proto.so.0` (webrtcbin2), `libcsound64.so.6.0`,
  `libcdda_paranoia.so.0`. Decide per plugin: ship the runtime lib or drop the plugin.
- **`libvvdec.pc` not collected → possible H.266/VVC gap (S·★★).** copy-media-payloads
  warns `optional payload missing: /usr/local/lib/pkgconfig/libvvdec.pc` on every arch.
  VVdec (VVDEC_VERSION=v3.1.0) builds but its pkg-config isn't in the artifact set, so
  ffmpeg/gstreamer VVC detection downstream can't find it. Verify VVdec is actually
  wired into the finals or fix collect-artifacts to include libvvdec.pc.
- **riscv64 `uv.lock` regeneration fails, silently falls back (S·★★).** The riscv64
  torch/wrapper stage logs `WARNING: uv lock regeneration had issues on riscv64;
  continuing with --find-links + local`. Works, but the venv is then resolved off a
  different path than amd64/arm64 (drift risk). Root-cause why `uv lock` breaks under
  qemu-riscv64 and make the fallback explicit/asserted rather than a warning.
- **riscv64 Python `iree` blocked on `ml_dtypes` (M·★★).** `[WARN] iree
  ModuleNotFoundError: No module named 'ml_dtypes'` — the iree_base_runtime wheel deps
  ml_dtypes, which has no riscv64 PyPI wheel, so `import iree.runtime` degrades on
  riscv64 (native iree-compile PASSES). Options: source-build ml_dtypes into the
  riscv64 wheelhouse, vendor it, or formally accept riscv64 python-iree as best-effort.
- **`--cache-from type=local` noise when the dir is absent (S·★).** 11× `could not
  read .../kata-buildcache/...` when a local cache-export dir doesn't exist (first run
  or after pruning). cross-stage-build.sh should only pass `--cache-from type=local`
  when the dir exists, to keep logs clean and avoid implying a cache problem.
- **auditwheel manylinux-retag NOTE spam (S·★).** Every local wheel (iree, litert,
  libcamera, onnxruntime_dnnl, …) logs `auditwheel cannot retag … host glibc newer
  than the profile; shipping unrepaired`. Expected (in-image use), but N-wheels ×
  3-arches of NOTEs is noise — emit once per stage, not per wheel.
- **IREE LLVM builds are the media time sink (data point, not new action).** The two
  slowest single stages were ~4020s and ~3971s (~67 min each) = the from-source IREE
  LLVM app-wheelhouse builds; next tier ~2100–2260s are the gcc/llvm compiler stages.
  Confirms the ccache-warmth and `--from-stage media` fast-path items above are where
  the wall-clock actually is.

## Harvested 2026-07-18 — deep 3-agent audit of the webval build (log + changes + cross-correctness)

Verified findings (each ground-truthed against the webval log or live images before acting):
- **FIXED (9d793d1):** web-asset smokes were FATAL under set -e but the vendor is
  best-effort → a truncated/partial vendor or an upstream variant-count change would
  break the media build. Downgraded magic/count/node-compile checks to WARN (optional
  browser assets, served not loaded).
- **FIXED (9d793d1):** GStreamer plugin health check only counted `ldd => not found`
  (missing .so), MISSING undefined-symbol load failures → reported "0 cannot load"
  while gtk4/gtk were actually broken on arm64/riscv64. Now drives gst-inspect (real
  scanner) — verified it reports the 2 genuinely-broken plugins.
- **FIXED (9d793d1):** onnx-web WASM compile became load-bearing on any arch (amd64-only
  skip removed) → made best-effort (ships empty on failure, not a build break).
- **FIXED (d60c166):** gtk4/gtk sinks unloadable on arm64/riscv64 — libgtk-4.so.1
  `undefined symbol: vkCreateWaylandSurfaceKHR` (cross runtime Vulkan lacks the Wayland
  surface ext amd64's full SDK has). Disabled the gtk plugin on those cross arches
  (display-only, useless headless). Confirm on next rebuild.
- **FIXED earlier (5d18bc8):** riscv64 ml_dtypes → source-built into the venv.
- **FALSE POSITIVE (verified):** an agent flagged the LiteRT cross wheel as shipping a
  host-x86_64 SOABI ext. Live riscv64 image proves otherwise: the ext is
  `_pywrap_litert_interpreter_wrapper.so` (plain name, no SOABI), ELF machine=riscv64,
  and `from tflite_runtime.interpreter import Interpreter` imports fine. No fix needed.
- **NOT A DEFECT (reviewed):** smoke `installed_version()` metadata fallback "masks import
  failures" — it's INTENTIONAL for the cross-build sandbox (imports legitimately fail
  there); the functional on-target import IS gated by the app-wheel smoke. Leave as is.
- **OPEN (deliberate cross limitation, low priority):** riscv64 ffmpeg ships without
  gnutls (HTTPS/TLS), libass (subtitles), sdl2, freetype (drawtext), svt-av1 — each an
  explicit documented skip because Ubuntu-Ports/FFmpeg's cross-probe can't satisfy them
  on riscv64. Improvable (like the earlier openssl-sys cross fix) but non-trivial.
- **COSMETIC:** `import ai_edge_litert` (branded top-level) fails while `tflite_runtime`
  works; the app + smoke use tflite_runtime, so functionally fine.
- **Validated SAFE by the changes-review agent:** all new Dockerfile COPYs (source dirs
  always mkdir'd), --no-push/CROSS_NO_PUSH wiring, disk gate, pywrap rename, ml_dtypes
  relocation, nv-codec removal.

## 2026-07-18 — second deep audit (post-tvmval-launch, 2-agent fresh sweep)

Re-audited the surface changed SINCE the first deep audit (the audit-fix commits
themselves + TVM cross + orchestrator DX), which the earlier pass never reviewed.

### FIXED (commits 2630844, 48b5a7b)
- **`install_target_packages` had no per-package fallback (2630844).** The cross
  primitive every media build routes through did a single atomic `apt-get install`;
  one unresolvable/renamed SONAME aborts the whole transaction (apt installs
  nothing) and callers `|| true` it, so ~20 required libs (gstreamer graphics/HLS/X11
  batches at install-deps.sh:105/150/206) vanish silently — the exact bug the
  host-side `install_host_packages` fix already addressed, left on the target twin.
  Ported the isolate-and-retry-per-package loop; `cross_package_files_present`
  stays the arbiter (preserves foreign-postinst-noise tolerance).
- **ELF-arch mismatch check was toothless (2630844).** validate-media-runtime.sh
  printed `MISMATCH: <bin> ELF machine=...` for a wrong-arch artifact but exited 0;
  smoke-media skips execution on cross, so nothing caught it. Now counts non-vendor
  mismatches and `exit 1`s (escape hatch `MEDIA_ELF_MISMATCH_FATAL=0`). Directly the
  host-vs-target-triple defect class this whole effort fights.
- **`--no-push` broke the runtime manifest step (48b5a7b) — HIGH.** First `--no-push`
  run to reach the runtime stage (every prior validation run actually pushed). Under
  --no-push the wrapper tags are never pushed, but create_manifest still ran
  registry-based `nerdctl manifest create` → "no such manifest" → set -e aborts at
  the very end, before the boot-smoke. Fixed both ways: orchestrator passes
  --skip-manifest under CROSS_NO_PUSH, AND build-runtime-manifest.sh honors the
  exported env directly (reaches an already-running orchestrator, which reads that
  script live). Per-arch images still build + load locally + boot-smoke.
- **`gtk_feature` was a global, not `local` (48b5a7b).** Stale `disabled` from a prior
  cross arm64/riscv64 call could leak into a later native/amd64 call in the same
  shell. Declared `local` to match its sibling `python_feature`. Latent (each arch
  builds in its own process today).

### VERIFIED SAFE (checked, no change)
- **TVM cross / BUILD_MODE inheritance.** `BUILD_MODE` is a real ENV in the `base`
  stage (inherited by `tvm` FROM base); orchestrator passes `--build-arg
  BUILD_MODE=cross` for every arch; `cross_build_is_active` = `BUILD_MODE=cross AND
  target≠host`, so amd64 correctly takes native and arm64/riscv64 take cross. Wheel
  glob (`apache_tvm-*|tvm-*|tvm_ffi-*|apache_tvm_ffi-*`) matches `python -m build`
  output; retag rewrites only the platform tag, never the dist name → stays best-effort.
- **smoke-media non-fatal web checks + gst-inspect health check** — no residual `fail`,
  heredoc parses, gst-inspect stderr-capture correct, all WARN-only.
- **disk gate math** — sound; two limitations (measures buildcache-parent fs not the
  containerd data-root when split-mounted; coreutils-only `df --output`), neither a
  false-abort. Logged as low-priority below.

### STILL OPEN (lower priority, from the robustness sweep)
- **opencv sends ALL target_packages through `install_optional_target_packages` on
  arm64/riscv64** (install-deps.sh:51-53) — core codecs (libjpeg/png/x264/avcodec) are
  silently droppable, not just the flaky harfbuzz/gst chain that motivated best-effort.
  Split genuinely-required codecs into a fatal `install_target_packages` call. (Now
  lower risk since #1's per-package fallback makes a required batch tolerant of one
  bad name.)
- **media runtime image uses a hand-maintained codec runtime-lib list**
  (03-media/runtime/install-deps.sh:53-96) while the torch image auto-derives from the
  ffmpeg manifest + fail-loud SO-closure assert. This list already drifted once
  (libgudev/libcdparanoia comment). Converge on the manifest + closure assert.
- **`so-package-map.txt` is a third source of runtime-lib truth** with hardcoded
  versioned SONAMEs — manual edits needed on each Ubuntu base bump.
- **disk gate: measure the containerd/buildkit data-root fs**, not the buildcache dir's
  parent, for the split-mount case; guard the coreutils-only `df --output` path.
- **riscv64 ffmpeg TLS via openssl** — libssl-dev is already installed on all arches
  (gstreamer/install-deps.sh:201), so `--enable-openssl` is an available alternate TLS
  backend for riscv64 instead of the unconditional gnutls skip (like the openssl-sys
  cross fix). Attempt an openssl cross-probe rather than short-circuiting.

## 2026-07-18 — speed + feature pass (3-agent audit: speed / features / complexity)

Third deep audit lens (maintainability/speed/features/complexity). User picked: ccache +
wire/enable --parallel-archs (speed); ONNX WebGPU + ffmpeg x265 (features). All committed;
the two features are gated OFF so the in-flight tvmval run is unaffected — flip on in the
combined validating rebuild.

### DONE — speed
- **ccache on the cross app-wheelhouse (dcc6ce8).** install_build_dependencies omitted
  ccache on the arm64/riscv64 paths (only amd64-native had it), so the ~1h IREE
  bundled-LLVM (×2 arches) + multi-hour riscv64 torch aten compiles rebuilt from scratch
  every run despite the persistent /var/cache/ccache mount + already-wired cmake launcher.
  Added ccache to both cross branches; build_torch_wheel now sets the launcher + CCACHE_DIR.
- **BUILD_MEM_DIVISOR wired (9df9414).** parallelism.sh sizes jobs as RAM/BUILD_MEM_DIVISOR
  but nothing ever SET the divisor (only read) — so --parallel-archs would N× overcommit RAM
  and OOM. Added cross_build_mem_divisor()=min(MAX_PARALLEL_ARCHS,#arches) under
  PARALLEL_ARCHS, forwarded via append_cross_build_args + ARG/ENV in toolchain/sdk/media/
  android Dockerfiles. Serial default=1 (inert). Enable --parallel-archs in the validating
  rebuild; watch resource-monitor for OOM (intra-Dockerfile stage parallelism means model
  holds total RAM ~constant vs serial, but verify).

### DONE — features (gated off; enable in validating rebuild)
- **ffmpeg libx265 HEVC encode (02f8718).** Was unconditionally --disable-libx265 despite
  libx265-dev installed. New ffmpeg_probe_libx265 + FFMPEG_ENABLE_X265 gate (versions.env,
  default 0). Flip to 1 to validate; if the old source-x265 compile break recurs, pin a
  known-good x265/ffmpeg pair.
- **ONNX WebGPU (Dawn) EP (9adcdd5).** Was wired but dormant (ORT_ENABLE_WEBGPU never set).
  New onnx_webgpu_enabled_for_target(): amd64 on when ORT_ENABLE_WEBGPU=true; arm64/riscv64
  need ORT_WEBGPU_ALLOW_CROSS=true too (Dawn cross unproven). Validate amd64 first.

### DEFERRED (until tvmval completes — critical runtime-venv path)
- **Wheel-family glob classifier (assemble-torch-app.sh).** opencv 4-name glob verbatim ×3
  (109/133/290), torch/litert/iree/tvm globs split across ~8 sites — already bit once
  (dropped-torch-wheel). DRY into one _wheel_family classifier. Behavior-sensitive; do
  post-tvmval with full verification.

### NOT TAKEN this round (offered, user deferred) — still open
- Toolchain speed flags (host GCC 3-stage bootstrap, host clang double-build, CPython PGO
  all ON) → ~50-100min CI saving, trades self-miscompile checks. GCC_HOST_BOOTSTRAP=0 /
  clang --no-bootstrap / PYTHON_PGO gate.
- Trim built-but-maybe-unused: clang-tools-extra ×3, BUILD_GENAI source ×3, redundant
  SDK-stage TVM (built then wiped by media `uv venv --clear`).
- Feature: llama.cpp + Vulkan backend (absent all arches; agent's top pick), ONNX ACL EP
  on arm64 (verify --use_acl survives ORT 1.27), ffmpeg libvvenc (VVC encode), TVM
  CUDA/OpenCL codegen tied to ENABLE_NVIDIA, riscv64 ffmpeg TLS-via-openssl.
- Minor: GCC install/clang install single-threaded (add -j/--parallel); onnx WASM 4×
  no-ccache; tvm.sh non-shallow recursive clone; pre-existing NV_CODEC_HEADERS_REF script
  default drift (n12.2.1 vs versions.env n13.0.19.0, advisory).

## 2026-07-19 — disk strategy + feature-enabled publish run

### Disk findings (rootless nerdctl+buildkit)
- **buildkit OCI-worker cache (~348G) is NOT pruneable mid/post-run** — `buildctl prune
  --all` and `nerdctl builder prune --all` both reclaim 0B; every record pins as
  `Reclaimable:false` (held as image results). Only a buildkitd restart w/ a
  keepstorage GC policy would cap it (avoided: "never kill buildkitd").
- **Deleting an intermediate image TAG frees ~nothing** — cross-android-<arch> is FROM
  cross-media-<arch>, so they share layers; only deleting a FULL image set (all of an
  arch's chain, or the whole tag family) frees space.
- **Effective bulk cleanup** (done out-of-band before a run, freed 210G: 75G→285G):
  `nerdctl rmi` the stale feature-less intermediates (cross-media-*/cross-android-*)
  and the re-pullable published `latest-cross-*` locals (they're on ghcr; the new build
  replaces them). containerd 258G→48G.
- **Wired mid-build guard (56adf0c):** `_chain_stage_disk_guard()` clears the regenerable
  kata-buildcache export between stages when free < CROSS_DISK_GUARD_GB (default 40) —
  the only reclaimable mid-run space. Off with CROSS_DISK_GUARD_GB=0.
- **Push mode is more disk-friendly than --no-push** — offloads images to ghcr instead of
  retaining all locally, so a publishing chain fits where a --no-push validation didn't.

### Publish run (in progress)
Full media→android→runtime, 3 arches, PUSH (new :latest-cross), SERIAL, x265+WebGPU(amd64)
enabled. parallel-archs deliberately NOT used — it 3×'s peak disk on the exact constraint
being managed; validate it separately on a cached scope, not on a 10h production publish.

## 2026-07-19 — WebGPU (Dawn) does NOT build with GCC 16.1.0 [FINDING]
Enabling ORT_ENABLE_WEBGPU=true failed the amd64 onnxruntime NATIVE build:
Dawn's tint compiler (`_deps/dawn-build/src/tint/.../tint_lang_core_intrinsic`) fails to
compile (`type_matchers.h` MatchMat error → gmake Error 2 → "ONNX Runtime CPU build failed
after 3 attempts"). This is on amd64 native — not even cross — so Dawn is incompatible with
the toolchain (GCC 16.1.0), not a cross-only gap. WebGPU reverted to gated-OFF (its default).
To ship WebGPU later: pin a Dawn/onnxruntime combo that builds under GCC 16, or build Dawn
with clang. x265 kept ON for the publish (probe-gated; libx265 4.1-4 installs cleanly).

## 2026-07-20 — WebGPU (Dawn) FIXED for GCC 16.1.0 ✅
Root cause of the earlier Dawn build failure: tint's generated data.cc has 36 constexpr
matcher functions calling the non-constexpr MatchMat; GCC 16 raises -Winvalid-constexpr
and errors on it, because Dawn feeds clang-only -Wno-* flags (e.g.
-Wno-unknown-warning-option) that GCC silently drops, leaving the diagnostic unsuppressed
(clang ignores it by design → Dawn builds everywhere else). It was the ONLY error type.
Fix (common.sh, append_onnx_optional_lto_webgpu_args): when WebGPU is enabled, inject
`CMAKE_CXX_FLAGS=-Wno-error=invalid-constexpr -Wno-invalid-constexpr` into the Dawn build.
VALIDATED via a targeted onnxruntime-stage diagnostic (ORT_ENABLE_WEBGPU=true): 0
invalid-constexpr errors, onnxruntime CPU build + WebGPU EP "Build complete", all artifact
checks pass. Re-enabled ORT_ENABLE_WEBGPU=true (amd64; ALLOW_CROSS stays false).

## 2026-08-02 — AGENTS.md/README/overview doc dedup, remaining items

Done in this pass: Host Constraints table removed from AGENTS.md (it was a
strict subset of Common Failure Modes); WindowsContainerBuild.Reuse function
list in AGENTS.md updated 3 -> 10; README's 01-core module enumeration now
defers to AGENTS.md's Repo Map (the two lists had already drifted); Repo Map
gained windows/ and shared/agentic-loop/prompts/ entries.

Still open (needs a careful row-by-row equivalence check before deleting):
- AGENTS.md's "per-library build notes" and "Windows Scripts" tables largely
  restate docs/windows-builds.md, which AGENTS.md links right below them.
  Decide the single home (windows-builds.md) and collapse the AGENTS.md
  tables to a pointer — but only after verifying every row-level fact
  (patch names, memory caps, EP flags) survives in the doc.
- docs/overview.md carries a third, coarser copy of the script-tree /
  build-chain description; align it with the Repo Map or trim to links.

## 2026-08-02 — repo has no LICENSE file

Surfaced by the BeschleunigerBallett third-party-license audit: this
repository contains no LICENSE/COPYING anywhere, so consumers cannot state
its terms (the audit had to list it as "unverified"). Owner decision needed:
pick a license (the sibling Kataglyphis repos use MIT) and add the file.

## 2026-08-07 — harvested during the from-base rebuild (Windows lane)

All of these were observed live during one full chain rebuild, not reasoned
about in the abstract. Ordered by value, not by effort.

### P1 — `versions.env` invalidates the ENTIRE media chain

`Dockerfile.media-builder`'s `common` stage does `COPY versions.env`, and all
three branch envs descend from it, so **any** edit to that file re-runs all six
media compiles (ONNX ~75 min, OpenCV, FFmpeg, GenAI, litert, tvm). Adding three
Windows toolchain pins today therefore turned what should have been a one-hour
merge-stage test into a full media rebuild — the cost was discovered only when
the ONNX layer failed to cache-hit.

This is the same class of problem the per-file module mounts already solve for
scripts: the file is copied wholesale, but each branch consumes only a handful
of keys. Options, cheapest first:

- pass the branch's keys as `--build-arg` (the drivers already compute exactly
  these — `Get-MediaBranchVersionArg`) and drop the `common` COPY entirely, so
  a versions.env edit invalidates nothing it does not actually change;
- or split the file per lane so a Windows-only pin cannot touch Linux stages;
- or move the COPY below the per-branch ENV blocks so it keys into fewer stages.

Note the scripts re-read `C:\temp\versions.env` at RUN time, so whatever is
chosen must keep that contract (see the re-COPY comments in the media builders).

### P2 — ✅ DONE (69b860e) — retry engine burned its budget on deterministic failures

`ImportLayer 0xb7` failed three times today with **byte-identical snapshot IDs**
(`3p059m2d68o… → o47dumb0ovs4…`). The pattern matched `failed to reimport
snapshot`, so the engine treated it as a flake and paid two pointless retries
plus cool-downs before failing. A flake changes; a poisoned snapshot does not.

Suggested refinement in `Invoke-TransientCooldown` / `Invoke-BkStage`: remember
the previous attempt's failure tail and **stop early when the new tail is
identical** — "deterministic, not transient". Cheap to implement, saves ~10 min
per occurrence, and the message can point straight at the `-NoCache` remedy.

### P3 — ✅ DONE (69b860e) — disk gate was start-time only, and that is how a snapshot got poisoned

`Assert-DiskHeadroom` passed at 164 GB and the chain still walked down to 23 GB
mid-run, into the band where hcsshim stops failing honestly. The rescue (killing
the solve) is what left the half-committed snapshot that then cost three failed
attempts and a `-NoCache` rebuild.

A per-stage check would have prevented the whole sequence: `Invoke-BkStage`
could refuse to START a stage below a floor and say which cleanup lever applies,
instead of letting the chain discover the wall inside a heavy RUN. The floor
wants to be stage-aware — CUDA needs ~36 GB, the media branches far more — so a
rough per-stage cost table beats one global number.

### P4 — ✅ DONE (see below) — CNI conf: presence was guarded, CONTENT drift was not

`Get-CniConfFormIssue` (added today) checks that both `0-containerd-nat.conf`
and `.conflist` exist, and `verify-host-setup.ps1` compares their `ipam.subnet`.
Nothing keeps the rest of the two files in sync, and they are hand-maintained
copies of each other — the classic two-copies-drift shape this repo eliminates
everywhere else. Better: generate the `.conf` FROM the `.conflist` (unwrap
`plugins[0]`) in `apply-containerd-config.ps1`, so one file is authored and the
other is derived.

Related, smaller: `Get-CniNatSubnetDrift` and `Get-CniConfFormIssue` are two
functions for one concern. A single `Test-CniHealth` returning a list of issues
would let the driver report every problem at once instead of the first.

### P5 — small, safe, do them on a base rebuild that is already being paid for

- `Dockerfile.base`'s tail `ENV PATH` carries `$SCOOP_HOME;$SCOOP_GLOBAL` — the
  scoop *app roots*, which contain no executables. Two dead PATH entries in
  every image.
- `windows/BUILD-OBSERVATIONS.md` still opens with "NOT source; safe to delete",
  but now holds the authoritative four-root-cause GStreamer analysis. Either
  move that analysis into `docs/windows-builds.md` or drop the disclaimer.
- `pwsh -File build-buildkit.ps1 -Stages a,b,c` passes the list as ONE string
  and dies on the `ValidateSet` (hit today). Either document the call operator
  form in the examples or accept a comma-separated string and split it.
- `smoke-test-container.ps1` is ~1500 lines in one file; the section structure
  is already there in comments and would split cleanly.

### P6 — harvested from the ONNX build log of the same run (compiler-flag noise)

The ONNX CUDA compile emits a few warnings hundreds of times each. Most is
upstream noise, but two are worth a decision, and the ownership was checked
rather than assumed (`grep` over `windows/` + `linux/`):

- **`clang-cl: warning: argument unused during compilation: '/Zc:preprocessor'`
  (307×) — NO ACTION. Retracted after checking the precondition.**
  The first version of this entry claimed the flag was ours and inert. The
  precondition it demanded be verified was then verified, and it **falsifies the
  claim**: `WindowsSourceBuild.Cuda.psm1` sets
  `-DCMAKE_CUDA_HOST_COMPILER:FILEPATH=$clExe` from
  `(Get-Command cl.exe).Source`, i.e. **nvcc's host compiler on this lane IS
  MSVC `cl.exe`, not clang-cl** — exactly the case where CCCL genuinely needs
  `/Zc:preprocessor`. Our injection is load-bearing; removing it would break
  CUDA compilation.
  The 307 warnings come from clang-cl compilations (they are counted alongside
  307 `-fdelayed-template-parsing` warnings, a clang-only flag `cl.exe` would
  reject), so a different flag source — upstream ONNX's own CXX flags — puts
  `/Zc:preprocessor` on the clang-cl command line, where it is ignored. Not
  ours, not actionable, and now recorded so the next reader does not repeat the
  investigation or "clean up" a flag the CUDA build depends on.
- **`-fdelayed-template-parsing is deprecated after C++20` (307× in ONNX) —
  NOT ours in this stage.** We pass it only in
  `build-litert-lm-from-source.ps1` (with a matching `-Wno-…` right next to it);
  the ONNX occurrences come from upstream's own CMake. No action on ONNX, but
  **the pin makes this a scheduled problem**: LLVM is now fixed at 22.1.8, and
  a future bump can turn this deprecation into a removal, which would break
  litert-lm's flag set. Worth a note at the litert-lm call site so the next
  LLVM bump knows to look there.
- `/Zc:lambda` (60×), the `-Wunused-value` floods from ONNX's own headers
  (`stream_handles.h`, `execution_provider.h`, `data_types_internal.h`, 600×
  each), and the DML `use 'template' keyword` / D3DX12 enum warnings are all
  upstream. Known noise — the same category the existing
  "Verified NOT problems" list in `windows/BUILD-OBSERVATIONS.md` records.

### P7 — 🔴 DEFECT: FFmpeg's installed .pc files are unusable (found by probing the built image, 2026-08-07)

Probed `bk-windows-media-core-ffmpeg` directly rather than waiting for the merge
stage. All seven `libav*.pc` / `libsw*.pc` files exist at
`C:\runtime\ffmpeg\lib\pkgconfig`, but their content is broken in two
independent ways:

```text
prefix=/c/runtime/ffmpeg            <- MSYS path, not a Windows path
libdir=/c/runtime/ffmpeg/lib
Version: ..                         <- version fields EMPTY
Requires.private: libswresample >= .., libavutil >= ..
Libs: -L${libdir}  -lavcodec
```

1. **`Version: ..`** — the major/minor/micro substitutions produced nothing, so
   only the separating dots remain. Any consumer with a version constraint fails:
   gst-libav asks for `libavcodec >= 58.18.100`, `libavformat >= 58.12.100`,
   `libavutil >= 56.14.100`, `libavfilter >= 7.16.100`. **This alone keeps
   gst-libav out of the image**, independently of the `FFmpeg.wrap` problem
   already recorded — so `libav` had TWO separate causes, and fixing only the
   wrap would not have been enough.
2. **MSYS-style paths** (`/c/runtime/...`). pkg-config hands those to the
   compiler verbatim, and clang-cl / lld-link cannot resolve them; a consumer
   that gets past the version check still gets unusable `-I`/`-L` flags. Note
   `build-ffmpeg-from-source.ps1` already knows this class of problem — it takes
   care to give nv-codec-headers a forward-slashed *Windows* path (`C:/...`) so
   `ffnvcodec.pc` comes out right — but FFmpeg's own `--prefix` evidently goes in
   MSYS form.

Likely cause for (1): FFmpeg derives its version from `git describe` and the
build clones shallow (`--depth 1 --branch n9.0`); without tags in the clone the
substitution yields empty strings. Worth checking whether configure logs a
version-detection failure.

Fix direction: pass a Windows-style `--prefix` (matching the ffnvcodec handling)
and make the version explicit to configure rather than relying on git metadata —
FFMPEG_VERSION is already pinned in versions.env, so the value is at hand. Then
assert the generated `.pc` (non-empty `Version:`, `C:`-shaped `prefix`) at the
end of the FFmpeg stage, because this failed silently for months: the files
existed, so nothing looked wrong.

Also worth hardening: `Assert-PkgConfigModule` currently only runs
`pkg-config --exists`, which passes on these broken files. Teaching it the
minimum versions the consumers demand would move this failure from meson's
configure output into the pre-flight, where it names itself.

<<<<<<< HEAD
## 2026-08-07 — Linux toolchain closure audit (during the amd64 from-base run)

Agent-audited while the compiler stage was building. Everything below touches
the compiler closure (per-file bind mounts + the 01-core/02-toolchain bundle
COPY) unless marked otherwise — **apply as ONE batched commit before the next
planned full rebuild**, never piecemeal: every closure touch = new compiler
digest = full downstream rebuild. NOTE the bundle COPY makes the ENTIRE 01-core
directory closure-relevant, including files like resource-monitor.sh that no
RUN step mounts.

### Headline: the ccache wiring is inverted — that's why rebuilds don't speed up

- **GCC RUN mounts /var/cache/ccache but nothing ever execs ccache.** gcc.sh
  never passes `--ccache` (host :192, cross :227, Canadian :310), so
  build-gcc.sh's wiring block (gated `USE_CCACHE=1`) never fires. The cache is
  mounted, empty in, empty out. — S · ★★★
- **LLVM RUN wires ccache (CMAKE_*_COMPILER_LAUNCHER) but mounts NO cache dir**
  (Dockerfile.toolchain:126-128) → zero reuse, and ccache writes land in the
  image layer. Add the ccache+sccache cache mounts. — S · ★★★
- **Host GCC bootstraps** (`--enable-bootstrap`): stages 2/3 are compiled by the
  just-built xgcc, invisible to ccache. `--with-build-config=bootstrap-ccache`
  keeps the self-check and routes stages 2/3 through ccache. — S · ★★
- **Canadian path can never use ccache**: guard `[ -z "${HOST_TRIPLET}" ]` at
  build-gcc.sh:199 excludes it, and CC is re-defaulted later at :600. Prefix
  ccache at the defaulting site; set CC_FOR_BUILD too. — S · ★★★
- **No CCACHE_BASEDIR / SLOPPINESS** → per-target BUILD_DIRs make identical TUs
  hash differently; even a warm cache would mostly miss. — S · ★★
- compiler-cache.sh (01-core) documents itself as the ccache entry point but is
  sourced ONLY by 03-media — it has no bearing on the toolchain stage. Add a
  header note naming its real consumers (signpost fix, prevents this misread).

### Parallel per-target GCC builds (~30 % of the GCC RUN, ~1 h at 3 targets)

Host GCC must stay first (alternatives registration). Then arm64 ∥ riscv64:
1. Hoist `install_cross_gcc_sysroot_packages` (apt) into a serial pre-pass —
   concurrent callbacks collide on the dpkg lock (hard blocker).
2. Reuse run_parallel_arch_loop (parallel-loop.sh; add it to the three mount
   lists) + per-target log files, else failures are unattributable.
3. Fix the jobs math first: BUILD_MEM_DIVISOR divides RAM only; concurrent
   targets each request full nproc (gcc.sh passes JOBS=$(nproc)) → CPU
   oversubscription. Apply the divisor to cores in compute_jobs.
GCC_TARBALL_CACHE_DIR is already concurrency-safe (atomic rename); BUILD_DIRs
are disjoint; cross builds already --skip-system-registration. Peak disk ~2×.

### Next-rebuild breakers / hardening

- Dockerfile.toolchain:161,166: LLVM_CROSS_SOURCE_ROOT + llvm-src cache mount
  are ignored by build-clang.sh (:148 uses LLVM_BUILD_ROOT) — the ~2 GB clone
  is paid twice when the source path triggers. Honour it as the work root.
- repos.sh:38-48 `llvm_repo_available` dies on any non-200/404 (503/timeout
  kills a multi-hour layer). Treat 5xx/000 as "unavailable → source build".
- cmake.sh:6,17,21: CMAKE_VERSION default AND both SHA256 fallbacks hardcoded,
  invisible to verify-arg-consistency.sh → next CMake bump can fail as a bogus
  "checksum mismatch". Fail loudly when version is set but SHA is not.
- Shell-side version fallbacks drift silently (gcc.sh:429-433 "16.2.0"/"15.2.0",
  common.sh llvm_release_version "22.1.8"): extend verify-arg-consistency.sh
  (checker itself is closure-free) to diff these literals too.
- build-gcc.sh:576-581: riscv64 `--with-isa-spec=20191213` still never validated
  on real hardware — batch an on-device assemble smoke into the next rebuild.
- build-helpers.sh sits in all three heavy mount lists solely for
  strip_elf_tree (used once, build-clang.sh:304; bootstrap.sh already carries a
  fallback). Move strip_elf_tree into bootstrap.sh, drop the three mounts →
  host-orchestrator edits stop busting the GCC layer. (Bundling move, not dedup.)
- Latent IFS class (safe today, both compiler-closure): vulkan.sh:161 and
  llvm-cross.sh:164 iterate `${var//:/ }` — breaks if ever sourced from a
  strict-IFS script. Switch to `IFS=':' read -r -a`. Also reword the
  build-helpers.sh:54 doc comment that recommends the broken idiom.
- resource-monitor.sh:133: `pgrep -c` exits 1 on no match → sampler dies under
  errexit on an idle tick. `|| true` it. (01-core → still closure via bundle COPY.)
=======
### P8 — harvested from the litert/tvm stages of the same run (observability + log volume)

- **`WARNING: 5 lib stub(s) could not be created` names none of the five.**
  litert-lm pre-creates 319 ExternalProject `.a`/`.lib` stubs because the
  aggregate target references libraries that do not exist yet; five failed this
  run and the build succeeded anyway, so they were harmless *this time*. But the
  warning is unactionable as written: when lld-link eventually does fail with
  `could not open <path>`, nothing connects it back to this line. One-line fix —
  log the failed paths, not just the count. Cheap, and it turns a shrug into a
  lead the next time the litert link breaks.

- **16 % of the build log is upstream compiler warnings — 72 864 of 459 061
  lines in one chain.** Measured, not estimated. The floods are a handful of
  known-benign upstream constructs repeated a thousand times each:

  | source | warning | count |
  |---|---|---|
  | OpenCV `core/matx.hpp` | deprecated implicit copy assignment (7 operators) | ~7 700 |
  | ONNX `stream_handles.h` / `execution_provider.h` | `-Wunused-value` | ~2 460 |
  | IREE / MLIR `BuiltinAttributes.h` | MSVC STL4037 `'complex' is deprecated` | 657 |
  | TVM `tvm/ffi/reflection/accessor.h` | `-Wdocumentation-unknown-command` | ~900 |

  This is not cosmetic. buildkitd clips each RUN step's log at 2 MiB and then
  **deadlocks** the step (documented in windows-builds.md § BuildKit lane), which
  is why `BUILDKIT_STEP_LOG_MAX_SIZE=-1` is a required host setting. Cutting the
  floods would shrink the exposure and make the logs searchable again — a real
  failure signal currently hides among ~73 000 warnings.

  Fix direction: per-stage, TARGETED `-Wno-` flags for exactly these identified
  upstream constructs (e.g. `-Wno-deprecated-copy-with-user-provided-copy` for
  the OpenCV TU set, `-Wno-unused-value` for ONNX's headers), never a blanket
  `-w` — the point is to silence known upstream noise, not our own diagnostics.
  Each suppression should carry the count it removes, so a future reader can
  judge whether it still earns its place.
>>>>>>> b7c9751d65f74ab744bc499720d78ed622ed4a8a
