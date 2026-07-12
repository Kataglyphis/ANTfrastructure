# Refactoring backlog

A living list of refactoring / hardening / efficiency candidates observed while
operating the cross build. Each item: **what**, **why it matters**, and a rough
**effort·impact**. Not a commitment — a triage queue. Newest observations at the
bottom under "Harvested during runs".

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ (nice) … ★★★ (high).

---

## Build efficiency / speed

- **onnxruntime WebAssembly target is built in the media stage.** `build_wasm_output`
  + `wasm-opt` (single-tool, low-parallelism, ~minutes of wall-clock per arch) is
  compiled even though a native container runtime never loads a `.wasm`. Gate it
  off unless explicitly wanted. — S · ★★
  _CONFIRMED LIVE (0711f media-amd64): the `onnxruntime_webassembly` link
  (`ort-wasm-simd-threaded.mjs`, via an emsdk 4.0.23 install) ran at load ~6.5
  while the native framework compiles held load ~35 — a serial, under-parallel
  wall-clock sink on the critical path, ×3 arches._
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
