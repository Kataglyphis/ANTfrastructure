# Build cache tiers (Linux cross lane)

> **STATUS 2026-08-23: § 4 (S3 / T4) is DESIGN ONLY — that code change was
> written, reviewed and REVERTED.** The first implementation reintroduced the
> literal `${tag}-buildcache` cache ref, which `verify-critical-fixes.sh` has forbidden
> since fix7 (2026-07) precisely because that ref was self-defeating; the
> preflight gate failed on it immediately. It was also inert by default and had
> no regression coverage, so a future "just turn it on" edit would have flipped
> ~12-13 GB of extra registry traffic per run with nothing asserting the
> behaviour. § 4 is therefore the design and the constraints any implementation
> must satisfy — read the flake-recovery interaction below before writing code.
> § 5 is not covered by this banner: the ccache→sccache switch it describes is
> shipped and running.


**Audience:** anyone about to "add a registry cache", "turn on `mode=max`",
"wire sccache", or free disk by deleting a cache directory.

This is the *why* companion to the one-screen map in
[`linux-build-basics.md` § Caching Layers](linux-build-basics.md#caching-layers-what-is-cached-where).
That table says what is cached where; this document says **what each tier does
NOT cover, what destroys it, and what it costs to replace it** — the three
questions that produced an 18-hour cold rebuild (backlog S3, BIT 2026-08-21).

Scope: the Linux cross lane (`build-cross-chain.sh` →
`01-core/cross-stage-build.sh`). The Windows lane keeps its own cache story in
its own docs; nothing here proposes work there.

---

## 1. The tiers

| # | Tier | Wired at | Covers | Stored in | Destroyed by |
|---|---|---|---|---|---|
| T0 | BuildKit layer/history cache | implicit (the worker) | **every** vertex, including intermediate `FROM … AS x` stages | the buildkitd store | `nerdctl system prune`; buildkitd GC (`gckeepstorage` in `~/.config/buildkit/buildkitd.toml`) |
| T1 | exec cache mounts (ccache, sccache, apt, cargo, uv, pip, source trees) | `--mount=type=cache,…` in the Dockerfiles | compiler/package output at translation-unit / file granularity | the buildkitd store (`exec.cachemount` records) | `nerdctl system prune` (**35 → 1 records observed 2026-08-21**). Survives `linux/host-config/prune-safe.sh` and a daemon restart — both proven repeatedly |
| T2 | local stage cache export | `cross-stage-build.sh:177-181` (`--cache-to type=local,…,mode=max`) | **every** vertex of that stage's Dockerfile | `~/.cache/kata-buildcache/<tag-slug>/` — *outside* the buildkit store | our own disk guard (LRU below `CROSS_DISK_GUARD_GB`=40 G free, plus the `CROSS_CACHE_MAX_GB`=250 G total cap, `build-cross-chain.sh:513-562`); the disk-preflight's `rm -rf` hint (`build-cross-chain.sh:467`); `CROSS_NO_LOCAL_CACHE_EXPORT=1` stops new writes |
| T3 | inline registry cache | `cross-stage-build.sh:187-192` (`--cache-to type=inline` + `--cache-from type=registry,ref=<tag>`) | **only the final image's own layers** (`mode=min`) | inside the pushed image config — no separate blob, so no ghcr 400 | `ghcr-cleanup.yml` (keeps 3 versions per tag, 14-day floor) |
| T4 | per-stage registry cache, `mode=max` | **not enabled, and DESIGN ONLY** — the pilot knob `CROSS_REGISTRY_CACHE=max` was written and reverted with the rest of S3; no code reads it (`cross-stage-build.sh:162-192` adds the local `mode=max` export and, when pushing, `type=registry` cache-from + `type=inline` cache-to, and nothing else) | every vertex, off-host | a `<tag>-buildcache` ref on ghcr | see § 4 — the cost, not the mechanism, is the blocker |

Two properties are worth internalising because they are counter-intuitive:

- **T2 is not in the buildkit store.** `nerdctl system prune` does not touch
  `~/.cache/kata-buildcache`. The things that empty it are *ours*: the disk
  guard and the preflight hint.
- **T0/T1 are in the same store**, so the one command that wipes layers also
  wipes the compiler caches. That is why Standing rule 3 exists.

### 1.1 The cerbero state cachemount (CERB-CACHE)

`03-media/build/gstreamer/android/build-android-from-source.sh` keeps its
cerbero state in a T1 exec cachemount (`linux/Dockerfile.android`, the
`android-gstreamer` RUN, `target=/var/cache/cerbero`) with an unusual job: it
makes a *failed* build resumable. bootstrap + package is ONE `RUN`, so before
this mount existed any failure inside it discarded the whole ~40-60 min
bootstrap — wave5k/5l re-paid it on every freedesktop flap, while wave6b
restarted WARM (`HIT: resuming … 13G / 20G`) and finished with zero fetch
failures.

What lives there (cerbero's `home_dir`): `sources/local` (downloaded tarballs
and the git repos it checks out), `sources/<pkg>` (extracted + compiled build
trees), `build-tools/` (the host bootstrap prefix), `rust/`,
`dist/android_<arch>/` (the target prefix), and the `cache-file.cache` /
`build-tools.cache` pickles recording which recipes are already built
(`build/cookbook.py: _cache_file()`).

Four properties worth internalising:

- **A resume is not a re-verification.** Read against the pinned cerbero 1.29.2:
  `Oven._cook_recipe_step` returns before it ever calls the step function when
  that step is already in the pickle (`build/oven.py:511`), and `_cook_recipe`
  skips the whole recipe once `needs_build` is false (`:554`). The only caller
  of `Source.verify()` — the sha256 against the recipe's `tarball_checksum` — is
  the fetch step itself (`build/source.py:366/378/458`). Bytes reused out of
  `sources/local` are therefore never re-hashed: they buy speed, not trust.
- **The pickle only invalidates on recipe content.** A recipe's status is thrown
  away when its `built_version` changes, or when the content hash of the recipe
  file plus its patch files changes (`build/cookbook.py:426-440`;
  `Recipe.get_checksum` = `files_checksum` over the recipe's own FILES, not over
  the tarball) — so the sed-patched recipes in that script (PKGCFG-MIRROR,
  soundtouch, glib libiconv) do invalidate themselves. Nothing in the pickle
  knows about the toolchain, which is why `ANDROID_NDK_VERSION` and
  `ANDROID_API_LEVEL` are part of the cachemount id: a pin bump must start a NEW
  store, because cerbero would happily resume a tree built against the old NDK.
- **The state dir is deliberately NOT `/opt/cerbero`.** That path stays the git
  CHECKOUT: a mount target already exists when the RUN body starts, so the
  `[ ! -d cerbero ]` guard would skip the clone and `git clone` refuses a
  non-empty destination anyway. Separating them also un-collides cerbero's
  read-only seed dir `cached_sources` (= `<checkout>/sources`) from the live tree.
- **The disk trade-off, with the number, because the host runs near-full.** The
  prune at the end of the script is on the SUCCESS path ONLY: the package exists,
  so the extracted/compiled trees are dead weight and everything kept lives
  outside `sources/` (the dist prefix, the build-tools prefix at
  `config.py:1065`, the two pickles) plus `sources/local` — that is
  `local_sources` (`config.py:1146-1151`, because `home_dir` is non-default), the
  tarballs and git repos that make the next run cheap and network-independent
  (FD-OUTAGE). A FAILED attempt keeps its whole tree — that is the entire point
  of the mount, and it costs up to ~10-15 GB per lane, i.e. ~30-45 GB with all
  three arch lanes sitting on failures. Retries reuse the same cachemount id and
  the same paths, so a failing lane overwrites in place rather than accumulating
  a tree per attempt. Pruning on ENTRY instead was considered and REJECTED as
  unsafe: cerbero records progress per STEP, so a recipe can be mid-flight with
  `extract` recorded and `compile` not (`oven.py:511` then skips straight to a
  configure/compile on a directory the prune would have deleted) — that wedges
  the lane on every retry instead of bounding disk. `CERBERO_CACHE_RESET=1`
  empties the CURRENT store on entry when a lane must be forced cold.

GENERATIONS are the unbounded axis: the id carries the NDK/API pins, so a pin
bump starts a fresh store and ORPHANS the previous one, and nothing inside the
build can reach it (a different cachemount id is simply not mounted into the
RUN). `linux/host-config/prune-safe.sh` will not clean it up either — it prunes
`type==regular` only and treats every cachemount as sacred by design (CACHE1: it
aborts if the cachemount count drops). Reclaiming an orphan is a deliberate
host-side act, e.g. a duration-bounded
`buildctl prune --filter type==exec.cachemount --keep-duration <t>` chosen so the
ccache/sccache mounts a live build keeps warm stay above the cutoff — check what
it would remove before running it.

---

## 2. The blind spot: what `type=inline` cannot carry

`--cache-to type=inline` is `mode=min`. It records cache keys for the layers
that end up **in the exported image** and nothing else.

The media stage's expensive work is not in those layers. `Dockerfile.media`
builds onnxruntime / litert / tvm / opencv / app-wheelhouse / armnn / ffmpeg /
pyav / gstreamer / opencv-gst as **named intermediate stages**
(`FROM base AS …`, `:249-976`) and lifts the results out with
`COPY --link --from=…` (`:768-775`, `:1013-1056`). The layers those COPYs
produce are in the image; the RUN vertices that *built* them are not, and a
`mode=min` export carries no cache record for them. So:

> A host that still has the pushed image, and reads the inline cache back from
> it, will still recompile every framework.

This is not a theory, it has been measured twice:

- **2026-08-09** — after a prune emptied the local media slugs, the next amd64
  media run recompiled every framework (~1.5–2 h) *despite* the previous day's
  push (original S3 write-up, `refactoring-backlog-archive-2026-08-10.md:2010`).
- **2026-08-21** — a `nerdctl system prune` took T0+T1, the media slugs were
  not there to save the run either, and the relaunch cold-rebuilt all media
  intermediates: ~18 h across torch/IREE/litert × 3 arches (backlog S3, BIT).

So S3's premise is correct: **only a `mode=max` tier carries intermediates**,
and today the only `mode=max` tier is the local one (T2).

---

## 3. Failure modes and the recovery path that already exists

| Symptom | Cause | What the code does by itself | Operator knob |
|---|---|---|---|
| `DeadlineExceeded: failed to compute cache key: … httpReadSeeker … no active session` | ghcr cache **import** flake (killed 6 attempts across 2 lanes in one afternoon, 2026-08-18) | retry; after **2** such failures drop the registry cache-from + inline cache-to and finish on the local tier (`cross-stage-build.sh:266-294`) | `NO_CACHE_EXPORT=1` does the same thing up front |
| `error writing layer blob: 400 Bad Request` on cache push | ghcr rejecting an oversized `mode=max` cache blob (why T4 was removed in `4f27634`; `195285f` replaced it with T2+T3) | **nothing** — 400 is not in the transient class (`_cross_stage_push_error_is_transient`), so the stage fails | `NO_CACHE_EXPORT=1` |
| A stage fails after hours of completed work → T2 exports **nothing** | `--cache-to type=local` only materialises on a successful solve (~8 h of arm64 media work exported ZERO once) | S1 salvage: re-drive the same build per named `--target`, each a pure cache hit, so the export lands anyway (`cross-stage-build.sh:230-262`) | `SALVAGE_CACHE_EXPORT=0` |
| Disk below 40 G between stages | T2 growth (209 G measured today) | LRU-prune unprotected slugs; stages still to run in **this** chain are protected; if still short, stop writing new exports | `CROSS_DISK_GUARD_GB`, `CROSS_CACHE_MAX_GB`, `CROSS_NO_LOCAL_CACHE_EXPORT=1` |
| `could not read …/kata-buildcache/…` | empty slug dir, i.e. a clean miss | suppressed: cache-from is only added when `index.json` is non-empty (`cross-stage-build.sh:171-173`) | — |
| Chain refuses to start: `Insufficient disk: 19G free, ~180G recommended` | T2 grew 62 G → 110 G in ONE session (D4) and there is no room for the run | **preflight trim**: reclaim oldest-first from `~/.cache/kata-buildcache` up to the deficit, then re-measure and continue if it now fits (§ 3.1) | `CROSS_PREFLIGHT_TRIM=0`, `FORCE_LOW_DISK=1` |
| A stage fails while disk is nearly full, and the salvage then writes GBs more | S1 salvage re-drives up to 15 named media targets, exporting cache for stages that get rebuilt anyway (D5) | skip the salvage, with a warning naming the free space and the threshold (§ 3.1) | `SALVAGE_MIN_FREE_GB` (`0` = always salvage), `SALVAGE_CACHE_EXPORT=0` |
| Sessions die after 1–2 h of parallel load | BKD1 (buildkitd session rot) | — | restart buildkitd between rounds; cachemounts provably survive |

**The rule any new cache tier has to obey:** it must be *droppable on the flake
path*. The auto-recovery works by removing argument pairs from `build_cmd`
before the retry; a tier that is not in that case statement keeps hammering a
registry that is already timing out.

### 3.1 Preflight trim (D4) and the salvage disk gate (D5)

Both landed 2026-08-31, after the r3 disk emergency forced a controlled chain
stop at 19 G free.

**Preflight trim.** `_chain_disk_preflight` used to *print* `rm -rf
${bc_dir}/*` and abort, leaving the reclaim to a human. It now calls
`_disk_guard_trim_cache_export` (`01-core/disk-guard.sh`) first:

* target = the same `need_gb` the preflight already computes;
* budget = `need_gb - free_gb`, i.e. **the deficit only** — the loop stops the
  moment either the target or the budget is reached, so it trims instead of
  emptying the directory. Without that bound a second process eating disk would
  turn the trim into `rm -rf` of every slug;
* victims come from `_disk_guard_pick_victim`, so removal is strictly
  oldest-mtime-first and honours a protected list (the preflight passes none —
  nothing has run yet, and protecting every upcoming stage would protect
  everything);
* every removal is logged with its size, plus a `removed N slug(s), freed X
  GiB` summary and the resulting free space. A silent reclaim is how people
  stop trusting a tool.

Then free space is re-measured. If it now clears `need_gb` the chain proceeds;
otherwise the old hint-and-abort path runs unchanged. `CROSS_PREFLIGHT_TRIM=0`
skips the trim entirely and restores the pre-2026-08-31 behaviour.

**Why this is safe.** T2 is a *cache export*, not the buildkit store. Losing a
slug costs export reuse for that stage and nothing else — no ccache, no
sccache, no cachemount. The trim only ever `rm -rf`s directories directly under
`BUILDKIT_CACHE_DIR`; it never invokes `buildctl prune`, `nerdctl builder
prune` or `nerdctl system prune`. The sanctioned buildkit-store reclaim remains
`linux/host-config/prune-safe.sh`.

**Salvage disk gate.** `_cross_salvage_disk_ok` gates the S1 salvage on free
space: below `SALVAGE_MIN_FREE_GB` (default `CROSS_DISK_GUARD_GB`, i.e. 40 G)
the salvage is skipped and says so, because those stages are rebuilt anyway and
the export is the last thing that should run when disk is scarce. Unknown free
space, a non-numeric threshold, or `SALVAGE_MIN_FREE_GB=0` all keep the old
always-salvage behaviour; `SALVAGE_CACHE_EXPORT=0` still disables it outright.

Unit coverage: `linux/scripts/tests/test-disk-guard.sh` (oldest-first order,
budget respected, no-op when ample, protected slugs, never aborts under
`set -euo pipefail`) and `linux/scripts/tests/test-cache-salvage-gate.sh`.

---

---

## 4. S3 — per-stage registry cache refs (`mode=max`)

### 4.1 What it would buy

Exactly the gap in § 2: intermediate stage layers, off-host, surviving a store
wipe. Had it been in place on 2026-08-21 the relaunch would have been a
fast-forward instead of ~18 h.

### 4.2 What it costs — measured, not estimated

The local `mode=max` exports are *the same content* a registry `mode=max` ref
would hold, in the same compressed form, so the disk sizes are a direct proxy
for the bytes on the wire (± the export compression setting).

Measured on this host, 2026-08-23 (`du -sh ~/.cache/kata-buildcache/*`):

| slug | size |
|---|---|
| `cross-media-amd64` | 52 G |
| `cross-media-arm64` | 49 G |
| `cross-media-riscv64` | 34 G |
| `cross-android-amd64` | 27 G |
| `cross-android-arm64` | 26 G |
| `cross-android-riscv64` | 24 G |
| **total** | **209 G** |

The measured uplink is **~4–5 MB/s** (the PUSH1 note at
`cross-stage-build.sh:126-132`; PUSH1 also measured a media *image* push at
~10 min with zstd, i.e. ~2.7 GB of new layers).

At 4.5 MB/s:

| what | bytes | added push time |
|---|---|---|
| one media arch | ~50 G | **~3.1 h** |
| all three media arches | 135 G | ~8.5 h |
| all three android arches | 77 G | ~4.9 h |
| everything | 212 G | **~12–13.5 h per chain run** |

**Verdict: a blanket per-stage `mode=max` export to ghcr is net negative here
by roughly an order of magnitude.** It would add ~12 h to *every* chain run to
insure against an ~18 h loss that has happened twice in a fortnight. On a
100 Mbit uplink the same design would be obviously correct — the numbers, not
the idea, are what disqualify it. Re-run the table above before re-opening S3
if the uplink ever changes.

Secondary costs, for completeness:

- **Registry storage.** `ghcr-cleanup.yml` keeps 3 versions *per tag*, so 11
  stage tags × 3 generations of cache is up to ~600 G of cache blobs retained.
  Its referential-integrity pass (added 2026-08-11) resolves kept tags'
  manifests, so it will not orphan a live cache ref — but the package listing
  doubles in size.
- **Failure surface.** A cache export that 400s fails the stage outright
  (§ 3), and it does so *after* the image already pushed.

### 4.3 Where it *does* pay: the cheap shared stages

The value ratio is `recompute_time / push_time`, and it inverts by stage:

| stage | cache size | push at 4.5 MB/s | cold recompute | verdict |
|---|---|---|---|---|
| `compiler` (GCC + LLVM) | not currently on disk; the archive recorded 12 G-class `sdk` slugs | ~45–60 min for a 12–16 G cache | LLVM alone was ~50 min *warm* and projected 11 h cold (PAR4 note, CHANGELOG 2026-08-21) | **plausible** — and it is built once, not per arch |
| `sdk` | ~12 G (archive) | ~45 min | ~1 h class | marginal |
| `media`, `android` | 24–52 G per arch | 1.5–3.3 h per arch | 1.5–2 h per framework | **no** |

Read that table with the right arithmetic: the push cost is paid on **every
run**, the recompute saving only on the **rare** run that starts with the local
tiers gone. For media the premium is ~3 h per arch per run against a payout of
roughly one cold media rebuild (~6 h per arch, from the 18 h / 3 arches figure)
— it only breaks even if the local tier is lost more often than every other
run. It is not; it has been lost twice in a fortnight.

So if S3 is implemented at all, it is implemented **for `compiler` (and maybe
`sdk`) only**, never chain-wide.

### 4.4 The shape that dodges the cost entirely

A re-drive of an identical build is a pure cache-hit solve — S1 salvage already
depends on that property and it is proven in production. Therefore the cache
**export does not have to sit on the build's critical path**:

> After a green chain, re-drive the stage you want insured with the registry
> cache export configured. Every vertex hits, nothing recompiles, and
> the multi-hour upload happens in a window you chose, can interrupt, and whose
> failure cannot kill a build that already succeeded.

That is the recommended S3 shape: an out-of-band, opt-in "cache snapshot" pass,
not a flag on every stage build. It also composes with the flake recovery for
free, because it is not on the retry path at all.

Cheaper still, and worth doing first because it costs zero bytes:

1. **Fix the preflight hint.** `build-cross-chain.sh:467` tells the operator to
   `rm -rf ${bc_dir}/*` to reclaim space, describing T2 as "regenerable" — it
   is, at ~18 h. The hint should point at the LRU path (the disk guard's own
   ordering, or `prune-safe.sh`), not at the wholesale delete of the only tier
   that holds intermediates. *(Filed, not fixed here: that file is outside
   this change's scope.)*
2. **Never `nerdctl system prune`** — Standing rule 3, already sharpened.

### 4.5 The pilot knob, and the rules it must obey

`CROSS_REGISTRY_CACHE=max` is **DESIGN ONLY** — read the STATUS banner at the
top. It was written so the experiment above could be run **without editing
code mid-wave**, and it was reverted along with the rest of S3;
`grep -rn CROSS_REGISTRY_CACHE` over the tree matches these docs and nothing
else, so setting it today is a silent no-op. What follows is the shape a
re-implementation has to take. In the reverted version it was off by default
and the default path was byte-identical to what shipped before it existed
(verified by dry-running the old and new function side by side and diffing the
assembled command) — keep that property.

When set to `max` the stage would additionally get:

```
--cache-from type=registry,ref=<tag>-buildcache
--cache-to   type=registry,ref=<tag>-buildcache,mode=max,image-manifest=true,oci-mediatypes=true
```

`image-manifest=true,oci-mediatypes=true` is there because the cache is then
exported as a plain OCI image manifest rather than the index shape that
motivated the original ghcr 400. **That is a hypothesis this repo has not yet
tested** — proving or disproving it is the first job of the pilot.

Rules the reverted implementation satisfied, and that any future one must keep:

- **It composes with the flake auto-recovery.** The DeadlineExceeded/
  `httpReadSeeker` handler must strip `--cache-to type=registry*` alongside the
  registry cache-from and the inline cache-to, so two import flakes still
  degrade the build to local-only instead of leaving a multi-GB export pointed
  at a registry that is timing out. The reverted implementation was verified by
  driving the real `_cross_stage_build_impl` through four failing attempts:
  attempts 1–2 carried all four registry/inline arguments, attempts 3–4 only
  the local `--cache-to`. **The handler that ships today strips only
  `--cache-from type=registry*` and `--cache-to type=inline*`
  (`cross-stage-build.sh:275-291`)** — because there is no registry export left
  to strip. Re-adding one means re-adding its case arm.
- **`NO_CACHE_EXPORT=1` still turns everything registry-facing off**, because
  the knob lived inside that guard.
- **A missing `-buildcache` ref on the first run is a miss, not a fatal.**
  In-repo evidence: `195285f`'s post-mortem of the never-written `-buildcache`
  ref — the importer failed and the stages rebuilt, the solve continued.

**Pilot protocol** (do not skip a step; this is the item that has burned this
repo before):

1. Pick `compiler`, and use `build-cross-stage.sh` — **not** a full chain. A
   cache-export 400 is non-transient and will fail the stage.
2. Run 1 (cold ref): re-implement the knob, then set
   `CROSS_REGISTRY_CACHE=max`. Confirm the build *accepts*
   the flags (nerdctl/buildkit here must support `image-manifest`), that the
   `-buildcache` ref appears in the ghcr package list, and record the wall time
   the export added.
3. Run 2 (warm): same command. Confirm the cache-from actually resolves and the
   solve reports cache hits for intermediate vertices, not just final layers.
4. Run 3 (the real test): move the local slug aside (`mv`, do not delete) and
   re-run. If the intermediates still fast-forward, T4 works and S3 is proven
   for that stage. If they do not, the tier bought nothing and the item closes.
5. Only after 3 green runs, and only for the stages in the § 4.3 "plausible"
   row, consider making it a default.

In the reverted implementation, revert was `CROSS_REGISTRY_CACHE=inline` — or
unsetting it, or `NO_CACHE_EXPORT=1`; any value other than the literal `max`
gave exactly the shipped behaviour, and nothing else in the chain read it. That
is the property to preserve in a re-implementation, not a knob to reach for
today.

---

## 5. SCC1 — the ccache/sccache hybrid

### 5.1 The division of labour — REVERSED 2026-08-26

> **This section previously read "ccache owns C/C++, sccache owns rustc + the
> GPU compilers … a full switch to sccache was rejected by the owner on
> 2026-08-17". The owner reversed that on 2026-08-26 and the C/C++ switch is
> implemented and built (5d94a37, c42091e, d5bafe8).** The old text is kept
> nowhere but in git history, because a design doc that states a superseded
> decision reads authoritative and gets followed.

**sccache is the C/C++ compiler cache. ccache is the automatic fallback.**
There is no per-language split any more, and every site resolves through ONE
resolver: `compiler_cache_launcher()` (`01-core/common.sh:443-467`) direct
from the 02-toolchain GCC/LLVM builds and the CMake/onnxruntime/wheelhouse
call sites, and via `_resolve_compiler_cache_launcher()` on the media lane
(`01-core/compiler-cache.sh:36-93` — the single seam that forwards to the
common.sh resolver when 01-core is loaded, 2026-08-30 backlog F2). Either
way: the guarded launcher if sccache's server answers, else ccache, else
build uncached.

It is never *bare* sccache in a stage that mounts `01-core`: each site starts
at `sccache` and upgrades to `sccache-launcher.sh` as soon as one is
executable, keeping the bare name only where the helper is absent
(`common.sh:451-458`, `compiler-cache.sh:84-87`). The gate at
`verify-critical-fixes.sh:220-231` is what stops the *hardcoded* bare form
coming back — that is how the first cut shipped inert.

All three load-bearing points of the old rationale still hold — the last one
only after a detour through the config file:

- **Still true:** ccache cannot wrap `rustc`, `nvcc` or `hipcc`; sccache can.
- **Still true, and now the operating constraint:** sccache HARD-FAILS where
  ccache simply execs the compiler. That is not limited to unidentifiable
  compilers, and it bit hard during the switch:

  > **The TryCompile trap (root cause, 2026-08-26).** CMake creates a
  > `CMakeScratch/TryCompile-XXXX` directory, compiles a probe in it, and
  > DELETES it. sccache then spawns the compiler with that directory as the
  > working directory — and spawning a process whose cwd no longer exists fails
  > with `ENOENT`. Measured directly: spawning `/bin/true` with `cwd` set to a
  > removed directory returns errno 2, exactly what sccache reports. The same
  > trap in preprocessor-cache mode surfaces earlier, as
  > `while hashing the input file`, because that mode re-reads the source after
  > the compile.
  >
  > It killed the media stage three times, MOVING between OpenCV, onnxruntime
  > and litert depending on which probe lost the race — and it does not
  > reproduce against directories that persist. Nine isolated attempts came
  > back clean before the pattern was read correctly.

  The answer is `01-core/sccache-launcher.sh`: sccache runs for every compile,
  and only its OWN fatal errors ("sccache: encountered fatal error") fall
  through to running the compiler directly. A real compile error is passed
  through untouched — retrying blindly would hide genuine failures. In the run
  that proved it, the guard fired 1451 times with ZERO build aborts.

  ccache stays installed and mounted as the deeper fallback, and
  `probe-sccache.sh` exists — it asserts, per compiler SHAPE this chain feeds a
  launcher, that the compile survives AND that cache activity was recorded.
- **True again, and on purpose:** "sccache's C/C++ path always preprocesses".
  The base image *does* bake `use_preprocessor_cache_mode = true` plus
  `file_stat_matches` / `use_ctime_for_stat` into `/etc/sccache/config.toml`
  (`Dockerfile.base:118-130`, reached via `SCCACHE_CONF`, `:90`) — those knobs
  have NO environment-variable path in sccache, which is why the config file
  exists at all. But the runtime turns the mode back off: both entry points
  export `SCCACHE_DIRECT=false` (`01-core/common.sh:404-418`,
  `01-core/compiler-cache.sh:119`), and the environment variable wins over
  the config file. That is the TryCompile trap seen from the other end —
  preprocessor-cache mode re-reads the INPUT FILE *after* the compile in order
  to store the entry, so a deleted scratch dir surfaces as `while hashing the
  input file` and is fatal. It killed OpenCV's compiler test, then
  onnxruntime's, three times running. **Effective state today:
  preprocessor-cache mode is OFF and every TU is preprocessed.** The cost is
  hit rate, not correctness; set `SCCACHE_DIRECT=true` to re-test it once the
  ephemeral-dir interaction is understood. `ignore_time_macros` stays **false**
  on purpose: ccache's sloppiness list included it, but that trades correctness
  for hit rate and this chain ships compilers.

Two knobs have no counterpart and must not be looked for: there is no
`sccache -M` (the cap is `SCCACHE_CACHE_SIZE`), and `CCACHE_COMPILERCHECK=content`
needs none — sccache does not key on mtime+size the way ccache does by default,
so the invalidation that setting prevents does not arise.

**Rust rejoined this on 2026-08-27; nvcc did not.** The hard clear that used to
sit in `build-gstreamer-monorepo.sh` is gone. `RUSTC_WRAPPER` resolves to the
same guarded launcher from two places: `setup_sccache` exports it
(`01-core/compiler-cache.sh:156-195`), and `build_gstreamer_monorepo` installs
it for any process where the variable was never set at all
(`build-gstreamer-monorepo.sh:581-590`). What made that safe is the UDS fix in
§ 5.4 (`compiler-cache.sh:69-79`, `common.sh:394-403`), not optimism — the
deaths at 99 % were the *wrong server* answering, and the launcher is the
second belt that turns a remaining sccache hiccup into lost hits instead of a
lost build. To go back to uncached Rust, export
`RUSTC_WRAPPER=""`; that is what `Dockerfile.toolchain:58` and
`Dockerfile.package:173` do, and it holds for every stage that never calls
`setup_sccache`. Where `setup_sccache` *does* run it overwrites the empty value
(`compiler-cache.sh:182`), so the off switch on that lane is `USE_SCCACHE=0` —
which also drops C/C++ back to ccache (`compiler-cache.sh:123-129`). nvcc and hipcc
stay untouched (§ 5.4), and the Windows lane records that released sccache
breaks the build around them.

### 5.2 Does the current setup double-cache or fight ccache? No — verified

The precedence is explicit and correct:

- `setup_ccache` (`01-core/compiler-cache.sh:95-155`) sets
  `CMAKE_C/CXX_COMPILER_LAUNCHER` to the **guarded launcher**
  (`01-core/sccache-launcher.sh`, resolved via `_resolve_compiler_cache_launcher`, `:84-87`) when `USE_SCCACHE` is
  not disabled, sccache is on `PATH`, and its server answers `--show-stats`;
  otherwise it falls back to **ccache** and says why. (Before 2026-08-26 it set
  ccache unconditionally. Its first cut at the switch hardcoded *bare*
  `sccache` here, which shipped inert; `verify-critical-fixes.sh:222-241` now
  fails any launcher in this file pointed at bare sccache.)
- `setup_sccache` (`:208-255`) sets those two launchers **only if they are
  empty** (`:245`), and otherwise touches only `RUSTC_WRAPPER` (`:242`) —
  resolved the same way (`:238-241`): the guarded launcher where it is mounted,
  bare `sccache` only where it is not.
- `media_common_init` (`03-media/core/common.sh:134-149`) always runs
  `setup_ccache` **first**, then `setup_sccache` only under
  `ENABLE_SCCACHE_RUST=1`.

So on the media lane there is exactly one C/C++ launcher, and it is the guarded
sccache launcher; ccache is used only when sccache's server does not answer.
The LLVM cross build picks the same way round
(`02-toolchain/llvm-cross.sh:202-207`, commented "preference INVERTED": it asks
`compiler_cache_launcher` (`01-core/common.sh:443-467`), i.e. sccache first,
ccache only as the fallback).

The cache **mounts** do not collide either: `/var/cache/ccache` and
`/var/cache/sccache` are separate ids. Their `${TARGETARCH}` (not
`${TARGET_ARCH}`) suffix is deliberate and documented at
`Dockerfile.media:26-31` — they are unlocked and content-addressed, so a lane
collision is free while splitting them would triple the cold compile. **Do not
"align" those ids with the apt ones.**

### 5.3 Three things that are not what the comments claim

Found while reading for this document; all filed, none fixed here (the files
are outside this change's scope):

1. **The `ENABLE_SCCACHE_RUST` gate is not the single control point it says it
   is — and since 2026-08-27 it barely controls anything.**
   `setup-gstreamer.sh:50` calls `setup_sccache` **unconditionally**, and
   `USE_SCCACHE` defaults to `true` (`compiler-cache.sh:19`, `Dockerfile.media`
   `ARG USE_SCCACHE=true`). So in that process `RUSTC_WRAPPER` is exported even
   with `ENABLE_SCCACHE_RUST=0`, and an sccache server is started. The
   counterweight used to be an explicit `export RUSTC_WRAPPER=""` inside
   `build_gstreamer_monorepo`; it is gone. That block is now the opposite — it
   *installs* the guarded launcher when `RUSTC_WRAPPER` is unset
   (`build-gstreamer-monorepo.sh:579-591`, sourced into the same process at
   `setup-gstreamer.sh:559-563` and only *called* at `:640`). The monorepo's
   Rust is therefore cached deliberately, and the gate does not gate it.
   What the gate still decides is one thing: `media_common_init` runs
   `setup_sccache` only under `ENABLE_SCCACHE_RUST=1`
   (`03-media/core/common.sh:144-149`), and that is the path
   `install-rice-proto.sh`'s `cargo cinstall` takes — a *different* process
   (`build-gstreamer-stage.sh:112`, before `setup-gstreamer.sh` is invoked at
   `:144`), which therefore still inherits the image's `RUSTC_WRAPPER=""`
   (`Dockerfile.toolchain:58`) and builds uncached. Between `:50` and `:640`
   the only cargo touch is `cargo --version` (`:447`). So the knob's name
   promises the monorepo and delivers rice-proto; read the two together before
   trusting either.
2. **A dead parameter.** `source_build_acceleration_helpers` takes
   `include_sccache` (`03-media/build/onnxruntime/build/lib/common.sh:193-213`),
   but all three call sites (`30-build-native.sh:7`, `-amd.sh:11`,
   `-nvidia.sh:26`) pass nothing, so the `true` branch has never run.
3. **`USE_CCACHE=false` does not disable compile caching — it migrates C/C++ to
   sccache.** With ccache off (or simply absent from `PATH`), `setup_ccache`
   returns early leaving the launchers unset, and any later `setup_sccache`
   fills them (`compiler-cache.sh:156-195`). There is no log line that
   distinguishes "ccache disabled" from "sccache silently took over C/C++".

### 5.4 Where sccache is actually worth it

| target | gate | state | recommendation |
|---|---|---|---|
| **rustc** (gst-plugins-rs, the monorepo's Rust) | none any more — `ENABLE_SCCACHE_RUST=1` only reaches `media_common_init` (§ 5.3 item 1) | **ON by default since 2026-08-27**, through the guarded launcher (`compiler-cache.sh:156-195`, `build-gstreamer-monorepo.sh:581-590`) | [details](#rustc-gst-plugins-rs-the-monorepos-rust) |
| **nvcc / hipcc** | `ENABLE_SCCACHE_CUDA=1` (one gate, three sites: `build-opencv.sh:558`, `30-build-native-nvidia.sh:195`, `30-build-native-amd.sh:65`) | wiring exists, default OFF | [details](#nvcc--hipcc) |
| **C/C++** | — | sccache via the guarded launcher, always on; ccache is the automatic fallback | leave it — this is the owner-directed default since 2026-08-26 (§ 5.1), and both launcher resolvers already pick sccache first (§ 5.2). |
| **cross-machine tier** (`SCCACHE_MULTILEVEL_CHAIN`, webdav L2) | — | Windows lane only | [details](#cross-machine-tier-sccache_multilevel_chain-webdav-l2) |

### Per-target detail

The targets whose recommendation needs more than a table cell.

#### **rustc** (gst-plugins-rs, the monorepo's Rust)

**The one genuine win — and it was taken on 2026-08-27.** It is also the one that broke: sccache's server died mid-compile in three separate rounds ("Failed to send/receive data from server", "No such file or directory" on trivial crates), each time killing an otherwise-green gstreamer build at 99 %. That signature was root-caused on 2026-08-26 and it was never about Rust: the server is located by a fixed TCP port, which is not container-local, so concurrent BuildKit steps reached each *other's* server — one that cannot see their files. `SCCACHE_SERVER_UDS` took the media stage from 2359 sccache faults to zero, so Rust caching came back, pointed at the guarded launcher rather than bare sccache (`build-gstreamer-monorepo.sh:579-591`); a server hiccup now costs hits, not a build at 99 %. The preconditions this section used to prescribe are already unconditional in code: `SCCACHE_IDLE_TIMEOUT=0` (`compiler-cache.sh:116`, `common.sh:375` — the Windows-lane forensics traced all-zero end-of-vertex stats to the server idle-exiting at 600 s), `SCCACHE_ERROR_LOG` (`compiler-cache.sh:122`, `common.sh:419`), and `sccache --show-stats` printed **to stderr**, the stream buildkit's 2 MiB step-log clip never cuts. **What is still open is the measurement:** two consecutive green cross-arch media runs with a non-zero *Rust* hit rate. Until those are on the board the re-enable is shipped but unproven — judge it by the stats line, not by the flag (§ 7).

#### **nvcc / hipcc**

**Do not flip on the strength of the hit-rate argument alone.** The theoretical win is large (`CUDA_ARCHITECTURES` compiles each kernel 4×) but a sibling lane produced an evidence-backed verdict that the pinned sccache's **nvcc decomposition silently drops device-conditional code** — a byte-identical link failure across two runs, falsified as cache poisoning, i.e. *silent wrong code*, disqualifying regardless of hit rate (CHANGELOG 2026-08-10/11). Any re-enable needs the three-canary bar recorded there: verify probe + a real kernel compile + a full link canary, on the sccache version actually installed.

#### **cross-machine tier** (`SCCACHE_MULTILEVEL_CHAIN`, webdav L2)

Out of scope for this document. Note only that the mechanism is real and version-gated: on an older sccache the chain variable is **ignored silently**, which is exactly the failure shape this repo keeps eliminating — so it would need a pinned sccache and a hit-rate assertion before it could be considered on the Linux lane.

### 5.5 The one-line answer to "does sccache fight ccache?"

No — but the *gates* still lie about who is on. The honest summary is: C/C++
runs through the guarded sccache launcher everywhere, with ccache as the
automatic fallback for a server that will not answer; Rust runs through that
same guarded launcher since 2026-08-27, which `ENABLE_SCCACHE_RUST=0` does not
stop (§ 5.3 item 1); only the GPU compilers are uncached, and that is a
correctness verdict, not an oversight. Any change to that should be a
measurement, not a default flip.

---

## 6. Knob reference

| Knob | Default | Effect |
|---|---|---|
| `NO_CACHE=1` | unset | `--no-cache`; also disables T2 and T3 entirely |
| `RUNTIME_NO_CACHE=1` | unset | `--no-cache` on just the runtime package + wrapper builds |
| `NO_CACHE_EXPORT=1` | unset | drops everything registry-facing (T3, and T4 when enabled); keeps T2 |
| `CROSS_NO_LOCAL_CACHE_EXPORT=1` | unset (set by the disk guard) | stop *writing* T2; still read it |
| `SALVAGE_CACHE_EXPORT=0` | `1` | disable the per-`--target` salvage re-drive after a failed stage |
| `SALVAGE_TARGET_TIMEOUT` | `600` | per-target timeout for that salvage pass |
| `CROSS_DISK_GUARD_GB` | `40` | free-space floor that triggers T2 LRU pruning (`0` disables) |
| `CROSS_CACHE_MAX_GB` | `250` | total T2 size cap (`0` disables) |
| `CROSS_PREFLIGHT_TRIM=0` | unset (trim on) | skip the disk-preflight trim of T2 (§ 3.1) |
| `SALVAGE_MIN_FREE_GB` | `CROSS_DISK_GUARD_GB` (40) | free-space floor below which the S1 salvage is skipped (`0` = always salvage) |
| `BUILDKIT_CACHE_DIR` | `~/.cache/kata-buildcache` | where T2 lives |
| `PUSH_MAX_ATTEMPTS` / `PUSH_RETRY_BASE_SECS` | `4` / `15` | transient-push retry budget |
| `ENABLE_SCCACHE_RUST` | `0` | **not** the monorepo's Rust switch any more — it only adds `setup_sccache` to `media_common_init`, i.e. it caches `install-rice-proto.sh`'s `cargo cinstall` (§ 5.3 item 1) |
| `ENABLE_SCCACHE_CUDA` | `0` | sccache as the CUDA/HIP compiler launcher (§ 5.4) |
| `USE_CCACHE` / `USE_SCCACHE` / `USE_LLD` | `true` | per-tool switches in `compiler-cache.sh`; note § 5.3 item 3 |

`CROSS_REGISTRY_CACHE` is deliberately **not** in this table. The T4 pilot knob
was written and reverted, nothing in `cross-stage-build.sh` reads it, and
listing it beside live knobs is how an operator ends up setting a no-op. § 4.5
keeps the design.

---

## 7. Do-not-repeat list

- Do not add a `--cache-from` whose matching `--cache-to` is gated off. That
  self-defeating pair made every stage rebuild from scratch until `195285f`.
- Do not add a cache tier that the DeadlineExceeded auto-recovery cannot strip.
- Do not "align" the ccache/sccache cache-mount ids with the apt ones
  (`Dockerfile.media:26-31`).
- Do not judge a cache change by whether the flags appear in the command. Judge
  it by bytes that did not move: cache hits on **intermediate** vertices, or a
  measured wall-clock delta. Two changes were reverted on 2026-08-23 for
  looking right and doing nothing.
