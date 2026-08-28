# Refactoring backlog — CLOSED items, archived 2026-08-27

> Split out of [`refactoring-backlog.md`](refactoring-backlog.md) so that file
> shows only OPEN work. Nothing here needs action; it is kept because several
> entries record WHY a thing is the way it is, and because a few were closed by
> being REFUTED or RETRACTED rather than fixed — which is exactly the kind of
> finding that gets re-discovered if the reasoning disappears.
>
> The older round (2026-08-10 and before) is in
> [`refactoring-backlog-archive-2026-08-10.md`](refactoring-backlog-archive-2026-08-10.md).

## Closed on 2026-08-27 and before

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

- ✅ **`preflight.sh` exits 0 on failure — RETRACTED 2026-08-27, the bug is not
  real.** The script's summary block ends `exit 0` / `exit 1` / `exit 2` and
  those propagate correctly: `PREFLIGHT_ONLY=<unknown-slug>` returns 2 when run
  directly. Both "observations" were the same measurement error —
  `bash preflight.sh | tail | sed; echo $?` reports SED's status, not the
  script's. Demonstrated: `(exit 1) | tail -1 | sed 's/^//'; echo $?` prints 0,
  while `(exit 1); echo $?` prints 1. I added the "re-confirmed 2026-08-27"
  note to this entry on the strength of that artifact, so the retraction is
  mine to make. `exit 1` has been in place since 928e745 (2026-08-25).
  LESSON worth keeping: when checking an exit code, do not pipe.

- ✅ **stdout-as-return-value — CLOSED 2026-08-27 with a GATE, not a sweep.**
  The exposure turned out to be small and the risk structural, so the fix is
  `linux/scripts/verify-stdout-returns.py`, wired into preflight as
  `stdout-returns`. It cross-references every function consumed via `$( )`
  (411 of them) against every `log`/`info` call inside one, because those reach
  fd 1 while `warn`/`err` reach fd 2 (logging.sh:77-83).
  Found exactly one live offender: `normalize_llvm_cmake_dir` (tvm-detect.sh),
  whose stdout is a path consumed at three call sites — latent, firing only
  when an LLVM CMake path actually needs normalising. Both of its log lines are
  redirected now; the gate found the SECOND one after the first had been fixed
  by hand, which is the whole argument for having it. Mutation-checked in both
  directions.

- ✅ **`--ccache` renamed 2026-08-27.** build-gcc.sh and build-clang.sh now take
  `--compiler-cache` ("sccache first, ccache fallback"), with `--ccache` kept as
  a DEPRECATED alias so llvm.sh:28 and any operator habit keep working. Both
  spellings verified to parse; an unknown flag still warns.

- ✅ **sccache stats — FIXED 2026-08-27.** build-gcc.sh zeroed the counters
  before EVERY compiler, so five GCCs produced five disjoint windows and no
  aggregate. Zeroed once per run now, via a /tmp marker whose lifetime matches
  the sccache server's. Fixed alongside the third dead `= "sccache"` identity
  check in the same file, which had every GCC stage reporting CCACHE stats
  while sccache did the work.

- ✅ **Mount-id keys — RESOLVED 2026-08-27, but NOT by unifying all of them.**
  Investigated rather than swept. The two conventions are mostly principled:
  `${TARGETARCH}` is BuildKit's automatic value and resolves to amd64 for every
  cross lane, so the caches keyed on it are SHARED across targets --
  pip/uv/rustup, cargo, ccache/sccache, llvm-src. That is correct and desirable:
  wheels carry a platform tag, sccache keys on compiler+flags, crate sources and
  LLVM sources are arch-independent, so sharing raises the hit rate and splitting
  them would only cost a cold rebuild. `${TARGET_ARCH}` is the explicit per-target
  value and keys the caches whose CONTENT is arch-specific (apt debs,
  ffmpeg-sdks). Also correct.
  The one real defect was cargo: Dockerfile.toolchain:228-229 used
  `${TARGETARCH}` while Dockerfile.media:863-864 used `${TARGET_ARCH}`, so the
  same registry/git caches carried two different ids and the toolchain's copy
  could never help the media stage. Aligned on the shared convention, since
  crate sources are arch-independent.

