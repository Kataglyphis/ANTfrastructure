# Build cache tiers (Linux cross lane)

> **STATUS 2026-08-23: DESIGN ONLY — the code change was written, reviewed and
> REVERTED.** The first implementation reintroduced the literal
> `${tag}-buildcache` cache ref, which `verify-critical-fixes.sh` has forbidden
> since fix7 (2026-07) precisely because that ref was self-defeating; the
> preflight gate failed on it immediately. It was also inert by default and had
> no regression coverage, so a future "just turn it on" edit would have flipped
> ~12-13 GB of extra registry traffic per run with nothing asserting the
> behaviour. What follows is the design and the constraints any implementation
> must satisfy — read the flake-recovery interaction below before writing code.


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
| T2 | local stage cache export | `cross-stage-build.sh:178-188` (`--cache-to type=local,…,mode=max`) | **every** vertex of that stage's Dockerfile | `~/.cache/kata-buildcache/<tag-slug>/` — *outside* the buildkit store | our own disk guard (LRU below `CROSS_DISK_GUARD_GB`=40 G free, plus the `CROSS_CACHE_MAX_GB`=250 G total cap, `build-cross-chain.sh:513-562`); the disk-preflight's `rm -rf` hint (`build-cross-chain.sh:467`); `CROSS_NO_LOCAL_CACHE_EXPORT=1` stops new writes |
| T3 | inline registry cache | `cross-stage-build.sh:194-198` (`--cache-to type=inline` + `--cache-from type=registry,ref=<tag>`) | **only the final image's own layers** (`mode=min`) | inside the pushed image config — no separate blob, so no ghcr 400 | `ghcr-cleanup.yml` (keeps 3 versions per tag, 14-day floor) |
| T4 | per-stage registry cache, `mode=max` | **not enabled** — pilot knob `CROSS_REGISTRY_CACHE=max`, `cross-stage-build.sh:30` + `:199-234` | every vertex, off-host | a `<tag>-buildcache` ref on ghcr | see § 4 — the cost, not the mechanism, is the blocker |

Two properties are worth internalising because they are counter-intuitive:

- **T2 is not in the buildkit store.** `nerdctl system prune` does not touch
  `~/.cache/kata-buildcache`. The things that empty it are *ours*: the disk
  guard and the preflight hint.
- **T0/T1 are in the same store**, so the one command that wipes layers also
  wipes the compiler caches. That is why Standing rule 3 exists.

---

## 2. The blind spot: what `type=inline` cannot carry

`--cache-to type=inline` is `mode=min`. It records cache keys for the layers
that end up **in the exported image** and nothing else.

The media stage's expensive work is not in those layers. `Dockerfile.media`
builds onnxruntime / litert / tvm / opencv / app-wheelhouse / armnn / ffmpeg /
gstreamer / opencv-gst as **named intermediate stages** (`FROM base AS …`,
`:248-914`) and lifts the results out with `COPY --link --from=…`
(`:705-712`, `:950-974`). The layers those COPYs produce are in the image; the
RUN vertices that *built* them are not, and a `mode=min` export carries no
cache record for them. So:

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
| `DeadlineExceeded: failed to compute cache key: … httpReadSeeker … no active session` | ghcr cache **import** flake (killed 6 attempts across 2 lanes in one afternoon, 2026-08-18) | retry; after **2** such failures drop the registry cache-from + inline cache-to and finish on the local tier (`cross-stage-build.sh:309-341`) | `NO_CACHE_EXPORT=1` does the same thing up front |
| `error writing layer blob: 400 Bad Request` on cache push | ghcr rejecting an oversized `mode=max` cache blob (why T4 was removed in `4f27634`; `195285f` replaced it with T2+T3) | **nothing** — 400 is not in the transient class (`_cross_stage_push_error_is_transient`), so the stage fails | `NO_CACHE_EXPORT=1` |
| A stage fails after hours of completed work → T2 exports **nothing** | `--cache-to type=local` only materialises on a successful solve (~8 h of arm64 media work exported ZERO once) | S1 salvage: re-drive the same build per named `--target`, each a pure cache hit, so the export lands anyway (`cross-stage-build.sh:273-304`) | `SALVAGE_CACHE_EXPORT=0` |
| Disk below 40 G between stages | T2 growth (209 G measured today) | LRU-prune unprotected slugs; stages still to run in **this** chain are protected; if still short, stop writing new exports | `CROSS_DISK_GUARD_GB`, `CROSS_CACHE_MAX_GB`, `CROSS_NO_LOCAL_CACHE_EXPORT=1` |
| `could not read …/kata-buildcache/…` | empty slug dir, i.e. a clean miss | suppressed: cache-from is only added when `index.json` is non-empty (`cross-stage-build.sh:176-180`) | — |
| Sessions die after 1–2 h of parallel load | BKD1 (buildkitd session rot) | — | restart buildkitd between rounds; cachemounts provably survive |

