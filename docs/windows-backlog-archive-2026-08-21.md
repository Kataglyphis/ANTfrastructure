# Windows backlog archive — 2026-08-21

Resolved narratives moved out of `windows-builds.md` per the lean-OPEN-only
policy (COUNTING NOTE there). This tranche covers everything resolved up to
and including 2026-08-21: the post-08-17 numbered entries (#72-#110 with
their verification evidence), the CURRENT-SEQUENCE ride log (versions.env
bump ride, the sccache deadlock/miscompile verdict), P0-P7 narratives, and
the complete P8 refactor-audit cycle (#120-#131, opened AND liquidated
2026-08-21, commits 48f5733f..891394c4). Standing directives extracted from
these entries live on in `windows-builds.md` — this file is the record, not
the rulebook. Earlier tranches: windows-backlog-archive-2026-08-11.md,
windows-backlog-archive-2026-08-17.md.

### CURRENT SEQUENCE (the one list — batches A–D/G completed, see archive)

> Ordered by what unblocks what; the verification chain is the bottleneck, not
> the code. One experiment per build.
>
> **2026-08-17 late: steps 1+2 are DONE-GREEN** (verify10–15 + final; smoke
> gate 190 passed / 1 skipped / 0 failed). That run verified #93/#95/#65/#66/#88
> end-to-end and en passant surfaced+fixed: the #47 TVM LLVM heal (own minimal
> LLVM — scoop has none, dev tarball is /MT), the Anubis/`.git` wrap-download
> pair, graphene's clang-cl port, and #113 (stall-guard exports).
>
> 1. **versions.env bump full-chain ride — DONE-GREEN 2026-08-18** (4 h 01,
>    smoke 190/1/0, image verified; first full-chain #61 manifest: onnx 60.5
>    min, litert 43.9, base 31.1, merge 28.9 incl. two snapshotter-mount
>    retries, tvm 21.8 with the mini-LLVM warm). #112's `chain=''` reproduced
>    deterministically on this ride too — it is a parse hole, not a flake.
> 2. **Deadlock repro — VERDICT IN (2026-08-18, run 2):**
>    * **Deadlock GONE under WebDAV-only** — all 1891 CUDA objects incl.
>      every fused_moe launcher compiled through the sccache server, no
>      stall. The two historical wedges were #99 collateral (the L0
>      write-failure storm), not a decomposition hang.
>    * **Miscompile CONFIRMED, storage-independent, on a COLD-CACHE run** —
>      link died on dropped instantiations (`QkvToContext<*, __nv_fp8_e4m3>`,
>      `BiasSoftmaxImpl<double>`, `run_memory_efficient_attention`): the
>      objects are wrong as they leave the wrapped compile, so the loss is in
>      sccache's nvcc decomposition itself, not cache-hit replay. **CUDA
>      stays bare; the launcher-default question is CLOSED (canary 3 is red
>      before any hits are even consumed).** Addendum draft updated:
>      `out/upstream-sccache-2808-addendum.md` (owner posts).
>    * (Run 1 earlier that morning was a false all-clear — `& pwsh -File`
>      flattened the -BuildArg pair into one mangled string buildctl silently
>      discarded. Fixed: in-process invocation + driver key validation.)
> 3. **After those builds free the mounts/files:** #100 (FFmpeg/PyAV sccache),
>    #107 (extract sccache session helpers), #112 (opencv-stage provenance
>    gate empty-read), #68/#69 (FFmpeg fallback + pin drift), #45 (CUDA path
>    fail-open), #106 rest (mass `#requires`), #49/#51 (media ENV split).
> 4. **Base-tier batch — NEVER land alone** (#50 + #81, plus #78/#79 if their
>    fixes touch setup-vs): one deliberate base rebuild for all of them.
> 5. **Owner decisions:** #31 (registry push; #59 branch protection DECLINED 2026-08-17), and the
>    upstream actions in "Pending" below.
> 6. **Latent / needs a repro first:** #73 (ONNX-CUDA infinite retry — needs a
>    runtime repro), #75/#76 (timeout+heartbeat insurance; re-measured quiet
>    across 5 chains), #80 (warning-stream noise filter), #52/#54 (toolchain
>    bind-mounts / merge CUDA-runtime dedup — each wants its own verify build,
>    #54 carries a load-bearing warning).

### P0 — LIVE DEFECTS (not refactors; the chain is green *and* wrong)

> Found by the 2026-08-14 deep audit (static sweep of 151 scripts + 6
> Dockerfiles + 102 build logs). Each was verified against the tree/logs, not
> inferred. These ship broken today — do them before any refactor below.

### P0d — RESOLVED 2026-08-16 (stub; full narrative in windows-backlog-archive-2026-08-17.md)

sccache lost 100 % of L0 cache writes (`os error 3`). ROOT CAUSE: BuildKit WCOW
cache mounts lose writes into a directory an EARLIER RUN populated (158/250 on
the mount vs 0/250 in a plain dir; fresh dir on the same mount is clean).
RESOLUTION: `SCCACHE_MULTILEVEL_CHAIN` defaults to `""` (WebDAV only) in both
media Dockerfiles; genai went 157 write errors → 0 → 157 HITS. Eleven
hypotheses were measured and killed on the way; the method lessons live in
AGENTS.md (probe-reproduces-environment-not-failure; probe-destroys-own-
experiment). Trail items #89–#99 (verbatim, with every measurement): archive.
Upstream follow-ups: see "Pending" at the bottom.

### P0b — Confirmed by log forensics (49 runs, 185 MB; 2026-08-14)

> The corpus predates the step-log fix, so 28 of these logs are CLIPPED
> (the green reference run is 49 % blind in its merge step; historical ONNX
> steps are 83 % blind). Findings below survive that caveat — they rest on
> end-of-step stat blocks and timestamps, not on clipped body text. Re-run the
> forensics once a full chain has been captured with the env now in place.

- **72 [M·★★★, none] CLOSED 2026-08-20 - PREMISE DISPROVEN by the 2026-08-16 re-measurement (export ~1.2% of the chain, not 23%; the old figures came from stall/cache-failure-dominated runs). Standing instruction: do NOT collapse the media-core checkpoints on this item's authority - the resume granularity is worth more than ~60 s. Original finding: image export/unpack costs MORE than the build it wraps —
  4.33 h across the corpus, 339 operations.** The chain is split into 9+
  separate `buildctl` invocations and **each pays a full Windows-image export
  AND unpack**. Torch: 358.4 s export vs 172.6 s build (**2.08×**). LiteRT:
  1401.8 s export vs 1117 s build (1.25×). Today's base build: 605.6 s
  export/unpack = **33.5 % of the whole stage**. In the green 41:30 run,
  export/unpack is **23 % of the entire chain** — more than every COPY, every
  fan-in and the torch build combined. No static reading of the Dockerfiles
  reveals this. FIX: collapse the four `media-core-built-*` checkpoints into
  one invocation → removes 3 export/unpack round-trips per run. **CONFLICT —
  decide before doing:** those four checkpoints are exactly what gives
  media-core its per-library BuildKit-native resume (the reason litert/tvm,
  which lack them, re-pay a whole branch on any failure). Collapsing them buys
  ~3 export round-trips and costs that resume granularity. Measure both before
  choosing; this is a trade-off, not a free win.

  **RE-MEASURED 2026-08-16 on five complete media chains — THE PREMISE NO LONGER
  HOLDS; DOWNGRADE TO [S·★].** Batch A's standing caution said this item rests
  on the clipped pre-fix corpus and must be re-checked before anyone acts on it.
  Done, across `bk-run-{webdavonly,reuse,chain-disk,legacy-disk,forcelocal}.log`:

  | | per chain |
  |---|---|
  | `exporting layers`, all vertices summed | **63–69 s** |
  | longest single build vertex (onnx) | 3277–3517 s |
  | whole chain | ~5 400 s |

  Export is **~1.2 % of the chain**, not 23 %, and nowhere near "more than the
  build it wraps". The old figures were real for the runs they came from, but
  those runs were dominated by stalls and cache failures that no longer occur.
  **Do NOT collapse the four `media-core-built-*` checkpoints on this item's
  authority** — the resume granularity it would cost is now worth far more than
  the ~60 s it would save. Keep the entry only as the record of a disproven
  premise.
