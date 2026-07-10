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

Every memory-capped stage obeys this invariant:

```
concurrent_jobs  ×  PEAK_per-TU_RAM  ≤  usable_RAM
```

The config knob is `mb_per_job`, which **is** `PEAK_per-TU_RAM`. The scheduler
then runs `jobs = min(cores, usable_RAM / mb_per_job)`.

- Lowering `mb_per_job` **raises** `jobs` → faster **only if** RAM allows it.
- If `jobs × PEAK` exceeds RAM, `cc1plus` gets **OOM-killed** and the build dies.

**Tune against the PEAK per-TU footprint, never the average.** See the trap below.

---

## The helpers (`linux/scripts/01-core/parallelism.sh`)

| Helper | Used for | `mb_per_job` (normal) | `mb_per_job` (aggressive) |
|---|---|---|---|
| `compute_jobs` | pure CPU-bound, no mem cap | — (just `cores`) | — |
| `compute_jobs_with_mem_cap` | generic C/C++ (OpenCV, ONNX, …) | `DEFAULT_MB_PER_JOB:-2000` | `DEFAULT_MB_PER_JOB:-800` |
| `compute_rust_jobs` | Rust / Cargo (gst-plugins-rs) | `RUST_MB_PER_JOB:-2500` | `RUST_MB_PER_JOB:-1200` |
| `compute_cpp_heavy_jobs` | **PyTorch / torch_cpu / heavy LTO** | `CPP_HEAVY_MB_PER_JOB:-4096` | `4096` (floor kept) |

Job count = `min(cores, usable_RAM / mb_per_job)`, where:
- `cores` = `detect_available_cores()` (respects cgroup CPU quota).
- `usable_RAM` = `_mem_available_mb()` = `MemAvailable` from `/proc/meminfo`,
  or the cgroup memory limit remaining, **whichever is smaller**.

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
| `DEFAULT_MB_PER_JOB` | Per-job estimate for generic C/C++. |
| `RUST_MB_PER_JOB` | Per-job estimate for Rust. |
| `CPP_HEAVY_MB_PER_JOB` | Per-job estimate for torch/heavy C++. **See warning.** |

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