**The rule any new cache tier has to obey:** it must be *droppable on the flake
path*. The auto-recovery works by removing argument pairs from `build_cmd`
before the retry; a tier that is not in that case statement keeps hammering a
registry that is already timing out.

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
`cross-stage-build.sh:133-139`; PUSH1 also measured a media *image* push at
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

### 4.5 The pilot knob, and the rules it obeys

`CROSS_REGISTRY_CACHE=max` (`cross-stage-build.sh:229-234`) exists so the
experiment above can be run **without editing code mid-wave**. It is off by
default and the default path is byte-identical to what shipped before it
existed (verified by dry-running the old and new function side by side and
diffing the assembled command).

When set to `max` the stage additionally gets:

```
--cache-from type=registry,ref=<tag>-buildcache
--cache-to   type=registry,ref=<tag>-buildcache,mode=max,image-manifest=true,oci-mediatypes=true
```

`image-manifest=true,oci-mediatypes=true` is there because the cache is then
exported as a plain OCI image manifest rather than the index shape that
motivated the original ghcr 400. **That is a hypothesis this repo has not yet
tested** — proving or disproving it is the first job of the pilot.

Rules the knob already satisfies, and that any future implementation must keep:

- **It composes with the flake auto-recovery.** The DeadlineExceeded/
  `httpReadSeeker` handler now strips `--cache-to type=registry*` alongside the
  registry cache-from and the inline cache-to, so two import flakes still
  degrade the build to local-only instead of leaving a multi-GB export pointed
  at a registry that is timing out. Verified by driving the real
  `_cross_stage_build_impl` through four failing attempts: attempts 1–2 carry
  all four registry/inline arguments, attempts 3–4 carry only the local
  `--cache-to`.
- **`NO_CACHE_EXPORT=1` still turns everything registry-facing off**, because
  the knob lives inside that guard.
- **A missing `-buildcache` ref on the first run is a miss, not a fatal.**
  In-repo evidence: `195285f`'s post-mortem of the never-written `-buildcache`
  ref — the importer failed and the stages rebuilt, the solve continued.

**Pilot protocol** (do not skip a step; this is the item that has burned this
repo before):

1. Pick `compiler`, and use `build-cross-stage.sh` — **not** a full chain. A
   cache-export 400 is non-transient and will fail the stage.
2. Run 1 (cold ref): `CROSS_REGISTRY_CACHE=max`. Confirm the build *accepts*
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

Revert is `CROSS_REGISTRY_CACHE=inline` — or unsetting it, or
`NO_CACHE_EXPORT=1`; any value other than the literal `max` gives exactly the
shipped behaviour. Nothing else in the chain reads it.

---

## 5. SCC1 — the ccache/sccache hybrid

### 5.1 The division of labour, and why it is not negotiable

ccache cannot wrap `rustc`, `nvcc` device compiles, or `hipcc`; sccache can.
sccache's C/C++ path always preprocesses and silently declines to cache on
unsupported flags, where ccache's direct/depend mode hashes through an include
manifest. So the split is: **ccache owns C/C++, sccache owns rustc + the GPU
compilers, and neither is a replacement for the other.** A full switch to
sccache was rejected by the owner on 2026-08-17; this section is about *where
sccache is worth turning on*, not about replacing ccache.

