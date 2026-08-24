# Build resource monitoring

The cross container builds are long and QEMU-heavy, and the failure that hurts
most is silent resource exhaustion — an OOM-killed `cc1plus` at hour six, or a
full disk mid-export. `linux/scripts/01-core/resource-monitor.sh` records what
the system was doing throughout a build so you can answer, after the fact:

> **When, and during which build activity, did RAM / disk / CPU headroom run out?**

## What it captures

A CSV time-series (`resources-<run-id>.csv`), one row per tick (default every
15 s), plus a computed `resources-<run-id>.summary.txt` on exit.

| Column | Meaning |
|---|---|
| `epoch`, `iso`, `elapsed_s` | sample time (absolute + seconds since start) |
| `load1`, `cpu_pct` | load average and CPU-busy % (from `/proc/stat` deltas) |
| `mem_used_mb`, `mem_avail_mb`, `mem_pct` | `MemTotal-MemAvailable`, `MemAvailable`, % used |
| `swap_used_mb` | swap in use — **any** value >0 means real memory pressure |
| `disk_avail_gb`, `disk_pct` | free space / % used on the build filesystem |
| `compilers` | live `cc1plus`/`cc1`/`clang(++)`/`rustc`/`lto1`/`ld` count |
| `stage`, `context` | coarse build stage + the exact build log line active then |

The **`context`** column is the key one: at every peak-pressure moment the
summary tells you *which file/target was compiling*, so you can trace an OOM or
disk spike straight to the offending stage (e.g. torch's `aten` TUs).

## Overhead

Negligible. Each tick is a handful of `/proc` reads plus ~3 short-lived forks
(`df`, `pgrep`, `tail|grep`). At 15 s that is far below the noise floor of a
32-core build and never competes with the compilers.

## Automatic use

`build-cross-chain.sh` starts it automatically for the whole run (gated by
`RESOURCE_MONITOR`, default on) and it self-terminates when the orchestrator
exits (via `--watch-pid`), writing the summary. Output lands in `--log-dir`.

```bash
# default: monitoring on, 15s interval, CSV+summary in the run's log dir
bash linux/scripts/build-cross-chain.sh --from-stage media --log-dir ~/build-logs

# disable it
RESOURCE_MONITOR=0 bash linux/scripts/build-cross-chain.sh ...
```

## Manual use (any build, or a surgical `build-cross-stage.sh`)

```bash
# start in the background, following whichever log is newest, self-ending with
# the build process:
setsid bash linux/scripts/01-core/resource-monitor.sh \
  --out-dir ~/build-logs --run-id my-run --interval 15 \
  --stage-log-dir ~/build-logs --disk-path / --watch-pid "$BUILD_PID" &

# ...or re-analyze a finished run's CSV at any time:
bash linux/scripts/01-core/resource-monitor.sh summarize ~/build-logs/resources-my-run.csv
```

Thresholds for the summary's "near-OOM" / "low-disk" sample counts are tunable
with `--near-oom-mb` (default 4096) and `--low-disk-gb` (default 20).

## Reading the results

- **`swap_used_mb` climbing or `mem_avail_mb` near zero** → you are at the OOM
  edge. Cross-reference the `context` at that row and lower the relevant
  `*_MB_PER_JOB` per [build-parallelism-memory-tuning.md](build-parallelism-memory-tuning.md),
  or add RAM.
- **`disk_avail_gb` dropping toward the low-disk threshold** → prune the local
  buildkit cache (`~/.cache/kata-buildcache`) before the next run.
- **`compilers` well below core count while `mem_avail` is low** → the stage is
  RAM-bound (expected for torch); more RAM, not more `-j`, is the lever.
- The CSV plots directly in any spreadsheet / `gnuplot` if you want a timeline.

> The CSV is **rewritten** on each start, so give each build a distinct
> `--run-id` (the orchestrator passes `CROSS_RUN_ID`) to preserve history.

## Mining a build log for the actual failure

The monitoring above tells you what a build *consumed*. When one fails, the
complementary problem is finding the real error in tens of thousands of lines,
where the last line printed is usually a downstream symptom rather than the
cause.

Capture the log in the first place — every orchestrator script takes
`--log-dir`, and a hand-run build should be teed:

```bash
docker build -t <tag> -f linux/Dockerfile . 2>&1 | tee out/build-logs/build.log
```

Then pull out the lines that actually mark failures:

```bash
grep -nE '(^| )FAILED: |ninja: build stopped|error:|fatal error:|undefined reference|collect2: error|ld\.lld: error|permission denied|no space left on device|exit code [1-9]' out/build-logs/build.log
```

Reading the hits, in order of what they mean:

| Match | What it usually means |
|---|---|
| `FAILED:` | The ninja edge that broke — **start here**, it names the target |
| `fatal error:` / `error:` | The compiler diagnostic; the first one is the cause, later ones are fallout |
| `undefined reference` / `collect2: error` / `ld.lld: error` | Link stage — a missing library or an ABI mismatch, not a source bug |
| `no space left on device` | Host disk, not the build. See [Linux Host Setup § B3](linux-host-setup.md#b3-cap-container-log-growth) |
| `permission denied` | Usually a bind-mount uid mismatch rather than a real permission problem |
| `ninja: build stopped` | Terminator line only — the cause is above it |

`-n` matters: it gives you the line number to seek to, which is the point of the
exercise on a log too large to read.