- ✅ **versions.env watch note MOVED 2026-08-27.** The -nostdinc++ libstdc++
  c++23 patch note now sits at the GCC_VERSION pin, where the patch actually
  lives (src/c++23/Makefile.in), instead of under LLVM_RELEASE.

- ✅ **UNOWNED env knobs — CLOSED 2026-08-27.** All five (HARFBUZZ_VERSION,
  IREE_CCACHE_MAXSIZE, IREE_SCCACHE_LOG, PY_MLC_Z3_STATIC_VERSION,
  SCCACHE_CONF) are registered in lint-env-knobs.allow with their reason and
  reader. Verified under KNOB_GATE=1, which is the failure the entry warned
  about: the gate now passes on its first strict use instead of failing.

- ✅ **IREE host stage no longer builds LLVM** [was never tracked here — the win
  the wave went looking for]. `-DIREE_BUILD_COMPILER=ON` on the HOST stage was
  a leftover; the target reads only `iree-c-embed-data` + `iree-flatcc-cli`
  out of `IREE_HOST_BIN_DIR`, both LLVM-free, so the host stage runs
  COMPILER=OFF. Review corrected the fallback: a failed *build* now fails fast
  instead of escalating to a multi-hour LLVM compile that provably cannot
  succeed where OFF failed. **Watch in the rebuild:** the riscv64/arm64 IREE
  host stage must NOT show clang/MLIR compilation, and both tools must exist.
- ✅ **ORPHAN-PINS closed** — PyAV is BUILT (new
  `linux/scripts/03-media/build/pyav/build-pyav.sh` + a `pyav` stage landing
  `av-<ver>-cp314-cp314-linux_<arch>.whl` in /opt/wheels); the TVM half was
  already closed by 202634c. **Watch:** the PyAV wheel must appear on all
  three arches and the wheel-smoke warning must disappear.
- ✅ **RV1-FREETYPE fixed** — riscv64 opencv freetype is ENABLED against staged
  static target harfbuzz; `-DBUILD_opencv_freetype=OFF` survives only as the
  not-staged fallback. **Watch:** the riscv64 `opencv-freetype` wheel-smoke
  warning must be gone — if it is not, the static-harfbuzz staging is what
  failed, not the module.
- ✅ **TVM ffi honesty** — a failed `tvm-ffi` wheel build now WITHDRAWS the wheel
  set instead of leaving an apache-tvm wheel that dies at `import tvm`.
  **Watch:** either a complete tvm+tvm_ffi pair, or an explicit skip reason —
  never "python wheel staged" alone.
- ✅ **GStreamer known-broken guard repaired** — it compared space-delimited
  against a newline-separated list, so it stopped firing as soon as TWO
  plugins failed, with a new hard FAIL resting on it. **Watch:** no spurious
  ARCH-PARITY abort at the end of a green build.

- Media source-cache mounts, cerbero extra_mirrors fallback, C3 `:?`
  guards, TS4 llvm checkout keying (**PROVEN LIVE 2026-08-26**, log
  quote: `[INFO] Evicting stale llvm checkout llvm-project-22.1.8 (superseded
  by llvmorg-23.1.0)` — the LLVM 23 bump found a 22.1.8 tree in the cache mount
  and evicted it instead of silently reusing it, which would have shipped an
  image claiming 23.1.0 while containing 22.1.8; fold on ship), CERB-CACHE warm/evict behaviour,
  APT-HTTP restore (only if the fast-mirror knob is ON), DUP2 SSOT +
  literal gate — each shipped and reviewed; the rebuild is their proof.
  Fold them with log quotes in the post-ship evidence audit.

- ✅ **TS8 — ALREADY DONE, closed 2026-08-27.** Verified in the source rather
  than assumed: build_python.sh calls `ubuntu_write_deb822_source` from the
  shared ubuntu-mirror.sh writer, with a comment recording that the hand-rolled
  stanzas are gone and the output is byte-identical. Eight files now use that
  writer. The entry had simply gone stale.