- **73 [S·★★★, none] SOLVED 2026-08-20 (verify: next media rebuild must show ZERO -Winfinite-recursion) - and the culprit was OUR OWN inline patch: the `_udiv128 -> udiv128` substitution (added for clang-cl's missing MSVC intrinsic; probe-udiv128-recursion proved clang 22.1.8 has no _udiv128) rewrote the call INSIDE cutlass's udiv128 into a self-call. Fix: disable CUTLASS's intrinsic guard for __clang__ instead - the portable 128-bit loop compiles, correct by construction. Upstream candidate (owner): NVIDIA/cutlass's guard `#if _MSC_VER >= 1920 && !defined(__CUDA_ARCH__)` should also carry `&& !defined(__clang__)`. Original finding: latent defect in the SHIPPED ONNX CUDA provider: infinite
  recursion in CUTLASS `udiv128`.** 225 occurrences of
  `uint128.h(96,90): warning: all paths through this function will call itself
  [-Winfinite-recursion]`, reached via `flash_api.h:36` while compiling
  `onnxruntime_providers_cuda` TUs (`attention.cc`, `paged_attention.cc`,
  `packed_multihead_attention.cc`). CUTLASS selects an MSVC `_udiv128`
  intrinsic path that clang-cl does not resolve, so the function calls itself
  unconditionally → stack overflow **if that path is taken at runtime**. It
  sits in the flash-/paged-attention code of a shipped provider. Static
  analysis cannot see this — it exists only in the clang-cl port's compiler
  output. FIX: runtime smoke test of flash-attention, then a clang-cl
  `udiv128` patch alongside the existing `patches/onnxruntime` set.
- **74 [S·★★, none] DONE + VERIFIED 2026-08-20: the batch-verify ride (cold C++ media build, green + smoke 190/0/1) logged ninja -j19 in ALL three formerly -j9 stages (genai, litert, tvm) - the MemGBPerJob=2 change measures out. Original PARTLY DONE 2026-08-15 — the `-j9` half is fixed, the
  measurement is not.** Backlog #28 lowered `MemGBPerJob` to 2 for onnx and
  opencv only, so the 2026-08-15 chain still logged `ninja -j9` three times
  (genai, litert, tvm) against `-j19` three times. Those three are now at 2 as
  well, justified by the ONNX measurement (9274 samples, peak per-process
  WorkingSet 998 MB, same nvcc workload) and by build-iree, which compiles LLVM
  in-tree — the heaviest TUs in the chain — at 2 all along. **UNVERIFIED:** no
  build has run since the change, and the claim that sccache is "provisioned for
  32 jobs" while ninja runs at 9 came from the CLIPPED corpus. Confirm the job
  count and the wall-clock on the next cold media build before closing.

- **75 [S·★★★, none] DONE 2026-08-19 (module edit, next media rebuild): the downgrade is now LOUD - Write-Warning before (naming the cross-run crash signature to watch for) and after (stamping the serial fallback's added minutes on a green finish); the ladder was already bounded to ONE incremental attempt. Original finding: the `-j` downgrade ladder is a SILENT self-heal that
  converts a failure into an hours-long serial rebuild.** One run
  (`bk-chain-20260810-nogpu`) burned **11 h 17 m re-running the same ONNX build
  11 times**, each cycle ending
  `ninja -j9 failed (exit 2) - retrying incrementally with -j2...` at 4911.5 s
  / 4909.2 s — a ±2 s determinism that identifies the sccache-CUDA server crash
  rather than an env flake. 12 occurrences corpus-wide. FIX: make the downgrade
  loud and bounded; abort instead of grinding serially.

  **RE-MEASURED 2026-08-16: zero occurrences across five complete media chains.**
  Still worth fixing — a self-heal that can silently cost 11 h must be loud and
  bounded whether or not it fires today — but it is **latent, not active**, so it
  does not belong ahead of work on live defects. Same status as #76.
- **76 [S·★★, none] DONE 2026-08-20: the make/gawk provisioning region is bounded (10-min ceiling, 60-s heartbeat via Invoke-BoundedProvisionStep) - a recurrence costs minutes and names itself. Original finding: the ~120-min ffmpeg stall (old #35) is CONFIRMED as a
  one-off and DENIED as recurring — and it is a TIMEOUT, not jitter.** Exact
  gap: **7200.9 s** (≈ exactly 2 h) of zero output between
  `WARNING: vswhere returned no installation; using filesystem fallback` and
  `Replaced MSYS2 awk with gawk`. In 10 other runs that marker lands at
  t = 11.5-17.9 s. Actual ffmpeg work in that step was only ~162 s. The
  two-hour boundary reads as a network timeout in the MSYS2/gawk provisioning
  call. Not recurred in 9 subsequent runs → latent, not active. FIX: bound that
  step with an explicit timeout + heartbeat. **Supersedes the old #35 observe
  entry**, which can now be closed.

  **RE-MEASURED 2026-08-16: not recurred in five more complete chains** (longest
  vertex anywhere 3 517 s = onnx, no >2 h gap). 14 clean runs since the one-off.
  Confirms latent-not-active; the timeout+heartbeat is still the right fix and
  is cheap, but it is insurance, not a repair.
- **77 [S·★★, none] STALE 2026-08-17 — the retry has NOT fired since the GStreamer 1.29.2 bump.** Today's full chain compiled GStreamer clean on attempt 1 (0 hits for the retry marker), matching the code comment: in 1.29.2 there is no `_commit` collision and the reactive path is documented DORMANT INSURANCE (the .patch stays git-appliable for a future clang/io.h/gstreamer combination). The "3/3 runs, ~20 min each" evidence predates the bump. No action; re-open only if the marker reappears. Original finding: GStreamer's GES `_commit` conflict is patched REACTIVELY
  after a failed compile — deterministic, 3/3 runs, ~20 min discarded each
  time.** `Compile attempt 1 failed; patching _commit conflict in GES and
  retrying...` at 1236.8 s / 1392.2 s / 1391.3 s in three separate runs. Tight
  clustering + 100 % reproduction = this belongs in `patches/gstreamer`
  applied up-front, not as a post-failure repair.
- **78 [S·★★, none] DONE 2026-08-20: the filesystem fallback prefers the VISUAL_STUDIO_VERSION major (a VS promotion can no longer float in newest-first), warns loudly on a pin miss, and is memoized per process (was x100 warnings). Original finding: the VS major-version pin is NOT being honoured — the
  toolchain is pinned by luck.** Today's base build:
  `WARNING: major-pinned VS alias unavailable — used floating 'stable' channel
  (currently VS 18…)`. Plus `vswhere returned no installation; using filesystem
  fallback` ×100 — so the build depends on a literal path string rather than on
  discovery. The day Microsoft promotes VS 19, the pin floats AND the fallback
  path breaks simultaneously, re-opening the documented vcpkg/VS-toolset
  rejection class.
- **79 [S·★★, none] DONE 2026-08-20: pinned-alias retry budget 2->3 before the loud stable degrade; the Adoptium half already shipped separately (github-first JDK fetch in build-litert-lm-bazel). The MZ-signature guard remains the HTML defence; no bootstrapper preseed (its hash floats within a channel by design). Original finding: `aka.ms` serves HTML instead of the VS bootstrapper binary
  — the same failure family as the known nuget trap.** Today's base build:
  `expected a MZ-signature file but got first bytes 60,33 (likely an HTML error
  page)` — `60,33` is `<!`. Also 3 consecutive failures against
  `api.adoptium.net` for JDK 21. The MZ-signature guard is excellent defence,
  but the retry budget is 2 and it self-heals only because a fallback URL
  exists. The pre-seed fix already applied to nuget was never extended to the
  VS bootstrapper or Adoptium.
- **80 [S·★★, none] DONE 2026-08-20 - the suppression half shipped too (Get-WarningNoiseSuppressionFlags, ONE module-exported list feeding onnx/opencv/tvm/genai/litert-lm; gstreamer=meson deliberately untouched) and rode the green batch-verify ride. Earlier: HALF DONE 2026-08-17 — the observability half shipped: `analyze-warning-stream.ps1` classifies any build log in seconds (verified against today's 34-MB chain: 87,515 warnings, 82.7 % noise, and LIVE signal — 422 ×inconsistent-missing-override, 26 ×undefined-var-template, 14 ×infinite-recursion, 68 ×inconsistent-dllimport). STILL OPEN: suppress the top-5 noise classes at build-script level (files are bind-mounted — land between builds). Original finding: 96 % of the warning stream is 5 noise classes, hiding 1,055
  genuine signals.** Corpus totals: `-Wunused-parameter` 68,502,
  `-Wdocumentation-unknown-command` 18,144, `-Wdeprecated-copy…` 17,887,
  `-Wundef` 17,056, `-Wmissing-field-initializers` 12,294 — vs the signal
  classes `-Winconsistent-missing-override` 9,449 (vtable/ABI),
  `-Wundefined-var-template` 552 (ODR/link), `-Winconsistent-dllimport` 252
  (Windows linkage), `-Winfinite-recursion` 225 (#73), `C4715` 26 (UB — all in
  the vendored `tvm-ffi/.../creator.h(112)`, falling off the end of a
  value-returning function). Also `-Wunused-command-line-argument` 7,200:
  `/Zc:preprocessor` is passed but ignored by clang-cl — a config smell worth
  removing. FIX: suppress the top-5 noise classes at build-script level so CI
  can see the rest.

### P0e — status 2026-08-17 (stub; full narrative in windows-backlog-archive-2026-08-17.md)

- **#94 RESOLVED, DEFAULT ON** — OpenCV links the chain''s FFmpeg (avcodec 63,
  avdevice YES; was prebuilt 61/NO). Four parts, all required: stage swap
  (ffmpeg before opencv), `pkgconfig-shim.cmake` via CMAKE_PROJECT_INCLUDE,
  SKIP_DOWNLOAD + ENABLE_LIBAVDEVICE, and the FFmpeg-9 source patch
  (`ffmpeg9-avcodec-config.ps1` — AVCodec::pix_fmts/supported_framerates were
  removed upstream). Full-chain smoke: 188/1/1. `(prebuilt binaries)` is NOT a
  provenance signal — the avcodec-major comparison is.
- **#95 DONE** — smoke asserts the video backends (runtime-aware since the
  plugin route). Watched failing before the fixes, as designed.
- **#93 IMPLEMENTED, awaiting its first merge build** — standalone
  `opencv_videoio_gstreamer` plugin built in the merge stage AFTER GStreamer
  (`build-opencv-gstreamer-plugin.ps1`); breaks the circularity without a
  second OpenCV pass. `getBuildInformation()` stays `GStreamer: NO` BY DESIGN
  (compile-time string; plugin is runtime) — the smoke guard asserts
  `hasBackend(CAP_GSTREAMER)` + an actual videotestsrc frame read instead.

### P2 — Fail-open gates & silent degradation (green build, crippled image)

- **45 [S·★★★, none] DONE 2026-08-19 (module edit, next media rebuild): Get-GpuEnvironment THROWS on GPU_TYPE=nvidia with no resolvable CUDA root; FORCE_CPU opt-outs short-circuit before the gate (2 unit tests).** Original finding: a mis-plumbed CUDA path yields a fully green, CPU-ONLY
  media chain — discovered hours later. `WindowsSourceBuild.Cuda.psm1:47`
  gates on `Test-Path $cudaRoot`; every consumer then takes a quiet else-branch
  (`build-onnx:307` "CPU-only build", `build-opencv:277` `WITH_CUDA=OFF`,
  `build-tvm:39` silently). `GPU_TYPE=nvidia` is baked at `Dockerfile.nvidia:93`,
  so "lane says nvidia but no CUDA" is never legitimate. Cost: ~75 min ONNX +
  ~30 min OpenCV + ~45 min GenAI all green and all useless. The explicit
  opt-outs (`ONNX_FORCE_CPU`, `GENAI_FORCE_CPU`) already exist, so a `throw`
  is safe. FIX: fail closed when `GpuType -eq 'nvidia' -and -not $CudaRoot`.
- **47 [S·★★, none] DONE + VERIFIED 2026-08-17 — and the gate's first live run
  DISPROVED its own premise:** "the toolchain always bakes LLVM" was false —
  scoop LLVM (official Windows installer) ships NO llvm-config/dev-libs at all,
  so every prior Windows TVM was silently USE_LLVM=OFF. The throw fired on
  verify5 and forced the real fix: the tvm stage now builds its own minimal
  pinned LLVM (see Component Build Matrix row + AGENTS invariants; the /MT dev
  tarball detour and the 4-fix path are in the 2026-08-17 commits). Loud
  cuDNN/Vulkan OFF-paths shipped as planned. Original finding: TVM silently
  drops LLVM / Vulkan / cuDNN.**
  `build-tvm-from-source.ps1:76-82` (and :68-73, :53-64) print on the ON path
  and print NOTHING on the OFF path. `USE_LLVM=OFF` removes TVM's CPU codegen
  entirely: build green, `import tvm` green, and every `tvm.build` for an LLVM
  target fails at runtime in the shipped image. An LLVM/scoop bump that drops
  `llvm-config.exe` off PATH is a plausible one-line regression.
### P2b — Per-component build-script gaps (sibling scripts that drifted apart)

- **65 [S·★★★, none] DONE 2026-08-17 (verify in the next merge build) — GStreamer compiles with NO job budget, NO retry ladder and
  NO sccache stall guard — while using sccache.** Verified: 0 hits for
  `Start-SccacheStallGuard` / `Get-BuildJobCount` / `MemGBPerJob` in
  `build-gstreamer-from-source.ps1`. It sets `$env:CC = 'sccache clang-cl'`
  (:205) then runs `meson compile` (:879) with no `-j`, so ninja's default
  (cores+2) ignores `MEMORY_LIMIT_GB` entirely — exactly the OOM shape
  `MemGBPerJob` exists to prevent. It is also the ONE compile stage using
  sccache without the watchdog written for the documented sccache-server
  deadlock; a wedge there hangs the merge stage indefinitely with no
  kill/resume. FIX: `meson compile -j (Get-BuildJobCount -MemGBPerJob 2)` +
  the stall guard.
- **66 [S·★★★, none] DONE 2026-08-17 via an EARLY presence-only fast-fail (the full gate stays where its outputs are consumed; a missing fan-in now dies in seconds) — original finding: GStreamer's "must resolve NOW" pre-flight runs AFTER the
  tarball, ~20 wrap downloads and five patch loops.** The gate's own comment
  reads "Everything the required set needs must resolve NOW, not after an
  hour" (:676) — but the block starts at :522 while the downloads run at
  :242-:323 and patching at :404-:485, and the things it checks (OpenCV
  headers, `onnxruntime.lib`, LiteRT headers, `tensorflowlite_c.lib`) depend on
  NONE of that work. Hoisting it above :228 turns a missing media fan-in from
  "full download+patch phase, then fail" into a ~5-second failure.
- **68 [M·★★★, none] DONE 2026-08-20: the BtbN fallback is FAIL-CLOSED (throws unless FFMPEG_ALLOW_PREBUILT=1; the opt-in path scrubs the whole prefix first so a MIX is impossible, and the .pc gate skip is loud); the skip-if-present early return runs Assert-FfmpegPkgConfig before trusting an inherited install. Original finding: FFmpeg's prebuilt fallback ships a MIXED install, and the
  skip-if-present early return bypasses every gate on re-entry.** On a missing
  `ffmpeg.exe` it downloads BtbN's zip and copies `*.exe`/`*.dll` over whatever
  a partial `make install` left (:441-459), while OUR import libs and `.pc`
  files stay — so gst-libav links a version mismatch, announced by one
  `Write-Warning`. Separately `:110` returns early when `ffmpeg.exe` exists, so
  a `-ResumeFrom FFmpeg` after such a failure skips `Assert-FfmpegPkgConfig`,
  the import-lib assert and PyAV — the resumed run cannot detect the broken
  install it inherited.
- **88 [S·★★★, none] DONE + VERIFIED 2026-08-17 (fail-closed summary after the
  loop; VERIFIED live in verify15+smoke. NOTE the fetch route changed same-day:
  wraps + libffi go through the script-local `Invoke-WrapDownload` — curl-native
  UA + magic-byte check — NOT the shared `Invoke-DownloadWithRetry`, whose
  browser UA gets Anubis HTML challenge pages from freedesktop/videolan GitLab;
  `.git` is stripped from GitLab archive URLs. The gate's first live run also
  caught graphene entering the build for the first time, see AGENTS invariants)
  — original finding: GStreamer wrap downloads fail SILENTLY and the build ships
  a feature-reduced image — OBSERVED, not theorised.** The 2026-08-14 full chain
  logged **22 failed wrap downloads** in one merge stage:
  `gst-plugins-base` ×15, `theora` ×5, `pango` ×2, each as
  `WARNING: failed to download ... features may be disabled`, and the build went
  green. The fetch is `curl.exe ... 2>nul` (`build-gstreamer-from-source.ps1`
  ~:294 and the libffi fetch at ~:313), so the ONE thing that distinguishes a
  moved wrap revision (404) from a DNS/TLS problem is discarded — and 20 lines
  earlier the main tarball already uses `Invoke-DownloadWithRetry` with backoff
  and non-empty verification. Only the four MANDATORY plugins are gated; every
  other codec silently becomes optional. FIX: route the wrap and libffi fetches
  through the shared helper, and fail (or at least summarise loudly at the end
  of the stage) rather than emitting 22 warnings nobody counts. NOTE this was in
  the 2026-08-14 audit and was dropped when the findings were numbered — the
  numbers came from the audit's list, and this one fell out; re-verify the P2b
  set against the audit before assuming it is complete.
- **69 [S·★★, none] DONE 2026-08-20: W1c AST scanner covers the if($env:KEY){...}else{'<literal>'} idiom (pin membership filters behavior defaults; scanner-rot guard pins 9 sites) and caught 3 LIVE drifts, all fixed: build-ffmpeg NV_CODEC_HEADERS_REF n13.0.19.0->n13.1.15.0 (the documented 404/NVENC-skip seed), build-litert-lm-bazel 0.15.0->0.16.1, assemble-torch-app v0.0.22->v0.0.27. Original finding: live pin drift that the parity gate structurally cannot
  see.** `build-ffmpeg-from-source.ps1:241` hardcodes
  `else { 'n13.0.19.0' }` against `versions.env:184 NV_CODEC_HEADERS_REF=n13.1.15.0`
  — verified drift. `SourceBuild.PinParity.Tests.ps1:80` scans only
  `Get-SourceBuildVersion` call sites, so the `if ($env:X) {…} else {<literal>}`
  idiom is invisible to it (~13 such sites; four more version literals bypass
  the gate the same way). versions.env:180-183 records that a wrong
  nv-codec-headers ref once "404'd and NVENC was silently skipped on both
  lanes" — this is that incident's seed, re-planted. FIX: route the literals
  through `Get-SourceBuildVersion`; teach the AST scanner the second idiom.
- **70 [S·★★, none] DONE 2026-08-20, subsumed by #100: FFmpeg compiles through the make-time sccache launcher (2198/2198, 100.00% on the hit run) and the chain epilogue emits its stats.** Original finding: FFmpeg is the only compile stage with NO sccache wiring at
  all — verified: 0 `Write-SccacheStats` calls, and the script never sets the
  sccache endpoint. The precedent is its sibling, which documents that
  GStreamer "ran completely uncached (~30 min hot)" until 2026-08-04 because
  "the merge builder simply never wired the endpoint through". A 30-60 min
  stage recompiles cold every attempt and is not even MEASURABLE. Emitting the
  stats is unconditionally safe; whether FFmpeg's `configure` tolerates
  `--cc="sccache clang-cl"` needs a configure-only probe first.

### P3 — Cache tiering (pure rebuild-time cost; no correctness change)

- **49 [M·★★★, media-core once] LANDED 2026-08-19, riding the full ride (verify: a later PYAV-only bump must NOT re-run onnx): per-component ARG/ENV blocks in the BK stages, media-core-env is classic-lane-only, TwinParity suite carries the new contract. Original finding: nine version ARGs share ONE ENV layer directly
  above the ~75-min ONNX compile.** `Dockerfile.media-builder:142-168` declares
  ONNX/GENAI/OPENCV/FFMPEG/PYAV/NV_CODEC/CUDA_ARCH/PYTHON in a single
  `media-core-env`, and opencv/ffmpeg/genai chain `FROM` ONNX's output. So a
  **PyAV bump re-runs the full ONNX build** and cascades through the whole
  branch (hours). The 2026-08-07 versions.env-COPY removal fixed this at BRANCH
  granularity and never reached COMPONENT granularity. FIX: move each ARG+ENV
  into the stage that consumes it.
- **50 [M·★★★, base once] DONE 2026-08-18 (riding the #114 base batch): versions.env COPY relocated below scoop/vcpkg/rust; the 9 consumed keys (incl. helper-reads GIT_VERSION/WIX_*/SCOOP_INSTALLER_SHA256 - invisible to a naive $env: grep) ride as ARGs mirrored in both drivers. AFTERMATH FIXED 2026-08-19: the final-stage ARG mirrors sat in the process env during the bake RUN, load-versions' override branch left Machine untouched, and those keys (measured: SCCACHE_GIT_REV, machine=[] in-container) were never baked into post-#50 images - load-versions now persists the winning override to Machine (Dockerfile.load-versions-probe, fail-closed; rides the next base build). Original finding: `versions.env` is COPY'd above scoop + vcpkg + the
  ~30-min rust/sccache-from-source layer.** `Dockerfile.base:87-89`, then
  `:114-120`, then `:156`. versions.env is shared by BOTH lanes, so editing a
  purely *Linux* key (`PANDOC_VERSION`, `ROCM_VERSION`, `UBUNTU_DIGEST`)
  re-pays GB-scale scoop + vcpkg + the 30-min rust layer on the next base
  build. The file already proves it knows the pattern — `setup-vs.ps1` was
  deliberately hoisted above this COPY for exactly this reason (`:71-76`). Only
  8 keys are needed below the COPY; promote those to ARGs and move the COPY
  down. (The sibling ARG-below-the-expensive-RUN fix for TensorRT shipped
  2026-08-14 — same pattern, see the archive addendum.)

  **SCOPED 2026-08-14 — and the audit's "only 8 keys" was wrong.** Enumerating
  what the three RUNs below the COPY actually read (both `$env:X` *and*
  `Resolve-ContainerImageValue -EnvironmentVariable 'X'`, which the first pass
  missed because it uses no `$env:` syntax):
  - `setup-scoop-tools.ps1`: CMAKE_VERSION, FLUTTER_VERSION, GIT_INSTALLER_URL,
    GIT_VERSION, GIT_WINDOWS_INSTALLER_SHA256, LLVM_WINDOWS_VERSION,
    NASM_WINDOWS_VERSION, NINJA_WINDOWS_VERSION, SCOOP_INSTALLER_SHA256,
    VULKAN_VERSION, WIX_UI_EXT_VERSION, WIX_VERSION
  - `setup-vcpkg.ps1`: VCPKG_REF
  - `setup-rust-toolchain.ps1`: SCCACHE_GIT_REV, RUSTUP_DIST_SERVER,
    RUSTUP_IO_THREADS

  Five of those (CMAKE/LLVM/NINJA/NASM/VULKAN) **already have ARGs** and are
  passed as parameters, so the work is ~11 NEW ARG declarations, each
  duplicating a versions.env pin into the most expensive Dockerfile in the repo.

  **TRADE-OFF — decide before doing.** The gain is purely cache cost: editing a
  Linux-only key (PANDOC_VERSION, ROCM_VERSION, UBUNTU_DIGEST) would stop
  re-paying scoop + vcpkg + the ~30-min rust/sccache layer on the next base
  build. The cost is eleven new duplicated pins, i.e. exactly the drift surface
  that #69 still tracks and that `Pins.CanonicalValues.Tests.ps1` was written to
  police (closed #60) — that test covers Dockerfile.media-merge-builder today
  and would have to be extended to Dockerfile.base before landing them. Not obviously
  worth it; that judgement is the owner's, which is why this was NOT landed with
  #81 on 2026-08-14 even though the base was rebuilt anyway.
- **51 [M·★★★, media once] DONE 2026-08-20: no longer image metadata - the driver publishes the effective budget to the webdav (preseed/memory-limit-gb.txt), Get-BuildJobCount reads env -> webdav (memoized) -> CIM; under -ConcurrentAux every branch now gets the halved budget (the old full+halved+halved asymmetry oversubscribed the host). Original finding: `MEMORY_LIMIT_GB` — a scheduling knob — is an image
  ENV and therefore a CACHE KEY** (`Dockerfile.media-builder:29,67`). The
  driver halves it for `-ConcurrentAux` (`build-buildkit.ps1:378`), so merely
  TOGGLING that flag changes the layer digest and invalidates every litert/tvm
  compile. Same on any host with different RAM. `Dockerfile.torch:57-60`
  already states the principle ("Build-time state belongs in the build step,
  not in the artifact"). FIX: derive in-container, or bind-mount it.
- **52 [M·★★, toolchain] LANDED 2026-08-19, riding the full ride: BK 'built' stage bind-mounts script/module/versions.env (sibling versions.env preferred), classic lane gets builder-classic COPY stage (build.ps1 target updated). Original finding: the toolchain builder never got the bind-mount
  treatment.** `Dockerfile.toolchain-builder:38-43` COPYs the shared module +
  versions.env + the build script into the stage whose child RUNs the CPython
  compile — so editing *any* of them (incl. a module ~30 scripts share)
  re-pays the full CPython build, and toolchain is the parent of every media
  branch. `Dockerfile.media-builder:243-259` documents the exact solution.
- **81 [S·★, base] DONE - STALE ENTRY: already fixed 2026-08-14 (the SHELL line sets PSNativeCommandUseErrorActionPreference correctly; the entry outlived its fix). Original finding: The base SHELL sets a variable
  that does not exist.** `Dockerfile.base:58` sets
  `$PSNativeCommandErrorActionPreference = $false`; the real pwsh variable is
  **`PSNativeCommandUseErrorActionPreference`** (verified against pwsh 7.6.4,
  exactly `PWSH_VERSION`: `Get-Variable PSNative*` returns only
  `PSNativeCommandArgumentPassing` and `PSNativeCommandUseErrorActionPreference`).
  The assignment creates an unrelated variable and does nothing — the base
  believes it has a guard it does not have. Harmless *today* only because the
  real variable already defaults to `False`; the day pwsh flips that default
  (its stated direction), every native non-zero exit inside a base RUN starts
  throwing. Note the repo spells it correctly elsewhere
  (`WindowsFormatting.Common.psm1:279`). Also: all six derived Dockerfiles
  re-declare `SHELL` and drop the clause — `SHELL` IS inherited via image
  config, so those are redundant layers against the 125-cap.
- **54 [S·★★, merge] DONE 2026-08-20, PREMISE DISPROVEN + RE-SCOPED TO A TRIM: the merge lineage (merge-fanin FROM toolchain; final <- torch <- media) never carries the nvidia originals, so the flatten is the ONLY copy, not a duplicate. The real win: the closure probe (probe-cuda-runtime-closure) showed 13/36 staged DLLs statically imported; the stage now trims the closure-verified-unreferenced, non-dynamic-load families (cusparse/cusolver/cusolvermg/nvjpeg/npps, ~436 MB) and KEEPS all cudnn_* + the nvrtc JIT chain (dlopened at runtime; unverifiable on this GPU-less host). Next merge build. Original finding: `cuda-runtime-stage` ships a SECOND, flattened copy of the
  CUDA + cuDNN runtime DLLs** (`Dockerfile.media-merge-builder:138`); cuDNN's
  set alone is 0.52 GB uncompressed, plus CUDA 13's cublas/cufft/cusolver/nvrtc.
  The originals are still in the image (merge descends from the nvidia stage)
  and `Dockerfile.nvidia:97` already PATHs them. One extra PATH entry for
  cuDNN's nested layout likely replaces the whole stage. NOTE: verify the
  actual cuDNN 9 nesting against the installed tree before removing the stage —
  the flatten fix was load-bearing for OpenCV's `cudnn64_9.dll`.
- **100 [M·★★★, media-core] SOLVED 2026-08-20 after 5 probe rounds - make-time launcher ON, 2198/2198 compile requests through sccache (was 0 forever):** the crash trigger was `-options:strict` - cl.exe-only; clang-cl parses the PREFIX as the deprecated `-o` (output). Bare builds survived by ORDER (the later -Fo wins); sccache's generate_compile_commands REORDERS (-Fo first), the hijack wins, and the object lands in an NTFS ALTERNATE DATA STREAM (`ptions:strict.obj`, literally recovered by probe-sccache-options-strict.ps1) at exit 0 -> 'failed to zip up compiler outputs'. Chain fix: the flag is stripped in Remove-MakefileShowIncludes (a bare-build correctness fix too - the silent -o hijack was always there, just overridden). configure stays bare (its own tests still break through sccache). UPSTREAM angles (owner decides, possible PR 3): (a) sccache's -Fo-first reorder is a semantic hazard for ANY unknown flag whose prefix parses as -o; fix = emit the output flag AFTER the forwarded args; (b) sccache never logs the spawned compile line even at trace. Hit-run VERIFIED 2026-08-20: 2198/2198 hits, 100.00%, 0 misses. PyAV remains the open lower-value half. Previous state: (1) configure --cc='sccache clang-cl': configure's own compiler tests produce objects lld-link rejects ("unknown file type"); (2) make-time CC override: dies ~20 files in with sccache "failed to zip up compiler outputs" on the RELATIVE forward-slash -Fo outputs (libavdevice/dshow*.o resolved to C:	emp\...\libavdevice/dshow_pin.o, file absent) - and the bare `make install` then silently recompiled everything launcher-less (15 min), so both "green" rides were uncached anyway. Next angle: sccache-side (does it mishandle relative -Fo through a server whose cwd differs? possibly upstream PR 3 material - owner decides); PyAV unchanged. Original finding: FFmpeg and PyAV compile with sccache COMPLETELY
  BYPASSED — the whole ffmpeg branch is uncached, every build, forever.**
  Measured 2026-08-15 in the #99 verification run: the `media-core-built-ffmpeg`
  stage reported `Compile requests 0` — not "0 hits", *zero requests*. sccache
  never saw a single compile.

  CAUSE: sccache is wired **only** through CMake, in
  `WindowsBuild.Common.psm1:642-643` (`CMAKE_C_COMPILER_LAUNCHER` /
  `CMAKE_CXX_COMPILER_LAUNCHER`). FFmpeg does not use CMake — it configures with
  `--toolchain=msvc --cc=clang-cl --ld=lld-link`
  (`build-ffmpeg-from-source.ps1:317`), so every one of its C files goes
  straight to `clang-cl`. PyAV is the same story from the other direction: it
  builds through setuptools, which invokes MSVC `cl.exe` directly (visible in
  the same log right before `Staged wheel: av-18.0.0-…`).

  WHY IT WENT UNNOTICED: the chain's aggregate hit rate looks excellent
  (onnx 1498/1498, opencv 1861/1862) precisely BECAUSE the uncached components
  contribute no requests to the denominator. A component that bypasses sccache
  entirely is invisible in a hit-rate metric — it can only be seen by reading
  `Compile requests` per stage. Cf. the AGENTS.md "aggregate evidence" rule.

  FIX TO TRY: pass the launcher into FFmpeg's own configure —
  `--cc="sccache clang-cl"` (FFmpeg's configure tolerates a launcher prefix in
  `--cc`; verify `ffbuild/config.mak` afterwards, and that `--ld` stays bare).
  For PyAV, setuptools honours `CC`/`CXX` only on non-MSVC; the realistic lever
  is a compiler shim on PATH, so treat PyAV as a separate, lower-value item.
  VERIFY BY: `Compile requests` > 0 for the ffmpeg stage — that number, not the
  hit rate, is the acceptance criterion. Do NOT accept a rerun with a warm
  cache as evidence: a stage with 0 misses writes nothing and proves nothing
  (that trap cost two stages' worth of "0 write errors" in this very run).

### P4 — Missing regression tests (each maps to a bug that already cost hours)

- **59 [S·★★, none] CLOSED 2026-08-17 — owner decision: no branch protection wanted. Lint/tests are advisory, not gating.** `main` is not
  branch-protected (`gh api …/protection` → 404); `windows-scripts.yml:50` runs
  the linter WITHOUT `-FailOnAnalyzer`; `.githooks/pre-commit` runs the Linux
  preflight but neither `Invoke-Lint.ps1` nor `Invoke-Tests.ps1`. The gate is
  currently human discipline plus a post-hoc notification.
### P5 — Observability (makes everything above measurable)

- **61 [M·★★★, none] DONE 2026-08-17 (first manifest lands with the next driver run) — stage logs now carry a per-run id (bk-<runid>-<label>.log; the Keep-80 rotation finally has something to rotate), each stage prints its duration, and a machine-readable per-stage manifest is written at the end. Original finding: No per-stage timing, no run manifest, and stage logs are
  OVERWRITTEN every run.** `build-buildkit.ps1:284` names logs by label only —
  no run id, no timestamp — so run N truncates run N-1, and `Limit-DiagnosticLogs
  -Keep 80` never fires because there are only ~10 distinct names. On failure
  the BK lane prints no elapsed time at all (the total is past the throw; the
  `finally` only pops the location). The Linux orchestrator already emits
  `chain-status.json` per stage — Windows has no equivalent, so run-over-run
  comparison is done by hand in CHANGELOG prose. FIX: stamp logs with a run id;
  emit `run-<id>.json` (stage, tag, attempts, seconds, exit, disk before/after);
  print the table at the end AND in a `finally` on failure.
### P6 — 2026-08-17 static audit, OPEN remainder (done items #101/#102/#103/#105 + methodology: archive)

- **104 [S·★, none] DONE 2026-08-17 — with a finding: the corpse was ALREADY GONE.** `clean-sccache-mount.ps1` (+ `Dockerfile.cache-mount-clean`, via the shared probe runner, network-free) found the mount root holding only KB-scale bucket remnants — **no v2, no v3, no v4** — and freed just 0.1 MiB. v4 (~63 MiB, experiment B) verifiably existed yesterday; something reclaimed the mount contents during today's build churn, most plausibly buildkitd GC treating the exec.cachemount as reclaimable under the shared tier-0 budget. RELEVANT LATER: when the disk,webdav tier returns (#99 restore), do not assume cache-mount contents survive GC pressure between runs. Fixtures probe-persist/bulk-inherit kept (the #99 repro). Original finding: The sccache cache mount carries dead weight that no build will ever read again.** The damaged original root tree (buckets `0..f`,
  ~114 MiB — the #99 corpse), the empty `v3`, experiment B''s `v4` (~63 MiB),
  and the probe fixtures `probe-persist`/`bulk-inherit` (keep those until the
  BuildKit upstream report is filed). Only `v2` is referenced. One probe-style
  cleanup RUN reclaims ~200 MiB of the shared 40 GB tier-0 budget. Builder
  disk, not image size. BLOCKED while any build holds the locked mount.
- **106 [S·★, none] DONE 2026-08-20 - STALE REMAINDER: the '~52 undeclared files' were already normalized by 09f97bab (repo-wide sweep); today's audit finds exactly ONE file without `#requires -Version 7.0` - bootstrap-pwsh.ps1, the DELIBERATE 5.1 exception whose test asserts it must NOT declare 7.0. Entry outlived its fix (same class as #81). Earlier: PARTLY DONE — the 5.1 parse gate shipped and immediately
  corrected the entry''s own premise** (only `bootstrap-pwsh.ps1` runs under
  WPS 5.1; setup-vs/setup-scoop declare 7.0 and run after the SHELL switch).
  STILL OPEN: add `#requires -Version 7.0` to the ~52 undeclared files — many
  are bind-mounted into media stages, land between builds.
- **114 [M·★★★, BASE-TIER] DONE 2026-08-18 EVENING: shipped with the base batch ride (3h30, smoke 190/1/0), three-canary bar PASSED (cold: link green + 153 CUDA device writes; hit: link green at 100.00% CUDA/PTX/CUBIN hit rate, 207/816 hits), SCCACHE_CUDA_LAUNCHER default flipped ON. Original: Ship the sccache nvcc quote-protection fix.**
  2026-08-18: the dropped-instantiation miscompile is ROOT-CAUSED and the fix
  VERIFIED on the reproducer (patch-verify probe: bare 3189 == wrapped 3189
  symbols). Cause: nvcc.rs flattens `\` before tokenizing dryrun lines, `\"`
  escapes collapse, shlex packs ~30 -D pairs into one 493-char token, the
  cpp4 preprocess loses `USE_CUDA` & friends, cudafe++ emits no stubs. The
  package (patch + README + verify probe) lives in
  `windows/upstream/sccache-nvcc-quote-fix/`. Shipping = editing
  `setup-rust-toolchain.ps1` (clone+apply+install instead of `cargo install
  --git`) = BASE rebuild — rides the next base-tier batch, never alone.
  After shipping: three canaries + a cache-hit second run, THEN the
  SCCACHE_CUDA_LAUNCHER default discussion reopens (~50 min/chain at stake).
  Upstream PR mozilla/sccache#2811 MERGED 2026-08-19 (ffac4a5, sylvestre);
  SCCACHE_GIT_REV bumped to the merge commit, patches 0001/0002 deleted —
  the series now carries only 0003 (#115 diag-suppress; local until its own
  PR lands). Owner: post the #2808 addendum comment referencing it.
- **116 [S·★★, none] DONE 2026-08-19 (module edit — takes effect with the
  next media rebuild, cache closure): Invoke-GitClone retries transient
  failures** (3 attempts, backoff doubling capped at 30 s, mount-safe
  partial-tree wipe between attempts; throw/SkipOnFailure only after the
  last). 4 unit tests (fake git.bat, NinjaRetry pattern). Original finding:
  one TCP drop (`curl 18 transfer closed` at 610 s of the LiteRT clone)
  killed a 4-hour ride; the driver correctly does not infra-retry script
  failures, so the chain stopped and the relaunch cost the full stage queue.
- **115 [S·★★★, none] DONE 2026-08-19 EVENING - OPENCV_CUDA_LAUNCHER default ON: cold run wrote every CUDA category (155 cudafe++/nvcc, 620 cicc/ptxas, link green), the no-cache hit run came back 100.00% on all four CUDA categories (99.97% overall) and cut the opencv stage ~13->~4.3 min. Upstream PR 2 submitted by the owner (fix/nvcc-diag-suppress-separated). Original: OpenCV
  CUDA was never an rsp/length problem** (both earlier theories were probe
  artifacts: an undefined `$obj` interleaved 'replay1.obj' between every
  character and manufactured a phantom 24k command). The real command is
  ~2,040 chars, inline, no rsp. sccache rejects it as
  `CannotCache(multiple input files)` because **`--diag-suppress 1394,1388`
  (separated) is missing from the nvcc ARGS table** - the value parses as a
  bare token = phantom second input. Measured: separated form uncached,
  attached form cached; all 155 OpenCV .cu compiles carry the flag. Fix =
  patch 0003 in windows/upstream/sccache-nvcc-quote-fix (diag-error/
  suppress/warn, both dash forms, + regression test); ships with the next
  base ride, upstream PR 2 draft in the package (OWNER submits - no direct
  PR interaction per 2026-08-19 directive). The OPENCV_CUDA_NO_RSP knob is
  moot and stays only as a documented dead end. AFTER the ship: the
  OPENCV_CUDA_LAUNCHER=1 experiment repeats and should finally show CUDA
  cache categories.
- **112 [S·★, none] DONE 2026-08-19 (verify in the next media rebuild):
  the chain-side probe read back empty because ffmpeg.exe died 0xC0000135
  STATUS_DLL_NOT_FOUND** — `--enable-libonnxruntime` links avfilter-12.dll
  against the chain's onnxruntime.dll (lib\onnxruntime-source\bin), which the
  bin-dir-on-PATH fix never covered. Measured in-image via
  the ffmpeg-provenance probe, now scripts/diagnostics/archive/probe-ffmpeg-provenance.ps1 (symptom → dumpbin walker names the DLL
  → fixed-gate replay exit 0 / avcodec 63). Gate now adds the discovered
  onnxruntime.dll dir to the probe PATH and prints the exit code hex on a
  parse miss instead of a silent chain=''. Original finding: verify5
  (2026-08-17) logged `could not compare avcodec majors (chain=''
  configure='63')`. Not release-gating: the
  authoritative #94/#95 assertion runs in `smoke-test-container.ps1` against
  the shipped image. But the stage gate exists to fail 25 minutes earlier than
  the smoke does; today it can only ever throw when BOTH majors read back,
  so the empty-read path silently waives exactly the case it was built for.
  Fix: make the empty chain-read loud (assert the probe path exists + version
  output non-empty when `OPENCV_LINK_CHAIN_FFMPEG=1`), and print WHY it was
  empty (path missing vs exit code vs regex miss).
- **107 [M·★★, none] DONE 2026-08-19 (module edit — takes effect with the
  next media rebuild): `Start-/Complete-SccacheServerSession` extracted** with
  a `-SccachePath` test seam + 6 unit tests pinning the truncation and the
  failures-first dump (each had cost a false alarm); war-story comments moved
  with the code, chain functions back to readable size, suite 511/511.
  Original finding: the chain functions carried 134/158 lines of inline
  sccache choreography accreted through #97–#99.

### P7 — PERFECTION CAMPAIGN (owner mandate 2026-08-17: "drastische Maßnahmen erlaubt")

> Sequenced by the verification chain — every tranche lands with the build that
> proves it, never blind. Tranche 1 (uniform `#requires`, zero build cost)
> landed 2026-08-17.

- **108 [M·★★, none] DONE 2026-08-20: directory convention LANDED + verified
  by its own full ride (bk-20260820-152656, 3h14, smoke 190/0/1). 74 scripts
  moved (build=26, host=25, diagnostics=23); container mount TARGETS stayed
  FLAT (C:\bkmnt, C:\temp\scripts) — only host-side sources grouped; the 38
  moved scripts with shared-asset refs carry the `$scriptAssetRoot` resolver
  (modules/ beside = flat, else one level up). Ride needed 3 path follow-ups
  before green: .dockerignore `**/build/` needed a `!windows/scripts/build/`
  negation, Dockerfile.nvidia bare-context refs, and container run paths that
  were wrongly grouped (flattened back). Original: directory convention for
  `windows/scripts/` (60 flat scripts).** **EXECUTION SPEC (2026-08-20, measured surface: 66 Dockerfile
  mount/COPY refs, 26 test files with path assumptions, 57 docs refs, 11
  scripts with $PSScriptRoot-relative imports, 3 driver refs, plus
  downstream-vendored module refs):** (1) mapping: build-* and the *-all
  wrappers -> scripts/build/, setup-*/apply-*/repair-*/bootstrap-* ->
  scripts/host/, probe-*/analyze-* + top-level diagnostics/ ->
  scripts/diagnostics/; modules/tests/patches/shims stay. (2) THE
  dual-layout trap: after the move, $PSScriptRoot-relative modules/patches
  refs cannot serve host (scripts/build/) AND container (flat C:/bkmnt)
  with one string - the bind-mount TARGETS must mirror the new layout
  (C:/bkmnt/build/<script> + C:/bkmnt/modules), which cascades through
  every -ScriptDir contract in the chain wrappers. (3) land as ONE commit,
  ONLY on a green chain, verified by ITS OWN full ride + smoke.
  Prerequisite not met at spec time (the 2026-08-20 batch-verify ride was
  still running); execute as a fresh dedicated session, never at the tail
  of a change-heavy day. Target: `scripts/build/` (chain components), `scripts/host/`
  (setup/repair/elevated tools), `scripts/diagnostics/` (probes + analyzers,
  merging the half-empty top-level `diagnostics/`), `modules/` and `tests/`
  stay. COSTS: every bind-mount path in the Dockerfiles, the docs script
  table, and downstream repos'' vendored references (CONSUMED-BY modules stay
  put). Land in ONE sweep with a full-chain verify — path moves are the most
  cache-hostile edit there is.
- **109 [L·★★★, staged] CORE LANDED 2026-08-20: Start-/Complete-BuildPhase + summary machinery in the module (scope-transparent try/catch brackets, 4 unit tests); build-gstreamer bracketed into 10 named phases (its numbered sections, duplicate '6' renumbered); build-litert-lm's 8 #region markers made live (catch stamps the failing phase before the chain wrapper). smoke-test-container needs NOTHING - its 23 Write-TestHeader sections + per-assertion counters already satisfy the goal. OPTIONAL remainder: bracket onnx/opencv (mid-size, already chain-labeled - low value). Verify: next merge/media builds print the phase tables. Original: phase-split the monolith build scripts.**
  **TRANCHE PLAN (2026-08-20, execute one tranche per planned rebuild window,
  never standalone - script edits bust the bind-mount cache keys):**
  T1 build-gstreamer (largest, most phases; carry #110's logging sweep for
  the files touched); T2 build-onnx + build-opencv; T3 the litert/tvm pair;
  T4 the setup-* family + #108's directory convention in the same window
  (one big COPY/mount path sweep, all Dockerfiles + drivers + tests in ONE
  commit, verified by a full ride). #110 rides each tranche (its own entry
  says so); #108 lands WITH T4, never alone.
  `build-gstreamer` (991 lines), `build-litert-lm` (1207),
  `smoke-test-container` (1419) each mix download/patch/configure/compile/
  verify in one file. Target: phase functions in the script (not new files —
  bind-mount closures stay stable), each with its own gate, so a failure names
  its phase and a reader navigates by structure instead of scrolling. Do ONE
  script per tranche, verify with its own build; gstreamer first (its three
  fresh gates from #65/#66/#88 already mark the seams).
- **110 [S·★★, none] CLOSED 2026-08-20 with a DECISION instead of a sweep: chain build scripts use Write-Host (stage labels + the #109 phase tables carry the structure), build-gstreamer keeps its STRUCTURED `log` (richest idiom - file+console via New-StructuredLogContext; converting it would lose the file log), Write-BuildLog stays host-driver territory. A mass sweep would bust every bind-mount cache key for cosmetics - enforcement is review + this note. Original finding: `log` vs `Write-Host` vs `Write-BuildLog` across sibling scripts.
> **DECLINED by owner 2026-08-17:** branch protection (#59) and a scheduled
> nightly/weekly chain run (would-be #111). Manual launches remain the
> verification cadence — do not re-propose either.

### P8 — 2026-08-21 REFACTOR AUDIT: FULLY LIQUIDATED same day
### (four-agent deep audit → 7 bugs fixed + guards/dedups/driver-convergence
### in c7d24907..48a87c15, the residue below in f1883cd9..891394c4; every
### entry stamped DONE or CLOSED-with-reason.)
###
### >>> THE ONE OPEN ITEM: the P8 batch (13 commits total, suite 523→536) is
### >>> test-verified but NOT yet ride-verified. The post-store-reset rebuild
### >>> ride is the verification gate — its risk surfaces: classic-lane smoke
### >>> gate (docker-run form), ffmpeg/onnx trap-phase tables, litert-lm 5a-5e,
### >>> Dockerfile.probe consolidation, chain Invoke-stage shape (litert-all),
### >>> Find-TensorRtZipIn newest-by-version, cpython props COPY, the 7 SHELL
### >>> guard lines, merge sccache ARG parity. A green ride + smoke closes P8
### >>> for good; a red one starts at these touchpoints.

- **120 DONE 2026-08-21 (7 assert sites converted; the 3 $isAdmin FLAG sites are mode logic, untouched by design). Original: Assert-Elevated adoption, remaining ~9 host sites.** The
  function exists in Shared (2 adopters). The rest need a Shared import ADDED
  to elevated tools — decide per script; NEVER for the module-free repair
  pair (reset-container-locks, repair-windows-componentstore — documented in
  the function help).
- **121 DONE 2026-08-21 (HasCuda on the env table, 8 scripts converted). Original: Get-GpuEnvironment: add HasCuda, collapse the 6 divergent
  "is this the CUDA lane?" predicates.** Since the #45 fail-closed fix,
  `GpuType -eq 'nvidia'` already guarantees CudaRoot; 5 sites carry dead
  defensive Test-Paths (build-iree's terse form is the correct one).
- **122 DONE 2026-08-21 (5a-5e at the audit seams; ffmpeg 6 phases + onnx 6 phases via script-level trap). Original: litert-lm Phase 5 split (716 lines, 54% of the file) into
  5a-5e at the audit's seams; ffmpeg/onnx get phase brackets (#109 T2).**
  Bind-mount cache keys — land inside a planned rebuild window.
- **123 CLOSED 2026-08-21 as WONTFIX per Source Patch Policy #7: the 19 calls live exclusively in the FROZEN CMake fallback (primary path is Bazel, zero patches); several transforms are env-pin-parameterized and cannot be static diffs. Original: the 19 litert-lm Edit-SourceFile CMake patches → real
  .patch files** (pinned upstream 0.16.1; patches/litert-lm/ precedent
  exists). High-touch: per-patch verification ride required.
- **124 DONE 2026-08-21 (Initialize-SmokeScratch scrub-then-create at all 10 sites kills the dirty-reuse hazard; the ComponentRoot half closed by finding — env-pointer-first + the asserted ENV contract already unify the paths). Original:** Use-SmokeScratch (10 sites, 3
  leak on throw), Test-ComponentRoot (5 sites — including the absolute-path
  vs Join-Path -InstallDir mismatch for litert/litert-lm), and
  Get-ComponentInstallRoot as the single owner of the lib\<component> layout
  table (16 scattered literals).
- **125 CLOSED 2026-08-21 as deliberate DROP: only 4/7 sites contiguous, and the per-line variance (-InstallConfig, missing -Install, #43/#74/#3 rationale comments) is information a wrapper would bury. Original: Invoke-CmakeSourceBuild (configure/build/stats trio).** Only 4
  of the audit's 7 sites are actually contiguous (ninja patching sits between
  configure and build in onnx/opencv/genai) — extract for tvm×2/litert/iree
  or drop deliberately.
- **126 DONE 2026-08-21 (Get-RepoRoot in the harness + versions.env readers converted; Get-Pin wraps ConvertFrom-VersionsEnv; ONE Get-PinScanAst owns enumeration/parse for W1/W1b/W1c — matchers stay separate by design; Invoke-Thing was a false positive, both defs are here-string fixtures). Original:** collapse PinParity's 3 parallel scanner
  families (~200 lines); Get-RepoRoot in TestHarness (9 spellings of the
  repo-root walk, $PSCommandPath vs $PSScriptRoot under dot-sourcing);
  Pins.CanonicalValues' hand-rolled Get-Pin → ConvertFrom-VersionsEnv; the
  two same-name Invoke-Thing test helpers (shared-session collision).
- **127 DONE 2026-08-21 (provenance+llvm-config probes extracted to archive/ scripts, Dockerfiles deleted; props file checked in + COPY; TRT zip finder newest-by-version in setup-tensorrt; LTSC inline default dropped; ONNX_GPU_VARIANT removed, 3 path ENVs joined the smoke pointer contract; B6+B4 parity tests added). Original:** extract ffmpeg-provenance's 22-line
  inline dumpbin walker + llvm-config's inline body to diagnostics scripts
  (both files carry quoting-trap scar tissue); check in the CPython
  Directory.Build.props as a real file (toolchain-builder:36's 300-char
  Set-Content); nvidia's TRT-zip-discovery regex → setup-tensorrt.ps1
  (-LocalZipDir) so the filename contract is unit-testable; WINDOWS_LTSC
  drop the redundant inline default; the 4 reader-less merge ENVs
  (ONNX_GPU_VARIANT/LITERT_LM_INCLUDE/LITERT_LM_LIB/FFMPEG_ROOT) — add to
  smoke's $envPointerNames or delete; classic-COPY vs BK-mount script-set
  parity test (B6) + buildmods 5-module-core parity test (B4).
- **128 DONE 2026-08-21 (chain stages accept an Invoke scriptblock, build-litert-all collapsed to one chain call; gstreamer got the sccache session pair; litert-lm-bazel needs none — no sccache in the bazel lane). Original:** build-litert-all's 26-line partition dup →
  extend the $Stages entry shape; route gstreamer + litert-lm-bazel through
  Start-/Complete-SccacheServerSession (they run outside the chain and never
  get a fresh server/error-log dump).
- **129 DONE 2026-08-21 (LLVM_WINDOWS_SRC_SHA256 key in versions.env; the litert-lm SHAs carry an explicit patch-anchor exemption note). Original:** tvm's LLVM SHA256 table and
  litert-lm's two baked 40-char git SHAs (:363) + stale absl anchor (:349) —
  give them keys or a documented exemption.
- **130 DONE 2026-08-21 with a SMALLER footprint than audited: on close reading most of the 345 comment lines are knob-side operating rules or live recovery pointers, not archaeology — relocated/trimmed the #99 measurement narrative (docs pointer) and rewrote the stale-then-corrected media-core-env header; smoke-gate/base headers judged operative. Original: media-builder comment archaeology (~250 of 345 comment lines)
  → docs/ under stable anchors, 2-4 line summaries + links stay.** Same for
  smoke-gate/base headers. Relocation, NOT deletion — owner-reviewed.
- **131 CLOSED 2026-08-21 by DECISION (see commit c92c5283): all three root files stay (cargo-retry is the consumer-CI class the 2026-08-08 sweep incident restored), language-lane dirs stay. Original:** Invoke-Lint.ps1/entrypoint.cmd homes;
  `cargo-retry.cmd` referenced ONLY by AGENTS.md — confirm dead or re-wire;
  certificates/ python/ rust/ are language-lane groupings that cut across the
  verb scheme — decide, don't drift.

---

## Addendum (same day, later): audit ROUND 2

Second deep audit (4 agents incl. an adversarial review of the refactor
batch itself) — 2 build-breakers + 4 wrong-results caught BEFORE the verify
ride (commits 72d92fb1, e680fb4b), outer-ring/setup/module-tail fixes, and
the P9 residue below, liquidated the same day (f5f6de07) with consumer
contracts VERIFIED against the local repos. Suite 523 -> 547 over the day.

### P9 — 2026-08-21 audit ROUND 2 residue (deferred with reasons; the fixes
### themselves landed same day in 72d92fb1 + e680fb4b, suite 523->537)

- **140 DONE 2026-08-21: ZERO callers verified across ALL local consumer repos (BeschleunigerBallett/Inference-Engine/Orchestr-ANT-ion/RustProjectTemplate/WebDavClient/jotrockenmitlocken + the reusable workflows) — the comment was wrong, the code was unowned. Comment now states the truth (ContainerHub checkout root) + explicit -RepoRoot override for vendored consumers. Original: [M·decision] `Initialize-CiEnvironment.ps1` repo-root depth vs its own
  comment.** `..\..\..` from scripts/python resolves to the ContainerHub
  checkout root, the comment claims "the parent of the ContainerHub checkout".
  All 8 python/rust lane drivers have ZERO in-repo callers — the real contract
  lives in the consumer repos. Verify against a consumer checkout, then fix
  either the comment or the depth. Highest-value unknown of the outer ring.
- **141 DONE 2026-08-21: New-CiSession (+ canonical Write-CiLog/-Warning/-Error/-Success + Close-CiLog + uv-delegate wiring) in Initialize-CiEnvironment; all four drivers converted, CiTests's divergent wrapper names renamed. Original: [S·★] the four `Invoke-Ci*.ps1` share a 30-line context/log/uv
  preamble that has already drifted once** (CiTests adds Write-LogError/
  Success the others lack) — `New-CiSession` in Initialize-CiEnvironment.
  Consumer-facing lane: change alongside a consumer-repo check.
- **142 DONE 2026-08-21: Export-ModuleMember matching the .psd1 added to the .psm1 itself — encapsulation now holds on the direct-psm1 import path every consumer actually uses (BeschleunigerBallett verified); Invoke-LoggedAgenticCommand is private again. Manifest stays for manifest-path importers. Original: [S·decision] WindowsAgenticLoop.Common.psd1 is an inert manifest**
  (every consumer imports the .psm1 directly; the export whitelist and the
  PowerShellVersion gate are not in effect). Either wire consumers to the
  manifest or delete it — consumer-repo check required first.
- **143 CLOSED 2026-08-21 — the module is ALIVE: RustProjectTemplate's container scripts (Invoke-StevedoreBuild, rust-build/test-all) import it, vendored into BeschleunigerBallett + Inference-Engine. Added to the AGENTS.md never-delete consumer-API list, where it had been missing. Original: [S·decision] `WindowsContainerLog.Common` (97 LOC, 3 exports) has
  ZERO references anywhere in-repo AND is not on the AGENTS.md consumer-API
  list.** The only true dead-module candidate — but four restore incidents
  say: grep the consumer repos before deleting anything.
- **144 DONE 2026-08-21 (4 of 6): new Modules.Orchestrators suite — Invoke-WasmOpt (3 cases incl. the --all-features retry ladder), Get-ReusableBuildContainer (create/reuse/wcifs-survivor-fallback, via a FUNCTION fake — a .bat fake loses the | in the inspect format string to cmd), Slang + Vulkan fail-fast contracts. CodeQL (needs a real PE at a fixed path) and CmakeConfigureAndBuild (needs a full Build.Common session) are documented gaps in the suite header. Original: [M·★] untested-orchestrator pattern:** in six library modules the
  ENTRY POINT is a dead export while only leaf helpers have tests
  (Invoke-VulkanValidationRun, Invoke-WasmOpt, Invoke-SlangShaderCompile,
  Invoke-CmakeConfigureAndBuild, Invoke-BuildCodeQL,
  Get-ReusableBuildContainer) — the composed path is untested and unused
  in-repo. Consumer-facing: add orchestrator tests, don't prune.
- **145 CLOSED 2026-08-21 by DOCUMENTATION: the warn-not-throw is load-bearing — the MSIX is signed either way, only the local trust-store import for signtool verify needs elevation, and consumer dev loops run unelevated. Now stated at the site, so it is no longer the undocumented Slang-class silent skip. Original: [S·★] `WindowsMsix.Signing`: missing-elevation degrades to a warning
  with no documented reason** — the exact "silent skip" shape Slang.Common
  documents as a past CI-green-with-no-output incident. Decide: throw, or
  document why warning is right. Also its exported Test-Administrator
  duplicates Shared's expression (consumer API — coordinate before touching).
- **146 DONE 2026-08-21: setup-scoop-tools got 5 #regions, setup-rust-toolchain 3 (sccache-from-source named as the split candidate in its region title) + the manifest accepted-risk note inline. Original: [S·note] setup-rust-toolchain: manifest authenticity is self-asserted
  after the local-mirror rewrite** (per-component hashes survive; accepted
  risk) and its ~70-line sccache-from-source block is a split candidate;
  setup-scoop-tools' ~180 top-level lines want #region structure. Both ride
  a future base-tier window, never alone.

