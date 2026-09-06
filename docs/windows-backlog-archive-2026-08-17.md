# Windows backlog archive — 2026-08-17

Verbatim narratives moved out of `docs/windows-builds.md` on 2026-08-17 to
restore the lean-OPEN-only backlog (owner policy). Numbers stay canonical:
a reference like "#99" resolves HERE when the live backlog only carries a
stub. Nothing in this file is open work.

---

## Execution batches as they stood (A–H; A–D and G were DONE)

### HOW TO WORK THIS BACKLOG (execution batches — read this first)

> The P-sections below are ordered by SEVERITY, which is how to *read* the
> backlog. This section is how to *execute* it: grouped by what shares a
> rebuild, a file, or a decision. **The numbers are discovery order, not work
> order — never work top-to-bottom by number.** Batches A-C are independent of
> each other; D-H can follow in any order.
>
> **Batch A — DONE 2026-08-14. It closed #71, and its "sccache is healthy"
> reading was WRONG — see #99.** sccache was believed dead (0 hits / 189,861
> failed writes across 94 stat blocks). A probe against the real cache mount and
> the real WebDAV endpoint showed **miss → store → HIT, 0 write errors**, and
> the corpus really was stale (newest stats 2026-08-13 19:43, same day as the
> dufs SYSTEM-service migration, no run since had exercised sccache). Both true,
> and the conclusion drawn from them still did not hold: that probe wrote ONE
> object into a directory it had just created, which is the one shape the defect
> cannot appear in. The writes were failing all along, and stayed failing for
> another two days. **This batch is the origin of the "a probe that cannot
> reproduce the bug cannot clear it" invariant in AGENTS.md.** See the archive
> addendum. **Standing caution: the whole P0b section rests on that
> same clipped, pre-fix corpus.** Re-run the forensics against the first
> fully-captured media chain before acting on #72's export numbers or #74's
> `-j19` — treat those as hypotheses, not measurements.
>
> **CAUTION DISCHARGED 2026-08-16 for #72/#75/#76** — re-measured across five
> complete chains (`bk-run-{webdavonly,reuse,chain-disk,legacy-disk,forcelocal}`):
> export is ~1.2 % of a chain (not 23 %), zero `-j` downgrades, zero >2 h stalls.
> #72's premise is dead; #75/#76 are latent, not active. The remaining P0b items
> (#73, #74, #77–#80) have NOT been re-checked and still carry the caution.
>
> **Batch B — DONE 2026-08-14.** (#39, #40, #41, #42, #43, #62, #63, #64 —
> landed, lint 152/0, tests 484/484, entries moved to the archive addendum.)
> The pattern is worth reusing: eight fixes in one sitting because none of them
> touched a Dockerfile, so nothing invalidated any cache and the whole batch was
> verifiable without a single container build. **Group future work this way.**
>
> **Batch C — DONE 2026-08-14** (the TensorRT chain, #53 then #38 — see the
> archive addendum). **UNVERIFIED BY A BUILD:** the logic was proven against
> synthetic trees on the host (normalize + two fail-closed cases + the zip-less
> graceful case), but the Dockerfile itself has not been rebuilt. The next sdk
> build re-pays CUDA + cuDNN once regardless, because #53 reordered the
> instructions above that RUN.
>
> **Batch D — DONE 2026-08-14** (#44, #46, #57, #67). The gate now runs as a
> buildctl solve after `final` and FAILS the chain. It paid for itself
> immediately: pointed at the existing image it returned **176 passed, 8
> FAILED** — see P0c. Treating the four as one piece was right; they all landed
> in `Test-Container.ps1` plus one new Dockerfile.
>
> **Batch E — base-tier. MUST be batched; never land alone.** #50 + #81. One
> base rebuild (~30 min + full downstream invalidation) pays for both. Add any
> future base-tier item to this batch rather than landing it on its own — this
> is the same rule that governed #27.
>
> **Batch F — media cache tiering, NO base rebuild.** #49, #51, #52, #54.
> Each is self-contained; #49 has the largest payoff (a PyAV bump currently
> re-runs the 75-min ONNX build).
>
> **Batch G — DONE 2026-08-14 except #59** (#55, #56, #58, #60, #82 landed;
> tests 486 → 493). **#59 stays open because it is an OWNER action, not a code
> change:** enabling branch protection on `main` and adding `-FailOnAnalyzer`
> to the CI lint step are repo-settings decisions. See the archive addendum.
>
> **Batch H — needs a measurement or a decision before any code.** #72 is a
> genuine trade-off (export round-trips vs. resume granularity), #70 needs a
> configure-only probe, #74 needs one cold media-core to confirm, #31 needs
> your registry choice. Do NOT start these as coding tasks.
>
> **Cross-cutting note:** #71 (sccache) is CLOSED — the write path works. #74
> (`-j9`) and #75 (the silent `-j` downgrade ladder) are NOT retired by it:
> #75's trigger is the sccache-**CUDA** server crash (±2 s deterministic,
> ~4909-4911 s into ONNX), which the clang-cl probe says nothing about. Verify
> both against the first real media build rather than against the old corpus.


---

### P0d — RESOLVED 2026-08-16: sccache write failures were BuildKit's WCOW cache mounts

> **Read #99 first — it carries the answer; #89/#92/#97/#98 below are the trail
> that led there and are kept for their method value, not as open work.** The
> section title used to read "sccache writes fail in EVERY stage after the
> first", which was itself one of the wrong turns: the failure was never
> stage-dependent, it tracked whether the cache directory held objects an
> EARLIER RUN had written. Fix shipped — `SCCACHE_MULTILEVEL_CHAIN` defaults to
> `""` (WebDAV only) in both media Dockerfiles; genai went 157 write errors → 0
> and then to 157 cache HITS. Still open in here: the upstream report to
> moby/buildkit, and the owner's intent to restore `disk,webdav` once WCOW cache
> mounts mature.