- ✅ **DUP2 — deleted 2026-08-27 as its own text instructed.** The entry ended
  "Residual: nothing to build — just run preflight.sh before launch (AGENTS.md
  already says so). Delete on the next groom if no counter-evidence appears."
  This is that groom, preflight ran repeatedly today at 32/32, and no
  counter-evidence appeared.

- ✅ **QUEUED BUMPS — CLOSED 2026-08-27, three of four were already applied.**
  Re-checked with the tool rather than trusted: UV 0.12.6, CMAKE 4.4.3 and
  CARGO_C 0.10.25 all report "up to date", so they landed in an earlier wave and
  this entry had gone stale. Only OLLAMA had moved — 0.33.0 -> 0.33.1, both
  SHA256s written by bump_versions.py, "rebuilds: llm-stack image only" so it
  costs nothing on the cross chain. Followed by sync_versions --write and the
  check battery: version-snapshot, arg-consistency, env-knobs and (after
  regeneration) the curated SBOM are all green. VULKAN 1.4.357.1 stays blocked
  on the shared-key problem recorded above.

- ✅ **F6 — DONE 2026-08-27, both halves.** (a) ABSEIL now pins the
  DECOMPRESSED-STREAM hash (`ABSEIL_TARBALL_STREAM_SHA256=ec28d875…`), which
  outlives GitHub's "no less than a year" byte-stability pledge because the
  gzip container may be re-encoded while the stream cannot. BOTH sides moved
  together, as the old note demanded: `download_verified_file()` grew a
  `stream` mode, abseil-headers.sh passes it, and bump_versions.py writes the
  stream form under the new key via a new `sha256_of_gz_stream()`. Verified
  end to end — the tool computes exactly the pinned value, the shell accepts
  the right hash, rejects a wrong one, and rejects the stream hash in FILE
  mode, so the two modes cannot be confused. (b) ANDROID_CMDLINE_TOOLS needed
  no change: the repository2-3.xml sha1 cross-check is already written beside
  the key and the pin sits in the tool's manual-tier allowlist.

- ✅ **SCC1 — SUPERSEDED, closed 2026-08-27.** The entry already recorded that
  the owner reversed the 2026-08-17 rejection and that the C/C++ half is
  implemented; it was only ever still open because nobody ticked it. The Rust
  half followed on 2026-08-27 with the always-sccache decision.

- ✅ **SCC-BARE-FALLBACK — DECIDED and implemented 2026-08-27.** The owner's
  answer is "benutze immer sccache": guarded launcher where 01-core is
  mounted, bare sccache where it is not, never uncached.
  build-gstreamer-monorepo.sh was the one writer choosing uncached and now
  agrees with common.sh:449-450. The gate this entry produced was rewritten to
  assert the DECISION rather than the spelling -- the property is "never
  uncached", mutation-checked in both directions.

- ✅ **SCC-DIAG-LEFTOVERS — CLOSED 2026-08-27.** build-app-wheelhouse.sh no
  longer defaults SCCACHE_LOG to sccache=info, so IREE builds are quiet again
  (IREE_SCCACHE_LOG still turns it back on), and compiler-cache.sh's "Remove
  once the cause is known" note now states the cause: concurrent BuildKit RUN
  steps shared one sccache server because the port is not container-local,
  cured by SCCACHE_SERVER_UDS.

- ✅ **MANIFEST-FRESHNESS-WIRING — WIRED 2026-08-27.** verify-manifest-freshness.sh
  now runs from build-runtime-manifest.sh right after create_manifest, with
  EXPECT_RUN_ID threaded from CROSS_RUN_ID. Deliberately ADVISORY: it runs
  after the push, so failing hard could not unpublish anything and would only
  turn a finished run red; MANIFEST_FRESHNESS_STRICT=1 makes it fatal for CI,
  MANIFEST_FRESHNESS_GATE=0 skips it. Sensitivity-checked against the live
  index: PASS with this run's id, FAIL with any other.

- ✅ **BINFMT-UNIT-REINSTALL — DONE 2026-08-27.** The dev host's unit now
  carries `PartOf=containerd.service` and the fix was verified against a real
  containerd restart. The mechanism and the measurement live in AGENTS.md
  § Prerequisites (QEMU/binfmt) — one owner, not two.

