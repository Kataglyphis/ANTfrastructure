# Refactoring backlog — OPEN items only, grouped by EXECUTION CONTEXT

Lean working document (restructured 2026-08-19; previously organized by
discovery-sweep date, which had fragmented into 27 sections with ~12 stale
already-shipped entries). Every item here is OPEN. Completed/obsolete items
and the observation journal live in `refactoring-backlog-archive-2026-08-10.md`
+ CHANGELOG.md + memory — do not resurrect without re-verifying.

Legend — effort: S(mall)/M(edium)/L(arge); impact: ★ … ★★★.
Prefix glossary: **AP**=artifact perf · **TG/TS**=toolchain · **GPU**=GPU
lanes · **SMK**=smoke gaps · **DUP**=duplication · **PAR**=parallelism ·
**SCC**=cache tiers · **BT**=bump-tool · **LOG**=build-log mining ·
**C#/D#/P#/S#/F#/XC#**=legacy rounds (archive).

Last groomed: 2026-08-24 (CLOSURE WINDOW 3 declared — see the 🎯 plan). LIVE `:latest-cross` = WAVE-6 ship (a25a38c5/
bd9953a9/d3710282, run id 20260823-223111-d0336283) — see § WAVE-6 SHIPPED.
**Windows items live in the SEPARATE Windows backlog** — this file is
Linux/cross-lane only.

## Standing rules (read first)

1. Never edit versions.env or the 01-core / 03-media bind-mount closure
   outside a closure window — one edit re-runs hours of media compiles.
2. Respect the protected lists (deliberate dedup, standalone bundling,
   load-bearing case arms, ARG sprawl, LiteRT-LM patch stack, SH1 retry
   semantics, SH2 non-exiting error(), DUPN2 two-pass arg mirror) —
   re-verified intentional across four sweep rounds.
3. Disk reclaim mid-run: prune-safe.sh → targeted rmi of pushed tags →
   NEVER system/image prune while a chain runs (removes TAGGED locals).
   SHARPENED 2026-08-21: `nerdctl system prune` ALSO wipes the buildkit
   store INCLUDING exec.cachemount records (35→1 observed) — even with no
   chain running it costs the compile caches. It is the last-resort hammer
   ONLY; prune-safe + rmi + kata-buildcache/archive-log trims come first.
