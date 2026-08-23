# Build parallelism & per-job memory calibration

**Audience:** anyone (human or AI agent) tempted to "speed up the build" by raising
job counts or lowering the per-job memory estimates in
`linux/scripts/01-core/parallelism.sh`.

**Read this first.** The per-job memory numbers look conservative but are
**calibrated to the host's RAM**. Lowering them the naive way OOM-kills a
multi-hour build. This doc explains the model, the one trap that makes it
counter-intuitive, and how to tune it *safely* with data.

---

## TL;DR — the one rule

Every memory-capped stage obeys **one** formula:

```
jobs = min( cores ,  usable_RAM / BUILD_MEM_DIVISOR / PEAK_per-TU_RAM )
```

The config knob is `mb_per_job`, which **is** `PEAK_per-TU_RAM`.

- Lowering `mb_per_job` **raises** `jobs` → faster **only if** RAM allows it.
- If `jobs × PEAK` exceeds RAM, `cc1plus` gets **OOM-killed** and the build dies.
- `BUILD_MEM_DIVISOR` (default 1) is the **only** concurrency knob: set it to the
  number of builds sharing the host RAM at once (see *Max speed* below).

**Tune against the PEAK per-TU footprint, never the average.** See the trap below.

---

## The helpers (`linux/scripts/01-core/parallelism.sh`)

All logic lives in **one** core function; the named helpers just pick a profile:

```
mem_capped_jobs <peak_mb> [requested]        # the core: jobs = min(cores, usable/peak)
```

| Named wrapper | Profile / used for | peak (normal) | peak (aggressive) |
|---|---|---|---|
| `compute_jobs` | pure CPU-bound, no mem cap | — (just `cores`) | — |
| `compute_jobs_with_mem_cap` | `generic` — C/C++ (OpenCV, ONNX, …) | `DEFAULT_MB_PER_JOB:-2000` | `DEFAULT_MB_PER_JOB:-800` |
| `compute_rust_jobs` | `rust` — Cargo (gst-plugins-rs) | `RUST_MB_PER_JOB:-2500` | `RUST_MB_PER_JOB:-1200` |
| `compute_cpp_heavy_jobs` | `heavy` — **PyTorch / torch_cpu / LTO** | `CPP_HEAVY_MB_PER_JOB:-4096` | `4096` (floor kept) |

Peak values come from `_profile_mb <profile>`; the wrappers are one-liners over
`mem_capped_jobs`. Where:
- `cores` = `detect_available_cores()` (respects cgroup CPU quota).
- `usable_RAM` = `_usable_mem_mb()` = `_mem_available_mb()` (`MemAvailable`, or the
  cgroup memory limit remaining — smaller wins) **divided by `BUILD_MEM_DIVISOR`**.

Each workload gets a *different* estimate because its **peak translation unit**
is different — torch's `aten/autograd` TUs peak ~4 GB per `cc1plus`, while a
typical OpenCV TU is a few hundred MB.

### `AGGRESSIVE_PARALLELISM` auto-enables at ≥ 16 GB RAM

`_auto_aggressive_parallelism()` sets `AGGRESSIVE_PARALLELISM=true` automatically
when `usable_RAM ≥ 16 GB` (unless you export it `false`). In aggressive mode the
**generic** and **rust** estimates drop (2000→800, 2500→1200), so on any
real-size host those stages run at **full core count** — they are *not*
RAM-capped and have **no headroom to reclaim**.

**`compute_cpp_heavy_jobs` deliberately ignores aggressive mode** and keeps the
4 GB floor: torch TUs do not get cheaper on a big host, so the only thing more
RAM buys is *more of them at once* — which the `usable_RAM / mb_per_job` formula
already grants automatically.

### Override knobs

| Env var | Effect |
|---|---|
| `PARALLEL_JOBS=N` | Hard override — bypasses all auto-detection for every helper. |
| `AGGRESSIVE_PARALLELISM=true\|false` | Force aggressive on/off (auto ≥16 GB). |
| `BUILD_MEM_DIVISOR=N` | Divide usable RAM by N. Set = #concurrent builds. **See *Max speed*.** |
| `DEFAULT_MB_PER_JOB` | Per-job estimate for generic C/C++. |
| `RUST_MB_PER_JOB` | Per-job estimate for Rust. |
| `CPP_HEAVY_MB_PER_JOB` | Per-job estimate for torch/heavy C++. **See warning.** |

---

## 🚀 Max speed — the real lever is `--parallel-archs`, not the per-job numbers