- ✅ **XC2-PARTIAL-RUN — FIXED 2026-08-27 at the consumer, not the orchestrator.**
  runtime_android_pin returned empty whenever the android stage had not built
  in this run, so a `--only runtime` resume shipped wrappers carrying run-id
  and build-type but no parent-digest — which is what today's published index
  did. It now resolves the mutable android tag to a digest itself when the
  threaded pin is absent. Chosen over re-threading ANDROID_PIN through the
  orchestrator because that is a wide change with no validating run available;
  this is one function. Guarded on both halves (needs registry_pin_ref AND a
  configured repo), so a --no-push run behaves exactly as before. The unit
  test now pins the new contract and caught an unbound-variable crash in the
  first version of the fix.

## Closed 2026-08-28 — SHIPPED record, consumed phase plan, and verdicts

Moved out of `refactoring-backlog.md` so that file shows only OPEN work. The
2026-08-27 ship and its post-ship audit, the consumed CLOSURE WINDOW 3 phase
plan, the ALREADY-MAXIMAL anti-re-sweep block, the "already landed / watch"
items, the declined/disproven verdicts, and the consumed B3-PLAN reference.

### SHIPPED 2026-08-27 — and the audit that followed it

`:latest-cross` = index `a26bf2f4dbc8`, children amd64 `a0d1a144` / arm64
`2d354459` / riscv64 `7e0ed041`, run id `20260827-073226-d491cb10`. Freshness
VERIFIED against the registry: every index child matches its per-arch tag and
all three share this run's id.

The ship itself needed two rescues. The chain died after 5.5 hours on a QEMU
binfmt registration that the 2026-08-26 daemon restart had silently taken with
it — the guard for exactly that existed but sat AFTER the builds it protects.
Resumed with `--only runtime`, it then died again on an ARCH-PARITY arm that
correctly reported the IREE compiler wheel the same day's IREE fix had removed.

Then two audits read the result rather than the code, and between them found
24 defects — of which 22 were fixed, one refuted, and one retracted as my own
measurement error. The ones that had SHIPPED: Dockerfile.package expanded two
prefixes to empty inside their own ENV, so PATH carried `/bin` twice and
GST_PLUGIN_PATH pointed at `/lib/gstreamer-1.0`; the Android ONNX Runtime
carried Microsoft's 1DS telemetry because only the native lane passed
`--no_telemetry`; amd64 alone shipped a setuid-root gst-ptp-helper; Node.js was
an alpha its own npm refuses; and TVM had been missing from both cross arches
behind four stacked causes.

Three gates were reporting success over things they never tested, and are
fixed: `check_ffmpeg` fell back to an absolute path exactly when PATH
reachability broke, the app-wheel smoke printed one identical PASS over 15/15,
14/15 and 12/15, and the shipped-content byte gate hid behind a boot smoke so
riscv64's wrapper reached the index unchecked.

### The previous ship, for the record

**WAVE-6 SHIPPED 2026-08-24** (the gate-truth build — three blind gates now actually work)

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

### CLOSURE WINDOW 3 — consumed phase plan (declared 2026-08-24, pre-build wave DONE 2026-08-27)

The operator committed to a fresh build, so the versions.env lock was OPEN
and build-validated items were IN SCOPE. The pre-build wave is worked through
and the validating rebuild ran. 27 unit suites / 677 assertions green,
shellcheck clean over 263 files plus the new SC2215 pass. Preflight 31/32:
the one red check is `docs cross-references`, all three findings Windows-lane
(they belong to the separate Windows backlog). The backlog went 46 → 30 in
the pre-build wave, then back to 39 when the 2026-08-27/28 run was mined (§ G,
§ F LOG19, § B LOG17/LOG18).

Two fixes in this wave are proven by EXECUTION, not inspection: TVM now
compiles and stages its arm64 wheels (four stacked causes, each only visible
once the one before it was fixed), and `PartOf=containerd.service` was tested
against a real `systemctl --user restart containerd`.