### 5.2 Does the current setup double-cache or fight ccache? No — verified

The precedence is explicit and correct:

- `setup_ccache` (`01-core/compiler-cache.sh:77-120`) sets
  `CMAKE_C/CXX_COMPILER_LAUNCHER=ccache` unconditionally.
- `setup_sccache` (`:124-157`) sets those two launchers **only if they are
  empty** (`:147`), and otherwise touches only `RUSTC_WRAPPER`.
- `media_common_init` (`03-media/core/common.sh:134-149`) always runs
  `setup_ccache` **first**, then `setup_sccache` only under
  `ENABLE_SCCACHE_RUST=1`.

So on the media lane there is exactly one C/C++ launcher, and it is ccache.
The LLVM cross build picks the same way round (`02-toolchain/llvm-cross.sh:187-196`:
ccache if present, sccache only as a fallback).

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
   is.** `setup-gstreamer.sh:50` calls `setup_sccache` **unconditionally**, and
   `USE_SCCACHE` defaults to `true` (`compiler-cache.sh:35`, `Dockerfile.media`
   `ARG USE_SCCACHE=true`). So in that process `RUSTC_WRAPPER=sccache` is
   exported even with `ENABLE_SCCACHE_RUST=0`, and an sccache server is
   started. What actually saves the build is the explicit
   `export RUSTC_WRAPPER=""` inside `build_gstreamer_monorepo`
   (`build-gstreamer-monorepo.sh:673-681`, sourced into the same process at
   `setup-gstreamer.sh:557-563` and only *called* at `:640`) — the fix for the
   server that died at 99 % in three separate media rounds. Impact today is
   nil: between `:50` and `:640` the only cargo touch is `cargo --version`
   (`:447`), and the one real Rust build that precedes it, `install-rice-proto.sh`'s
   `cargo cinstall`, runs in a *different* process
   (`build-gstreamer-stage.sh:112`, before `setup-gstreamer.sh` is invoked at
   `:144`) and therefore inherits the image's `RUSTC_WRAPPER=""`
   (`Dockerfile.toolchain:58`). But the gate reads as OFF while the wrapper is
   ON, and the next `cargo` call added ahead of `build_gstreamer_monorepo`
   would silently inherit it.
2. **A dead parameter.** `source_build_acceleration_helpers` takes
   `include_sccache` (`03-media/build/onnxruntime/build/lib/common.sh:188-200`),
   but all three call sites (`30-build-native.sh:7`, `-amd.sh:11`,
   `-nvidia.sh:26`) pass nothing, so the `true` branch has never run.
3. **`USE_CCACHE=false` does not disable compile caching — it migrates C/C++ to
   sccache.** With ccache off (or simply absent from `PATH`), `setup_ccache`
   returns early leaving the launchers unset, and any later `setup_sccache`
   fills them (`compiler-cache.sh:147-150`). There is no log line that
   distinguishes "ccache disabled" from "sccache silently took over C/C++".

### 5.4 Where sccache is actually worth it

