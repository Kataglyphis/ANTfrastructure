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