CORRECTED 2026-08-28: that PartOf claim was HALF the fix and the sentence
"now self-heals" was wrong. Both reboots that night lost the emulators anyway.
PartOf did fire — the unit re-ran in the same second — but it then FAILED with
`cat: /run/user/1000/containerd-rootless/child_pid: No such file`. `After=`
orders the UNIT start only; containerd-rootless still has to unshare and write
child_pid afterwards, so on a cold boot the binfmt unit wins the race. A manual
re-run always succeeds because containerd is warm by then, which is exactly why
the restart test looked green while every boot stayed broken. Fixed for real in
afefdfc (`wait_for_namespace()` polls for the pid file and a joinable namespace,
plus `Restart=on-failure`). LESSON: a unit that is `active` proves nothing —
prove emulation with a real foreign-arch run.

What the rebuild still has to prove is everything static analysis cannot: today
showed three separate times that a defect only becomes visible after the one in
front of it is gone.

### What the 2026-08-28 maximality audit found ALREADY MAXIMAL (anti-re-sweep)

- **FFmpeg is feature-identical across all three arches.** The `External
  libraries` block is byte-identical on amd64/arm64/riscv64 (45 libraries), and
  so is the hwaccel block. A riscv64 cross build that loses ZERO codecs against
  amd64 is rare — do not "improve" this.
- **Runtime SIMD dispatch is maximal and justifies the conservative `-march`
  baselines**: FFmpeg reaches AVX-512ICL (amd64), SVE/SVE2/SME/SME2 (arm64) and
  `RISC-V Vector enabled yes` + CBO prefetch (riscv64), each with runtime CPU
  detection. OpenCV dispatches to AVX512_SKX / NEON_BF16.
- **Declarative optimization is clean**: 41× `CMAKE_BUILD_TYPE=Release` and 0×
  Debug/RelWithDebInfo across all three media logs; meson `Optimization: 3`,
  `Debugging: false`; stripping centralized and proven on shipped bytes;
  `--gc-sections --as-needed -z now`; amd64 CPython is PGO+LTO.
- **GStreamer is the full monorepo on all three lanes**, Rust plugins included
  (riscv64 builds them in 3m44s), 220/229/222 plugins, amd64−arm64 difference
  empty.
- **The smokes that DO run are functional, not cosmetic**, and run per-arch under
  QEMU on the real shipped bytes: a real `InferenceSession` on a generated ONNX
  protobuf, `iree-compile` + `iree-run-module` with result checking, cv2
  GStreamer appsink with frame shape, torch forward+backward, torchvision
  `ops.nms` through the `._C` extension, an 8-case compiler battery.
- **The anti-fake-green discipline is first-rate**: scan-done stamps, EP
  sentinels, CMDOK markers, SIGPIPE fixes, and parity tables that fail when a
  documented exception STOPS applying.

### Already landed, validated by the rebuild alone (watch, no work)

- **BKD1 — buildkitd session rot: RESEARCHED, no upstream fix exists** [M·★,
  downgraded from ★★ 2026-08-24; host figures refreshed 2026-08-26] host runs
  buildkit **v0.31.2** (nerdctl 2.3.5, containerd 2.3.3) since the 2026-08-26
  upgrade. The session rot is UNAFFECTED by that upgrade. The symptom IS a known
  open upstream issue — moby/buildkit#6422 ("no active session … context deadline
  exceeded", open, no linked PR) and #5624 (same class during cache-export
  registry auth) — and NO release through v0.32.2 (2026-08-04) mentions a
  session/keepalive fix. VERDICT: keep the restart playbook (stop chain → restart
  buildkit.service → relaunch; cachemounts survive). The concurrency rider is
  now PARTLY taken: #6916 (daemon crash under concurrent builds) came with
  v0.31.2; **#6955 (parallel-build cache miss) did not** — it needs v0.32.0,
  which no nerdctl-full bundle ships. Do NOT chase it by installing buildkit
  outside the bundle: the pieces are version-matched. Re-open when a
  nerdctl-full carries 0.32.x.

### Verdicts (anti-re-sweep records — do NOT re-audit without new evidence)

