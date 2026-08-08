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

### P7 — ✅ DONE (2026-08-07/08): FFmpeg's installed .pc files were unusable (found by probing the built image)

> **The fix direction proposed at the bottom of this entry was WRONG and was not
> taken.** "Pass a Windows-style `--prefix`" is impossible: configure runs under
> MSYS bash and `make install` puts the tree in the wrong place without an MSYS
> prefix. The MSYS prefix is *required* going in and rewritten in the installed
> `.pc` files afterwards. Cause (1) was also mis-guessed — see below.
>
> Shipped instead: a `VERSION` file written before configure (the real cause: the
> source is a GitHub **auto-tarball**, which ships no VERSION file, and the
> post-extraction `git init` carries no tags — so the guess about `--depth 1`
> was close in spirit but wrong in mechanism), a post-install MSYS→Windows
> prefix rewrite, and `Assert-FfmpegPkgConfig` at the end of the stage.
> `Assert-PkgConfigModule` did get the suggested `-MinimumVersion` floors.
> The gate is unit-tested (`SourceBuild.Artifact.Tests.ps1`) via AST extraction,
> since it must stay OUT of the shared module's compile closure.

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

### P8 — ✅ stub-names DONE; warning floods still open — harvested from the litert/tvm stages of the same run (observability + log volume)

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

### 2026-08-08 — batch APPLIED (except the items below)

The closure batch above was implemented on 2026-08-08 (ccache wiring for
host/cross/Canadian GCC incl. CCACHE_BASEDIR/SLOPPINESS and the multi-word-CC
PATH fix; LLVM RUN ccache/sccache mounts; LLVM_CROSS_SOURCE_ROOT honored by
build-clang.sh; llvm_repo_available 5xx tolerance; cmake.sh SHA-vs-version
guard; vulkan.sh/llvm-cross.sh IFS-scoped splits; resource-monitor pgrep guard;
arch_list_to_words doc warning; case-mapped version literal check added to
verify-arg-consistency.sh; R2 BUILT_THIS_RUN in the local build path; R3 error
propagation through runtime_build_chain; Dockerfile.package ENV re-declaration;
compiler-cache.sh consumer note). Parallel target-GCC landed GATED:
`GCC_PARALLEL_TARGETS=1` (default 0 = sequential unchanged); serial apt
pre-pass, per-target logs, divided JOBS.