- **89 [M·★★★, none] ~~Only the FIRST media stage writes to the compiler
  cache~~ — SUPERSEDED BY #99, and the framing was the error.** The pattern is
  real, the "stage-dependent" reading of it was not: what actually decides is
  whether the cache directory already holds objects an EARLIER RUN wrote. onnx
  looks privileged only because it fills its own. Kept because the numbers below
  are the first trustworthy full-chain capture and #99's explanation has to
  account for all of them. Measured on that chain
  (`bk-run-fullchain-verify.log`, **zero clip events**):

  | stage | hits | misses | write errors |
  |---|---|---|---|
  | media-core-built-onnx | 10 | 1488 | **0** |
  | media-core-built-opencv | 0 | 1862 | **1849** |
  | media-core-built (genai) | 0 | 157 | **157** |
  | media-litert-built | 0 | 5037 | **5037** |
  | media-tvm-built | 0 | 596 | **596** |
  | media-tvm-built (iree) | 0 | 6686 | **6686** |

  **This RETRACTS the earlier "#71 is resolved" conclusion**, which generalised
  from two samples (a synthetic probe in the base image, and the ONNX stage) to
  the whole chain. The write path is stage-dependent, not fixed.

  Ruled OUT: "dufs died mid-chain" (the pre-2026-08-13 failure mode) — dufs was
  running and answering HTTP 200 immediately after the run.

  **TWO candidate causes, neither confirmed. Do not fix one before
  distinguishing them:**
  1. **`SCCACHE_CACHE_SIZE=15G` is exhausted by ONNX alone.** 1488 CUDA objects
     is plausibly ~15 GB, which would put the ceiling exactly at the boundary
     between the stage that works and the ones that do not.
  2. **BuildKit's tier-0 GC evicts the cache mount.** `buildkitd.toml`'s first
     gcpolicy is `maxUsedSpace = "40GB"` with filters
     `source.local + exec.cachemount + source.git.checkout` and **no
     `reservedSpace` floor** — so the sccache mount competes with context
     uploads and git checkouts for one 40 GB budget. Corroborating: `buildctl du`
     lists **no sccache cachemount record at all** (only the 1.2 GB bazel one),
     and a probe found the mount present but EMPTY. Store total is 559.76 GB
     with 483.51 GB reclaimable.

  **RESULT 2026-08-15 — cause 2 CONFIRMED, cause 1 REFUTED, and a residue
  remains.** `reservedSpace = "30GB"` + `maxUsedSpace = "60GB"` on the tier-0
  policy was deployed and a targeted rebuild (`-NoCacheStage onnx,opencv`) ran:

  | stage | hits | misses | write errors | before |
  |---|---|---|---|---|
  | onnx | **1498** | 0 | 0 | 10 / 1488 / 0 |
  | opencv | 37 | 1825 | **0** | 0 / 1862 / **1849** |
  | genai (`media-core-built`) | 0 | 157 | **157** | 0 / 157 / **157** |

  - **opencv 1849 → 0.** The GC was reclaiming the mount; the floor stops it.
  - **ONNX ran at a 100 % hit rate** (1498 hits, 0 misses) off the previous
    aborted run's writes — the first time this cache has ever been *reused*,
    and the reason that stage looked suspiciously fast mid-run.
  - **Cause 1 is dead:** the mount holds **236 MB**, nowhere near the 15 G
    ceiling, so `SCCACHE_CACHE_SIZE` was never the constraint.
  - **genai is UNCHANGED at 157/157** — same mount id, same inherited sccache
    ENV, so the remaining failure is neither GC nor configuration. Open.

- **91 [S·★★★, none] RESOLVED 2026-08-15 — the sccache error log was never
  FLUSHED, not never written.** The real mechanism, after three wrong
  hypotheses: the log is written by the sccache SERVER;
  `SCCACHE_IDLE_TIMEOUT=0` means it never exits on its own; BuildKit tears the
  RUN's process tree down at step end with the log still buffered, so nothing
  reaches the mount. **The tell was there the whole time and was misread**: a
  hand probe that sleeps 3 s with the server alive sees content instantly
  (`FILE sccache-error.log` + `WARN opendal::services service=webdav …`), while
  every real build left the directory empty. Path, level and mount were correct
  from the moment #90 landed. FIX: `Complete-SourceBuildChain` now runs
  `sccache --stop-server` as the chain epilogue — after every
  `Write-SccacheStatsToStderr` (those need a live server) — which also flushes
  the async webdav write-through tail the Dockerfile's own IDLE_TIMEOUT note
  already warned "dies with the server". **UNVERIFIED:** no build has run since.
  **Rule this earns:** when a log is empty only after REAL runs but fine under a
  probe, suspect lifetime before correctness.

- **96 [S·★★★, none] METHOD TRAP that cost four wrong conclusions: `buildctl
  --no-cache` EMPTIES the cache mount for that build.** Every probe used to read
  `SCCACHE_ERROR_LOG` passed `--no-cache`, so each one wiped the mount before
  looking into it and reported "no log" — four times, feeding four separate
  wrong hypotheses (LRU pruning, wrong location, unset `SCCACHE_LOG`, missing
  flush). Proven by isolation: write a marker with `--no-cache`, then read it
  **without** → `SEE marker2.txt COUNT=1`; read it **with** → mount empty.
  **RULE: never pass `--no-cache` to a probe that reads a cache mount.** Only
  the write side may use it. Worth a one-line note wherever cache-mount probes
  are documented, because the failure looks exactly like the thing being
  investigated.