- **S3 — per-stage registry cache refs: operator DECLINED 2026-08-24.** Design
  stays at docs/build-cache-tiers.md (DESIGN ONLY banner); cost ~12-13 GB
  registry upload per run was judged not worth it while prune-safe + local
  caches hold. Re-open ONLY on new evidence (another cold-rebuild loss). v1
  implementation history: reverted twice (fix7 gate token; inert-by-default
  with no coverage) — read the doc before any retry.
- **S5 — shared cargo cache ids: DECLINED, premise falsified 2026-08-26.** The
  entry claimed "cargo cache ids arch-independent". They are not: the media lane
  uses `id=cargo-registry-${TARGET_ARCH}` / `id=cargo-git-${TARGET_ARCH}`
  (Dockerfile.media:857-858), i.e. already per-lane BY DESIGN since PAR2. The 3x
  crate duplication is the accepted cost of lane isolation. Re-open only with
  new evidence that cargo guards a shared store safely.
- **PAR5 — a lone surviving lane stays throttled; the obvious fix is
  DISPROVEN** [S/M·★★, tried and REVERTED 2026-08-23] symptom unchanged: a
  single remaining wheelhouse crawls at 1-2 jobs for HOURS while the host idles
  (wave4f arm64, wave5h riscv64). DO NOT re-attempt the flag-dir live-lane-count
  approach that this entry used to propose — it was built, reviewed and
  reverted: BUILD_MEM_DIVISOR is a build-arg consumed as `ENV BUILD_MEM_DIVISOR`
  when the container build STARTS, so it cannot change while that build runs;
  the clamp could not fire at all in the shipped topology (all lane markers
  exist before any lane retires), and where it could fire it made the divisor
  depend on sibling timing and could drop the intra-step multiplier entirely
  (6→1) — an overcommit in exactly the direction PAR4 exists to prevent. A
  tripwire in test-stage-defs.sh now fails if flag-dir state is wired back into
  the divisor. Achievable options only: PAR4-hard (a host-level memory governor:
  systemd-run MemoryHigh per build, or a global compile-job server), or
  re-sizing at container-build/STAGE boundaries. Full verdict in
  docs/build-parallelism-memory-tuning.md.
- **Nondeterministic file-picks (2026-08-22, PKGCFG-MIRROR post-mortem)**: any
  `grep -rl … | head -1 / grep -m1` that CHOOSES a file to patch is
  readdir-order dependent — it can pick a different file inside the container
  than on the host and still echo success. The v1 pkg-config mirror override
  did exactly that (patched a stray .patch file, cold bootstraps kept 404ing)
  while the host reproduced "correct". Rule: patch the KNOWN path explicitly,
  treat the grep as a supplement, and echo the RESULT (the patched line) as
  proof, never the intent.
- **CI sweep (2026-08-17)**: CI1-3 fixed same day (timeouts, ollama digest-pin,
  env-var login); otherwise CLEAN.
- **Idempotency / GST1 runs-twice class (2026-08-17)**: CLEAN — only
  install-deps + configure-runtime run twice, both second-run-safe; this
  section is the checklist for any NEW double-run path.
- **Bump-tool (2026-08-19)**: BT1+BT2 fixed same day (spec_vulkan SHA,
  artifact-gating, empty-download rejection).
- **A1 allowlist (2026-08-18)**: 148/148 knobs have live readers.
- **onnxruntime 1.28-vs-1.27 (2026-08-15)**: NO source dedupe to do — runtime
  __version__ quirk, already asserted as a union in the smoke; residual folded
  into C3.
- **Version-ARG mirrors / dead stages / USER-ordering (2026-08-17 sweep)**:
  zero drift, clean.
- **Coverage map (2026-08-10, unchanged)**: chain swept end-to-end across six
  rounds; thin spots = GPU lanes, Windows psm1 (sampled), lib/ beyond smoke,
  benchmark-viewer. THE REMAINING DISCOVERY CHANNEL IS RUNS — the classes that
  matter (cache-bust latents, foreign-arch paths, timing/OOM) only surface in
  real rebuilds.

### Reference (consumed)