4. Per-arch out/build-logs/*.log persist across runs — mtime-check before
   re-arming watchers.

## ✅ WAVE-6 SHIPPED 2026-08-24 (the gate-truth build — three blind gates now actually work)

`:latest-cross` = amd64 `a25a38c5` / arm64 `bd9953a9` / riscv64 `d3710282`.
Run id `20260823-223111-d0336283` — and for the FIRST time that is a
verifiable statement: all three wrappers carry it as an image LABEL, read back
from the REGISTRY (not the local store). cv2 GStreamer:YES + FFMPEG:YES holds
on the new bytes. Runtime smokes 0 failures x3.

**What this build proved** (each had been silently broken for months):
  - **XC3** — provenance is written and READ. `per-arch wrapper generation check:
  OK` with NO "carry no run-id" warning (it was 3/3 in every prior run), and
  `[ancestry] android→wrapper (<arch>): OK` with real digests on all three.
  The label also says *android*, confirming the XC2-STAGE fix: the writer
  stamped android while the check resolved "package", which would have thrown a
  false STALE ANCESTOR on every run the moment provenance returned.
  - **AP4** — `AP4 strip verified: libavcodec.so.63.1.100 has no .symtab`.
  Every previous ship printed `check skipped (could not extract ...)` while the
  wrapper gate said PASS: `tar --occurrence=1` exits early, SIGPIPEs the
  exporter, and pipefail turned that into a failure.
  - **SMK1** — the cv2 media assert is hard on all three arches.
  - **CERB-CACHE** — validated the hard way. wave6a lost all three lanes to five
  freedesktop 503/404 flaps, but the cerbero state survived (15.7 GB / 14.5 GB
  on the cachemounts); wave6b restarted WARM (`HIT: resuming ... 13G / 20G`)
  and completed with ZERO fetch failures. Before this, wave5k and 5l discarded
  the full ~50-minute bootstrap on every flap.

**Wave-5 (2026-08-23, superseded):** amd64 `54ab7f01` / arm64 `7bb70a4b` /
riscv64 `fb701200` — first ship with cv2 GStreamer+FFMPEG on 3/3 arches, and
the ship whose post-audit found the three gates above.

## 🎯 CLOSURE WINDOW 3 — OPEN (declared 2026-08-24): pre-build wave, then a FULL validating rebuild

The operator has committed to a fresh build, so the versions.env lock is OPEN
and build-validated items are IN SCOPE. Work the wave in this order; the
rebuild then validates everything at once (that is the whole point of a
closure window — ONE rebuild pays for all).

**Phase 0 — host prep (no-build window, do FIRST):**
- ✅ **DONE 2026-08-26 — buildkitd upgraded, but READ THE VERSION.** The host
  went nerdctl 2.3.4 → **2.3.5**, buildctl/buildkitd v0.31.1 → **v0.31.2**,
  containerd 2.3.2 → **2.3.3**, daemons confirmed reporting the new versions,
  51 cache-mount records unchanged. CORRECTION to this item's original text:
  **v0.32.2 was not reachable this way.** buildkitd here comes from the
  nerdctl-full bundle, and 2.3.5 — the newest release — ships BuildKit
  **0.31.2**. So #6916 (daemon crash under concurrent builds, v0.31.2) WAS
  obtained; **#6955 (parallel-build cache miss) was NOT** — it landed in
  v0.32.0 and no nerdctl-full ships it. Getting it would mean installing
  buildkit outside the bundle, i.e. breaking the version-matched set. Not
  worth it; revisit when a nerdctl-full bundles 0.32.x. Tooling:
  `linux/host-config/install-nerdctl-full.sh` (needs
  `NERDCTL_INCLUDE_ROOTFUL=1` on this host; see
  docs/linux-host-setup.md § B3b. That section carries the rationale and
  the reference run).
- ✅ **DONE — buildkitd.toml gcpolicy is live.** Repo and
  `~/.config/buildkit/buildkitd.toml` are in sync and the daemon restarted
  during the upgrade above, which is the event it was waiting for.
- ⛔ **OPEN AND BLOCKING — disk.** 72G free; the playbook wants **≥150G** for a
  full from-base rebuild. prune-safe first; the 215G kata-buildcache trim
  stays the operator's call, not the agent's. **Do not launch the rebuild on
  72G** — ENOSPC mid-lane is the expensive way to learn this.
- ⬜ Run preflight.sh (the full gate battery incl. the GCC-literal gate).

**Phase 1 — pin-bump pass (versions.env window): ✅ DONE (7a2639e)**
- Swept: CMAKE 4.4.3, UV 0.12.6, CARGO_C 0.10.25, OLLAMA 0.33.0 (+ SHA
  pairs). VULKAN deliberately held at 1.4.357.0 with a documented reason
  (1.4.357.1 is a Linux-only republish; windows.txt still says .0 and the key
  is shared — bumping it would break the Windows lane, which is out of scope
  here).
- Riders landed: **AP6** decided → `ORT_ENABLE_LTO=false`; `LLVM_COMMIT=`
  opt-in key added; `RUFF_VERSION`, `APPIMAGETOOL_VERSION`, `ABSEIL_VERSION`
  and the `PY_*` keys now live in versions.env.
- Still open in this phase: the **MESON-GI probe** — if meson >1.12 resolves
  g-i's glib subproject again, lift the riscv64 pin in this window; else it
  stays with its reason (tracked in § E).
- MESON-GI probe: if meson >1.12 resolves g-i's glib subproject again, lift
  the riscv64 pin in this window; else it stays with its reason.

**Phase 2 — producer fixes (media/android lane): ✅ mostly DONE**
- ✅ GENAI-DRIFT producer half — the arm64 genai wheel builds. The tolerance
  line at smoke-torch-venv.sh:179 must be deleted AFTER the rebuild proves
  0.15.2 ships, not before.
- ✅ ORPHAN-PINS — PyAV is built (own stage + own script dir); the TVM half
  closed by 202634c.
- ✅ RV1-FREETYPE — freetype ENABLED against staged static target harfbuzz;
  OFF survives only as the not-staged fallback.
- ⬜ **LOG2 open half — build the wasm asyncify/jspi flavors.** The only
  Phase-2 item still outstanding.

**Phase 3 — toolchain trims (from-base rebuild validates):**
- TG1 residual (fuller toolchain-closure trim) + TG3 residual (collapse the
  two toolchain RUNs). Both were bitten before — implement + adversarial
  review + the rebuild as the only accepted proof.

**Phase 4 — DECIDED by the operator 2026-08-24:**
- S3 registry cache mode=max: **NO** — inline stays; the design doc
  (docs/build-cache-tiers.md) remains for a future revisit. S3 moves to § D
  as decision-recorded, do not re-pitch without new evidence (e.g. another
  cold-rebuild incident).
- USE_FAST_UBUNTU_MIRROR: **YES** — the rebuild launches with the knob ON,
  which exercises the APT-HTTP https-restore for real (its validator).

**The rebuild itself:** from BASE, all three arches, --parallel-archs
--max-parallel-archs 3, launched CLEAN — it doubles as the long-owed PAR1
timing run. It auto-validates the already-landed-but-unproven set (media
source-caches, TS8, DUP2 SSOT, cerbero extra_mirrors, C3 :?-guards, TS4 llvm
keying, CERB-CACHE warm behaviour) and fires the § E triggers:
GCC_PARALLEL_TARGETS, gcc-prereq facets, post-restart base cache-miss.

**After the ship:** evidence-audit the logs (the wave-6 ritual), fold
validated items with quotes, THEN: GPU lane opt-in build (GPU1-7), first
compose up + WEBUI_SECRET_KEY rotation (user-side).

## F. Refactor candidates found while switching ccache -> sccache (2026-08-26)

Collected DURING the switch and the staged rebuild, each with the evidence that
produced it. None of these blocks the current run; they are the debt the switch
either created or exposed.

- **`preflight.sh` exits 0 on failure** [S·★★★] Observed live: it printed
  `3 check(s) failed` AND `Fix these before a multi-hour rebuild.` and then
  `exited with code 0`. Anything that calls it non-interactively and trusts the
  exit code gets a green light on a red result. This is the highest-value item
  here because it silently disarms the one gate standing between a bad tree and
  a many-hour rebuild.
- **stdout-as-return-value is a live footgun** [M·★★★] `compiler_cache_launcher`
  returns the launcher NAME on stdout while `info()` writes to fd 1
  (logging.sh:77). The leak produced
  `CC="[INFO] Using sccache ...sccache gcc"` and GCC died as
  `configure: error: C compiler cannot create executables` -- a message pointing
  nowhere near the cause. Fixed there + regression-tested
  (test-compiler-cache-launcher.sh, with a mutation case). **The refactor is the
  CLASS, not the instance:** sweep every function whose stdout callers capture
  with `$(...)`, and either route all logging to stderr repo-wide or return
  values through a nameref instead.
- **The compiler-cache abstraction is split across seven places** [L·★★]
  compiler-cache.sh:4-8 already warns "the 02-toolchain GCC/LLVM builds do NOT
  source this module ... that misread hid a dead ccache mount for months". The
  sccache switch had to touch build-gcc.sh, build-clang.sh, llvm-cross.sh,
  compiler-cache.sh, cmake-cache-linker.sh, build-app-wheelhouse.sh and the
  onnxruntime build lib SEPARATELY, and one of them (cmake-cache-linker.sh, a
  SHARED helper) would have silently overridden the switch for every consumer.
  Consolidate onto one resolver; the launcher helper is the seam to build on.
- **Two compiler caches are now installed and mounted** [M·★★] ccache stays as
  the fallback for invocations sccache refuses, so every stage carries both
  mounts (5/5, 1/1, 13/13, 3/3) and the ~27 GB warm ccache still occupies disk
  while contributing nothing. DECIDE after the switch is proven: drop ccache and
  delete the fallback branches, or keep it and document why. Do not leave it
  ambiguous -- ambiguous is how the dead mount survived months last time.
- **`--ccache` no longer means ccache** [S·★] build-gcc.sh and build-clang.sh
  keep the flag name (llvm.sh:28 passes it) while it now selects whichever cache
  is usable. Rename to `--compiler-cache` with `--ccache` as a deprecated alias,
  or the next reader will believe it forces ccache.
- **sccache stats are per-build-window only** [S·★★] build-gcc.sh zeroes stats
  before each GCC and reports after, so a run yields N disjoint windows (this
  run: 3.02 / 2.50 / 1.81 / 6.45 / 2.00 %) and NO aggregate. That makes the one
  question the switch has to answer -- "did the hit rate improve on a warm
  build?" -- unanswerable without hand-summing logs. Emit a per-stage aggregate.
- **Mount-id keys are inconsistent** [S·★★] cache-mount ids mix `${TARGETARCH}`
  and `${TARGET_ARCH}`; PAR2 is the documented bug class where the wrong one
  silently shares or splits caches across lanes. Audit all ~43 mount lines and
  pick one, with a test.
- **`RUSTC_WRAPPER=""` is now an unexplained exception** [S·★★] After "sccache
  everywhere", build-gstreamer-monorepo.sh:681 still hard-clears the Rust
  wrapper. The reason is real (the sccache SERVER died mid-compile in three
  media rounds, killing green builds at 99%) but it now reads as an oversight.
  Either revalidate against the bar in docs/build-cache-tiers.md:340 or promote
  the comment into a Verdict entry so nobody "fixes" it.
- **versions.env mis-attributes a watch note** [XS·★] The LLVM 23 block lists
  the `-nostdinc++` libstdc++ c++23 patch as something to watch for the LLVM
  bump. That patch lives in GCC's `src/c++23/Makefile.in` and is a GCC concern;
  it ran clean in this build's GCC stage. Move the note, or it sends the next
  reader looking in the wrong stage.

**Folded in from the 2026-08-26 backlog truth-audit (15 agents), corrections
that were verified but not yet applied above:**

- **GCC_PARALLEL_TARGETS has now been missed TWICE** [S·★★] The § E entry says
  "next compiler-stage rebuild", but the flag defaults to 0, so the 2026-08-24
  and 2026-08-25 compiler rebuilds both took the sequential path and validated
  nothing. It must go on the LAUNCH COMMAND or it will be missed a third time.
- **LLVM_COMMIT is present but INERT** (versions.env:41) -- the consumers
  (build-clang.sh / llvm-cross.sh) do not read it. The key landed; the wiring
  did not. Re-word the rider to the residual work.
- **TS1 is half-landed and CAN break a build** [S·★★] The
  APPIMAGETOOL_*_SHA256 keys exist in versions.env, but packaging-deps.sh:156-174
  still uses its own case-arm literals. Bumping APPIMAGETOOL_VERSION alone would
  therefore break. This is the only rider whose half-state has teeth.
- **S5 premise is falsified** -- media cargo ids are already per-lane by design
  (Dockerfile.media:856-857). Move to Verdicts as declined-with-evidence rather
  than leaving it as open work.
- **3 UNOWNED env knobs** (HARFBUZZ_VERSION, IREE_CCACHE_MAXSIZE,
  PY_MLC_Z3_STATIC_VERSION), two introduced 2026-08-24/26. Register them in
  lint-env-knobs.allow before anyone flips KNOB_GATE=1.
- **docs/build-cache-tiers.md still advertises CROSS_REGISTRY_CACHE=max** as a
  live knob with line refs that no longer exist (5 sites). S3 was declined and
  the code reverted; setting it today is a no-op. Mark those sites DESIGN ONLY.

**Do NOT close (closure attempts were reviewed and REJECTED):** the § B QUEUED
BUMPS bullet (closing as written drops real in-scope work), the § E gcc-prereq
measurement facets, and A1's TG1 residual (the proposed replacement text was
wrong in both directions).

## A. Window inventory — A1 needs WORK in the wave, A2 is validated by the rebuild ALONE

### A1. Work items (all referenced by the phase plan above)

- **GENAI-DRIFT — onnxruntime-genai differs per arch and the pin assert
  says OK** [S·★★, 2026-08-23] versions.env pins v0.15.2; shipped reality is
  amd64 0.15.2 (local wheel), arm64 0.14.0 (PyPI, from the app lock), riscv64
  absent. The dual-authority union (lock ∪ pin) accepts all three, so the
  assert cannot catch it. **PRODUCER HALF DONE** (wave-6): the arm64
  `onnxruntime_genai-0.15.2-cp314-cp314-linux_aarch64.whl` now builds. What
  REMAINS is consumer-side and rebuild-gated: once the rebuild proves 0.15.2
  ships on arm64, DELETE the dated tolerance entry at
  smoke-torch-venv.sh:179 (`("onnxruntime-genai", "arm64", "0.14.0",
  "0.15.2", …)`) — leaving it in place silently re-disarms the assert. Also
  still open: make a versions.env BUILD pin authoritative over the lock for
  every arch that builds the package.
- **Complexity-queue survivors** [S-M each] append_tvm_cmake_args 15
  positionals; vulkan/llvm-cross long stanzas; _cross_stage_build_impl;
  build_iree_wheels; parse_options 116-liner; modules.sh dir-walker.
- **TG1 residual — fuller toolchain-closure trim** [M·★★] llvm-cross/
  llvm-validate lazy + true per-RUN closures; no COPY fallback → needs a
  per-RUN mount audit + real toolchain rebuild.
- **TG3 residual — collapse the two toolchain RUNs** [S·★] RUN-3d recompiles
  instead of reusing RUN-3 (ccache absorbs, ~97s); pairs with TG1.
- **LOG2 open half — build the wasm asyncify/jspi flavors** [S/M·★★] so
  onnxruntime-web ships its webgpu JS backend (exclusion is documented in
  versions.env since wave-3; this is the build half).
- **GEN1 — genai wheel for riscv64 (self-build)** [L·★, ON-DEMAND] upstream
  ships none; IREE-style build plausible; only if it has a user. Needs a
  real generate() smoke.
### A2. Already landed, validated by the rebuild alone (watch, no work)

**Added 2026-08-26 (pre-rebuild wave + its adversarial review, commit 9a86d2f
— static review only, NO build has exercised these):**

- **IREE host stage no longer builds LLVM** [was never tracked here — the win
  the wave went looking for]. `-DIREE_BUILD_COMPILER=ON` on the HOST stage was
  a leftover; the target reads only `iree-c-embed-data` + `iree-flatcc-cli`
  out of `IREE_HOST_BIN_DIR`, both LLVM-free, so the host stage runs
  COMPILER=OFF. Review corrected the fallback: a failed *build* now fails fast
  instead of escalating to a multi-hour LLVM compile that provably cannot
  succeed where OFF failed. **Watch in the rebuild:** the riscv64/arm64 IREE
  host stage must NOT show clang/MLIR compilation, and both tools must exist.
- **ORPHAN-PINS closed** — PyAV is BUILT (new
  `linux/scripts/03-media/build/pyav/build-pyav.sh` + a `pyav` stage landing
  `av-<ver>-cp314-cp314-linux_<arch>.whl` in /opt/wheels); the TVM half was
  already closed by 202634c. **Watch:** the PyAV wheel must appear on all
  three arches and the wheel-smoke warning must disappear.
- **RV1-FREETYPE fixed** — riscv64 opencv freetype is ENABLED against staged
  static target harfbuzz; `-DBUILD_opencv_freetype=OFF` survives only as the
  not-staged fallback. **Watch:** the riscv64 `opencv-freetype` wheel-smoke
  warning must be gone — if it is not, the static-harfbuzz staging is what
  failed, not the module.
- **TVM ffi honesty** — a failed `tvm-ffi` wheel build now WITHDRAWS the wheel
  set instead of leaving an apache-tvm wheel that dies at `import tvm`.
  **Watch:** either a complete tvm+tvm_ffi pair, or an explicit skip reason —
  never "python wheel staged" alone.
- **GStreamer known-broken guard repaired** — it compared space-delimited
  against a newline-separated list, so it stopped firing as soon as TWO
  plugins failed, with a new hard FAIL resting on it. **Watch:** no spurious
  ARCH-PARITY abort at the end of a green build.

- Media source-cache mounts, cerbero extra_mirrors fallback, C3 `:?`
  guards, TS4 llvm checkout keying, CERB-CACHE warm/evict behaviour,
  APT-HTTP restore (only if the fast-mirror knob is ON), DUP2 SSOT +
  literal gate — each shipped and reviewed; the rebuild is their proof.
  Fold them with log quotes in the post-ship evidence audit.

- **TS8 + shared apt-source include** [S] build_python.sh hand-rolls the 4th
  apt-sources copy; one include, five consumers (nvidia/amd/android too).
- **DUP2 residual — SETTLED 2026-08-24, one operator habit remains** [S·★]
  the gate IS wired: preflight.sh:140 runs verify-arg-consistency.sh as the
  `arg-consistency` check, and with the C3 exemption it passes rc=0 with 32
  sites scanned. The evidence audit's "chain never runs it" observation is
  BY DESIGN — build-cross-chain.sh performs only the disk preflight, the
  full gate battery is the operator-run preflight.sh. Residual: nothing to
  build — just run preflight.sh before launch (AGENTS.md already says so).
  Delete on the next groom if no counter-evidence appears.
- **BKD1 — buildkitd session rot: RESEARCHED, no upstream fix exists** [M·★,
  downgraded from ★★ 2026-08-24; host figures refreshed 2026-08-26] host runs
  buildkit **v0.31.2** (nerdctl 2.3.5, containerd 2.3.3) since the 2026-08-26
  upgrade — see Phase 0. The session rot is UNAFFECTED by that upgrade. The symptom IS a known open upstream issue —
  moby/buildkit#6422 ("no active session … context deadline exceeded", open,
  no linked PR) and #5624 (same class during cache-export registry auth) —
  and NO release through v0.32.2 (2026-08-04) mentions a session/keepalive
  fix. VERDICT: keep the restart playbook (stop chain → restart
  buildkit.service → relaunch; cachemounts survive) — this is still the cure
  and the upgrade did not change that. The concurrency rider is now PARTLY
  taken: #6916 (daemon crash under concurrent builds) came with v0.31.2;
  **#6955 (parallel-build cache miss) did not** — it needs v0.32.0, which no
  nerdctl-full bundle ships. Do NOT chase it by installing buildkit outside
  the bundle: the pieces are version-matched. Re-open when a nerdctl-full
  carries 0.32.x.

## B. Next PIN-BUMP window (versions.env riders — NEVER alone)

- **QUEUED BUMPS (checked 2026-08-26, operator requested — apply the moment
  wave7e ships, NOT while it runs):** OLLAMA 0.33.0 (llm-stack only, cheap),
  CARGO_C 0.10.25 (toolchain), UV 0.12.6 + CMAKE 4.4.3 (both hit linux BASE →
  full-chain rebuild; bundle them with the NEXT window's riders so one rebuild
  pays for all). VULKAN 1.4.357.1 re-probed and STILL blocked (windows.txt
  answers .0; shared key). Command: `python3 docs/scripts/bump_versions.py
  --write --only OLLAMA_VERSION,CARGO_C_VERSION,UV_VERSION,CMAKE_VERSION`
  then sync_versions --write + the check battery.

- **AP6 — ORT_ENABLE_LTO never set/decided** [S·★★] flip per-arch-gated,
  measure in the validating rebuild, or document the decision.
- **F6 — remaining stray SHA pins: RESEARCHED, exact bump-window changes
  recorded** [S, was M] (a) ABSEIL: codeload-by-commit VERIFIED byte-stable
  (two sequential fetches, identical sha256 7f4240fe…, matches the pin at
  versions.env:194) — but GitHub only pledges byte stability "no less than a
  year", so the durable form is a STREAM hash of the decompressed tar
  (gunzip -c | sha256sum = ec28d875…); switch the pin to that at the next
  bump. (b) ANDROID_CMDLINE_TOOLS: Google DOES publish checksums —
  repository2-3.xml carries sha1 040d3996… for
  commandlinetools-linux-15859902_latest.zip; verified against the real zip,
  and our sha256 pin (versions.env:503) matches the same bytes. Bump-window
  change: cross-check the manifest sha1 when regenerating the sha256 pin.
  Both edits touch versions.env → pin-bump window only.
- Small riders [S each]: pyav dead-pin check (Windows consumer?),
  LLVM_COMMIT opt-in key, setup-package-image residual pins (:283-285),
  peripheral pins (renovate hints, ollama ALLOW_UNVERIFIED, ghcr token
  scope), TS1 APPIMAGETOOL_*_SHA256 keys, RUFF_PIN → versions.env (C4).

## C. Orchestrator lifecycle (one coherent PR)

- **--no-push OCI-layout handoff + dual-path collapse** [M·★★] --no-push
  builds resolve parents against the REGISTRY (two runs lost historically).

## D. CI / infra / cache tiers (own triggers)

- **S3 — per-stage registry cache refs: operator DECLINED 2026-08-24**
  [decision recorded] design stays at docs/build-cache-tiers.md (DESIGN ONLY
  banner); cost ~12-13 GB registry upload per run was judged not worth it
  while prune-safe + local caches hold. Re-open ONLY on new evidence (another
  cold-rebuild loss). v1 implementation history: reverted twice (fix7 gate
  token; inert-by-default with no coverage) — read the doc before any retry.
- **S5 — cargo cache ids arch-independent** [S·★] downloads duplicated 3×
  (deliberately per-lane since PAR2 — revisit as shared+non-locked).
- **SCC1 — sccache hybrid design** [M·★★] ccache stays for C/C++; sccache
  ONLY for rustc (wiring exists, flip controlled) + nvcc + the webdav
  cross-machine tier. Absorbs "ccache remote_storage" + "Rust sccache
  unblock". Full switch rejected (owner decision 2026-08-17).

## E. Waiting on a TRIGGER (not on work)

- **GHCR-LEGACY-TAGS — six dangling legacy tags need an operator decision**
  [S, user-side, found 2026-08-24] `android`, `compiler`, `latest`, `media`,
  `sdk`, `torch` are docker manifest lists whose 18 children ALL 404 —
  unpullable since before ghcr-prune-package.sh existed (old retention or a
  past manual prune). Decide: delete the six tags, or re-point them at
  current digests. The prune tool deliberately keeps them (tagged = kept).

- **PAR4-hard — true memory cap (MemoryHigh/jobserver)** — only if a
  divisor-6 parallel run OOMs again.
- **GCC_PARALLEL_TARGETS validation** — next compiler-stage rebuild.
- **gcc-prereq measurement facets** (sig-cache, LIBRARY_PATH leak, verify
  coverage, dup-compile overlap) — needs ccache stats from a real build;
  the "unify prereq paths" reading is CLOSED (deliberately different).
- **post-restart base cache-miss** — observe at the next host reboot.
- **LOG7 — sdkmanager CLI deprecated** — bit-rot watch before Google
  removes it.
- **MESON-GI — meson 1.12 breaks g-i-1.84 glib-subproject resolution
  (riscv64 cross gst)** [S·★, watch] falsified the RV1-poison theory in
  wave5: reproduces with a clean sysroot. Scoped pin meson==1.11.2 in
  setup-gstreamer.sh for riscv64 cross only. Re-bump when upstream
  meson/g-i fix the `subproject('glib')` resolution — retest by removing
  the pin in a closure window.
- **NODE-RV — riscv64 ships Node v22 (pin: 26.7)** [S·★, watch] ubuntu-ports
  has no 26.x for riscv64; the install falls back fail-open with a WARN (by
  design, seen in every wave-4 smoke log). Lift when ports ships 26.x —
  check via `apt-cache policy nodejs` on the ports snapshot at each bump
  window; until then the riscv64 image runs the distro v22.
- **SV-residual — watch the first real `compose up`** — user-side.
- **riscv64 isa-spec smoke on real hardware** — needs hardware.
- **WEBUI_SECRET_KEY server-side rotation** — user action.

## Verdicts (anti-re-sweep records — do NOT re-audit without new evidence)

- **PAR5 — a lone surviving lane stays throttled; the obvious fix is
  DISPROVEN** [S/M·★★, tried and REVERTED 2026-08-23] symptom unchanged: a
  single remaining wheelhouse crawls at 1-2 jobs for HOURS while the host
  idles (wave4f arm64, wave5h riscv64). DO NOT re-attempt the flag-dir
  live-lane-count approach that this entry used to propose — it was built,
  reviewed and reverted: BUILD_MEM_DIVISOR is a build-arg consumed as
  `ENV BUILD_MEM_DIVISOR` when the container build STARTS, so it cannot
  change while that build runs; the clamp could not fire at all in the
  shipped topology (all lane markers exist before any lane retires), and
  where it could fire it made the divisor depend on sibling timing and
  could drop the intra-step multiplier entirely (6→1) — an overcommit in
  exactly the direction PAR4 exists to prevent. A tripwire in
  test-stage-defs.sh now fails if flag-dir state is wired back into the
  divisor. Achievable options only: PAR4-hard (a host-level memory
  governor: systemd-run MemoryHigh per build, or a global compile-job
  server), or re-sizing at container-build/STAGE boundaries. Full verdict
  in docs/build-parallelism-memory-tuning.md.


- **Nondeterministic file-picks (2026-08-22, PKGCFG-MIRROR post-mortem)**:
  any `grep -rl … | head -1 / grep -m1` that CHOOSES a file to patch is
  readdir-order dependent — it can pick a different file inside the
  container than on the host and still echo success. The v1 pkg-config
  mirror override did exactly that (patched a stray .patch file, cold
  bootstraps kept 404ing) while the host reproduced "correct". Rule: patch
  the KNOWN path explicitly, treat the grep as a supplement, and echo the
  RESULT (the patched line) as proof, never the intent.

- **CI sweep (2026-08-17)**: CI1-3 fixed same day (timeouts, ollama
  digest-pin, env-var login); otherwise CLEAN.
- **Idempotency / GST1 runs-twice class (2026-08-17)**: CLEAN — only
  install-deps + configure-runtime run twice, both second-run-safe; this
  section is the checklist for any NEW double-run path.
- **Bump-tool (2026-08-19)**: BT1+BT2 fixed same day (spec_vulkan SHA,
  artifact-gating, empty-download rejection).
- **A1 allowlist (2026-08-18)**: 148/148 knobs have live readers.
- **onnxruntime 1.28-vs-1.27 (2026-08-15)**: NO source dedupe to do —
  runtime __version__ quirk, already asserted as a union in the smoke;
  residual folded into C3.
- **Version-ARG mirrors / dead stages / USER-ordering (2026-08-17 sweep)**:
  zero drift, clean.
- **Coverage map (2026-08-10, unchanged)**: chain swept end-to-end across
  six rounds; thin spots = GPU lanes, Windows psm1 (sampled), lib/ beyond
  smoke, benchmark-viewer. THE REMAINING DISCOVERY CHANNEL IS RUNS — the
  classes that matter (cache-bust latents, foreign-arch paths, timing/OOM)
  only surface in real rebuilds.

## Reference

- **B3-PLAN**: CONSUMED by wave-4 (all listed bumps applied 2026-08-18,
  incl. the F7-coverage PY_* set; TENSORFLOW_C landed at 2.18.1 — last
  version with a published C tarball). Next refresh at the next window via
  `bump_versions.py --check` (now artifact-aware).