On any ≥16 GB host the per-job math is **already optimal**: generic and rust run
at **full core count** (aggressive mode), and torch is **RAM-bound** at 4 GB/TU
(can't go faster without more RAM — see below). There is **no idle throughput**
to reclaim by tuning `*_MB_PER_JOB` for a *single* build.

The wall-clock win is at the **orchestration** layer. `build-cross-chain.sh`
builds the three arches of each per-arch stage (sdk / media / android)
**sequentially** by default. `--parallel-archs` runs them **concurrently** —
close to a **3× speedup** on those stages.

**The catch it used to have:** each per-arch build runs its own
`parallelism.sh`, which reads the *full* host RAM. Three concurrent torch builds
would each launch `RAM/4096` jobs → **3× overcommit → OOM at hour six.**

**The fix (now built in):** `BUILD_MEM_DIVISOR`. When the orchestrator runs N
arches in parallel it passes `BUILD_MEM_DIVISOR=N` into each build; every helper
then sizes against `usable_RAM / N`, so the **sum** of all N builds' jobs still
fits one host. Sequential builds pass nothing (divisor 1) → unchanged.

```
# 62 GB host, 3 arches in parallel:
#   without divisor:  3 × (62000/4096)=15 jobs × 4 GB = 184 GB  → OOM
#   with DIVISOR=3:   3 × (20666/4096)= 5 jobs × 4 GB =  61 GB  → fits
```

Because a container can't know how many siblings share the host, the divisor
**must be injected** — it is the one number auto-detection can't supply. Wiring:
the orchestrator computes `min(--max-parallel-archs, #arches)` and forwards it as
a build-arg → `ENV BUILD_MEM_DIVISOR` in each heavy Dockerfile.

> **Before the first `--parallel-archs` run**, validate the divisor actually
> reaches the container (grep a build log for the job count on a *cheap* stage),
> and watch `dmesg | grep -i oom`. Trading 3× disk + bandwidth too — the parallel
> arches all push large images at once.

---

## ⚠️ The trap: average RAM usage lies

`free`/`/proc/meminfo` during a heavy build shows **low average usage** and lots
of "free" RAM — because heavy TUs are **staggered**, so most samples catch the
light ones. This is *not* slack you can reclaim.

**Worked example (this host, 2026-07, riscv64 torch build):**

- Host: 32 cores, **62 GB** RAM.
- `compute_cpp_heavy_jobs` @ 4096 MB/job → **~14 concurrent jobs**.
- `free` snapshots during the build: **~14–18 GB used, ~44 GB free.** 🚩 *looks* wasteful.
- **But** torch's aten/autograd TUs peak **~4 GB each**. Worst case when the heavy
  ones align: `14 × 4 GB = 56 GB` — fits under 62 GB with a thin margin. ✅
- Lower it to 2500 "because 44 GB is free" → `~24 jobs × 4 GB = 96 GB` → **OOM,
  build dies at hour six.** ❌

This exact failure is already recorded in code: at the generic 2 GB/job estimate,
`27 jobs × 4 GB` overcommitted a 60 GB host and the OOM-killer terminated
`cc1plus` (see the comment above `compute_cpp_heavy_jobs`). **4096 is the tightest
value that keeps the worst case under 62 GB. It is not padding.**

## ⚠️⚠️ The second-order trap: the divisor ignores INTRA-build step parallelism (PAR4 — OOM incident 2026-08-18)

`BUILD_MEM_DIVISOR = min(MAX_PARALLEL_ARCHS, n_arch)` sizes each build's job
pools as if that build ran **one step at a time**. It does not: buildkitd's
`max-parallelism = 4` lets EVERY build run up to 4 independent Dockerfile
stages concurrently. Worst case under 3-way `--parallel-archs`:
`3 builds × up to 4 heavy steps × jobs sized for RAM/3` — a multiple of
physical RAM.

**The incident (wave3b, 2026-08-18):** the first run with the PAR2 cache-mount
id split. Before PAR2, the shared `sharing=locked` apt mounts accidentally
SERIALIZED the lanes' heavy phases — a hidden safety net. With PAR2 fixed, all
3 media lanes reached their heaviest phase (IREE wheelhouse) simultaneously at
~2h09m, and the kernel OOM-killed `cc1plus` on arm64 AND riscv64
(`g++: fatal error: Killed signal terminated program cc1plus`; both lanes'
media builds failed; recovery rode the retry+salvage staggering). Lesson:
**removing a contention bug can surface a latent memory overcommit** — the two
bugs were load-bearing for each other.

**Interim operator rule (until the PAR4 fix lands):** for 3-way parallel media
either set `BUILD_MEM_DIVISOR=5` (or higher) explicitly, or exclude media from
parallelism via `PARALLEL_STAGES=sdk,android`. sdk/android phases have not
OOMed under 3-way (validated 2026-08-17/18).

**The fix (PAR4, LANDED 2026-08-18, VALIDATED through wave-4 2026-08-21 —
ONE isolated OOM kill across ~12 parallel media rounds, absorbed by
retries; plus the 2026-08-19 amend: SHARED stages get divisor 1):**
`cross_build_mem_divisor` now multiplies the arch count by
`PAR_INTRA_STEP_BUDGET` (default 2 = assumed concurrent heavy steps per
build; observed 2-4, and an effective ×5 held through the android×3 recovery
run). 3-way parallel → divisor 6. Parallel-archs only; the sequential path
(bounded by max-parallelism alone) is empirically fine and unchanged.
Escalation if a lane still OOMs: `PAR_INTRA_STEP_BUDGET=3` or
`PARALLEL_STAGES=sdk,android`. The stronger options (systemd-run MemoryHigh
per build, a global compile-job governor) stay on the backlog as PAR4-hard.

## ⚠️⚠️⚠️ The third-order trap: the divisor outlives the lanes it was sized for (PAR5 — OPEN; the obvious fix was tried and REVERTED 2026-08-23)

**The symptom (real, still unfixed).** PAR4 sizes the divisor from the
**launch-time** lane count. Lanes do not finish together — amd64 media typically
lands hours before riscv64 — so the survivor keeps dividing the whole host by 6
long after it is alone on it. Observed twice and costed in hours: **wave4f
(arm64) and wave5h (riscv64) each spent hours on a lone media wheelhouse at 1-2
compile jobs while the rest of the machine idled.** `MemAvailable` recovers when
a sibling exits; `/ 6` does not.

### VERDICT: do not re-attempt "shrink the divisor when a sibling lane finishes"

It cannot work at this layer. An attempt (PAR5: a live `lane.<arch>` marker
registry in `run_parallel_arch_loop`'s flag dir, which `cross_build_mem_divisor`
clamped to) was written, reviewed, reproduced and **reverted the same day**.
Three findings, in the order that matters:

**1. The divisor is fixed at lane start BY CONSTRUCTION.**
`cross_build_mem_divisor()` has exactly ONE production call site —
`cross_stage_build_args()` ← `cross-stage-build.sh:553` — and it runs *once per
stage build*, to emit `--build-arg BUILD_MEM_DIVISOR=N`. Inside the image that
value is `ARG` → `ENV` in the `base` stage of every Dockerfile
(`Dockerfile.media:61,92`; likewise `.sdk`, `.android`, `.toolchain`) and
`parallelism.sh` reads it at each `RUN`. **A build-arg is bound when the build
starts; nothing on the host can move it afterwards.** The step that actually
crawls — the app wheelhouse, `Dockerfile.media:~515` — is hours downstream of
that `ENV`, inside the same build. So "adapt when lanes finish" is unachievable
at this layer, no matter how the host-side number is computed.

**2. The clamp could not fire where it was meant to.** The chain runs one
`run_parallel_arch_loop` per stage and joins before the next
(`build-cross-chain.sh:420`), and that loop starts every lane at t0. With
`MAX_PARALLEL_ARCHS >= #arches` — the shipped 3-arch topology — all lanes are
launched before any lane retires, so the lone survivor still reads the full
static divisor. **The exact case PAR5 existed for was the one case it could not
reach.**

**3. Where it COULD fire it was worse than nothing.** Only with
`MAX_PARALLEL_ARCHS < #arches` does a lane start after a sibling has retired.
There the clamp made `BUILD_MEM_DIVISOR` a function of **wall-clock sibling
timing** — nondeterministic between runs, and (see below) part of the BuildKit
cache key — and it could land **below** the PAR4 value: clamping to one live
lane skips the `× PAR_INTRA_STEP_BUDGET` multiplication entirely (6 → 1). That
is an N-times RAM overcommit in exactly the direction PAR4 exists to prevent —
the 2026-08-18 incident OOM-killed `cc1plus` in two lanes. Intra-build step
concurrency is a property of ONE build; it does not shrink when siblings exit,
so a live-lane count is the wrong input for it.

Regression guard: `linux/scripts/tests/test-stage-defs.sh` asserts the divisor
is a pure function of `PARALLEL_ARCHS` / `TARGET_ARCHES` / `MAX_PARALLEL_ARCHS`
/ `PAR_INTRA_STEP_BUDGET` and that flag-dir state cannot reach it.

### The cache-key coupling (why the manual workaround doesn't exist either)

Every host→build channel (build-args, bind mounts) is part of the **BuildKit
cache key**. `ENV BUILD_MEM_DIVISOR` sits in `base` (`Dockerfile.media:92`),
above all 39 downstream `RUN` steps, so a divisor that varies with lane
liveness would cache-miss the whole media chain on **every** run. The same
coupling removes the obvious hand recovery: **killing the lone lane and
relaunching it with a smaller divisor does not resume from cache** — the changed
`ENV` invalidates its whole media chain, so you would trade a 6× throttle for a
full rebuild.

### What IS achievable (both unbuilt; pick one and validate with a real build)

- **PAR4-hard — a host-level memory governor.** Stop encoding "how much RAM may
  I use" in an immutable build-arg and enforce it from outside, where it *can*
  change while a build runs: `systemd-run --scope -p MemoryHigh=…` per build, or
  a global compile-job governor. This is the only real answer to "the host's
  free RAM changed mid-build".
- **Re-size at STAGE boundaries.** The only honest in-band re-sizing point is a
  container-build boundary, and there is one at every stage (all lanes join, the
  next stage's builds compute a fresh divisor). Finer granularity means
  *splitting* the long stage (media) into more, smaller builds — Dockerfile
  work, and each new boundary is a cache-key boundary too.
- Anything that "tells the running build" a new number needs a channel that is
  off the cache key (per-`RUN` secret mount, a divisor file in a `type=cache`
  mount, a governor the container polls). Dockerfile-level work; it wants one
  real build to validate. Not reachable from the shell layer.

**Interim operator rule.** Both levers are launch-time — decide before the run,
because there is no mid-run recovery that keeps the cache. If the arches desync
predictably (riscv64 is always last), either run the slow arch as its **own**
chain invocation from the start — it then gets its own correct sizing at t0 —
or accept the throttle. Do not kill and relaunch a straggler to "fix" its
divisor.

---

## How to tune safely (procedure for an agent)

1. **Identify the binding stage.** Only stages using `compute_cpp_heavy_jobs` are
   RAM-capped on a ≥16 GB host. Generic-C++ and Rust already run at core count —
   **no config change speeds them up; don't touch their estimates.**
2. **Measure the PEAK, not the average.** While the target stage compiles, sample
   the *largest single* `cc1plus`/`rustc` RSS, not total used:
   ```bash
   # peak RSS (MB) of the biggest compiler process, sampled repeatedly
   for _ in $(seq 60); do
     ps -eo rss,comm --sort=-rss | awk '/cc1plus|cc1|rustc|lto/{print $1/1024; exit}'
     sleep 5
   done | sort -n | tail -1
   ```
3. **Apply the invariant.** Only lower `mb_per_job` if:
   ```
   (target_jobs) × (measured_peak_MB) ≤ usable_RAM_MB × 0.9   # keep ~10% headroom
   ```
   Solve for the max safe `target_jobs`, then set
   `mb_per_job = usable_RAM_MB / target_jobs`. Never set it below the measured peak.
4. **Verify on a real build.** Watch `dmesg -w | grep -i oom` and the compiler
   logs for `Killed`/`signal 9` on the first run after a change. If anything is
   OOM-killed, revert immediately.

---

## RAM upgrade guidance (corrected)

- **torch build time _is_ peak-RAM-bound.** You can only fit `usable_RAM / 4 GB`
  heavy TUs at once. On 62 GB that's ~14 jobs on 32 cores — cores sit idle *not*
  because of a bad estimate, but because RAM can't feed more 4 GB TUs.
  → **More RAM genuinely speeds up the torch stage** (e.g. 128 GB → ~30
  concurrent → roughly 2× torch parallelism). This is the *only* real lever for
  torch; the config estimate must stay at 4 GB.
- **Everything else is already core-bound** (aggressive mode), so more RAM does
  **not** help OpenCV / ONNX / Rust / GStreamer.
- Bottlenecks that more RAM does **not** fix at all: disk headroom (the cross
  images are large), registry **upload bandwidth** (each per-arch stage ends in a
  slow push), and single-threaded serial work (GCC mega-TUs, final links).

**Do not "free up" the torch estimate. If torch speed matters, add RAM.**