- **B3-PLAN**: CONSUMED by wave-4 (all listed bumps applied 2026-08-18, incl. the
  F7-coverage PY_* set; TENSORFLOW_C landed at 2.18.1 — last version with a
  published C tarball). Next refresh at the next window via
  `bump_versions.py --check` (now artifact-aware).

## Closed 2026-08-28 (code fixes) — Linux backlog maximality audit

Moved out of `refactoring-backlog.md`. Each was found in the 2026-08-28
maximality audit and fixed with code + assertions in the same session.

- **LOG10 — riscv64 OpenCV RVV false comment** [CLOSED] Fixed the false comment
  in `opencv/android/build-android.sh` that claimed "the Linux riscv64 OpenCV
  keeps RVV under GCC" — the cross build detects no RVV (DETECT finds nothing in
  a cross build). The actual RVV enablement decision remains open as a separate
  item if needed.
- **LOG11 — OpenCV TBB on amd64 only** [CLOSED] Moved `libtbb-dev` from
  `install_deps_preamble` (host) to `target_packages` in
  `03-media/build/opencv/install-deps.sh` so the cross lanes pull the
  target-arch package. Added `Parallel framework: TBB` assertion to
  `smoke-media.sh` after the OpenCV videoio roundtrip.
- **LOG15 — android OpenCV BUILD_JAVA=ON produces no Java wrappers** [CLOSED]
  Changed `BUILD_JAVA=ON` to `OFF` in `opencv/android/build-android.sh` (it
  produced no wrappers anyway — ant was absent). Added `check_opencv()` to
  `smoke-android.sh` asserting Java wrappers are absent.