- **97 [S·★★★, none] The sccache server in a real build never picks up
  `SCCACHE_ERROR_LOG`.** Now cleanly isolated (after #96 removed the probe
  artifact): the mount persists, `SCCACHE_LOG=warn` and `SCCACHE_ERROR_LOG` are
  verifiably present in the image env, the epilogue's `--stop-server` runs in
  all four stages and reports the true counters (genai: 157 misses, 157 write
  errors) — and **no log file is ever created**. Yet a hand probe in the SAME
  image with the SAME env produces one immediately. The one difference left:
  the probe calls **`--stop-server` BEFORE the first compile**, forcing a fresh
  server that reads the current env, while a build lets the first sccache
  invocation start the server implicitly. HYPOTHESIS (untested): the server is
  started at a point where `SCCACHE_ERROR_LOG` is not yet in its environment, so
  the setting never takes. FIX TO TRY: add a `--stop-server` to the build
  PROLOGUE (not only the epilogue), so every stage starts its server with the
  fully-populated env. Cheap to try, and it would also make the epilogue's flush
  meaningful.

  **DONE 2026-08-15/16 — and worth reading as a half-success.**
  `Invoke-SourceBuildChain`'s prologue now stops the server, TRUNCATES the error
  log, and starts the server explicitly from `C:\`. The log is obtainable and
  per-stage attributable, which is what finally made #99 diagnosable at all. But
  note what it did NOT do: the explicit `--start-server` was also floated as the
  cure for the write failures themselves (the "server CWD gets deleted" theory)
  and the next full build measured genai at an unchanged 157/157. The truncation
  is the part that mattered — without it the epilogue replayed a PREVIOUS run's
  errors and produced a false alarm. Log plumbing is not a fix; it is what lets
  you find one.

- **99 [S·★★★, none] ROOT CAUSE FOUND — sccache's cache write fails with
  `os error 3` (ERROR_PATH_NOT_FOUND), and the artifact itself is fine.** After
  six dead hypotheses, sccache's own debug log (finally obtainable, see #96/#98)
  states it plainly, once per TU, 157 times:

  ```text
  [main.cpp.obj]: Compiled in 1.389 s, storing in cache
  [main.cpp.obj]: Created cache artifact in 0.000 s      <- packaging SUCCEEDS
  [main.cpp.obj]: compile result: cache miss
  Error executing cache write: The system cannot find the path specified. (os error 3)
  ```

  So it is not permissions, not disk space, not the remote, and not the
  packaging step — the STORAGE WRITE cannot resolve a path.

  **CWD HYPOTHESIS — TRIED AND DISPROVEN 2026-08-15.** The theory was that the
  server, spawned implicitly by the first wrapped compile, inherits the build
  script's CWD, which the chain later deletes (`Removing build tree: …`),
  breaking relative path resolution. An explicit `--stop-server` +
  `--start-server` from `C:\` shipped in `Invoke-SourceBuildChain` and the next
  full media build measured **genai 157 misses / 157 L0 write failures —
  bit-for-bit unchanged**. Do not resurrect this from the old evidence.

  That build also killed the "later stages are special" framing that had
  survived since #89. Writes fail at a **flat 100 % everywhere**; onnx merely
  had nothing to write:

  | stage | misses | write attempts | failures |
  |---|---|---|---|
  | onnx | 0 | 0 | 0 (vacuous) |
  | opencv | 1 | 1 | **1** |
  | genai | 157 | 157 | **157** |

  A "0 write errors" line from a stage with 0 misses is not evidence of health —
  it is evidence of nothing. Always read it next to the miss count.

  **CONFIRMED CAUSE 2026-08-15 — it is the BUILDKIT CACHE MOUNT.** Isolated by
  `windows/scripts/Test-SccacheWrite.ps1`, which reproduces the failure with
  ONE compile in ~2 minutes and varies one factor at a time:

  | variant | SCCACHE_DIR | chain | write errors |
  |---|---|---|---|
  | disk-only | `C:\sccache` (cache mount) | — | **1** |
  | multilevel-mounted | `C:\sccache` (cache mount) | disk,webdav | **1** |
  | multilevel-plaindir | `C:\sccache-alt` (plain dir) | disk,webdav | **0** |
  | webdav-only | (remote) | — | **0** |

  The identical configuration writes cleanly to an ordinary container directory
  and fails against the cache mount, so it is **not** the multilevel chain
  (row 3 disproves it) and **not** the remote (row 4). Meanwhile the probe's raw
  `.NET` tests — nested `create_dir_all`, file write, rename inside the mount,
  and rename from `%TEMP%` INTO the mount — all **pass**. So the mount is
  writable by the foreground script and not by the sccache server.

  **DETACHED-PROCESS THEORY — TESTED AND DEAD.** The spawn matrix runs the same
  raw write from an attached child, a hidden async child and a fully detached
  child (`CreateNoWindow`, no console): all three report
  `exists=True | entries=19 | write=OK` against the mount, same user. Process
  shape is not the difference.

  **AND THE MOUNT THEORY WAS A CONFOUND.** `multilevel-plaindir` changed TWO
  things at once — off the mount AND into an EMPTY directory. The extra row
  `disk-mounted-subdir` (empty dir ON the mount) writes **cleanly**, so the
  mount is innocent; what fails is the *populated* root. Never accept a
  two-variable comparison as a cause, however good the story sounds.

  **ACTUAL CAUSE: stale directory entries in the pre-existing bucket tree.**
  Bisecting the root (`Test-SccacheWrite.ps1`, ~2 min/round):
  - the foreign entries (`logs`, 65.8 MB, left over from before #90; `wtest.txt`)
    were **not** it — removing them changed nothing;
  - `preprocessor` was not it;
  - no SINGLE bucket reproduced it: the binary search ended at `f` by
    elimination, and restoring `f` alone wrote **cleanly**. Elimination is not
    reproduction — the confirmation step is what caught this;
  - but after every bucket had been moved OFF the mount and back, the same root
    wrote **10 of 10 clean**.

  A cross-volume `Move-Item` is copy+delete, so the cycle rewrote the whole tree
  and with it every directory entry. That is the repair, and it explains the one
  observation that made no sense for days: the probe's raw `.NET` writes always
  passed because they CREATE NEW paths (`probe-tmp\a1\b2`), while sccache writes
  into the PRE-EXISTING bucket subtree (`8\a\c\<hash>`) — only sccache ever
  touched the damaged entries. Cf. this host's known wcifs layer-rename quirk.

  **THE TREE-DAMAGE THEORY IS ALSO DEAD.** Pointing `SCCACHE_DIR` at a FRESH
  empty directory on the same mount (`C:\sccache\v2`, verified live in the build:
  `L0 (disk) Local disk: "C:\\sccache\\v2"`) changed nothing — opencv 1/1, genai
  157/157, exactly as before. So it is not the directory, damaged or otherwise.

  **RESOLVED 2026-08-16 by REMOVING L0, not by explaining it.** Running the media
  chain with `-BuildArg SCCACHE_MULTILEVEL_CHAIN=` (WebDAV as the sole cache,
  confirmed live: `Cache location  webdav, name: , prefix: /`, no `Multi-level`,
  no `Local disk`):

  | stage | misses | write errors — before → after |
  |---|---|---|
  | onnx | 0 | 0 → 0 (vacuous both times) |
  | opencv | 1 | **1 → 0** |
  | genai | 157 | **157 → 0** |

  157 objects across every hash bucket, zero failures, in the stage that had lost
  every single write in six consecutive builds.

  **THE L0 CAUSE REMAINS UNKNOWN — this is a workaround, not an explanation.**
  Eleven hypotheses were measured and killed: server CWD, the multilevel chain,
  the cache mount, foreign `logs`/`wtest.txt` entries, the `preprocessor` dir,
  bucket `f`, process detachment, concurrency (16 at once writes fine), tree
  damage, path length (239-char source path writes fine), and a fresh cache dir.

  **METHOD LESSON, the expensive one:** `Test-SccacheWrite.ps1` reproduces the
  environment but NOT the failure — every configuration it blessed then failed in
  a real build, and it never once predicted build behaviour. A probe that cannot
  reproduce the bug cannot clear a fix either. Only build-stage `--show-stats`
  numbers counted in the end, and only next to their miss counts: three separate
  "0 write errors" readings were vacuous because the stage had 0 misses.

  **RE-USE CONFIRMED 2026-08-16 — the loop is closed.** The follow-up run (same
  build-arg, plus `-NoCacheStage` so every stage really re-executed rather than
  replaying a layer):

  | stage | before the fix | after | follow-up run |
  |---|---|---|---|
  | genai | 0 hits / 157 misses / **157 write errors** | 157 misses / **0 write errors** | **157 hits / 0 misses** |
  | opencv | 1 miss / **1 write error** | 1 miss / 0 write errors | 1 miss / 0 write errors |
  | onnx | 1498 hits (from L1 all along) | unchanged | unchanged |

  genai's objects were written on one run and served from WebDAV on the next —
  the first time that stage has ever produced a cache hit. Note onnx got 1498
  hits with `--no-cache` on its own layer, which independently shows the remote
  carries the whole load without L0.

  **SIDE FINDING — upstream documents the amplifier:**
  `SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY` defaults to `l0` = "fail only if L0
  write fails". That is exactly why `L1 (webdav) writes` was always 0: one broken
  level poisoned every write instead of degrading to the next. `ignore` would
  keep the two-level chain alive through a broken L0 — untested here, and worth
  it only if L0 is ever wanted back.

  **STILL OPEN:**
  - ~~the default is still `disk,webdav`~~ **DONE 2026-08-16: both media
    Dockerfiles default to `""` (WebDAV only). Owner wants `disk,webdav` back
    once WCOW cache mounts mature — see the re-verification recipe below.**
  - ~~**backend or chain?**~~ **ANSWERED 2026-08-16 by an A/B pair — it is the
    BACKEND, not the chain.** Two full media builds, one variable changed:

    | stage | cache dir at stage start | A: `chain=disk` | B: legacy disk (no chain) |
    |---|---|---|---|
    | onnx | **empty** | 225 / 1488 (15.1 %) | **28 / 1488 (1.9 %)** |
    | opencv | **populated** | 1849 / 1862 (99.3 %) | **1849 / 1862 (99.3 %)** |
    | genai | populated | 157 / 157 (100 %) | **157 / 157 (100 %)** |

    Two separate effects, and the big one is not the chain:
    - **Dominant: the cache directory having CONTENT.** Reproduces bit-for-bit
      without any multi-level code — 1849 of 1862, and exactly **13** successful
      writes before it turns, in BOTH runs. That determinism rules out a race or
      a sporadic filesystem fault. The cache grew 62 → 63 MiB during opencv
      against a 15 GiB limit, so it is not capacity either.
    - **Secondary: the chain layer.** On an EMPTY directory it multiplies the
      failure rate ~8× (28 → 225). Once the directory is populated the effect
      is invisible because nearly everything fails anyway.

    So the honest upstream claim is *"sccache's local disk cache loses writes
    once its directory has content, on Windows containers"* — NOT *"the
    multi-level chain is broken"*. `SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY=l0`
    remains the amplifier that turns a partial L0 failure into a total one and
    stops anything reaching the remote.

    Running B needed `SCCACHE_FORCE_LOCAL=1` (`WindowsScripts.Shared.psm1`):
    clearing the endpoint to isolate the disk level silently disables sccache
    altogether (`Test-SccacheRemoteConfigured` gates the cmake launchers), and
    the first attempt reported `Compile requests 0` — a run that looks clean and
    measures nothing. Always check `Compile requests > 0` AND the
    `Cache location` line before reading any failure count.

    **Best remaining thread:** why exactly 13 writes succeed before the turn.
    That number is identical across both configurations and is the only
    deterministic handle found so far; `Test-SccacheWrite.ps1` can chase it in
    minutes instead of 90-minute builds.

  **ROOT CAUSE, 2026-08-16 — IT IS THE BUILDKIT CACHE MOUNT, NOT SCCACHE.**
  The bulk section of `Test-SccacheWrite.ps1` isolates it with one program, one
  moment, two target directories, 250 unique objects each:

  | target | inherited content | result |
  |---|---|---|
  | `C:\sccache\bulk-inherit` (BuildKit cache mount) | 250 files from the previous RUN | **158 of 250 FAILED** |
  | `C:\bulk-plain-inherit` (plain container filesystem) | none | **0 of 250 failed** |
  | `C:\sccache\<fresh>` (same mount, brand-new dir) | none | **0 of 250 failed** |

  Same sccache, same config, back to back — only the target filesystem differed.
  **Both conditions are required:** the BuildKit cache mount *and* content that an
  EARLIER container wrote. A fresh directory on the same mount takes all 250.

  That is precisely the chain's stage order, and it explains every earlier number
  without any of the eleven dead hypotheses:
  - **onnx** fills its OWN directory in its own RUN → 28 failures of 1488 (1.9 %)
  - **opencv** INHERITS onnx's directory → 1849 of 1862 (99.3 %)
  - **genai** inherits a fuller one → 157 of 157 (100 %)

  And it explains why sccache looked guilty for days: it is the only thing in the
  chain that writes many files into an inherited cache-mount directory. The
  probe's own raw `.NET` writes always passed because they created NEW paths and
  never wrote more than a handful.

  **Reportable against moby/buildkit, not mozilla/sccache.** Context fits: WCOW
  cache-mount support landed only in v0.21.0 (moby/buildkit#5603, PR #5708), a
  mounter race was fixed in PR #5885, `--mount=type=cache` failing SILENTLY is
  #1648, and CVE-2026-15788 (GHSA-388v-wmr2-g2v2) touched WCOW cache-mount source
  selectors. Host here runs buildctl **v0.32.0**. No open `area/windows-wcow`
  issue matches this signature. To make the report airtight, reproduce it with
  PLAIN FILE WRITES (no sccache at all) into an inherited cache-mount directory —
  not done yet.

  **METHOD TRAP, and it cost a spectacular false conclusion:** the first
  inheritance run reported "0 files inherited" and looked like the mount had
  silently lost 250 objects. It had not — an EARLIER section of the same probe
  classifies anything in the cache root that is not a hex bucket as debris and
  moves it off the mount, so the probe destroyed its own experiment. The
  directory listing at the top of the log is what exposed it. `$probeOwned` now
  excludes the probe's own state.

  **DEFAULT FLIPPED 2026-08-16:** `SCCACHE_MULTILEVEL_CHAIN` is now `""` in BOTH
  `Dockerfile.media-builder` and `Dockerfile.media-merge-builder` — WebDAV is the
  sole cache. Owner intent: **restore `disk,webdav` later, once BuildKit's WCOW
  cache mounts have matured.** Re-verification recipe when that day comes — do
  NOT assume a newer buildkit fixed it:
  1. `Test-SccacheWrite.ps1` twice against the real media base image; the bulk
     section's ON-mount row must read 0 failures on the SECOND (inheriting) run;
  2. then one media build with `-BuildArg SCCACHE_MULTILEVEL_CHAIN=disk,webdav`;
     genai must report 0 write errors next to its 157 misses.
  - nearest upstream neighbour is mozilla/sccache#739 (Windows in a container,
    local disk cache, unidentified path-not-found, "deleting the cache folder
    helps", open since 2019). No report matches this exact signature, and this
    repo now has what #739 lacks: a 2-minute repro and an isolation matrix.

  **DEPLOYABLE WORKAROUND, measured not guessed:** row 4 writes fine, so drop
  L0 and run WebDAV as the sole cache (remove `SCCACHE_MULTILEVEL_CHAIN` and the
  `C:\sccache` mount). The disk level is already contributing almost nothing —
  in the last opencv stage it served **13 hits against L1's 1848** and has been
  write-dead throughout — while the breakage costs genai its cache **entirely**
  (`L1 writes 0`: when L0's write fails, nothing reaches the remote either, so
  those objects have never been stored, which is why genai rebuilds every time).

- **98 [M·★★★, none] LOCALISED: every write failure is at **L0 (local disk)**,
  never at the WebDAV remote.** The multilevel breakdown — which nobody had read
  until 2026-08-15, because the top-level `Cache write errors` counter hides it —
  says it plainly for the genai stage:

  ```text
  L0 (disk)   misses 157 · writes 0 · write failures 157
  L1 (webdav) misses 157 · writes 0 · write failures   0
  ```

  opencv shows the same shape at its one write opportunity
  (`L0 (disk) write failures 1`). Because `SCCACHE_MULTILEVEL_CHAIN=disk,webdav`
  — the layout in force when this was measured, defaulted OFF since 2026-08-16 —
  writes L0 first, an L0 failure means L1 is never attempted — which is why
  `L1 writes 0` everywhere and why the remote looked suspicious for days. **The
  WebDAV endpoint is not involved in this defect at all.**
  Also visible in the same block: `L1 (webdav) backfills to 0` — remote hits are
  never copied down into L0 either, consistent with L0 being unwritable rather
  than merely empty.

  RULED OUT so far: cache-size exhaustion (`Cache size 65 MiB` against a 15 G
  ceiling), GC reclaiming the mount (#89, fixed), the log location/level
  (#90/#91), PDB locking (`CMAKE_BUILD_TYPE=Release`, no `/Zi`, no `.pdb`
  anywhere in the build log — mspdbsrv was a red herring), and MSVC-vs-clang-cl
  (sccache classifies clang-cl as `[msvc]`, so onnx and genai report the same
  compiler class).

  NEXT: the question is now narrow and concrete — *why is a write into the
  `C:\sccache` cache mount rejected, in a stage that reads from it fine?* Note
  onnx wrote 1488 objects into the SAME mount successfully on 2026-08-15 03:54,
  so it is not a permanent property of the mount. Read the L0 backend's own
  WARN output (now that `SCCACHE_LOG=warn` is set) rather than guessing again —
  five hypotheses have already died here.

- **92 [M·★★★, none] genai's 157/157 write failures are NOT explained by cache,
  mount or configuration.** A probe in the SAME `bk-windows-media-core` image
  with the SAME inherited env (`SCCACHE_LOG=warn`,
  `SCCACHE_ERROR_LOG=C:\sccache-logs\…`, both cache mounts attached) compiled a
  TU and reported **0 write errors**, while `media-core-built` reports 157 of
  157 in every run. Ruled out so far: GC reclaiming the mount (#89, fixed —
  opencv went 1849 → 0), `SCCACHE_CACHE_SIZE` exhaustion (mount holds 236 MB
  against a 15 G ceiling), the log location (#90), and the log level. Note
  opencv reproducibly shows `1 miss → 1 write error` in the last two runs, so
  the failure is not genai-specific — it is *write-attempt*-specific and merely
  invisible while the hit rate is ~100 %. Next step is now unblocked: with #91
  in place a real build finally leaves an error log naming the layer that
  rejects the write.

- **90 [S·★★, none] DONE 2026-08-15 — error log moved OUT of `SCCACHE_DIR`.
  CORRECTION: the stated cause was wrong.** The observation was real —
  `C:\sccache\logs` was absent while 236 MB of cache content in the same mount
  survived — and it was read as "sccache's LRU pruned it". **That was not the
  mechanism** (see #91: the log was never flushed at all, so it never existed to
  be pruned). The move is still correct and was kept: a log has no business
  inside a directory another tool manages, and the dedicated mount
  (`C:\sccache-logs`, `id=sccache-logs-winamd64`, added to all 6 compiling RUNs
  and to buildkitd.toml's tier-0 inventory) removes that risk permanently. It
  was simply not SUFFICIENT — and the fact that the log stayed absent on a mount
  nothing prunes is exactly what disproved the LRU story. Two hypotheses were
  spent here before #91: LRU pruning, then an unset `SCCACHE_LOG` (also fixed,
  also not the cause on its own — `SCCACHE_LOG="warn"` is now set and needed).

---

### P0e — OpenCV ships WITHOUT the GStreamer backend, and with a FOREIGN FFmpeg

- **93 [M·★★★, media] IMPLEMENTED 2026-08-17, awaiting its first merge build (standalone plugin route, see the IMPLEMENTED block below) — `-DWITH_GSTREAMER=ON` is requested and silently becomes
  `NO`; the owner's code calls `cv::VideoCapture(..., CAP_GSTREAMER)`.**
  Confirmed 2026-08-15 by asking the built artifact, not the log
  (`cv2.getBuildInformation()` on `bk-windows-media-core`):

  ```text
  FFMPEG:      YES (prebuilt binaries)      <- NOT the chain's ffmpeg
    avcodec:   61.19.100                    <- FFmpeg 7.1, while the chain builds n9.0
    avdevice:  NO
  GStreamer:   NO                           <- requested ON, silently disabled
  DirectShow:  YES
  ```

  CAUSE: build order. OpenCV configures at `media-core-built-opencv`, but
  GStreamer is not built until the MERGE stage, so CMake finds nothing and
  disables the backend without failing. **Do not trust
  `cv2.videoio_registry.getBackends()` here** — it lists known backend IDs
  (GSTREAMER appears) regardless of what was compiled in; only
  `getBuildInformation()` is authoritative. That mismatch is exactly how this
  stayed invisible.

  CIRCULARITY (why the order is not simply wrong): `gst-plugins-bad`'s
  `ext/opencv` needs OpenCV — this repo even ports it to the OpenCV 5 headers —
  while OpenCV's `CAP_GSTREAMER` needs GStreamer. The two directions are
  independent features and the owner needs BOTH: OpenCV inside GStreamer
  pipelines (works today) AND GStreamer pipelines inside `cv::VideoCapture`
  (missing).

  OPTIONS, cheapest first:
  1. **STANDALONE videoio plugin — VERIFIED PRESENT in 5.0.0, 2026-08-17.**
     `modules/videoio/misc/plugin_gstreamer/CMakeLists.txt` exists on the tag and
     builds `opencv_videoio_gstreamer` **against an INSTALLED OpenCV**, out of
     tree, from a single source file:

     ```cmake
     include("${OpenCV_SOURCE_DIR}/cmake/OpenCVPluginStandalone.cmake")
     set(WITH_GSTREAMER ON)
     include("${OpenCV_SOURCE_DIR}/modules/videoio/cmake/init.cmake")
     set(OPENCV_PLUGIN_DEPS core imgproc imgcodecs)
     ocv_create_plugin(videoio "opencv_videoio_gstreamer" "ocv.3rdparty.gstreamer" "GStreamer" "src/cap_gstreamer.cpp")
     ```

     This is the route: a small stage AFTER the merge's GStreamer that points at
     the installed OpenCV + the OpenCV source tree and builds only the plugin
     DLL, which videoio then loads at runtime. Breaks the circularity without
     rebuilding OpenCV.

     **CORRECTION to this entry's own wording:** `VIDEOIO_PLUGIN_LIST=gstreamer`
     alone does NOT achieve it. In `modules/videoio/CMakeLists.txt` the plugin
     branch sits inside `if(TARGET ocv.3rdparty.gstreamer)` — i.e. it still
     requires GStreamer to be DETECTED at OpenCV configure time. That option
     only changes HOW a detected backend is built (separate runtime-loaded DLL
     instead of linked in), never WHETHER detection succeeds. Do not plan around
     it as an in-tree flag.
  2. **Second OpenCV pass** after the merge's GStreamer, with
     `-DWITH_GSTREAMER=ON`. ~20 min, structurally simple, but duplicates the
     most expensive media compile after ONNX. Only worth it if the standalone
     plugin turns out not to link against this image's OpenCV.

  **IMPLEMENTED 2026-08-17 (option 1) — awaiting its first merge build.**
  `Build-OpencvGstreamerPlugin.ps1` + a second RUN in the merge builder's
  `built` stage, directly after the GStreamer RUN: shallow-clones the OpenCV
  source at the same pin, points the standalone plugin project at the installed
  OpenCV (`OpenCV_DIR` located by searching for OpenCVConfig.cmake) and at
  GStreamer via `-DGSTREAMER_DIR` (OpenCV's WIN32 detection uses
  find_path/find_library, NOT pkg-config — no shim needed here, unlike #94),
  builds `opencv_videoio_gstreamer*.dll` and installs it next to
  `opencv_videoio*.dll`, where the runtime plugin loader probes. Gates on day
  one, per the #94 lessons: GStreamer resolution asserted from CMakeCache
  BEFORE compiling, plugin DLL asserted after, install copy asserted, configure
  output persisted.

  **VERIFICATION CHANGED WITH THE ROUTE — read before "fixing" the smoke
  test:** `getBuildInformation()` legitimately KEEPS saying `GStreamer: NO`
  (compile-time string; the plugin is runtime-loaded). The #95 guard was
  rewritten to assert `cv2.videoio_registry.hasBackend(cv2.CAP_GSTREAMER)`
  plus a FUNCTIONAL open-and-read of a `videotestsrc` pipeline through
  `VideoCapture(CAP_GSTREAMER)` — the exact call the owner's code makes. The
  old build-info assertion would have stayed red on a correct image forever.

  Still to do: one merge build to watch the new gates pass and the smoke
  assertions flip green (or produce the next real finding — the videotestsrc
  read exercises the full GStreamer runtime underneath cv2, which has never
  been tested through this path).

- **94 [S·★★, media] RESOLVED 2026-08-17 (see the RESOLVED block below; DEFAULT ON) — OpenCV uses its OWN prebuilt FFmpeg, not the chain's.**
  Same evidence block: `FFMPEG: YES (prebuilt binaries)`, avcodec 61.19.100
  (FFmpeg 7.1) while the chain builds n9.0 — so the image carries TWO FFmpeg
  generations and `cv::VideoCapture`'s FFmpeg path uses the older one. Also
  costs an extra download and leaves `avdevice: NO`.
  **This one is nearly free to fix: FFmpeg does NOT depend on OpenCV** (no
  `--enable-libopencv` anywhere in Build-FfmpegFromSource.ps1), so the
  opencv/ffmpeg stages can simply SWAP — no circularity, no second pass. Verify
  with `getBuildInformation()` afterwards that avcodec reports the n9.0 line.

  ## RESOLVED 2026-08-17

  Measured on the rebuilt `bk-windows-media-core`:

  ```text
  FFMPEG:      YES (prebuilt binaries)
    avcodec:   YES (63.1.100)   <- this chain's FFmpeg (was 61.19.100)
    avformat:  YES (63.1.100)
    avdevice:  YES (63.1.100)   <- was NO
  ```

  Both symptoms gone. Four parts, all required:
  1. **stage swap** — FFmpeg builds before OpenCV (three places kept in step:
     `Build-MediaCoreAll.ps1`, the `FROM` graph, `build-buildkit.ps1`);
  2. **`patches/opencv/pkgconfig-shim.cmake`** via `CMAKE_PROJECT_INCLUDE` —
     runs the `find_package(PkgConfig)` OpenCV skips on Windows, which is the
     only thing standing between its pkg-config route and this chain's FFmpeg;
  3. **`OPENCV_FFMPEG_SKIP_DOWNLOAD=ON` + `OPENCV_FFMPEG_ENABLE_LIBAVDEVICE=ON`**;
  4. **`patches/opencv/Get-Ffmpeg9AvcodecConfig.ps1`** — OpenCV 5.0.0 does not
     compile against FFmpeg 9 without it (`AVCodec::pix_fmts` and
     `supported_framerates` were removed in favour of
     `avcodec_get_supported_config()`); 3 + 2 call sites, two compat shims.

  ~~Currently **opt-in**~~ **DEFAULT ON since 2026-08-17.** The flip criterion
  was met: full chain (fresh base included) ended with the smoke gate at
  **188 passed / 1 failed / 1 skipped**, the single failure being the
  deliberately-red #93 GStreamer guard — all three #94 assertions green in the
  SHIPPED image. Opt out with `-BuildArg OPENCV_LINK_CHAIN_FFMPEG=`. The ARG
  moved to the `media-core-built-opencv` stage in the same edit (#103), so
  future flips re-run opencv+genai (~25 min), not the whole branch.

  **`(prebuilt binaries)` IS NOT A PROVENANCE SIGNAL.** The label stays on a
  correct build — it reflects videoio's wrapper mechanism on Windows, not where
  the libraries came from. The #95 assertion that keyed on it failed against a
  CORRECT image and has been replaced by the avcodec-version comparison. Anyone
  reading that label as "OpenCV downloaded its own FFmpeg" will chase a
  non-defect.

  **PARTLY DONE 2026-08-16 — the swap SHIPPED, the flag that was supposed to
  exploit it REGRESSED and was reverted the same day.**

  Shipped and kept: FFmpeg now builds BEFORE OpenCV
  (`Build-MediaCoreAll.ps1` stage order, the `FROM` graph in
  `Dockerfile.media-builder`, the `Invoke-BkStage` order in
  `build-buildkit.ps1` — three places, all three verified in agreement), and
  every RUN passes BOTH `-ResumeFrom` and `-Until`. The ffmpeg step previously
  passed only `-ResumeFrom` and worked purely because it was LAST; after the
  swap that would have silently dragged OpenCV into the ffmpeg layer.

  Reverted: `-DOPENCV_FFMPEG_SKIP_DOWNLOAD=ON`. It turned
  `FFMPEG: YES (prebuilt binaries)` into a flat **`FFMPEG: NO`** — strictly
  worse than the defect it was meant to fix. Cause, from OpenCV 5.0.0's
  `modules/videoio/cmake/detect_ffmpeg.cmake`:

  ```cmake
  if(NOT HAVE_FFMPEG AND PKG_CONFIG_FOUND)   # <- the pkg-config route
  ```

  `PKG_CONFIG_FOUND` comes from `find_package(PkgConfig)`, which OpenCV does not
  run on Windows. So skipping the download removes the ONLY detection path that
  works there and nothing takes its place. **Do not try `SKIP_DOWNLOAD` on its
  own again — that experiment has been run.**

  METHOD NOTE, worth more than the failed attempt: the prerequisite was checked
  first, and the check was the WRONG one. `pkg-config --modversion libavcodec`
  → 63.1.100 inside the image proves *pkg-config* works; it says nothing about
  whether *OpenCV's CMake* ever calls it. Right question, wrong instrument.

  **DETECTION SOLVED 2026-08-16 — the blocker moved from the build wiring to the
  SOURCE.** `windows/scripts/patches/opencv/pkgconfig-shim.cmake` (passed via
  `CMAKE_PROJECT_INCLUDE`) runs the `find_package(PkgConfig)` that OpenCV skips
  on Windows, which unblocks its existing pkg-config route. With that plus
  `OPENCV_FFMPEG_SKIP_DOWNLOAD=ON` and `OPENCV_FFMPEG_ENABLE_LIBAVDEVICE=ON`,
  OpenCV's own configure summary reports what #94 asked for:

  ```text
  Checking for modules 'libavcodec;libavformat;libavutil;libswscale'
    Found libavcodec,  version 63.1.100      <- the chain's, not the prebuilt 61
    Found libavdevice, version 63.1.100      <- #94's `avdevice: NO` fixed
      FFMPEG:    YES
        avcodec: YES (63.1.100)
  ```

  **BUT THE COMPILE THEN FAILS.** OpenCV 5.0.0's videoio does not build against
  FFmpeg n9.0:

  ```text
  cap_ffmpeg_hw.hpp(760,761,762)    error: no member named 'pix_fmts' in 'AVCodec'
  cap_ffmpeg_impl.hpp(2632,2633)    error: no member named 'supported_framerates' in 'AVCodec'
  ```

  FFmpeg deprecated those `AVCodec` fields in 7.1 and REMOVED them by 9.0 in
  favour of `avcodec_get_supported_config()`; OpenCV 5.0.0 predates the removal.
  Five sites, two headers — that is the remaining work, and it is a source patch
  under `windows/scripts/patches/opencv/`, not a flag.

  **SHIPPED STATE: opt-in, default OFF.** `-BuildArg OPENCV_LINK_CHAIN_FFMPEG=1`
  turns the wiring on; without it OpenCV keeps its own prebuilt FFmpeg (the
  original #94 defect) because a chain that does not build is worse. The
  stage swap and the shim stay in place so the next attempt starts from a proven
  base.

  **THREE FALSE VERDICTS FROM MY OWN GATE, worth more than the attempt itself.**
  Each looked like a build defect and was an instrument defect:
  1. `pkg-config --modversion libavcodec` → 63.1.100 was taken as "OpenCV can
     find it". It proves pkg-config works, not that OpenCV's CMake calls it.
  2. The gate read `cvconfig.h` for `HAVE_FFMPEG` and got a false FAILURE —
     first blamed on `Select-Object -First 1` picking the wrong file. Both files
     lacked it. **`HAVE_FFMPEG` does not exist in OpenCV 5.0.0's
     `cvconfig.h.in` at all**; the gate could never have passed.
  3. `Invoke-CmakeConfigure ... | Out-Null` swallowed the entire configure
     output, so the first gate failure had no evidence to read at all — a
     "never swallow logs" violation exactly where the log decides.
  The gate now reads OpenCV's configure SUMMARY (the same text
  `getBuildInformation()` reproduces), the configure output is Tee'd to
  `opencv-configure.log` on the sccache-logs mount, and the failure branch
  prints the FFmpeg lines inline — pointing at a log inside a container that is
  about to be discarded helps nobody.

  COST NOTE: the revert rebuilt only opencv+genai — onnx and ffmpeg stayed
  CACHED, 21:55 instead of ~90 min. That per-library checkpoint granularity is
  exactly what #72 proposed collapsing; this incident is a concrete argument for
  keeping it.

- **95 [S·★★★, none] DONE 2026-08-17 (assertions live; #93 guard rewritten for the plugin route the same day) — GUARD BOTH: assert the compiled-in video backends, in the
  smoke test.** Neither #93 nor #94 may land without this — the whole reason
  they went unnoticed is that nothing ever asserted them, while the one obvious
  check (`cv2.videoio_registry.getBackends()`) reports GSTREAMER whether or not
  it was compiled in. The assertion must parse
  **`cv2.getBuildInformation()`**'s `Video I/O:` block and require:
  - `GStreamer: YES` (fails today — the point of #93)
  - `FFMPEG: YES` **and NOT `(prebuilt binaries)`** — the substring is what
    distinguishes the chain's FFmpeg from OpenCV's own download (#94)
  - the avcodec version line matching the `FFMPEG_VERSION` pin, so a future
    silent fallback to a bundled build fails instead of shipping
  This belongs with the existing OpenCV section in `Test-Container.ps1`,
  next to the bulk DLL-load enumeration (#57). Add the assertions FIRST, watch
  them fail, then land the fix — a guard written after the fact proves nothing
  about the defect it was meant to catch.

  **DONE 2026-08-16 — three assertions landed and VERIFIED FAILING on the real
  artifact.** They sit in the python section of `Test-Container.ps1`
  (where `cv2` is importable) and parse `cv2.getBuildInformation()` only:
  1. `GStreamer: YES` — guards #93
  2. `FFMPEG: YES` **without** `(prebuilt binaries)`, via a negative lookahead — guards #94
  3. OpenCV's `avcodec` major **== the chain's** `libavcodec` major, read from
     `ffmpeg -version` at runtime rather than hard-coded, so an `FFMPEG_VERSION`
     bump needs no edit and a silent fallback to a bundled build still fails

  Watched failing with `windows/scripts/Invoke-OpencvVideoProbe.ps1` (+
  `Dockerfile.opencv-video-probe`, ~4 s against a media image instead of a full
  chain). Measured against `bk-windows-media-core-ffmpeg`:

  ```text
  FFMPEG:      YES (prebuilt binaries)
    avcodec:   YES (61.19.100)
    avformat:  YES (61.7.100)
    avdevice:  NO
  GStreamer:   NO

  [FAIL] GStreamer backend compiled in (#93)
  [FAIL] FFmpeg is the chain's, not a prebuilt download (#94)
  [FAIL] OpenCV avcodec major == chain avcodec major (#94) - chain=? opencv=61
  ```

  **CORRECTION to this entry's own premise:** it says
  `cv2.videoio_registry.getBackends()` "reports GSTREAMER whether or not it was
  compiled in", and that is **not what this build does** — the registry listed
  GSTREAMER as *absent*, agreeing with `getBuildInformation()`. The rationale
  for parsing build information stands on its own (it is the authoritative
  source and also carries the FFmpeg provenance the registry cannot express),
  but do not repeat the "the registry lies" claim as fact; it did not reproduce.

  Two notes for whoever lands #93/#94: real OpenCV prints
  `avcodec: YES (61.19.100)`, not the abridged `avcodec: 61.19.100` quoted in
  #93 — the assertion accepts both. And `chain=?` above is honest: that media
  image has no `ffmpeg.exe` at `FFMPEG_BIN`, so assertion 3 fails closed there;
  it is meaningful in the final image, where the smoke test actually runs.

---

### P6 — 2026-08-17 static audit: dedup / size / clean code (no behaviour change)

> Scope: all 162 PowerShell files + 11 Dockerfiles, read against what the last
> week's incidents actually cost. Deliberately NOT re-reported here: #49/#50
> (ENV/COPY cache tiers), #52 (redundant SHELL re-declarations — counts
> re-confirmed today: media-builder/merge/torch/toolchain carry one each), #54
> (flattened CUDA runtime copy). Also deliberately NOT flagged: the
> `build-*-from-source.ps1` preambles (already deduped through
> `Initialize-SourceBuildScript`) and the in-container probe scripts defining
> their own `Write-Section`/`Write-Result` — those are bind-mounted WITHOUT the
> modules dir, so self-containment there is a feature, not drift.
>
> **Execution constraint: everything below touches files that are bind-mounted
> or COPY'd into the running chain. Land nothing until the current full chain
> is green.**

- **101 [S·★★, none] DONE 2026-08-17 — and the audit's "8 pasted sites" was
  itself wrong (grep counted `-CandidatePaths` ARGUMENTS as pastes).** Real
  picture after reading each site:
  - genuinely duplicated, now fixed: `build-buildkit.ps1` and both probe
    runners (the latter via the shared `Invoke-DiagnosticProbe.ps1`, #102);
  - already used the helper all along: `Test-CudaCache.ps1`,
    `Reset-ContainerStores.ps1` — false positives;
  - deliberately inline, now ANNOTATED as such: `Test-BuildCopy.ps1`
    (first script on a fresh host), `Reset-ContainerLocks.ps1` and
    `Set-BuildkitdGcpolicy.ps1` (elevated repair tools — a module import is
    one more thing that can be broken exactly when they are needed).
  Lesson for the next audit: a grep hit on the candidate PATH string is not a
  grep hit on the candidate WALK.
- **102 [S·★★, none] DONE 2026-08-17 — probe runners folded into
  `Invoke-DiagnosticProbe.ps1`.** The PROBE_NONCE + `probe complete` fail-closed
  machinery now exists exactly once; the two original names stay as thin
  wrappers with their defaults, so muscle memory and doc references keep
  working. The shared runner also uses `Get-PreferredToolPath` instead of the
  pasted buildctl walk, closing 2 of #101's 8 sites. Verified live against
  `bk-windows-media-core` (probe executed, verdict printed, marker check
  green).
- **103 [S·★★★, media once] DONE 2026-08-17 — `OPENCV_LINK_CHAIN_FFMPEG` moved
  out of the COMMON env block into the `media-core-built-opencv` stage** (and
  its default flipped to `1` in the same edit, see #94). While it sat in
  `common`, one flip re-ran the ~50-min ONNX stage although only opencv reads
  the variable — the #94 verification cost ~90 min instead of ~25 for exactly
  this reason. No merge-builder mirror needed: the merge rebuilds GStreamer,
  never OpenCV. Cost of the move itself: one last full-branch rebuild (the
  common ENV layer changed one final time); every flip after that is ~25 min.
  Same disease as #49; this was the instance that bit on 2026-08-17.
- **104 [S·★, none] The sccache cache mount carries dead weight that no build
  will ever read again.** The damaged original root tree (buckets `0..f`,
  ~114 MiB — the #99 corpse), the empty `v3`, experiment B's `v4` (~63 MiB),
  and the probe fixtures `probe-persist`/`bulk-inherit` (kept intentionally for
  the inheritance experiment — delete once #99's upstream report is filed).
  Only `v2` is referenced, and with the WebDAV-only default even that is
  dormant. One cleanup RUN (probe-style, bind-mounted script) that deletes
  everything except `v2` reclaims ~200 MiB of the shared 40 GB tier-0 budget
  and removes four foot-guns for future probes. NOT image size — builder disk.
- **105 [S·★★, none] DONE 2026-08-17 — `CONSUMED-BY` headers added, consumers
  VERIFIED by grepping the sibling repos** (not assumed from memory):
  - `WindowsContainerBuild.Reuse.psm1` ← BeschleunigerBallett
    `Build-Windows-Container.ps1` (8 functions) + RustProjectTemplate
    `Invoke-StevedoreBuild.ps1` (`Resolve-DockerExe`)
  - `WindowsAgenticLoop.Common.psm1` ← BeschleunigerBallett
    `Invoke-AgenticLoop.ps1`
  Both headers state explicitly that an in-repo dead-code sweep WILL flag the
  module and would be wrong, and that renames are breaking changes downstream.
- **106 [S·★, none] PARTLY DONE 2026-08-17 — and the gate's FIRST RUN corrected
  the entry's own premise.** The parse gate
  (`Bootstrap.Ps51Compat.Tests.ps1`: PSParser tokenization + no
  `#requires -Version 7` + no `?.`) shipped, and immediately flagged two of the
  "trio": **`Install-Vs.ps1` and `Install-ScoopTools.ps1` are NOT 5.1 scripts** —
  both declare 7.0 and both run AFTER Dockerfile.base switches SHELL to pwsh
  (SHELL ~:69, their RUNs ~:93/:125). Exactly ONE script runs under WPS 5.1:
  `Initialize-Pwsh.ps1` (RUN ~:45). The gate now covers precisely that one and
  documents the SHELL-order evidence. Lesson, same family as #101's: the
  "which scripts are 5.1" claim came from comments/lore, and the first
  measurement disagreed.
  STILL OPEN: add `#requires -Version 7.0` to the ~52 undeclared files (many
  are bind-mounted into media stages — land between builds).
  (Original trigger, still true: `Test-SccacheWrite.ps1` declared 5.1 while
  using `ProcessStartInfo.ArgumentList`, which 5.1 does not have.)
- **107 [M·★★, none] `Invoke-SourceBuildChain` / `Complete-SourceBuildChain`
  have grown to 134/158 lines of inline sccache choreography.** The prologue
  (stop → truncate log → start from `C:\`) and epilogue (stats → stop-server →
  log dump) accreted through #97/#98/#99 as inline blocks with long comment
  essays. Extract `Start-SccacheServerSession` / `Complete-SccacheServerSession`
  into the module: unit-testable (the truncation and `-Last N` dump each cost a
  false alarm), and the chain functions drop back to readable size.

---

## Former "Open items" list (superseded by CURRENT SEQUENCE in the live doc)

### Open items (effort·impact; ordered by leverage)

> **RECOMMENDED ORDER 2026-08-16.** Live, user-visible defects first; latent
> insurance last. Everything below the line is real work, but nothing below the
> line changes what the shipped image can do.
>
> 1. **#93/#94/#95 (P0e) — OpenCV has no GStreamer backend and a FOREIGN
>    FFmpeg.** The only items here that make the SHIPPED IMAGE wrong: the owner
>    calls `cv::VideoCapture`, and `getBuildInformation()` reports
>    `GStreamer: NO` with an avcodec that is not the chain's own. Write the
>    smoke-test assertions FIRST and watch them fail — that is what stops this
>    regressing again.
> 2. **#100 — FFmpeg and PyAV compile with sccache entirely bypassed**
>    (`Compile requests 0`). Pure rebuild cost, but it is invisible in every
>    hit-rate metric, so it will never surface on its own.
> 3. **#99-followup — the BuildKit upstream report**, while the measurements are
>    fresh and the repro still runs in two minutes.
> 4. **#59 — branch protection** (owner decision, minutes).
> 5. #75/#76 timeout+heartbeat, #73, #77–#80 — latent or unverified; re-measure
>    against a fresh chain before spending time on any of them.

- **99-followup [S·★★★, owner] Report the BuildKit WCOW cache-mount write loss
  upstream.** Cause, A/B measurements and the 2-minute repro are in #99; the
  report itself is unwritten. Strengthen it first by reproducing with PLAIN FILE
  WRITES (no sccache) into an inherited cache-mount directory — that removes the
  third-party tool from the argument entirely. Goes to moby/buildkit, NOT
  mozilla/sccache.
- **99-restore [S·★★, owner] Bring back the two-tier `disk,webdav` cache** once
  WCOW cache mounts stop losing writes. Owner intent recorded 2026-08-16; the
  default is `""` (WebDAV only) in both media Dockerfiles until then. Do not
  assume a newer buildkit fixed it — the two-step re-verification recipe is at
  the end of #99.
- **31 [S·★★, owner decision] Auto-push green stage images** (or export-
  cache) once a chain goes green — driver params exist; needs the registry
  choice + a `docker login`. Until then a host loss costs every stage.
- **0b human half [policy] versions.env bumps ride the Windows lane**: one
  local full-chain build before trust. (CI half shipped: the `patch-drift`
  job re-verifies every .patch against its pins on each trigger.)
- ~~**35 [observe·★] Transient ~120-min ffmpeg stall**~~ — **CLOSED 2026-08-14,
  superseded by #76.** The log forensics measured it exactly (7200.9 s ≈ a
  2-hour timeout, not jitter), located it in the MSYS2/gawk provisioning call,
  and confirmed it has not recurred in 9 subsequent runs. It is now an
  actionable item (bound the step with a timeout), not an observation.