| target | gate | state | recommendation |
|---|---|---|---|
| **rustc** (gst-plugins-rs, the monorepo's Rust) | `ENABLE_SCCACHE_RUST=1` | wiring exists, default OFF; the wrapper is additionally hard-cleared for the monorepo build | [details](#rustc-gst-plugins-rs-the-monorepos-rust) |
| **nvcc / hipcc** | `ENABLE_SCCACHE_CUDA=1` (one gate, three sites: `build-opencv.sh:509`, `30-build-native-nvidia.sh:195`, `30-build-native-amd.sh:65`) | wiring exists, default OFF | [details](#nvcc--hipcc) |
| **C/C++** | — | ccache, always on | leave it. sccache's C/C++ path is strictly worse here (§ 5.1) and the launchers are already owned. |
| **cross-machine tier** (`SCCACHE_MULTILEVEL_CHAIN`, webdav L2) | — | Windows lane only | [details](#cross-machine-tier-sccache_multilevel_chain-webdav-l2) |

### Per-target detail

The targets whose recommendation needs more than a table cell.

#### **rustc** (gst-plugins-rs, the monorepo's Rust)

**The one genuine win.** It is also the one that broke: sccache's server died mid-compile in three separate rounds ("Failed to send/receive data from server", "No such file or directory" on trivial crates), each time killing an otherwise-green gstreamer build at 99 %. Re-enable only as a *measured* experiment: `ENABLE_SCCACHE_RUST=1` **plus** removing the hard clear at `build-gstreamer-monorepo.sh:681`, with `SCCACHE_IDLE_TIMEOUT=0` set (the Windows-lane forensics traced all-zero end-of-vertex stats to the server idle-exiting at 600 s), `SCCACHE_ERROR_LOG` captured, and `sccache --show-stats` printed **to stderr** — the stream buildkit's 2 MiB step-log clip never cuts. Bar to flip the default: two consecutive green cross-arch media runs with a non-zero hit rate.

#### **nvcc / hipcc**

**Do not flip on the strength of the hit-rate argument alone.** The theoretical win is large (`CUDA_ARCHITECTURES` compiles each kernel 4×) but a sibling lane produced an evidence-backed verdict that the pinned sccache's **nvcc decomposition silently drops device-conditional code** — a byte-identical link failure across two runs, falsified as cache poisoning, i.e. *silent wrong code*, disqualifying regardless of hit rate (CHANGELOG 2026-08-10/11). Any re-enable needs the three-canary bar recorded there: verify probe + a real kernel compile + a full link canary, on the sccache version actually installed.

#### **cross-machine tier** (`SCCACHE_MULTILEVEL_CHAIN`, webdav L2)

Out of scope for this document. Note only that the mechanism is real and version-gated: on an older sccache the chain variable is **ignored silently**, which is exactly the failure shape this repo keeps eliminating — so it would need a pinned sccache and a hit-rate assertion before it could be considered on the Linux lane.

### 5.5 The one-line answer to "does sccache fight ccache?"

No — but the *gates* lie about who is on. The honest summary is: C/C++ is
ccache everywhere; Rust is ccache-less and currently uncached by deliberate
choice; the GPU compilers are uncached by a correctness verdict, not by
oversight. Any change to that should be a measurement, not a default flip.

---

## 6. Knob reference

| Knob | Default | Effect |
|---|---|---|
| `NO_CACHE=1` | unset | `--no-cache`; also disables T2 and T3 entirely |
| `RUNTIME_NO_CACHE=1` | unset | `--no-cache` on just the runtime package + wrapper builds |
| `NO_CACHE_EXPORT=1` | unset | drops everything registry-facing (T3, and T4 when enabled); keeps T2 |
| `CROSS_NO_LOCAL_CACHE_EXPORT=1` | unset (set by the disk guard) | stop *writing* T2; still read it |
| `CROSS_REGISTRY_CACHE` | `inline` | `max` adds the T4 pilot pair — read § 4 first |
| `SALVAGE_CACHE_EXPORT=0` | `1` | disable the per-`--target` salvage re-drive after a failed stage |
| `SALVAGE_TARGET_TIMEOUT` | `600` | per-target timeout for that salvage pass |
| `CROSS_DISK_GUARD_GB` | `40` | free-space floor that triggers T2 LRU pruning (`0` disables) |
| `CROSS_CACHE_MAX_GB` | `250` | total T2 size cap (`0` disables) |
| `BUILDKIT_CACHE_DIR` | `~/.cache/kata-buildcache` | where T2 lives |
| `PUSH_MAX_ATTEMPTS` / `PUSH_RETRY_BASE_SECS` | `4` / `15` | transient-push retry budget |
| `ENABLE_SCCACHE_RUST` | `0` | sccache as `RUSTC_WRAPPER` on the media lane (§ 5.4) |
| `ENABLE_SCCACHE_CUDA` | `0` | sccache as the CUDA/HIP compiler launcher (§ 5.4) |
| `USE_CCACHE` / `USE_SCCACHE` / `USE_LLD` | `true` | per-tool switches in `compiler-cache.sh`; note § 5.3 item 3 |

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