Two agent-report claims were DISPROVEN during implementation — kept here so
they don't come back:
- **`--with-build-config=bootstrap-ccache` does not exist in GCC 16.2.0**
  (verified against the tarball's config/*.mk); on a bootstrapped host build
  ccache covers stage1 only. Do not add that configure flag.
- **`build-helpers.sh` is NOT mounted "solely for strip_elf_tree"** — it
  defines `run()`, used by 11 toolchain scripts in-container. Dropping its
  mounts would break every guarded command. Item withdrawn.

Still open: riscv64 isa-spec on-device smoke (needs a riscv64 run);
RUNTIME_CONTEXT_ROOT in the disk preflight (edit blocked while a chain run is
live — build-cross-chain.sh is the running orchestrator's main file);
parallelism.sh core-divisor (superseded for GCC by the driver's own JOBS split).

### 2026-08-08 — accelerator/helper-lane audit (batch leftovers)

Confirmed-latent items DEFERRED because their files sit in the toolchain
bundle COPY (fixing now would bust the push run's compiler cache) or in the
untouched NVIDIA lane — fold into the post-push closure batch:
- smoke-common.sh:186 — smoke_uname_name unguarded under set -e makes the
  "Unknown arch" guard at :189 unreachable (latent on amd64 hosts).
- 01-core/install-tensorrt.sh:17 + 01-core/verify-cuda-stack.sh:14,21,28 —
  unguarded find|head assignments (NVIDIA lane only; verify-cuda-stack is a
  self-declared non-fatal banner that could abort).
- Dockerfile.nvidia:88 — same shape, unreachable today (COPY-guaranteed dir).
- smoke-cross-all-arches.sh:73 — cross_gpp missing from the local declaration.
- verify-runtime-paths.sh — GCC_VERSION never expands for envsubst (tr strips
  the escape BEFORE envsubst runs; var not exported) → permanent phantom
  "/opt/gcc-\/bin" WARNs; fix when making the checker a real gate.
- preflight.sh:41,47 (_in_csv leaks globals), :82 (failed git ls-files makes
  the w/crlf check pass falsely); verify-patch-integrity.sh:59 no-op grep -qv;
  verify-parity.sh:491 unreachable continue; lint-shell.sh:113 empty-array
  expansion (bash<4.4 only).

### 2026-08-08 — caching-coverage review (answering "cachen wir überall?")

Two real gaps found, both safe to close only between runs:
- **DONE 2026-08-08 (restart pending):** buildkitd config written to
  ~/.config/buildkit/buildkitd.toml (gckeepstorage=500GB). Activate BETWEEN
  runs: `systemctl --user restart buildkit`. Original finding: →
  DEFAULT GC policy governs the layer store. Nothing pins how much of the
  multi-hour GCC/LLVM/media layer cache survives between runs; an eviction
  between the validation run and the push run would silently cost hours. Add
  ~/.config/buildkit/buildkitd.toml with an explicit [worker.oci] gc policy
  (keepstorage sized to the disk, e.g. 500GB) and restart buildkitd BETWEEN
  runs, never during one. The local --cache-to exports (kata-buildcache) are
  the existing second net, but re-importing is slower than layer hits.
- **Media source trees are not cache-mounted**: opencv/gstreamer/ffmpeg/onnx
  clones re-download inside their RUN on every cache bust (only onnx-web and
  ffmpeg-sdks have dedicated mounts; llvm-src exists on the toolchain side).
  Version-keyed cache mounts (id=<lib>-src-${VERSION}) would make
  rebuild-after-bust skip the multi-GB fetches. Clones are minutes vs ccache's
  hours, so this is the smaller lever — batch it with the closure work.

### 2026-08-08 — --no-push chain handoff is broken on OCI-worker hosts [FINDING]

The BuildKit OCI worker (this host: oci-worker=true, containerd-worker=false)
keeps its OWN image store. `nerdctl build -t` loads into containerd, which the
next build's FROM never consults — the mutable parent tag resolves against the
REGISTRY. Every downstream stage of a --no-push chain therefore builds on the
last PUSHED parent (proved: fresh compiler shipped /opt/gcc-16.2.0, the sdk
built "from" it contained /opt/gcc-16.1.0 + the old alternatives; probe
`FROM repo@<containerd-digest>` errors "not found").

Fix direction (mirrors the runtime lane's existing local handoff): in
cross_stage_run's push=0 path, export the stage as an OCI layout and hand the
child `--build-context <parent_tag>=oci-layout://<dir>@<digest>` so the FROM
ref is overridden with the local content; delete the layout after the child
consumes it. Until then: --no-push documented as single-stage-only (usage text,
AGENTS quick-ref, cross-builds doc all updated); a warn fires at parse time.

- 2026-08-08: buildkit's 2MiB per-step log clip blinds monitoring during the
  long GCC/LLVM RUNs (the tee'd stage log freezes mid-step while the build
  continues — twice mistaken for a hang today). Raise via
  BUILDKIT_STEP_LOG_MAX_SIZE env on the buildkitd unit at the next restart
  window. Also still open: base cache-missed after the buildkitd restart with
  the new toml despite unchanged mounts and a surviving 119G store — root
  cause unknown, investigate before relying on cross-restart layer reuse.

## 2026-08-08 — Windows lane: refactors landed in the pin-bump window

Context worth recording, because it decided the *order* of this batch: another
session bumped `PYTHON_VERSION` (3.14.7), `OPENCV_VERSION` (5.0.0),
`ONNXRUNTIME_GENAI_VERSION` (v0.15.2) and `LITERT_LM_VERSION` (0.15.0). Since
`Dockerfile.base` COPYs `versions.env` at line 87, everything below it — scoop,
PATH, rust, verify, finalize — is invalidated, and `PYTHON_VERSION` invalidates
the toolchain and every media stage under it. Changes that would each normally
cost a rebuild were therefore FREE in this window, so they were batched here
rather than deferred. Rule of thumb for the next time: hold cache-busting
cleanups until a pin bump or a from-base run is already due, then land them
together.

### ✅ `Dockerfile.base` PATH held two dead entries AND was missing a live one

`$SCOOP_HOME` and `$SCOOP_GLOBAL` are scoop's *app roots* (`apps\`, `buckets\`,
`shims\` live under them; no executables of their own) — dead weight on PATH.
The interesting half is what was absent: flutter is installed `--global`
(`setup-scoop-tools.ps1`), so scoop DOES create `C:\ProgramData\scoop\shims`,
and that directory was on no PATH entry at all. A 2026-07-14 comment justified
removing `SCOOP_GLOBAL_SHIMS` as pointing at a "never-created ProgramData dir",
which stopped being true once anything was installed globally. Only
`FLUTTER_BIN` being baked separately kept the gap invisible; any *future*
`--global` package would have been silently unresolvable by name. Restored, with
user shims keeping priority, and now asserted by the smoke test (soft-skip on
images built inside the 07-14…08-08 window).

### ✅ The FFmpeg `.pc` gate could not fail in its worst case

Extracted to `Assert-FfmpegPkgConfig` (P9). Doing so exposed a hole the original
inline version had: the whole gate sat inside `if (Test-Path $ffPkgConfigDir)`,
so a **missing** `lib\pkgconfig` directory — the most complete failure available
— skipped every assertion silently. The function now treats an absent directory
as a hard failure and is called outside that guard. Five unit tests, one per
failure mode.

Placement note for future readers: it deliberately does NOT live in
`WindowsSourceBuild.Common.psm1`. That module is in the compile closure of all
three media branches, so an FFmpeg-only helper there rebuilds all of them on
every edit — the same reasoning that moved `Remove-MakefileShowIncludes` out of
it on 2026-08-03. Tests reach the in-script function by AST extraction, which is
the established pattern here.

### 🔴 An unresolved merge conflict was committed into this file

Lines 856/926/961 carried `<<<<<<< HEAD` / `=======` / `>>>>>>>` markers: the
Linux closure-audit section and the Windows P8 section were appended
concurrently and the merge was never finished. Both sides were wanted; P8 (a
`###` under the Windows `##` heading) had landed *after* the Linux `##` section,
which also broke the following "The closure batch **above**" reference.
Resolved by reordering, content verified identical modulo the markers.

Guard added: `.githooks/pre-commit` now greps the *staged* content (`git grep
--cached`, so it sees exactly what is about to be committed) for `<<<<<<< ` and
`>>>>>>> `. Verified to fire on the exact commit that carried the bug. A bare
`=======` is deliberately NOT matched — it is a valid Markdown setext H1
underline, and every real conflict carries the other two markers anyway.

### ⚠️ The hooks are not enabled on this clone

`git config core.hooksPath` is unset here, so `.githooks/pre-commit` has never
run on this machine — which is how the conflict marker (and the `fix` / `hi` /
`ja moin` auto-commits) got in unchecked. AGENTS.md §969 documents the one-time
`git config core.hooksPath .githooks`. Not set automatically: it changes commit
behaviour for every process committing into this tree, including the automated
one, and that is the owner's call.

Note for whoever enables it: the preflight subset needs `PREFLIGHT_PYTHON`
pointed at a real interpreter on this host (`~/.local/bin/python3.14.exe`) —
bare `python3` hits the Microsoft Store stub, which fails two Python-based
checks for reasons that have nothing to do with the commit. The hook header
documents this. With it set, one genuine failure remains and is NOT from the
Windows lane: `external/Kataglyphis-DocumANTation` (a **submodule**) has stale
Dockerfile ARG defaults after the concurrent pin bump. That fix belongs in that
repository.

### ✅ Nothing was linting the git hooks

Found while shellchecking the hook above: `.githooks/pre-commit` carried a live
`SC1072`/`SC1073` **parse error** — a comment beginning with the word
"shellcheck" is read as a malformed directive and aborts ShellCheck's parse of
the entire file. It had sat there unnoticed because `lint-shell.sh` filters to
`*.sh` and a git hook cannot have that suffix, so no gate ever looked at it.

Fixed both halves: the comment is reworded (with a warning not to reintroduce
it), and `lint-shell.sh` now also accepts explicitly-passed extension-less files
that carry a shell shebang. The default sweep is unchanged (still 223 files
discovered as `*.sh`); only the staged-file path gains coverage, and the
pre-commit hook feeds it such files, so the hook now lints itself.

Subtlety worth remembering: the first version of that filter tested the whole
path against `*.*`, which matched `.githooks/pre-commit` on the dot in the
*directory* name and silently dropped it. Test `${f##*/}`, not `$f`.

### Still open

- **P8b — the warning floods** (72 864 of 459 061 log lines). Unblocked now that
  nothing is building, and free in this window, but deliberately NOT taken in
  this batch: a wrong `-Wno-` either breaks a compile or hides a real diagnostic,
  and the counts in the P8 table need re-measuring against the bumped OpenCV
  5.0.0 / ONNX v0.15.2 before choosing flags. Do it against a fresh log.
- **Smoke-test split** (`smoke-test-container.ps1`, ~1600 lines). Still deferred
  on purpose: it is the gate that has not yet run green end-to-end with the new
  plugin assertions, and splitting a test file before you have seen it pass
  removes the baseline you would compare against.

## 2026-08-08 (cont) — the four remaining backlog items, closed

Cleared before restarting the chain, so the run happens against a tree with no
known open work. Two of them turned out to be blocked only by a third.

### ✅ P8b — the warning floods

Targeted suppressions, one per identified upstream construct, never a blanket `-w`:

| family | lever | where |
|---|---|---|
| `-Wdeprecated-copy` (~7 700) | `-Wno-deprecated-copy` in `CMAKE_CXX_FLAGS` | `build-opencv-from-source.ps1` |
| `-Wunused-value` (~2 460) | `/clang:-Wno-unused-value` | `build-onnx-from-source.ps1` |
| `-Wdocumentation-unknown-command` (~900) | `-Wno-documentation-unknown-command` | `build-tvm-from-source.ps1` |
| `STL4037` (657) | `_SILENCE_NONFLOATING_COMPLEX_DEPRECATION_WARNING` | `patches/iree/enable-ehsc.cmake` |

Three points decided the shape:

- **IREE gets a define, not a flag.** STL4037 comes from the MSVC STL headers
  themselves via a deprecation attribute, so no clang warning group can switch it
  off. The STL names its own escape macro in the diagnostic text, so this is not
  guesswork. It goes in the `CMAKE_PROJECT_INCLUDE` file at directory scope,
  which survives LLVM's `HandleLLVMOptions` stripping of `CMAKE_CXX_FLAGS` and
  never reaches the custom commands that cross-compile ukernel bitcode with a
  plain `clang.exe` — the same reasoning that already put `/EHsc` there.
- **OpenCV's is safe for the CUDA path**, which was the live risk: nvcc's Windows
  host compiler is `cl.exe` and rejects GNU-style flags with D8021. Read the
  patch rather than trusting the comment above it — `ocv_cuda_filter_options`
  strips `/clang:*`, `/FI*`, `-Xclang`, `-fopenmp` **and** `-W*` from
  `CMAKE_CXX_FLAGS` before the `-Xcompiler` block.
- **Parent group, not the narrow one.** clang reports
  `-Wdeprecated-copy-with-user-provided-copy`; the parent `-Wdeprecated-copy` has
  existed far longer. An unrecognised `-Wno-` is only a warning to clang, never
  an error, and ONNX passes `/WX-` anyway — so a wrong spelling could cost
  effectiveness, never a build.

New: `windows\scripts\Measure-BuildWarnings.ps1` counts warnings per diagnostic
family in a build log; `-Baseline` prints each known flood against its
pre-suppression count with a verdict. The backlog asked that every suppression
"carry the count it removes" — this is how the next run proves it, instead of the
flags becoming folklore nobody dares remove. The classifier is unit-tested
(`MeasureBuildWarnings.Tests.ps1`), including that bracket-less warnings are
grouped rather than dropped: otherwise a new flood could grow unseen precisely
because it carries no `-W` group.

**Run after the chain:**
`.\windows\scripts\Measure-BuildWarnings.ps1 -LogPath <chain log> -Baseline`

### ✅ Smoke-test split

`smoke-test-container.ps1` 1 573 -> 1 386 lines; the ~210-line assertion harness
is now `modules\WindowsSmokeTest.Common.psm1`. The 22 test SECTIONS deliberately
stay in the script — they are a linear probe run against a built image and gain
nothing from modularisation.

No Dockerfile change was needed: `windows/Dockerfile` already COPYs the whole
`windows\scripts\modules` directory into the final image, in the cheapest layer.

The extraction had exactly one hazard, and both halves of it fail SILENTLY:

1. `Assert-Test` read `$ExitOnFirstFailure` — a *parameter of the calling script*
   — through dynamic scoping. A module has its own session state and sees
   nothing; the lookup yields `$null`, which is falsy, so the switch would simply
   have stopped working with no error anywhere. It is module state now, set via
   `Initialize-SmokeTestRun`, with a regression test.
2. The SUMMARY block read `$script:passed`. Across a module boundary that
   resolves to an unset variable in the *script*, so the run would have reported
   0 passed / 0 failed and exited 0 regardless of what happened. It reads
   `Get-SmokeTestSummary` now.

Verified without a container: both files parse, every command the script invokes
still resolves, and an AST inventory of every `Assert-*` / `Skip-Test` /
`Write-TestHeader` call site is **194 before, 194 after** (script + module) —
identical as a set. 11 new unit tests; suite at 412.

The earlier objection — "do not refactor the gate before you have seen it pass" —
is answered by that inventory plus the tests, not overruled. The gate itself
still has to run green against the image this next chain produces.

### ✅ Hooks are enabled, and the reason they were not is fixed

`git config core.hooksPath .githooks` is set. It had been left off because the
Python-based preflight checks ran `python3`, which on this host is the Microsoft
Store stub — every commit would have failed for a reason unrelated to the commit.
`preflight.sh` now PROBES candidates and takes the first that can actually
execute code (the stub fails `-c pass`), so the hook runs green with no
environment setup at all. `PREFLIGHT_PYTHON` still overrides.

### ✅ Submodule ARG staleness

`external/Kataglyphis-DocumANTation` pinned `UV_VERSION=0.12.1` against
versions.env's `0.12.3` (Pandoc already matched), which kept the version-snapshot
check red and therefore blocked enabling the hooks. `sync_versions.py` includes
that Dockerfile deliberately — the doc image is meant to follow this repo's pins.
Committed **in the submodule** (`b0bffd5`); it still needs a push to that
repository and a pointer bump here. That is a change to a different repo, so it
is left explicit rather than done silently.

## 2026-08-08 — deep forensic audit of the live cross-build logs (2-agent sweep + verification)

Fixed immediately (land in the foreign arches' media/runtime stages + the amd64 refresh):
- assemble-torch-app.sh: the app uv.lock (v0.0.27 → genai 0.14.0) beat the
  chain's freshly built onnxruntime-genai 0.15.2 wheel; now pre-installed with
  --no-install-package like the other locked wheels.
- validate-media-runtime.sh: LIB_DIRS lacked the lib/<multiarch> dirs meson
  installs into → the validator declared the build's own libcamera "missing"
  and apt-installed Ubuntu's 0.7.0 as a shadow copy (false-positive repair).

Verified-corrected agent findings (do NOT chase):
- "NVENC/ffnvcodec missing" is ENABLE_NVIDIA-gated by design in the CPU lane.
- runtime Python 3.14.4 is Ubuntu's DISTRO CPython (venv base), not a stale
  layer; decide deliberately: use the staged 3.14.7 or pin-assert the distro one.
- "is not a commit!" clone warnings = annotated-tag peeling, cosmetic.

Open findings, prioritized (closure batch unless noted):
1. ccache launcher missing in LLVM's NESTED sub-builds (llvm-cross.sh:232
   CROSS_TOOLCHAIN_FLAGS_NATIVE lacks *_COMPILER_LAUNCHER) — measured 0% gain
   on 189 identical objects built twice. + emit `ccache -z/-s` to STDERR per
   RUN (stderr survives the 2MiB clip; stdout does not — logging.sh routes
   info() to stdout, warn/err to stderr, so [WARN]/[ERROR] streams are
   complete evidence even in clipped steps).
2. TVM ships broken (libtvm_runtime undefined symbol; built against DISTRO
   llvm-config-22 = 22.1.2 not the pinned 22.1.8) + dual-LLVM in the image;
   the "wanted 22.1.8, got 22.1.2" line prints at INFO. Promote + fix TVM's
   LLVM selection.
3. App-smoke inner warnings (pyav absent though PYAV_VERSION pinned; TVM
   import failure) do not reach the outer PASS/FAIL. Propagate; also delete
   the three "(import failed in build sandbox — will work at runtime)"
   assertion-free PASSes and the stale "libx264 may not be available" skip
   (x264 IS in the build).
4. FFmpeg DNN backends: TF-C SDK download failed silently (TENSORFLOW_C pin
   dead), OpenVINO pkg-config never resolvable (pin dead) — decide: make
   fatal, fix source, or drop the pins.
5. OpenCV configures at step #33 against DISTRO GStreamer 1.28.2/FFmpeg 62.x
   because /opt/gstreamer + /opt/ffmpeg build at #48/#68 — stage-order or
   PKG_CONFIG_PATH decision. Also OpenCV tree is "5.0.0-dirty" (patches) —
   note for reproducibility; ONNX/VA/AVIF off in OpenCV's own config.
6. GCC prereq inconsistency: passes 3+5 pull in-tree gmp/mpfr/mpc/isl (2×
   download+build), passes 1/2/4 use system libs; cache sha512.sum/.sig next
   to the tarball (5× refetch each, caused 3 of 4 transient retries);
   LIBRARY_PATH leaks into NATIVE sub-build links; verify step never
   exercises C/ASM cross paths; #12-vs-#15 duplicate-compile overlap worth
   measuring once ccache stats exist.
7. onnxruntime venv carries BOTH 1.28 (dnnl wheel) and 1.27.0 (PyPI) — dedupe;
   [DONE 2026-08-08: onnxruntime-genai added to the smoke-torch-venv pin
   assertion] python-version assertion still pending the distro-vs-staged
   CPython decision;
   APP_REF v0.0.27 reports stale __version__ 0.0.22 (upstream issue).

### 2026-08-08 (cont) — sccache multi-tier: VERIFIED, and a correction of my own claim

I told the owner that a two-tier sccache "isn't available — sccache has one
backend, remote wins over local, you'd need a caching HTTP proxy". **That was
wrong.** Checked against mozilla/sccache's own `docs/Configuration.md`:
multi-level caching exists, is read-through/write-through with automatic
backfill, and is selected with `SCCACHE_MULTILEVEL_CHAIN` ("Order matters:
left-to-right is fast-to-slow"). Valid backend strings include `disk` and
`webdav`.

What WAS right is that the repo's own note was incomplete: setting `SCCACHE_DIR`
next to a configured remote does nothing on its own, because without the chain
variable sccache stays in single-level legacy mode. Both the note and my claim
are corrected in `docs/windows-builds.md` § BuildKit lane.

Verified availability, not assumed:

| fact | evidence |
|---|---|
| multi-tier implemented | 2026-04-17, PR #2581 (commit on `docs/Configuration.md`) |
| released in | **v0.16.0**, 2026-06-19 (GitHub releases API) |
| latest upstream | v0.17.0, 2026-07-29 |
| version this image installs | **0.17.0** — read out of the 2026-08-08 chain's own base log |

So the lever is available on this host today.

**Consequence worth deciding deliberately:** sccache currently sits in
`setup-scoop-tools.ps1`'s FLOATING block, justified as "the build only invokes
them". Wiring the chain changes that — the L1 tier would exist or not depending
on the installed sccache VERSION, and on an older one the variable is ignored
**silently**, so the cache degrades with no error anywhere. That is exactly the
failure shape this repo spent the week eliminating. Pin sccache with
llvm/ninja/nasm in the same change, or accept a speed feature that can vanish
without a signal.

### 2026-08-08 — periphery audit (workflows/Makefile/py-tools/hooks/services)

Fixed immediately (all host/CI-side, zero build-closure impact): pre-commit
sphinx root (broke EVERY commit on hook-enabled clones, error swallowed);
deps.json libcamera now bound to LIBCAMERA_VERSION (license pages published
"git master"); install-deps cargo dirname-of-empty put "." on GITHUB_PATH;
build-viewer sh -euc + results-glob guard (failed npm build reported success);
flutter smoke's three probe substitutions guarded (FAIL branches were
unreachable); permissions: contents: read on ubuntu24.04 + build-docs;
free-disk-space + checkout SHA-pinned; hook: --diff-filter=ACMR (renames
bypassed all gates), git-grep rc>1 fails the conflict gate loudly;
generate-website-licenses: unknown var raises, flagless default is CHECK.

Deferred to the batch / follow-ups:
- versions.env: renovate hints for LIBCAMERA_VERSION + FLATPAK_RUNTIME_VERSION
  (closure file — batch); both currently have NO automated update path.
- preflight [ -f ] guards: a renamed target silently vanishes from the gate;
  fail when a PREFLIGHT_ONLY selection ran zero checks.
- hook shebang probe reads the WORKTREE not the staged blob (git show ":$f").
- bump_versions.py: failures counted but exit 0; write_env_values drops
  no-matching-line keys silently + unescaped re.sub template.
- actions: registry password via env not interpolation; clone-into-short-path
  leaves a token in global gitconfig on self-hosted runners; workspace-path
  quoting in run-in-linux-container.
- llm-stack: node:20-alpine vs NODE_VERSION=26.7.0 drift (unreachable by
  sync_versions — Dockerfile-ARG-only); ollama empty-SHA downgrade needs an
  explicit ALLOW_UNVERIFIED=1; ghcr-cleanup delete failures are warnings.

## 2026-08-08 — sccache multi-tier design (Linux) + bash simplification plan

Owner asked (a) whether the Windows lane's sccache multi-tier should come to
Linux, (b) for bash simplification/dedup. Both are CLOSURE work → batch with
task "apply the batched closure refactor". Design decided now:

### Multi-tier compile caching (Linux) — differentiated, not a wholesale switch
- C/C++: KEEP ccache (wired + populating since today; better direct-mode hit
  rates than sccache for GCC). Add the REMOTE tier via ccache's own
  `remote_storage` (>=4.4; Ubuntu resolute's ccache qualifies) pointed at a
  host-local redis/http endpoint → survives buildkit cache-mount loss (see the
  unexplained base cache-miss), shareable across runs/hosts.
- Rust: THE gap. sccache is already INSTALLED in the images and
  compiler-cache.sh::setup_sccache exists — but Dockerfile.toolchain:58 and
  Dockerfile.package:157 hard-disable it (`RUSTC_WRAPPER=""`). gst-plugins-rs
  + cargo-c + rust builds get zero compile caching today. Batch: find out WHY
  it was disabled (git blame first), then enable RUSTC_WRAPPER=sccache with
  SCCACHE_DIR on the existing mounts; optional SCCACHE_REDIS for the shared
  tier. Same backend host can serve the Windows lane's sccache (no cross-OS
  hits, shared infra).
- Wire `ccache -z`/`-s` + `sccache --show-stats` to STDERR per RUN (survives
  the log clip) so every tier's effectiveness is measured, not assumed.

### Bash simplification (accidental complexity only; protected repetition stays)
1. Named guard helpers in 01-core (bundling): `first_match` (find|head||true
   — ~426 sites use the raw idiom), `probe` (cmd||true with comment-free
   intent), `source_vendor` (the nounset-suspend window — 3 call sites),
   `csv_each` (IFS-safe split). Migrate hot files; new code uses helpers.
2. Unify the two parallel-loop implementations (gcc.sh's driver →
   run_parallel_arch_loop; costs one mount-list line, batch anyway).
3. cross-stage-build.sh push/local dual path collapses once the OCI-layout
   local handoff lands — the single biggest orchestrator simplification;
   design both together.
4. chain-verify.sh's manual-inspection fallback shrinks to a stub once all
   published images carry ancestry annotations.
5. Explicit NON-goals: splitting the big build scripts without functional
   cause; touching the protected repetition.
### 2026-08-08 (cont) — 🔴 ONNX's CUDA kernels are NOT cached, and never were

Raised by the owner as "with the sccache change ONNX's CUDA code should be
fully cached now". It is not, and the sccache change is not why.

**`CMAKE_CUDA_COMPILER_LAUNCHER` appears nowhere in this repo.** Only the C and
CXX launchers are wired, at three sites (`WindowsBuild.Common.psm1:631-632`,
`WindowsCMake.Common.psm1:289-290`, `WindowsSourceBuild.Common.psm1:176-177`).
So every `.cu` translation unit goes through nvcc uncached — before the
two-tier change and after it. The two-tier wiring only accelerates what was
already cacheable: the C/C++ TUs.

Scale, from this repo's own source (`build-onnx-from-source.ps1:197`):

> ONNX_FORCE_CPU=1 forces a CPU-only ONNX (skips the **~1h CUDA/TensorRT kernel
> compiles**)

That is very likely the single largest time sink in the chain, entirely
uncached, every run.

**Fixable — sccache supports nvcc.** Verified against mozilla/sccache's README:
"sccache includes support for caching the compilation of Assembler, C/C++ code,
Rust, as well as NVIDIA's CUDA using nvcc", with NVCC listed among the
supported compilers alongside gcc/clang/MSVC/rustc/NVC++/hipcc.

**Two risks to settle before wiring, both on the most fragile path here:**

1. nvcc's host compiler in this image is `cl.exe`, and the repo already carries
   a patch that strips clang-cl-only flags out of the `-Xcompiler` block
   (`ocv_cuda_filter_options`; cl.exe rejects them with D8021). Inserting
   sccache between CMake and nvcc adds a layer exactly there.
2. `SCCACHE_CACHE_MULTIARCH` — ONNX builds `CUDA_ARCHITECTURES=80;86;89;90`,
   i.e. several `-gencode` in one invocation. sccache's Configuration.md
   mentions the variable in a single clause ("disable caching of multi
   architecture builds") with no semantics, no default stated, and nothing
   about correctness across multiple gencodes. Measure; do not assume.

Deliberately NOT wired during the 2026-08-08 proof chain: that run exists to
green the FFmpeg .pc gate, the four mandatory GStreamer plugins and the warning
suppressions, and a CUDA-path failure would cost the media stage ~1h in and
take the proof with it. Wire it immediately after, with sccache stats read
before and after so the win is a number rather than a claim.

## 2026-08-08 — structural refactoring map (verified agent sweep, base→final)

### ★ A1 — THE structural finding: Dockerfile.base mounts ALL of 01-core +
02-toolchain into 6 RUNs. Any edit to ~120 files (incl. host-only orchestrator
modules) busts BASE → cascades to the entire chain. The toolchain's careful
per-file lists are undone one tier up. Actual closure of base-image.sh ≈ 14
files; verify-script-copy-coverage.py --report-core-usage already anticipates
the fix. Narrowing this is the ENABLER: it drops the marginal cost of every
future 01-core edit from "full chain" to ~nothing. Do FIRST in the batch.

### Drift bugs found by clone comparison (fix in batch, guard helpers first)
- A2: cross_build_is_active exists 5x with 3 semantics; the arch-normalization
  fix (documented in smoke-common:22) reached 1 of 5 copies — the raw copies
  report "cross active" on native arm64 hosts. Canonical: cross-env.sh.
- A4: resolve_host_compiler forked 3x; compiler-resolution.sh never ships to
  the android stages, and IREE-android's bare `command -v gcc` resolves the
  CUSTOM CROSS GCC as host compiler (live, masked by best-effort gating). Fix:
  COPY compiler-resolution.sh in Dockerfile.android + delete both fallbacks.
- A5: Dockerfile.package hand-rolls the ports-mirror rewrite: ignores the
  USE_FAST_UBUNTU_MIRROR gate and never derives ports-from-archive → package
  stage stays on ports.ubuntu.com when only the archive mirror is set.
- A3: base-image.sh parse_options 116→~40 lines (4 identical case blocks).
- A6: two upward-dir-walkers (+ documented workaround hack) → one.

### Free-anytime deletions (T4)
- B1: smoke-wrapper.sh fully orphaned — and docs CLAIM wrapper-smoke runs it
  (linux-cross-builds:625, cross-build-verification:70). Delete or wire; fix docs.
- B2: smoke-runtime-image.sh COPY in Dockerfile.package is vestigial (runs
  host-side; its own comment says so).
- B3: create_deb() 104 lines, zero callers, positioned unreachably.
- B4: run_quiet() zero callers (batch: lives in build-helpers).
- B5: smoke-runtime-image main() 459 lines → per-check functions + driver
  array (pattern exists in verify-parity). B6: AGENTS claims a
  media_build_preamble_init alias that does not exist. B7: micro.

### Do-not-do (recorded so nobody churns): usage texts/mount lists/ARG nets
(policy); folding the 9 verify RUNs into build RUNs (their separation is what
makes verification edits free); smoke-common arch fallbacks + path-helpers +
assemble-torch-app retry + android-sdk retries (deliberate standalone
bundling); is_cross alias rename (max closure cost, cosmetic gain — ride A2
if ever); the 5 android-lib stages (repetition BUYS BuildKit parallelism);
Dockerfile.base mount-preamble repetition (no macro exists — A1 changes
content, not repetition). Irreducible-complexity list recorded (iree wheels,
gi wrappers, pin assertions, llvm-cross, cross-stage impl).

### Sequence: A1 → guard helpers → A2+A3+A6 (one commit) → A4+A5 → B*.
Interaction: gcc.sh↔parallel-loop unification requires adding parallel-loop.sh
to all THREE protected mount lists (sync-maintenance, permitted) AND porting
per-target logs + job-splitting into it first. Totals: ~350 LOC out, 3 drift
bugs closed, one 459-line function decomposed, future 01-core edits ~free.

### 2026-08-08 status — applied in commit 300230e (round 1, mid-foreign-chain)

**DONE: A1, A2, A4, A5, B1, B2, B3, B4, B6.**

- **A1** — Dockerfile.base's six whole-dir mount pairs replaced with the traced
  15-file closure (13× 01-core + cmake.sh + packaging-deps.sh; the mirror RUN
  mounts only its 2). Validated with a REAL from-scratch base build
  (`local/kataglyphis:base-a1-test`, exit 0). The FIRST validation build failed
  exit 127: the static trace missed `use-fast-ubuntu-mirror.sh`, which
  bootstrap-ca `exec`s rather than sources — exec/`bash` call edges don't show
  up in source-statement greps. That's the recorded lesson: **closure = source
  edges + exec edges**, and a real build is the only trustworthy verifier.
- **A2** — all raw `cross_build_is_active` fallback clones (01-core/common.sh,
  03-media/core/common.sh, build-gstreamer-monorepo.sh) now normalize both
  sides via `arch_normalize` before comparing, matching the canonical
  cross-env.sh semantics.
- **A4** — Dockerfile.android now COPYs compiler-resolution.sh into
  /opt/scripts/core/; the IREE fallback prefers explicit /usr/bin compilers
  (aligned with the litert copy). Fallbacks kept (standalone-bundling policy)
  but are now normally dead code.
- **A5** — Dockerfile.package's inline ports-sed replaced by a 2-file bind
  mount running the canonical `use-fast-ubuntu-mirror.sh`; the leftover
  if-false block deleted.
- **B1** — smoke-wrapper.sh `git rm`'d; linux-cross-builds.md +
  cross-build-verification.md corrected (they claimed wrapper-smoke runs it).
- **B2** — vestigial smoke-runtime-image.sh COPY removed from
  Dockerfile.package. **B3** — create_deb() (104 unreachable lines) removed
  from package_archive.sh. **B4** — run_quiet() removed from build-helpers.sh.
  **B6** — AGENTS.md no longer claims the nonexistent
  `media_build_preamble_init` alias.

**Still open: A3** (parse_options table), **A6** (dir-walker unification),
**B5** (smoke-runtime-image main() decomposition), **B7** (micro). All three
substantives touch files the running foreign chain bind-mounts mid-flight —
deliberately deferred to the post-chain closure batch.

## 2026-08-08 (cont) — harvested from the from-base chain (run e)

Answering "are you tracking what could be refactored, detected during the
build?" — honestly, not systematically since the restarts. This is the sweep.

### 🔴 `nv/target.h` stub SHADOWS the real `nv/target` (setup-cuda.ps1)

Three log lines from the sdk stage that only mean something together:

```text
CCCL headers verified present (cub/cub.cuh found).
Using installer-provided: …\CUDA\v13.3\include\nv\target      <- real file, present
Created stub:             …\CUDA\v13.3\include\nv\target.h    <- host-only stub
```

CUDA 13.3 ships `nv/target` (extensionless) and no `nv/target.h`. The script's
`foreach` over `@('target.h', 'target')` therefore finds one and stubs the
other — and the stub is not neutral. It hardcodes

```c
#define NV_IS_DEVICE 0
#define NV_IS_HOST   1
#define NV_IF_TARGET(arch, ...) _NV_IF_TARGET_HOST(__VA_ARGS__)
#define NV_PROVIDES_SM_70 0   /* …80, 90, 61 likewise */
```

so ANY translation unit that includes `<nv/target.h>` gets "we are on the host,
no SM is available" — **including device compilation**, where the script's own
comment says the installer version "selects device branch when `__CUDA_ARCH__`
is defined". CCCL (CUB/Thrust/libcudacxx) uses `NV_IF_TARGET` heavily, and ONNX
and OpenCV both compile CUDA kernels against it.

Nothing has failed loudly, which is exactly the concern: a wrong `NV_IF_TARGET`
branch degrades or miscompiles device paths, it does not error. Unverified so
far whether anything in this chain actually includes the `.h` spelling — that is
the first thing to check, not an assumption to rest on.

Fix direction: when the extensionless `nv/target` exists, `target.h` must
FORWARD to it (`#pragma once` + `#include <nv/target>`), never re-declare a
host-only view of the world. Keep the standalone stub only for the case where
NEITHER exists. Same one-line change makes the log line honest too.

### ⚠️ rustup honours a PRE-EXISTING settings.toml (setup-rust-toolchain.ps1)

```text
warn: It looks like you have an existing rustup settings file at:
warn: C:\Users\ContainerAdministrator\.rustup\settings.toml
warn: Rustup will install the default toolchain as specified in the settings
warn: file, instead of the one inferred from the default host triple.
```

This run resolved to `stable-x86_64-pc-windows-msvc` / 1.97.1, i.e. exactly
`RUST_VERSION` — so the outcome is right TODAY. The trap is that a settings file
already present in the layer, not the script's intent, is what decided it. On a
base whose settings.toml names something else, the chain would silently install
a different default toolchain and this warning would be the only trace, buried
in a stderr log tail.

Worth: assert the resolved toolchain after install (`rustup show active-toolchain`
against `RUST_VERSION`) the same way clang-cl/ninja/nasm/sccache are asserted —
this is the one toolchain component in the base with no post-install assert.
Cheap, and it turns an advisory warning into a gate.

### Noise, triaged as harmless (do not chase)

- `[10] OverwriteTargetDirectory : Warning : … existing, non-empty directory` —
  installer re-running over its own target; expected on a rebuilt layer.
- `[1844] Warning: QFont::setPixelSize: Pixel size <= 0 (-1)` — Qt chatter from
  the cppcheck GUI's installer, headless container, no consumer.
- `scoop bucket add main -- already present, skipped` — idempotence working.

### Process note for the next reader

Disk fell 109 → 87 → 64 GB across three aborted runs of the SAME chain: every
abort leaves partial snapshots that no gate reclaims. `buildctl prune` after an
abort is part of aborting, not a separate chore. Confirmed safe mid-build twice
today (44.8 GB and 43.9 GB freed with a solve running, no disturbance) — the
2026-08-07 note that prune does not disturb an active solve holds.