- **LOG16 — CMAKE_POLICY_VERSION_MINIMUM=3.5 as eight literals** [CLOSED] Added
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` to `versions.env`. Replaced all 8 bare
  literals across 6 files with `${CMAKE_POLICY_VERSION_MINIMUM:-3.5}` (or
  `:=3.5` in android scripts to avoid the version-forwarding test tripwire).
- **LOG20 — FFmpeg ships no drawtext filter** [CLOSED] Added `libharfbuzz-dev`
  and `libfontconfig1-dev` to ffmpeg `install-deps.sh`; added
  `--enable-libharfbuzz`/`--enable-libfontconfig` probes to `build-ffmpeg.sh`.
  Added `drawtext` filter registration assertion to `smoke-media.sh`.
- **LOG22 — FFmpeg enables Vulkan but ships zero *_vulkan filters** [CLOSED]
  Added `glslang-tools` to `install_deps_preamble` in `install-deps.sh`
  (provides `glslangValidator` on PATH for SPIR-V shader compilation). Added
  `scale_vulkan` filter registration assertion to `smoke-media.sh`.
- **LOG23 — shipped Pythons have no readline/curses** [CLOSED] Added
  `libreadline-dev` (required) and `libncurses-dev` (optional) to
  `_CPYTHON_EXT_DEV_PKG_TABLE` in `cpython-dev-packages.sh`.
- **LOG25 — LiteRT GPU/NPU hard-off with no rationale** [CLOSED] Added
  rationale comment to `build-litert.sh` explaining why GPU and NPU delegates
  are OFF (no cross-buildable GPU delegate; no NPU SDK staged).
- **LOG29 — wrapper-smoke stage never built** [CLOSED] Added
  `_runtime_run_package_smoke()` to `runtime-build-fns.sh` that builds the
  `--target wrapper-smoke` stage between package and wrapper.
  `WRAPPER_SMOKE_GATE=0` to skip. Added unit test
  `test-runtime-smoke-gate.sh` (8 assertions).
- **LOG30 — no OPTIMIZATION property assertion** [CLOSED] Added
  `_smoke_optimization_level()` to `validate-compilers.sh` checking CPython
  `sysconfig.get_config_var('OPT')` for `-O0`/missing `-O`. Called from
  `validate_smoke()`.
- **LOG36 — libtvm*.so dropped at media-to-package COPY** [CLOSED] Added
  `libtvm.so*`, `libtvm_runtime.so*`, `libtvm_compiler.so*` to the
  copy_glob allowlist in `copy-media-payloads.sh`. Added the same entries to
  `so-package-map.txt` as `source-built`. Added TVM lib verification to
  `verify-media-artifacts.sh` media-inputs stage.
- **LOG37 — docs say strict smoke set closed the orphaned-smoke class; it lives
  in a stage nothing builds** [CLOSED] Updated `cross-build-verification.md` to
  state wrapper-smoke runs as a separate `--target wrapper-smoke` build.
- **LOG38 — AGENTS.md PartOf binfmt claim** [CLOSED] Corrected the PartOf
  binfmt claim in AGENTS.md to mention `wait_for_namespace()` +
  `Restart=on-failure`.
- **LOG39 — NVIDIA/AMD build recipes broken** [CLOSED] Fixed all NVIDIA+AMD
  build recipes in `docs/linux-accelerator-images.md` (`:sdk` to
  `:cross-sdk-amd64`, `--output type=image,name=...,push=true` to
  `-t ... --push`). Removed `:latest` row from `docs/overview.md`.
- **LOG40 — license/SBOM docs drifted from generator** [CLOSED] Verified
  green — no drift found in version-snapshot or SBOM gates.
- **LOG41 — :latest deleted from registry, docs still reference it** [CLOSED]
  Removed `:latest` row from `docs/overview.md`, fixed `:latest` to
  `:latest-cross` in `docs/linux-cross-builds.md`.

## Closed 2026-08-28 (host-only fixes) — backlog items F1

Moved out of `refactoring-backlog.md`. These three touched only host-only scripts
(not COPY'd or bind-mounted into any Dockerfile), so they could be fixed outside
a closure window. Each was fixed with code + verified via preflight/tests.

- **LOG33 — `verify-shipped-wrapper.sh` had only two hard assertions** [CLOSED]
  Promoted check 3 (onnxruntime .so presence) from advisory to HARD — the image
  is built around ORT, so its absence is always a defect. Promoted check 5 (AP4
  strip) from advisory to HARD when the sentinel lib was successfully extracted
  — a surviving .symtab means the MEDIA_STRIP pass regressed. Kept advisory only
  when extraction itself failed (cannot assert on missing evidence). x265 stays
  advisory (static linking makes a missing shared lib non-proof). The script now
  has four hard assertions (ffmpeg, libtensorflow toggle, onnxruntime, AP4 strip).
- **LOG31 (preflight half) — two preflight checks were structurally incapable of
  failing** [CLOSED] `lint-env-knobs.sh` was advisory by default (exits 0 unless
  KNOB_GATE=1) and its preflight invocation omitted KNOB_GATE=1, so it always
  passed; additionally the `if [ -f ]` guard had no `else`, so a missing file
  silently dropped the check. Fixed: preflight now invokes it with
  `KNOB_GATE=1` and has the same FAIL-not-skip `else` contract as the
  version-snapshot check. Three previously-unowned operator knobs
  (BUILD_ATTEST, CROSS_DISK_GUARD_GB, NO_CACHE_EXPORT) were added to
  `lint-env-knobs.allow`. `verify-runtime-paths.sh` was "ADVISORY ONLY — never
  fails" — it now fails hard on infrastructure errors (missing
  runtime-paths.env, versions.env, or a tracked Dockerfile) while keeping the
  heuristic path-mismatch WARN lines advisory (they produce false positives on a
  healthy tree). The COPY'd half of LOG31 (validate-media-runtime.sh,
  smoke-android.sh) remains OPEN — it needs a closure window.
- **Section C — --no-push multi-stage handoff resolves parents against the
  registry** [CLOSED] Added `_chain_no_push_guard()` to `build-cross-chain.sh`
  that refuses `--no-push` for multi-stage runs (FROM_STAGE != TO_STAGE) on
  this host: BuildKit's OCI worker resolves `FROM` against the registry, not
  the local store, so downstream stages silently build on the last PUSHED
  parent (two runs lost 2026-08-08). Single-stage (`--only`), dry runs, and the
  `CROSS_NO_PUSH_FORCE=1` escape hatch are allowed. The guard runs before any
  build or disk check. The full OCI-layout export + `--build-context` handoff
  (which would make `--no-push` multi-stage actually safe) remains a future
  improvement; the refusal prevents the silent data-loss path until then.
