# Changelog

> **Older entries** are archived, newest archive first:
> [`2026-08-14 … 2026-08-28`](docs/changelog-archive-2026-08-28.md) ·
> [`through 2026-08-13`](docs/changelog-archive-2026-08-13.md).
> Archive when this file passes ~700 lines; never delete. Cut on a DATE boundary.


## 2026-09-01 — Windows lane: the "container-start wedge" is a lost exit notification, not a wedge

A requested full dual-lane rebuild (amd64 `-Gpu` → arm64 cross) was **not
started**: the Windows lane is functional but every RUN step now costs ~47 min,
which makes a base→final chain weeks of wall-clock. No Dockerfile, driver or
script changed — this entry records the measurement and corrects the diagnosis
that was standing.

**What it actually is.** `RUN echo probe > C:probe.txt` on `servercore:ltsc2025`
reports `DONE 2841.2s`, byte-identical across two independent solves (the
second with a deliberately unique cache key, so it is not solve de-duplication).
2841.2 = ~141 s container boot + **2700 s = the 45 min `tearDownTimeout`** from
`windows/upstream/hcsshim-teardown-timeout/local-45min-deployed.patch`. The RUN
*succeeds*: on a stuck container `docker logs` prints the command's own output
and `docker top` shows no `cmd.exe`. What never arrives is the container's
shutdown/exit notification, so the shim waits out its whole timeout. `docker
stop` force-terminates in 91 s and the layer still exports cleanly.

**Where it lives.** Reproduced straight through **dockerd** — no shim, no
buildkit — so it is below both lanes in hcs/vmcompute, and it is **specific to
process isolation**: the identical image and command under `--isolation=hyperv`
exits 0 in 3.5 s. `nanoserver:ltsc2025` is unaffected (~2 s). It is the
Windows-Containers#547 / hcsshim#2855 family, escalated from
"filesystem-heavy containers only" to *every* container. On 2026-08-31 03:53
the same shape of step took 7.7 s / 9.2 s, so this is a ~350× regression that
appeared at the 15:12:59 boot and survived the 21:37 reboot.

**Falsified, with the experiment each time** (the standing "Defender platform
reload" suspicion is withdrawn): Defender RTP — reproduces with RTP already
off; the Defender platform — 4.18.26070.9 unchanged on disk since 2026-08-05,
and 15:13 was a *boot*, not a reload; CNI/HNS — ADD succeeds, IP and gateway
match the host nat adapter, and `--network none` stalls identically; disk space
— 515 GB free; disk health — `disk` event 51 fires only on *successful*
teardowns; the RDNA4 dGPU — cleanly disabled, Code 22; the shim patch — SHA256
matches the deployed one; the buildkitd GC policy — active, since buildkitd
reads `C:\ProgramData\buildkitd\buildkitd.toml` by default and the missing
`--config` in the service ImagePath is therefore a non-issue; a new KB or
driver — nothing was installed that day.

**The 141 s half has a name.** Inside the container SCM logs
`7022 The LSM service hung on starting` exactly 140.07 s after `RpcSs` starts,
and `LSM` then sits in `START_PENDING` forever — the only one of 121 services
not RUNNING or STOPPED, and `RUNNING` under hyperv isolation. Disabling it
(committed image with `LSM Start=4`) does **not** fix the teardown — that
container published its output and still sat in teardown >13 min before an
unrelated force-remove cut the run short, so the honest bound is ">13 min",
not a completed 2841 s. LSM is a co-symptom; and it is not worth chasing
economically, because **2700 of the 2841 s are the timeout** — the whole boot
stall is 5 %.

**The lever that matters.** 45 min was never the requirement: the measured
*legitimate* worst-case teardown here is **117 s** (`ISSUE.md`, OpenCV), so
2700 s is 23× the number it was raised to cover. `deploy-shim-patch.ps1
-ServiceEnvironment CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m` (the
`upstream-env` variant, already supported) keeps ~2.5× headroom, caps the
pathological case at 5 min and takes a RUN step from ~47 min to ~7 min — with
the timeout tunable afterwards without rebuilding the shim. **The value is a Go
duration string; a bare `300` fails `time.ParseDuration` and the patch treats
unparseable as unset, so it would silently restore the stock 30 s.** Owner's
call: it trades against the `ExportLayer 0x3` corruption the 45 min was raised
to prevent.

### Is the patch needed at all? Checked upstream before answering (2026-09-01)

Checked upstream HEAD before concluding, not just the pinned base: microsoft/hcsshim `main` (56195bbd,
checked 2026-09-01) **still hardcodes all the 30 s constants** — the only shim
change since the deployed base is #2868 (bootstrap protocol); `internal/hcs`,
the notification-receive layer, is untouched apart from a migration change.
PR #2855 is **open with zero maintainer response** since 2026-08-07, and
Windows-Containers#547 was **closed without a fix**. So there is no upstream
relief: dropping the patch means stock 30 s, and the 2026-08-06 A/B (stock →
deterministic `ExportLayer 0x3` on heavy layers; raised → 4 consecutive clean
OpenCV exports) still stands as the reason that breaks. Verdict: the patch is
needed for the healthy regime; the 45 min *value* is needed for neither regime
— in the current lost-notification regime every teardown ends in a forced
terminate anyway and the timeout only sets how long each step burns first.

### Deploy verified behaviourally: RUN echo = 441.3 s, exactly the 5 min cap

After the re-deploy with the fixed script (env now
`CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m`, services restarted in the
right order), a fresh unique-cache-key probe measured
`RUN echo … DONE 441.3s` — squarely the predicted ~141 s boot + 300 s teardown
cap + terminate, down from the byte-identical 2841.2 s under the 45 min
constant. Export and unpack clean, exit 0. The timing bands double as the
diagnostic: ~180 s would have meant the env was not inherited (silent stock
30 s), ~2841 s the old binary. Per-RUN cost is now ~7.4 min — the chain is
viable again, still ~50× off the healthy host's 7.7 s, which the (open)
lost-notification root cause keeps owning. Dual-lane rebuild started on the
back of this measurement — and its fresh OpenCV build then **passed the
canary under the 5 min cap** (RUN 965.4 s, `exporting layers 20.6s`, no
`ExportLayer 0x3`), closing the one risk the lowered timeout traded against.

### The first real `upstream-env` deploy found two host-script bugs (both fixed)

The 2026-09-01 11:20 deploy swapped the binary correctly but then hit, in one
run, two latent defects that had never been exercised:

- **`deploy-shim-patch.ps1` could not set a service's FIRST Environment value.**
  containerd ships with no `Environment` value, and under `Set-StrictMode` the
  bare `(Get-ItemProperty $svcKey).Environment` read throws
  (`The property 'Environment' cannot be found`) — so exactly the deploy the
  `upstream-env` variant exists for (knob via containerd's environment) failed
  after the swap, silently leaving the shim on stock 30 s defaults. Fixed by
  probing with `-Name Environment -ErrorAction SilentlyContinue` and treating
  "absent" as an empty list (both in the env-setting block and in the
  before/after report, which printed the same error as noise). The fix
  deliberately avoids `$x = if (…) {…} else { @() }` — an if-expression
  yielding `@()` assigns `$null`, not an empty array.
- **`Stop-HostServices` returned a `List[string]`, so every caller's
  `[array]::Reverse($stopped)` was a silent no-op** — PowerShell binds a Generic
  List to the `System.Array` parameter as a converted COPY. Services therefore
  restarted in STOP order: buildkitd came up before containerd and died on the
  missing containerd pipe (`buildkitd START ERROR`, measured in
  `out/deploy-shim-patch.log`). All three host scripts
  (`deploy-shim-patch.ps1`, `compact-host-vhdx.ps1`, `rebuild-host-vhdx.ps1`)
  share the pattern; fixed once at the source — the module now returns
  `$stopped.ToArray()`. Both fixes behaviourally verified (List reverse no-op
  reproduced, array reverse works; old env read throws, new read returns empty)
  and PSScriptAnalyzer-clean under the repo settings.

### The `upstream-env` shim is built and verified (deploy still pending, needs admin)

**Owner directive (2026-09-01): adaptations come from the fork, not from the
in-tree patch file.** Rebuilt accordingly from
`Kataglyphis/hcsshim@feature/configurable-teardown-timeout` (19251429 = current
upstream main 56195bbd + the patch; the patch commit is code-identical to the
in-tree file, one gofmt alignment apart): 25 998 336 bytes,
`sha256 9ABF1C5F…`, `spec: 1.3.0`, gofmt/vet clean, resolver test 7/7, both
knobs + duration log present. The fork base additionally brings the 40 upstream
commits since 81e2e01, including e6580439 *"fix leaked layer reader which
results in deadlock"*. The 81e2e01-based build below is kept as the
minimal-delta fallback.

Built from `hcsshim@81e2e01` — the same base as the deployed `local-constant`
45min/100min binary, so the only behavioural delta is that the constants become
knobs — plus the in-tree `0001-shim-configurable-teardown-timeouts.patch`, with
Go 1.27.0 (`windows/amd64`). `git am` applied clean, `gofmt` clean, `go vet`
exit 0, and `Test_resolveTeardownTimeouts` passes all 7 subtests. The binary is
26 048 512 bytes, `sha256 F8CC8C78…`, reports `spec: 1.3.0` like the deployed
one, and carries both env-var strings plus the new
`container shutdown completed` log — which finally makes the real teardown
duration observable, the number needed to size the timeout. The stock `.orig`
binary was checked as a control and does not carry them. Defaults remain 30 s,
so the binary alone changes nothing until the environment variable is set.

**Process lesson.** The four probe runs that looked like a hard wedge were
killed by a 240 s timeout. Left alone, they finished green at 2841.2 s. Judging
a step by console silence is exactly the mid-finalize kill that manufactures
`0xb7` debris — `docs/failure-modes.md` already said so, under
"`exporting layers` prints nothing for 20+ minutes".

### Full-lane audit: 17 confirmed defects (1 critical), recurrence vectors fixed first

A 26-agent read-only audit (7 lenses, adversarial verification per finding) ran
while the chain built. Confirmed most-severe: `-TargetArch` is never forwarded
to `-ConcurrentAux` children (arm64+ConcurrentAux would clobber amd64 tags or
merge stale trees, CRITICAL); the `DEPS_MIN_*` wheel floors in
`Dockerfile.media-merge-builder` are declared AFTER the RUN that reads them and
have been dead since landing; `-NoCache` leaks into the post-smoke export
re-solves via the `*final*` label match; the toolchain lane never runs the
Windows-Update guard the docs promise; `Invoke-GitClone` ignores the submodule
exit code on the pinned-commit path; `Dockerfile.probe` and the sccache write
probe mount files deleted/archived weeks ago (the diagnostics lane is dead);
`WindowsAgenticLoop` returns captured output LIFO. Full ranked list with fix
sketches: this entry's audit record, findings 1-15 plus 3 unverified majors
and 36 minors (fail-open error paths dominate). **Fixed immediately because
they re-arm the 45 min regression with every gate green:**
`apply-containerd-config.ps1` defaulted `-TeardownTimeout '45m'` and its
drift-repair would have silently reverted the deployed 5 m on the next apply
(now defaults `5m`), and `docs/windows-host-setup.md` § R1 still prescribed
the retired 81e2e01+45 min rebuild recipe (now the fork branch + the mandatory
`-ServiceEnvironment ...=5m`, with the Go-duration-string warning). The
remaining fixes are deliberately deferred until the running dual-lane chain
finishes: container-side files (Dockerfiles, modules, build scripts) are cache
inputs, and editing them mid-run would re-key the arm64 lane away from the
amd64 lane it must match. Tracked as **#158** in
`docs/windows-refactor-backlog.md` — one closure window, re-key paid once.

### Second audit wave (quality): 16 confirmed, 3 fixed on the spot, 13 filed as #159-#175

Lenses per the owner's priorities — dedup/cleanliness, build performance,
consumer fitness, comment discipline — deduplicated against both backlogs and
the protected deliberate-design lists; 0 refuted. **Fixed immediately (all
safe-now):** #161 `build-resource-sampler.ps1` swallowed the exception on
every failed sample (the running chain's CSV is 100 % bare `sample-error` rows
— 4.7 h of resource axis lost undiagnosably; the reason now lands in the row
and `-Summarize` reports an all-error CSV as a broken sampler instead of "no
samples"); #166 three smoke-gate numbers in `docs/windows-builds.md`
contradicted the driver (floors are 160/3 with GPU 190, not 40/24; arm64
66/20, not 66/25; baseline 222/0/0 from bk-20260826, not 184/0/1); #165 the
consumer CI table now leads with `set-docker-data-root` +
`assert-docker-disk-space` (a stock windows-2025 runner cannot hold the ~54 GB
image on C: — pulls died `ImportLayer 0x70`) instead of only the destructive
cleanup fallback. The open remainder is `docs/windows-refactor-backlog.md`
#159-#175: headline items are the versions.env full-copy that re-keys the
whole Windows chain on any Linux-only pin edit (~4 h, measured), the never-used
`-ConcurrentAux` (~24 min idle capacity per amd64 chain), the patched-LLVM
compile bypassing sccache, and a ~170-line comment-to-docs wave. The audit's
honest bright spots: single-source arch resolution, tight per-file mount
closures with zero dead local functions, and a smoke suite whose consumer
import surface is genuinely strong at the core.

### Docs

- `AGENTS.md` (post-update routine) and `docs/windows-build-lanes.md`
  § defect-solved: the deployed shim is now the fork-built `upstream-env`
  variant + `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=5m` on containerd —
  an update now reverts binary AND env; Go-duration-string trap and the
  containerd-restart-on-env-change caveat recorded.
  `windows/upstream/hcsshim-teardown-timeout/README.md` no longer claims the
  45 min constant build is what runs. `README.md`: the identical-RUN-timing
  symptom added to the first-touch list.
- Recurrence hardening: `windows/scripts/diagnostics/capture-lsm-waitstack.ps1`
  (new, elevated — dumps a fresh silo's earliest svchosts twice inside the LSM
  hang window via comsvcs, for the WinDbg wait-object analysis that names the
  never-signalling component), a timing-decode playbook in the failure-modes
  entry (~10 s healthy / ~180 s env wiped / ~450 s knob active / ~2841 s
  constant build back, plus the redeploy one-liner), and a fourth standing
  reflex in `AGENTS.md`: identical step timings mean a timeout, not slow work.
- `docs/failure-modes.md`: new entry *"Every RUN step reports `DONE 2841.2s` —
  the same number, whatever it runs"*, carrying the measurements and the whole
  falsified list so the next session does not re-run them. Contents index
  brought back in sync — it was also missing the two pre-existing entries
  *"A source build produces UNPATCHED sources…"* and *"`atlbase.h` not found…"*.
- `AGENTS.md`: the failure-mode count was stale at 35; it is 49.
## 2026-09-02 — dual-lane DELIVERED: bk-winamd64 222/0/0, bk-winarm64 97/0/15

The rebuild ordered on 2026-09-01 00:18 is complete and verified on both lanes:

- **arm64 cross** (`bk-winarm64`): OK in 04:44:46 — first post-wave arm64 run,
  so it re-paid toolchain (CPU base) + all media branches; smoke gate green at
  exactly the recorded baseline **97/0/15** (floors 66/20; payload sections
  skipped by design, QNN riding along, all wheels 0xAA64-verified).
- **amd64 GPU** (`bk-winamd64`): after the ASAN root-cause fix, the full
  re-run (new rustup pin re-keyed base; sanitizers re-keyed toolchain+media)
  finished in **07:04:10** with the smoke gate at the best recorded state:
  **222 assertions, 0 failed, 0 skipped** — including
  `[PASS] AddressSanitizer compile + runtime works`, the assertion that
  correctly killed the first attempt. The fresh toolchain log carries the
  `clang_rt.asan_dynamic-x86_64.dll` installs that were missing.

Recurring pattern, twice reproduced across both merge fan-ins: the FIRST
read-mount of freshly exported heavy media layers fails
`ActivateLayer 0x20 (file used by another process)` for ~2 solve attempts and
then self-heals — consistent with Defender scanning the new layer files once
(RTP re-enabled 2026-09-01 midday); the driver's transient-retry ladder absorbs
it both times with no intervention. Total wall-clock for the whole order,
including the teardown-regression diagnosis, shim deploy, one gate-caught
toolchain defect and the full re-run: ~31 h — of which the (still open)
lost-notification host defect taxed every uncached RUN with ~7.5 min.

## 2026-09-01 — the amd64 smoke gate caught the wave: sanitizers were off in the new toolchain

The dual-lane rebuild's amd64 smoke gate went red on exactly ONE assertion —
the ASAN probe (compile + run `/fsanitize=address`, require the intentional
overflow to be reported). Root cause: the 2026-08-31 pre-rebuild pass
(`bd150ae1`, the compiler-rt ride-along) added explicit
`-DCOMPILER_RT_BUILD_*=OFF` switches with the comment "sanitizer … unnecessary"
— and today's chain was that wave's FIRST real build (#152 said exactly this
could happen). The freshly built patched LLVM shipped builtins only (158
compiler-rt objects, zero `clang_rt.asan*` installs in the log); the previous
toolchain had ASAN because enabling the compiler-rt runtime builds sanitizers
by default. Fix: `COMPILER_RT_BUILD_SANITIZERS=ON` (fuzzer/profile/ORC stay
off), comment corrected to name the gate as the reason. Costs one toolchain
re-key + downstream media re-pay on the next amd64 run — the recorded price of
a toolchain-layer change, and the reason #164 (route this build through
sccache) is worth landing. The arm64 lane is unaffected (its gate skips the
ASAN probe — no aarch64-windows ASAN runtime exists) and kept running.

## 2026-09-01 — CI back to green: the guard that was never committed, a corrupt patch, and a leaking job env

All three failing workflows, one session:

- **Ubuntu 24.04 / delete-guard:** the Linux guard port shipped its wiring,
  tests and docs — but `.gitignore`'s `.claude/hooks/*` silently swallowed the
  `git add` of `guard-destructive-deletes.py` itself, so the file existed only
  in one working tree and the guard was inert everywhere else. Recreated the
  guard to the spec of its own 15-assertion suite (deny-only: package
  removals, system dirs, home root, credential/config/store dirs, block
  devices; quote-stripped verb matching, reclaimable blanking eats the
  trailing `/*`) and added the missing gitignore negation with the incident
  as its comment. 15/15 locally.
- **Ubuntu 24.04 / code duplication:** two new copies from the riscv64 wave —
  the embedded-python test's repeated extractor invocation (now a
  `_extract_fresh` helper, 6/6 still green) and the ffmpeg-TF-SDK vs
  opencv-harfbuzz file-presence gates, which are different domains sharing a
  shape: allowlisted at exactly their current 12 shingles so growth still trips.
- **Windows Scripts / patch-drift:** `003-mlas-windows-skip.patch` was
  structurally corrupt since a 2026-08-30 edit — hunk header promised +20
  lines, the body carries 21, plus a stray blank after the last context line.
  `git apply` refuses that outright; the in-container applier is more tolerant,
  which is why the OpenCV build itself kept passing. Header now says 21,
  `git apply --stat` parses clean, applied content unchanged.
- **llm-stack tests:** the three `TestResolutionOrder` failures were the
  v1-api-contract job's own `OLLAMA_BASE_URL` (its ollama service) leaking into
  tests that assert the order BELOW env — env beating the registry is pinned
  as correct by `TestEnvironmentPrecedence`. An autouse fixture now clears
  `LLM_BASE_URL`/`OLLAMA_BASE_URL`/`OLLAMA_HOST` for that class; verified by
  mutation (fixture removed → exactly the three CI reds reproduce).

## 2026-09-01 — riscv64 at Ubuntu's RVA23 baseline; prevention gates; one root cause for five GStreamer plugins

Gates: `make lint` clean (281 files), `make preflight` green,
`make test-linux-scripts` **42 suites / 1179 assertions** (up from 40 — two new
suites). The riscv64 RVA23 work is compiler-stage-onward and is **not** carried
by the in-flight runtime-only repair run; it needs a build from `compiler`, cold
for riscv64.

### riscv64 now builds WITH the vector extension

The premise was inverted. The shipped image's own glibc and loader already
require RVV 1.0 (997 `vsetvli` in apt's `libc.so.6`), so a board without a vector
unit could never run this image — the hardware floor is Ubuntu's, not ours. Our
binaries were the only sub-baseline objects in it.

The cross GCC now defaults to `rva23u64_zifencei` / `lp64d` (`build-gcc.sh`,
`RISCV_GCC_ARCH` / `RISCV_GCC_ABI` override) — the exact string apt's libc
carries. A compiler default, not a `CFLAGS` export: it survives the
`-DCMAKE_C_FLAGS=` whole-string resets and cannot leak into an amd64 host build.
Four consumers gate vector paths on their own switches and were wired separately:
OpenCV (`CPU_BASELINE=RVV`, `WITH_HAL_RVV`), ORT (`onnxruntime_USE_RVV`), Rust
(`-C target-feature=+v,+zvl128b`), and gst-plugins-rs, whose `cargo_wrapper.py`
**overwrote** `RUSTFLAGS` — the patch now merges. Full rationale:
[`docs/riscv64-rva23-baseline.md`](docs/riscv64-rva23-baseline.md).

New smoke gate reads `Tag_RISCV_arch` off the shipped objects. It is scoped to
the image's OWN gcc default, because the first version would have failed the
in-flight repair run on a pre-existing condition — the smoke script is read from
the repo at run time, so a new gate goes live in a running build.

### Five missing riscv64 GStreamer plugins, ONE cause

`gst-inspect-1.0` on the shipped images: 282 plugins on riscv64 against 290 on
arm64. `libjson-glib-dev`, `libgtk-3-dev`/`libgtk-4-dev` and `libgudev-1.0-dev`
all Depend on `libglib2.0-dev`, the package RV1 banned from the riscv64 sysroot,
so `MEDIA_SKIP_GLIB_STACK` / `_GTK_DEV` / `_GUDEV` are three spellings of one
ban. `liblcms2-dev` is the only one that does not depend on glib — installed
explicitly for every arch, which should restore `colormanagement`.

RV1's stated mechanism is refuted: ports' riscv64 `glib-2.0.pc` now ships in
`libgio-2.0-dev` and is byte-identical to arm64's modulo the triplet. One media
build with `MEDIA_SKIP_GLIB_STACK=0` would settle five plugins.

### Prevention gates

- `advert-keys` (new): fails when a version-shaped `ENV`/`ARG` is neither checked
  by the smoke nor excused with a reason. It found 6 of 31 keys checked; now 16
  and 16. `VULKAN_VERSION` could not disagree with itself — it read the version
  out of a directory named by the ARG under test.
- `pkg-names`: a PARTIAL index fetch counted as success, so a mirror hiccup would
  report live packages as dead. Now all-or-nothing. The vendor exemption covered
  whole FILES, leaving plain Ubuntu packages unfailable.
- `cross-apt`: a phased-back host `libc6` makes EVERY foreign-arch install
  unsatisfiable. The chain worked only because the base image happened to carry
  the newer libc.

## 2026-08-31 — Linux backlog closure window: ERR-trap bug, complexity queue, GEN1 riscv64 GenAI

Closed every open work item on the Linux refactoring backlog in one closure
window (A1 + GEN1). Gates: `make lint` clean (276 files), `make preflight`
green, `make test-linux-scripts` **38 suites / 1001 assertions** (up from 32
suites — six new suites). **No container build was run: everything below is
static-gate-proven only, and the riscv64 GenAI lane in particular is UNVALIDATED
until a real media-riscv64 build.**

### The bug: logging.sh ERR trap reported the wrong error (A1)

`_install_trap`'s `on_err` read its reporting action (`err`/`warn`) from a
`local` of the installer via **dynamic scope**. The trap fires long after the
installer returned, so under `set -u` the handler died with
`logging.sh: line 119: action: unbound variable` — which **replaced the real
error text** (it masked a parallel-GCC apt-lock failure during the 2026-08-30
rebuild) and meant the intended action never ran at all: `install_err_trap`
never exited 1, `install_warn_trap` never printed.

`on_err` is now a single top-level function and `_install_trap` bakes the
resolved action into the trap string with `printf -v '%q'`, keeping `LINENO` /
`BASH_COMMAND` escaped so they still expand **at fire time**. `_LOG_TRAP_ACTION`
covers `build-gcc.sh:709`, which re-arms the *bare* trap string by hand around
its configure step. New `test-logging-err-trap.sh` (30 assertions) fails 29/30
against the pre-fix file.

### Complexity queue (A1) — all decomposed, all behaviour-preserving

- `append_tvm_cmake_args`: 15 positionals → named options (a dropped or
  mis-ordered arg used to fail silently as wrong CMake flags, hours in).
- `_build_vulkan_targets` (137 lines) and `_llvm_cross_setup_and_build`
  (146 lines) decomposed along their real seams.
- `build_iree_wheels` split into nine `_iree_*` stages.
- `parse_options` (116-line nested case/while) collapsed to a data table, with
  the load-bearing asymmetries preserved (`--ports-url` `${2-}` vs
  `--archive-url` `${2:-}`; the `install-vulkan-runtime-files` passthrough).
- **`modules.sh` dir-walker: deliberately NOT changed.** All four suspected
  defects were probe-tested and refuted (the walk terminates for every input
  shape and cannot cycle; the `return 1` signal is consumed correctly;
  `BASH_SOURCE[1]` is right at any nesting depth). It is in the base/compiler/
  media closure and its last mistake SIGSEGV'd the media build — style churn
  there is a net negative. Do not re-flag.

### Two toothless-gate findings (the class this repo keeps getting bitten by)

- The new IREE suite claimed every `|| return 1` call site was covered; only
  2 of 5 were. While fixing it: (a) the fault injection silently did nothing
  because `grep` here is **ugrep**, which parsed a `--build …` pattern as an
  option — now `grep -qE -e`; (b) even with injection working, `rc==1` passed on
  all three mutations anyway, because `_iree_package_wheels` bails at its own
  `[ ! -d ]` guard and returns 1 — *the right answer for the wrong reason*, with
  a misleading diagnostic replacing the real configure failure. The cases now
  assert the packaging diagnostic is **absent**. All five call sites are
  mutation-verified.
- `smoke_genai_py` conflated "no wheel on this arch" with "wheel installed but
  its native library will not load" — both exited 3, reported as a benign SKIP.
  Every other gate is blind to the second case (`smoke-torch-venv`'s
  `installed_version()` falls back to `importlib.metadata` when the import
  raises; ARCH-PARITY only reads dist-info directory names), so a broken riscv64
  binding would have shipped green. An installed-but-unimportable distribution
  is now a hard FAIL.

### GEN1 — onnxruntime-genai riscv64 lane, built and wired ON

riscv64 now takes the same cross path arm64 takes; the hard arch guard is gone
and the allowlist is an explicit `arm64|riscv64`.

- **Upstream patch** `patches/onnxruntime-genai/001-riscv64-target-platform.patch`:
  `cmake/target_platform.cmake`'s Linux branch `FATAL_ERROR`s on any processor
  that is not arm64/x64/powerpc. One added `riscv64` arm fixes it, and
  `genai_target_platform` is read only under `WIN32` / `ENABLE_JAVA` / MSVC — so
  the patch is inert everywhere else. Proven to apply (and re-apply as a no-op)
  against a real clone of the pinned tag v0.15.2 (`ed5f4e87`).
- `--use_guidance` **kept** on riscv64 (auto-dropped with a WARN only if rustup
  lacks the std — see the A1 watch list): `riscv64gc-unknown-linux-gnu` is Rust
  Tier-2-with-host-tools, `install-rust.sh` adds its std for every
  `CROSS_TARGETS` arch, and the crate graph Corrosion imports is pure Rust.
- **Escape hatch `GENAI_ALLOW_RISCV64`** (versions.env → `Dockerfile.media`
  ARG/ENV) restores the pre-GEN1 placeholder-and-skip exactly. Two defects found
  in review and fixed: it never reached the in-container smoke (`nerdctl run`
  inherits nothing from the host, and the media *final* stage is
  `FROM media-inputs`), so the documented back-out still red the gate; and
  producer/verifier defaults pointed opposite ways (`:-false` vs `:-true`),
  disagreeing in the failing direction. The producer now drops a
  `.gen1-lane-off` marker and the verifier reads **the producer's actual
  decision** instead of re-deriving it.
- `smoke_genai_py()` added to `smoke-common.sh`, run on every arch: asserts the
  version against the versions.env pin, that the loaded extension's ELF machine
  is the target's, and that the pybind API objects exist. Tier 4 calls
  `generate()` **only when `GENAI_MODEL_DIR` is set — it is UNARMED by default,
  so token-level correctness is NOT yet proven.**

### Known-red until the next riscv64 build (by design)

Removing the `riscv64:onnxruntime_genai` ARCH-PARITY exemption means **every
currently-shipped riscv64 image now fails that assertion**. That is the table
working as intended, not a regression. The riscv64 app-wheel floor is
deliberately left at 12 (raise to 13 only after a real run *prints* it).

**Watch on the first media-riscv64 build:** the genai stage compiling at all
(GCC 16 cross, source-read only); `cross_target_python_dev_ready` returning true
there; llguidance actually *linking*; the pybind `EXT_SUFFIX` really being
`.cpython-314-riscv64-linux-gnu.so`; and possible `-latomic`. Upstream issue
\#594 is a RISC-V genai build that compiled, imported and emitted **nonsense** —
tiers 1-3 of the smoke pass in exactly that state.

### Two GEN1-adjacent defects fixed in the same window (risk-reducing, pre-rebuild)

- **The GenAI libraries were scanned by nothing.**
  `validate-media-runtime.sh` checks unresolved `NEEDED` only over `ARTIFACTS`
  (gst/libcamera/ffmpeg) plus the gst plugin dir; its `LIB_DIRS` sweep checks
  ELF *machine* only, advisory. `/usr/local/lib/onnxruntime-genai/lib` was in
  neither — so an unresolved `NEEDED` in `libonnxruntime-genai*.so` would have
  reached a shipped image unseen. That is precisely the riscv64 `-latomic` risk
  GEN1 flagged (GenAI's CMake, unlike upstream ORT's, has **no** libatomic
  probe). The prefix now joins `LIB_DIRS` *and* the lib dir is walked for
  unresolved NEEDED through the existing machinery. **New gate on all three
  arches; not yet run against a real image.**
- **`prune_conflicting_onnx_wheels` deleted the wheel the same file needs.** On
  the default `ONNX_PACKAGE=onnxruntime` path it ran
  `rm -f /opt/wheels/*genai*.whl` — matching the CPU wheel this lane now builds
  on every arch, which `build_uv_sync_args` looks for 60 lines later and which
  ARCH-PARITY now asserts. Prune runs first, so a successful `rm` would have
  resurrected GENAI-DRIFT (silent PyPI-genai fallback). Inert only by accident:
  `/opt/wheels` is a read-only bind mount and `|| true` swallowed the failure —
  making it rw would have broken all three arches at once. Narrowed to the
  GPU variants the arm actually means.

### Also

- `linux/qnn-sdk/README.md`: corrected a stale paragraph calling the
  `QNN_SDK_LINUX_ZIP_SHA256` pin "planned". It is implemented **and populated**
  with the proven QAIRT v2.49.0.260730 hash, so re-staging that exact version
  needs **no re-pin**; documented `QNN_SDK_LINUX_LIBDIR` as the single knob.


## 2026-08-31 — one Windows driver, and the module mount that re-keyed LLVM on every `.psm1` edit

### The DEFAULT toolchain target bind-mounted the WHOLE modules directory

`Dockerfile.toolchain-builder`'s `patched-llvm` RUN mounted
`windows/scripts/modules` as a directory, putting all ~40 modules into that
RUN's cache key. `patched-llvm` is the DEFAULT toolchain target
(`build-buildkit.ps1` picks it unless `-StockLlvm`), so editing ANY module — a
host-only driver module no container ever imports included — re-keyed a full
LLVM 23.1.0 compile plus every media lane that derives from
`bk-windows-toolchain`. It is now a per-FILE mount of exactly the six modules
`build-llvm-from-source.ps1` imports. Regression test:
`BuildKit.ModuleClosure.Tests.ps1` fails on a whole-directory modules mount in
any windows Dockerfile except `Dockerfile.probe` (exempt by design —
`PROBE_NONCE` busts that layer anyway, and its own header says so).

What the mount quietly falsified while it existed: AGENTS.md rule 5(b)
("TIERED in-container module closures so host-only module edits cannot bust a
compile layer") and `WindowsBuildDriver.Common.psm1`'s own "Edit cost: … cheap"
header. Both describe the tiering the Dockerfiles implement again. Second
correction in the same Dockerfile: the `BUILD_PATCHED_LLVM` comment still read
"OPT-IN … off by default" while `ARG BUILD_PATCHED_LLVM=1` and the driver have
defaulted it ON since #135.

### `windows/build.ps1` deleted — and the six functions only it called

The classic docker-build lane was retired 2026-08-26 and is now gone;
`build-buildkit.ps1` is the one driver. `WindowsBuildDriver.Common.psm1` lost
`Set-BuildDriverIsolation`, `Invoke-DockerWithRetry`, `Get-DockerBuildArgList`,
`Assert-ImageExists`, `Resolve-BuildIsolation` and `Assert-DockerDaemon`.
`Test-TransientDockerFailure` STAYS — `Invoke-TransientCooldown` classifies
against it and the BK driver calls that. `$script:BuildDriverContext` is down to
`TransientPattern`, and `Initialize-BuildDriverContext` takes only
`-TransientPattern` (Docker/LogDir/NoCache had no readers left).

Tests followed: `Driver.PreflightParity.Tests.ps1` (two drivers, one contract)
became `Driver.PreflightContract.Tests.ps1` (3 tests), `Driver.ClosureScope`
keeps the #40 closure rule but only for the surviving driver, and
`BuildDriver.Retry` lost 6 retry/build-arg tests. Suite is 773;
`Invoke-Tests.ps1`'s `$minTests` goes 763 → 762 — the first DOWNWARD move of
that floor, with the arithmetic recorded inline so it cannot read as hiding a
red run.

Stale `build.ps1` references were corrected in both `.dockerignore` files,
`Dockerfile.base` / `.nvidia` / `.torch` / `.toolchain-builder`, `versions.env`,
`bump_versions.py`, `sync_versions.py`, `windows/downloads/README.md`,
`Invoke-Lint.ps1`, the three `build-*-all.ps1` payload headers,
`build-toolchain-all.ps1`, `build-resource-sampler.ps1` and both diagnostics
probes. Two were not mechanical renames: `verify-host-setup.ps1` was a LIVE
CHECK reporting stevedore as the "classic fallback lane" and now reports it as
the publish/inspect tool (which is what `docker.exe` still is), and
`Dockerfile.torch`'s `-TorchBaseImage` recipe has NO BuildKit equivalent — the
BK driver has no such flag and pins the torch stage's `BASE_IMAGE` to the local
`windows-media` tag — so it is documented as not driver-supported rather than
renamed.

### `Set-StrictMode -Version Latest` on 7 scripts — 4 latent bugs, 1 already live

Added to `build-llvm-from-source`, `debug-litertlm-link`, `load-versions`,
`normalize-tensorrt-tree`, `stage-cuda-runtime`, `clean-sccache-mount` and
`bootstrap-pwsh`. On pwsh 7.6.5, `.Count` throws under StrictMode on a scalar
AND on an empty pipeline result, which is what made four sites bugs rather than
style:

- `debug-litertlm-link.ps1` — `(Get-Command 'llvm-nm.exe' -EA SilentlyContinue).Source`
  was ALREADY LIVE: its caller `build-litert-lm-from-source.ps1` sets StrictMode
  and `&`-invocation inherits it, so the "no llvm-nm" branch the script already
  had could never be reached. Bound first now.
- `normalize-tensorrt-tree.ps1` — `$dllDirs` was not `@()`-wrapped, so `.Count`
  threw on the NORMAL SUCCESS PATH (TensorRT 10+/11 ship the DLLs in `bin` only,
  leaving exactly one surviving dir).
- `stage-cuda-runtime.ps1` — same shape on `$roots`; would have re-broken the
  arm64/CPU merge lane the 2026-08-23 degrade-cleanly fix unblocked.
- `clean-sccache-mount.ps1` — `Measure-Object -Property` emits NOTHING for empty
  input, so the inline `.Sum` threw on an empty cache dir.

NOT added, on purpose: `WindowsFlutter.Common.psm1` and
`WindowsContainerLog.Common.psm1` (a module does not inherit its caller's strict
mode, so adding it is a real behaviour change downstream), and the dot-sourced
`Initialize-CiEnvironment.ps1` / `litert-lm-export-bridge.ps1` (strict mode
would leak into every caller).

### Two helper sets pushed down to their leaf modules

`Write-AssembledWheelDistInfo` and `Get-PyprojectDependencies` moved off the
`WindowsSourceBuild.Common.psm1` facade — mounted into all 11 media RUNs — into
`WindowsTvm.Common.psm1`, the `tvmmods` leaf only media-tvm mounts. Their sole
consumer is `build-tvm-from-source.ps1`.

The GStreamer wrap-git prefetch plus the libffi force-download (~64 lines of
phase 5) moved out of `build-gstreamer-from-source.ps1` (1575 → 1514 lines) into
`Invoke-GstWrapProvisioning` in `WindowsMeson.Common.psm1`, the merge-lane leaf.
It takes a `-Logger` scriptblock, accumulates failures in a LOCAL list and
RETURNS them; the caller keeps the #88 fail-closed throw so that gate stays
visible at the call site (inside a module `$script:` is MODULE scope, so a
caller reading its own accumulator would have seen zero failures). The libffi
version expression deliberately stayed in the stage script:
`SourceBuild.PinParity`'s W1c scanner keys the pin site by FILE NAME. New suite:
`SourceBuild.GstWrapProvisioning.Tests.ps1` (3 tests).

### `Assert-ShimPatch`'s fail-closed test could only pass on a host without Stevedore

The backlog #48 "throws when no shim is installed" test pointed at a missing
path, but the fallback probe then found the REAL shim under the Stevedore bin
root and the not-found branch never ran — so the test could only pass on a
machine that had never installed the toolchain, i.e. never on a build host.
`Assert-ShimPatch` gained an injectable `-AlternateRoot` (default unchanged);
`BuildDriver.HostGates.Tests.ps1` passes `-AlternateRoot @()`.

### Left standing on purpose

`Get-LlvmMasmCmakeArg` and four facade re-exports are dead in-tree but are
exported API for other Kataglyphis repos — the never-delete-on-a-zero-reference
audit rule in `docs/windows-builds.md`. `Export-BuildHandoff` /
`Import-BuildHandoff` stay on the facade because `bk-warm.ps1`'s header names
them the TESTED ROLLBACK PATH (restore the warm/materialize targets from
c9586c1^ and the payloads work unchanged) — but that recipe is ALREADY partially
stale: those retired targets mount the pre-#134 module set with no
`WindowsTvm.Common.psm1`, and `build-tvm-from-source.ps1` now throws without the
`tvmmods` mount. Worth repairing before anyone needs the rollback.
`.claude/settings.local.json` still holds 4 allowlist entries for `build.ps1`
invocations — permission config is the owner's call: flagged, not changed.

Docs: AGENTS.md rule 5(b) and the module-tier prose in `docs/windows-builds.md`
and `docs/windows-refactor-backlog.md` carry the per-file mount rule and the
one-driver reality; the in-tree headers listed above were corrected with the
code. Housekeeping: this file is past 2,300 lines against the "~700 lines"
archive rule in its own header — the split is a separate decision, not taken
here.


## 2026-08-31 — tool calling measured: the coding winner is weakest here

An agent lives on tool calls, and nothing measured so far touched them. New
`linux/llm-stack/bench_tools.py`; results in § 1f.

GenieX supports tool calling natively on both lanes (finish_reason=tool_calls,
correct names, correctly extracted arguments) -- the finding that could have
disqualified the current winner, and it did not.

| Model | Tool calls | Coding | Time |
|---|---|---|---|
| GGUF Qwen3-4B Q4_0 (CPU) | **12/12 = 100 %** | 44 % | 88 s |
| QAIRT 4B-Instruct (NPU) | **8/12 = 67 %** | 100 % | 25 s |
| GGUF Qwen3.8-2B (CPU) | 2/12 = 17 % | 44 % | 55 s |

This is the one benchmark that does not crown the coding winner. Its two
failures are reproducible and specific, and one is fixable by the user:

- picked list_files instead of read_file -- a selection error that disappears
  once the descriptions contrast explicitly ("returns CONTENTS" vs "returns
  names only, NOT contents"). Verified: FAIL -> PASS. Write tool descriptions
  contrastively; this model separates tools by their text, not their names.
- emitted the arguments as message TEXT instead of a tool call, with correct
  values but the wrong channel. tool_choice="required" does not fix it
  (verified). A fallback parser would recover the turn; opencode will not.

With better descriptions the realistic rate is ~10/12.

Every model handled the "no tool needed" case correctly, so over-eager calling
is not a problem here -- including the 2B, which failed everything else.

The recommendation stands but the trade-off is now stated: the GGUF 4B is
perfect at tool calls and hopeless at agent latency (34s prefill at 3k context,
151s at 8k, against the NPU's 3.2s), and an agent pays that on every turn.

15 grader tests, covering arguments as string or dict, prose instead of a call,
multiple calls, invalid JSON, exact boolean matching, and both directions of
the no-tool case.

## 2026-08-31 — the coding ranking, re-measured with repeats

A follow-up question ("did you test all configurations?") exposed two unchecked
assumptions. One held, one did not.

**Held:** the lane changes speed, not correctness. Qwen3-4B Q4_0 scores
identically on CPU and GPU (2/3 + 1 cut, the same task cut on both), the GPU
1.78x slower (397s vs 223s).

**Did not hold:** that temperature=0 makes a run reproducible. GenieX ignores
`temperature` exactly as it ignores `max_tokens`. Five identical requests to
the 2B produced FIVE different answers -- four passing the same task, one
failing. The same model scored 2/3 in one sweep and 0/3 in the next.

Re-measured with --repeats 3:

| Model | Pass rate | wrong | cut | per attempt |
|---|---|---|---|---|
| **QAIRT Qwen3-4B-Instruct-2507 (NPU)** | **9/9 = 100 %** | 0 | 0 | 10.2 s |
| GGUF Qwen3.8-2B-Distill (CPU) | 4/9 = 44 % | 5 | 0 | 10.5 s |
| GGUF Qwen3-4B Q4_0 (CPU) | 4/9 = 44 % | 0 | 5 | 101.9 s |

The winner survives intact and is strengthened: the QAIRT/QNN path is
byte-identical deterministic (four requests, one unique output per task), so
its 100 % is not a lucky draw.

Two things only repeats could show: the 2B has a real capability hole
(parse_version fails 3/3, its flakiness is confined to balanced), and the 4B
GGUF is never WRONG -- zero wrong answers in nine attempts, every failure the
2048-token cap. Given room it would likely match the winner; on this server it
cannot, and needs 10x the time per attempt.

Tuning the NPU lane does nothing: n-threads 3 -> 6 -> 8 with cpu-mask widened
to all cores gives 18.76 / 19.03 / 18.76 tok/s. The HTP does the work, those
threads only orchestrate, and perf_profile is already burst. Config restored.

Still unmeasured and recorded as such: the hybrid lane on coding tasks,
long-prompt coding, nctx scaling, --ngl.

## 2026-08-31 — measured: which model writes code that actually runs

Six models, three coding tasks each, code extracted and **executed** against
hidden tests (`linux/llm-stack/bench_coding.py`). Nothing judged by eye.

| Model | Lane | Pass | Cut | Total | ø tokens | think |
|---|---|---|---|---|---|---|
| **QAIRT Qwen3-4B-Instruct-2507 W4A16** | NPU | **3/3** | 0 | **30.2 s** | 188 | 0 % |
| GGUF Qwen3.8-27B Q4_0 | CPU | 3/3 | 0 | 128.7 s | 149 | 0 % |
| GGUF Qwen3.8-9B-Distill Q4_K_M | CPU | 3/3 | 0 | 251.1 s | 1151 | 51 % |
| GGUF Qwen3.8-2B-Distill Q4_K_M | CPU | 2/3 | 0 | 32.2 s | 485 | 37 % |
| GGUF Qwen3-4B Q4_0 | CPU | 2/3 | 1 | 227.2 s | 1639 | 61 % |
| QAIRT Qwen3-1.7B W4A16 | NPU | 1/3 | 2 | 173.8 s | 1829 | 31 % |

Three models solve all three tasks; time breaks the tie and it is not close.
The QAIRT 4B-Instruct is 4.3x faster than the 27B and 8.3x faster than the 9B
to the same score, because it does not reason -- 188 tokens per task against
the 9B's 1151.

The 27B beats the 9B while decoding at 5.6 vs 15.2 tok/s: ranking by tok/s
would have picked the wrong model, again.

A hard 2048-token output cap shapes the results more than model quality does.
GenieX ignores max_tokens outright (3000 -> 642 tokens; 500 -> 1249) and stops
at 2048. A reasoning model spends that inside <think> and is cut mid-function.
The 4B GGUF's balanced solution landed at 1896 tokens -- 152 short of the cap.
The first run of this benchmark scored that model 0/3 with all three failures
being truncation artefacts, which is why cut is now reported apart from wrong.

Caveat recorded with the numbers: three self-contained functions is a smoke
test, not a capability benchmark -- no multi-file work, no tool calls. And the
binding constraint for agent use remains the winning bundle's 4096-token
context, not its skill.

## 2026-08-31 — 2-bit measured; GenieX session harvested into an llm-stack backlog

**2-bit K-quants work; i-quants at any width do not.** `Qwen3-4B:Q2_K` is a
pure K-quant file (Q2_K 144, Q3_K 72, Q4_K 36, no i-quants) and produces
coherent output -- so the sub-Q4 failures really are the i-quant bug, not bit
width. It does cost accuracy: on a six-question verifiable battery at
temperature 0, Q4_0 scored 6/6 and Q2_K 4/6, losing exactly the two reasoning
items (letter counting 3->2, the machines/widgets puzzle 5->1) while keeping
arithmetic and factual recall. Six questions is a probe, not a benchmark, and
perplexity is not measurable through the OpenAI API. For the 27B it is moot:
the only sub-Q4 variants in that repo are i-quant based.

**New backlog group B/LLM-BENCH** (`docs/refactoring-backlog.md`): nine items
harvesting this session into `linux/llm-stack`, which already has a 502-line
benchmark harness, a sweep script and a React viewer. Every wrong conclusion
this session produced traces to a metric that harness does not collect:

- LB1 [M/3-star] a correctness probe -- it measures only speed, so the i-quant
  garbage would have scored *excellently* (fast, fluent nonsense)
- LB2 [S/3-star] TTFT/prefill; there is no first-token measurement at all,
  and prefill is what an agent actually waits on
- LB3 [S/3-star] report time-to-finished-answer; headlining tok/s ranks models
  wrongly (1.7B: fastest tok/s, slowest answer)
- LB4 [M/2-star] multi-endpoint + concurrent lane aggregate
- LB5 [S/2-star] batching/serialization probe
- LB6 [S/2-star] GGUF tensor-type introspection -- what actually diagnosed the
  i-quant bug, since no benchmark could
- LB7-LB9 [S/1-star] de-Ollama the harness (hardcoded gemma4:26b at line 171),
  worker-vs-listener resource attribution, Linux-only hardware info

## 2026-08-31 — CORRECTION: the sub-Q4 garbage is a GenieX i-quant bug, not a quality floor

The previous entry claimed "a hard quality floor at Q4 -- both 3-bit quants
answer with garbage, everything below is smaller still". The observation was
right; the explanation was wrong, and the extrapolation was unfounded.

Hypotheses walked down in order:

  sampling artefact   temperature=0, "Say hello."      still garbage; Q4_0 fine
  corrupt download    SHA256 vs the HF LFS oid         byte-perfect
  CPU-backend bug     same file on the GPU lane        fails there too
  "UD quants are bad" UD-Q4_K_M from the same repo     works fine
  "3 bits is too few" Qwen3-4B:Q3_K_M (3-bit K-quant)  works perfectly
  i-quant kernels     Qwen3-4B:IQ3_XXS                 garbage on BOTH lanes

The discriminator is the tensor *type*, not the bit width. GGUF tensor
histograms: the working files carry no i-quants below 4 bits (Q4_0: none;
UD-Q4_K_M: IQ4_XS 117, IQ3_S 4; Q3_K_M: pure K-quants), the broken ones are
dominated by them (UD-Q3_K_XL: IQ3_S 111 + IQ3_XXS 34 + IQ2_* 21; UD-IQ3_S:
IQ3_S 127 + IQ3_XXS 77 + IQ2_* 45 + IQ1_S 2; Qwen3-4B-UD-IQ3_XXS: IQ3_XXS 144
+ IQ2_S 52 + IQ3_S 41).

So: IQ4_XS and IQ4_NL are fine; IQ3_S, IQ3_XXS, IQ2_* and IQ1_* are broken in
the llama.cpp build GenieX v0.5.0 ships (runtime hash 873e5d8, aarch64). It
reproduces across two architectures (qwen3, qwen35), two sizes (4B, 27B) and
both compute lanes, on files verified byte-identical to Hugging Face -- so
neither a bad download nor a bad quantisation.

Consequences: never pull IQ1_*/IQ2_*/IQ3_* for this setup, for any model
(UD-Q2_K_XL is i-quant-heavy too and should be assumed broken); 3-bit itself is
fine, so a plain Q3_K_M is worth seeking out; the practical "do not go under
Q4_0 in this repo" advice survives, but only because this repo's sub-Q4
offerings all happen to be i-quant based. Worth reporting upstream to
qualcomm/GenieX, and worth re-testing after a runtime bump.

## 2026-08-31 — 27B quant ladder mapped end to end; Q4_0 stays

Enumerated every quant `unsloth/Qwen3.8-27B-GGUF` offers (22 variants, IQ1_S
6.2 GB through Q8_0 29 GB) and bounded them against the real constraint: host
RAM. 31.6 GB total minus WSL2's 10 GB cap and Windows leaves ~22-24 GB, so
Q6_K (22 GB) and up cannot run at all and Q5_K_S (18.7 GB) is the ceiling.

Pulled `UD-Q4_K_M` (16.5 GB) and measured it head to head against `Q4_0`:

  Q4_0      5.62 tok/s   TTFT 1.06 s
  UD-Q4_K_M 5.08 tok/s   TTFT 2.38 s    (~10% slower)

Output was equivalent on a code task, and both answered a verifiable arithmetic
check correctly (847 * 293 -> 248171). Likely cause of the gap: llama.cpp
repacks legacy Q4_0 into ARM kernels (Q4_0_4_8 / i8mm) that K-quants do not get
-- the same mechanism that makes the CPU lane fast at all.

Two prompts is not a quality evaluation, and the docs say so: UD-Q4_K_M is in
principle the better quantisation; the honest finding is only that no quality
difference was demonstrable while the 10% speed cost was.

Also documented: a hard quality floor at Q4. Both 3-bit quants (IQ3_S,
Q3_K_XL) load, answer, and return garbage, and everything below them is
smaller still -- so nothing under Q4_0 is worth pulling.

Bottom line unchanged: Q4_0 on the CPU lane is the 27B setup to use.

## 2026-08-31 — full Qwen3.8 lane matrix; 27B rehabilitated, Q3_K_XL retired

Every cached Qwen3.8 model against every lane, one prompt, one methodology:

| Model | Size | NPU | GPU | hybrid | **CPU** |
|---|---|---|---|---|---|
| 2B-Distill `Q4_K_M` | 1.3 GB | 18.2 | 23.1 | 20.7 | **47.6 tok/s** |
| 9B-Distill `Q4_K_M` | 5.8 GB | 8.4 | 6.8 | 7.35 | **15.2 tok/s** |
| 27B `Q3_K_XL` | 13.1 GB | ❌ | ❌ | ❌ | garbage output |
| 27B `Q4_0` | 16.1 GB | ❌ | HTTP 500 | ❌ | **5.6 tok/s** |

The CPU wins every row. The accelerator ranking flips with model size (2B:
GPU > hybrid > NPU; 9B: NPU > hybrid > GPU) and it makes no difference — the CPU
is 2-2.6x ahead of whichever one wins.

**The 27B was written off too early.** This page said "CPU-only territory...
~1 tok/s". Measured on the Windows host: **5.6 tok/s warm, 1.06 s TTFT, correct
well-structured code**. Slow for chat, fine for batch, and the best quality any
lane here can produce.

**`Q3_K_XL` is broken, not borderline.** Previously "the last quant worth trying
above 12 GB". It loads, answers, and returns garbage -- a real request gave
`'0\n\n\n\n\n\n\n\n -\n0\n0'` (12 tokens, finish_reason stop), the same
failure already noted for IQ3_S. Below Q4 this 27B is unusable at any speed.

**New crash found: mixing QAIRT and GGUF on the NPU lane kills the server.**
Deterministic -- fresh lane serves GGUF fine, serves a QAIRT bundle fine, and
the next GGUF request resets the connection and the process is gone. An opencode
provider lists several models against one baseURL, so switching model in the UI
is enough to trigger it. opencode.jsonc now keeps the NPU lane QAIRT-only and
gains a `geniex-cpu` provider for the GGUFs (which are faster there anyway).

## 2026-08-31 — hybrid falsified: no `--ngl` setting beats plain CPU

`--compute hybrid` was previously documented as "the sweet spot for models that
straddle the HTP budget". That conclusion compared hybrid against the NPU and
the GPU — **never against the CPU**. With the CPU lane measured, hybrid loses
everywhere:

| Model | hybrid | **CPU** | GPU | NPU |
|---|---|---|---|---|
| Qwen3-4B `Q4_0` | 9.96 tok/s | **23.7** | 12.5 | 11.9 |
| Qwen3.8-9B-Distill `Q4_K_M` | 7.5 tok/s | **15.2** | 6.5 | over HTP budget |

The 9B — the model hybrid supposedly existed for — is **2x faster on plain CPU**
(15.2 vs 7.5), first token 0.44 s instead of 26.6 s.

Swept `--ngl` on the 9B in hybrid mode to check whether the layer split was
simply mistuned: `-1` → 7.32, `32` → 7.20, `16` → 6.18, `8` → 7.83 tok/s. Every
configuration sits at 6–8 tok/s with a 14–27 s first token. The split is not the
bottleneck; any HTP participation drags the graph to `ggml-hexagon` speed.

**Verdict: `--compute hybrid` has no use on this machine.** Slower than CPU on
every model, 30–60x worse TTFT, and the only mode that damages a concurrent NPU
lane (19.25 → 12.84, shared HTP). Docs, launcher help and AGENTS.md now say so.

Also added: an § At a glance decision table at the top of the page, measured 9B
CPU figures in the model matrix, and a note that the original short-reply rows
and the re-measured full-stream rows are two methodologies that must not be
compared across.

## 2026-08-31 — Measured: the CPU beats the Hexagon NPU 2x on GGUF

The CPU rows on this page were *estimates scaled from a 27B WSL2 run* (~5 tok/s
for the 4B). Measured properly against a `--compute cpu` lane on the Windows
host (8x Oryon), same model, same quant, same prompt, they were wrong by ~4.6x:

| Model (GGUF) | CPU | NPU | CPU advantage |
|---|---|---|---|
| Qwen3-4B `Q4_0` | **23.2 tok/s** | 11.9 tok/s | **1.95x** |
| Qwen3.8-2B-Distill `Q4_K_M` | **46.5 tok/s** | 16.9 tok/s | **2.75x** |

llama.cpp's ARM CPU kernels (NEON/dotprod/i8mm; `Q4_0` is repacked for them) are
simply more mature than the bundled `ggml-hexagon` backend.

The NPU still earns its place, on two other axes: it runs QAIRT bundles (which
the CPU cannot load at all, and which are non-thinking and therefore fastest
end-to-end — 26.8 s vs 88.4 s to a finished answer), and it does so at
**165 % of 800 % CPU vs the CPU lane's 752 %** — a fifth of the cost, which is
what keeps the machine usable while the agent answers. Measurement note: the
inference worker is a *separate* `geniex` process from the port holder; sampling
the listener reads ~11 % and tells you nothing.

- `start-geniex-servers.ps1`: new `-WithCpu` opt-in lane on 18184
- docs: new § 1b, and the estimated CPU row replaced with measured numbers

## 2026-08-31 — GenieX throughput pass: QAIRT bundle + NPU/GPU dual lane (~6x faster agent answers)

Re-measured the Snapdragon on-device agent end-to-end rather than per compute
unit. The previous "4B on the NPU at 15.2 tok/s is the ceiling" conclusion
optimised the wrong variable; three larger wins were found and applied.

### The QAIRT bundle beats every GGUF here (~6x end-to-end)

`qualcomm/Qwen3-4B-Instruct-2507:W4A16` was cached but never benchmarked:

| | GGUF 4B Q4_0 | QAIRT 4B W4A16 |
|---|---|---|
| decode | 11.5 tok/s | **18.9–19.5 tok/s** |
| tokens per short answer | ~1889 | **522** |
| wall clock (warm) | 164.8 s | **26.8 s** |

Re-tested against `qualcomm/Qwen3-1.7B:W4A16`, which is *faster per token and
slower in practice*: **31.7 tok/s but 1921 tokens per answer = 60.8 s**, versus
the 4B's 19.5 tok/s / 522 tokens / **26.8 s**. Time-to-finished-answer is the
metric; tok/s alone picks the wrong model.

1.7x of that is decode; the rest is the **`<think>` tax** — the Qwen3/Qwen3.8
GGUFs are reasoning models (21 tokens to answer "reply with exactly one word"),
the Instruct-2507 bundle is not (2 tokens). It also runs at **3.0 GiB, above the
~2,93 GiB HTP vmem wall** — that ceiling is a property of the bundled llama.cpp
`ggml-hexagon` backend, not of the NPU.

### One server = one request; NPU + GPU compose, hybrid contends

`geniex serve` does no batching — a second request waits for the first to finish
completely (27.6 s TTFT), and a busy server will not even answer `/v1/models`.
Measured topologies: **NPU+GPU = 19.25 + 12.11 = 31.4 tok/s** (~1–3 % mutual
cost, separate silicon), while adding `hybrid` (NPU+CPU, same HTP) buys
+2.7 tok/s aggregate but drops the NPU lane to 12.84.

### Two defaults were wrong for agent use

`--keepalive` 300 s unloaded the model on every pause (14–15 s cold reload);
`--nctx` 4096 was *below* the 8192 the opencode config advertised, and overflow
does not error — a 6.4k-token prompt never returned within 400 s.

- New `windows/scripts/host/start-geniex-servers.ps1`: brings up the NPU + GPU
  lanes with `--nctx 16384 --keepalive 86400`, `-WithHybrid` for the third lane,
  `-Restart` to recycle. Validated live.
- `~/.config/opencode/opencode.jsonc`: QAIRT bundle promoted to primary, new
  `geniex-gpu` provider for the second lane.
- **QAIRT bundles carry a hard-compiled 4096 context** (`genie_config.json`
  → `"context": {"size": 4096}`); `--nctx` is llama.cpp-only and does not raise
  it. Overflow returns nothing rather than erroring. The opencode limit for the
  QAIRT model is set to 4096 accordingly — this is the binding constraint of the
  NPU lane, not its speed.
- § Wire the coding agent rewritten as a 5-step opencode integration guide
  (pull → serve → provider block → model select → verify) with the four silent
  misconfigurations that break it.
- [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): new
  § Getting the most out of this machine, plus five troubleshooting rows.

Still slow, honestly: **prefill dominates agent latency** — a 2.5k-token prompt
costs 13.1 s to first token (~190 tok/s) and pulls decode down to 13.0 tok/s.
No batching or speculative-decoding knobs exist in `geniex serve`, and
`max_tokens` is not honoured.


## 2026-08-31 — QNN SDK integrated into the arm64 cross build (#121 proven) + GStreamer compiler-rt self-heal (#135 follow-up)

### QNN EP build-time path PROVEN on the arm64 cross lane (#121)

The staged QAIRT SDK (qairt-2.44.0.260225, SHA-pinned) was exercised end-to-end
for the first time on a full `-TargetArch arm64` cross run:

- `Resolve-QnnSdk` verified the SHA, extracted the SDK and enabled
  `onnxruntime_USE_QNN=ON` with the `aarch64-windows-msvc` backend set
- ONNX Runtime built the QNN provider (symbol file `['cpu', 'qnn', 'dml']`),
  `QNN_SDK_ZIP_SHA256` forwarded driver → Dockerfile ARG → ENV → build script
- The run reached the merge stage (the last arm64 acceptance gate); the only
  failure was the unrelated GStreamer link below

### GStreamer cross-lane compiler-rt self-heal (#135 follow-up)

`C:\llvm-patched` (the source-built default toolchain) ships
`clang_rt.builtins-x86_64.lib` only, so the arm64 GStreamer link died on
`__udivti3` in the merge stage. `build-gstreamer-from-source.ps1` § 5d now
self-heals on the cross lane: it mines `clang_rt.builtins-aarch64.lib` from the
official LLVM release archive next to the x86_64 lib (same recipe as
`setup-scoop-tools.ps1`), then re-runs its candidate search. The first live
attempt used the GNU tar on PATH, which parses `C:\...` as a remote-host spec
("Cannot connect to C:") — the extract now forces System32's bsdtar (the same
trap build-llvm-from-source.ps1 already avoids). Chosen over adding the lib to
the toolchain layer because the media branches derive FROM
`bk-windows-toolchain` — that would have re-paid ~2 h of media compiles for one
lib. Regression test: `SourceBuild.GstreamerCompilerRt.Tests.ps1` (4 tests).
Docs: `docs/windows-cross-builds.md` § aarch64 compiler-rt;
`docs/windows-refactor-backlog.md` #135 follow-up.

The compiler-rt fix unmasked the speculative cross-lane opus intrinsics
enablement (added 2026-08-30), which had never reached a real compile: the RTCD
path applies `-mfpu=neon` (ARM32-only; clang-cl rejects it for aarch64) and its
CPU probe `celt/arm/armcpu.c` uses MSVC's `__emit` (absent from clang-cl).
REVERTED to the proven 2026-08-26 shape — `-Dopus:intrinsics=disabled` on both
lanes; the working enablement recipe (`intrinsics=enabled` + `rtcd=disabled`,
which needs a real-device smoke because it presumes NEON+dotprod) is recorded in
`docs/windows-cross-builds.md` and the backlog. Regression test extended to 6
assertions.

The arch-gate import walk then flagged the staged QNN runtime: the QAIRT HTP
stub DLLs import `libcdsprpc.dll`/`libadsprpc.dll` — Qualcomm's FastRPC
drivers, which ship in every Windows-on-Snapdragon OS image (never in the SDK
zip). Added to the gate's client-OS allowance (`ClientOsPattern`); regression
assertion in `SourceBuild.VerifyTargetArch.Tests.ps1`.


## 2026-08-31 — WSL2 RAM tuning: host gets ~20 GB back; 27B loads on GPU but stays impractical

The GenieX models run on the Windows host, but the host `.wslconfig` had capped
WSL2 at **30.3 GB of 31.6 GB**, and WSL contained ~4.3 GB of orphaned dead
weight. Both fixed:

- `.wslconfig`: `memory=10GB` + `autoMemoryReclaim=gradual` + `swap=4GB`
  (backup of the old file kept). WSL now reports ~9.7 GB total; the Windows
  host went from ~2 GB free to **~18–21 GB free**.
- WSL cleanup (elevated commands, documented): rootful `containerd.service`
  stopped+disabled (killed orphaned Elasticsearch + Collabora containers,
  ~2.5 GB) and `pkill` of orphaned clamd/freshclam + postgres (~1.1 GB).
  Containers from a running compose (llm-stack glances) kept.
- **What the RAM buy actually gives:** the 27B Q3_K_XL (13.1 GB) now *loads* on
  the Adreno GPU (was `CL_OUT_OF_RESOURCES`), but generation is still
  impractical there — 2.0 tok/s, 9.1 s first token, and the server hung under
  the first real request (HTTP 000, 14.4 GB RSS, killed to release RAM). The
  honest bottom line is now in the docs: on this machine, the GPU serves up to
  the 9B-Distill; the 27B stays CPU territory; the NPU serves 2B/4B fastest.
- New docs section "Making room: WSL2 RAM tuning" in
  [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): the
  `.wslconfig` cap + `autoMemoryReclaim`, the elevated cleanup commands, and
  the reality check (what freed RAM did and did not buy).

## 2026-08-31 — hybrid actually measured: 9B distill runs at 7.5 tok/s (faster than GPU)

Tested `--compute hybrid` against every Qwen3.8-class model on this Snapdragon
X, with the surprise that **hybrid is the right path for models that straddle
the HTP budget**:

- **Qwen3.8-9B-Distill Q4_K_M (5.78 GB)** does not fit the ~3 GB HTP alone but
  runs on `--compute hybrid` at **7.5 tok/s — faster than the same model on the
  GPU (6.5 tok/s)**. Hybrid offloads the layers that fit the HTP and runs the
  rest on CPU.
- **Qwen3.8-27B Q4_0 crashes on hybrid too** (like pure NPU): the single HTP
  cannot even stage a fraction, so there is no partial-offload win. 27B stays
  CPU-only territory (or GPU Q3_K_XL at degraded quality).
- Full measured envelope table added to
  [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md): NPU
  16.9 (2B) / 15.2 (4B), hybrid 7.5 (9B), GPU 13.2 (4B) / 6.5 (9B). CPU numbers
  for 2B/4B/9B are marked as estimates; NPU/GPU/hybrid are all measured.
- Bottom line: **no single model combines GPU+NPU** (hybrid = NPU+CPU only);
  you cannot add the GPU to hybrid. Docs now state this plainly and recommend
  2B-Distill (NPU) / 4B (NPU) / 9B-Distill (hybrid) per task weight.

## 2026-08-31 — hybrid compute truth + Qwen3.8 model matrix

Clarified what GenieX v0.5.0 can and cannot do with all three accelerators, and
which Qwen3.8-class models fit this Snapdragon X — all verified live:

- **`--compute hybrid` is the per-tensor NPU scheduler, NOT "GPU+NPU at once".**
  The device alias resolves to `DeviceID:""` + `ngl != 0`, which the llama_cpp
  plugin classifies as NPU; the HTP runs the layers that fit and CPU takes the
  rest. Measured 14.1 tok/s on the 4B (pure NPU: 15.2). A single model runs on
  HTP(+CPU fallback) or GPU, never both simultaneously.
- **Multi-HTP device lists** (`--compute HTP0,HTP1,...` + `GGML_HEXAGON_NDEV`)
  spread a model across several HTP cores — but this X126100 has a single HTP
  (hwinfo `threads 4, hvx 4, hmx 1`), so the list degenerates to one device.
- **QAIRT bundles are NPU-only** — `--compute cpu/gpu` on one is coerced back
  to NPU with a warning.
- **Run both accelerators at once**: one `geniex serve` binds one default
  compute; run a second server on another port (`--host 0.0.0.0:18182`) and
  point the agent at the right base URL per model.
- **Qwen3.8 model matrix** (verified): `Qwen3.8-2B-Distill` Q4_K_M 1.31 GB →
  NPU 16.9 tok/s (fits ~3 GB HTP); `Qwen3-4B` Q4_0 → NPU 15.2 / GPU 13.2;
  `Qwen3.8-9B-Distill` Q4_K_M 5.78 GB → GPU only (over HTP budget);
  `Qwen3.8-27B` → CPU territory (see quant ladder); `Qwen3.8-Flash-Next` too
  large for this class of machine. Docs updated with the matrix and an
  NPU-first opencode provider example.

## 2026-08-31 — GenieX NPU FIXED by a Qualcomm Hexagon NPU driver update + NPU probe

**The NPU now works.** Updating the Qualcomm Hexagon NPU driver
(`libcdsprpc.dll` 30.0.0140.1000 → 30.0.0220.3000; Hexagon NPU device driver
30.0.220.3000, installed via Windows Update optional driver updates + reboot)
fixed both NPU backends. Root cause (documented in
[`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md) § The NPU
problem): the old driver's `libcdsprpc.dll` exported only the legacy FastRPC
API, not the `dspqueue_*` symbols GenieX v0.5.0's bundled llama.cpp
`ggml-hexagon` backend dlsyms (`dspqueue_create` etc. — verified per-symbol
with `GetProcAddress`). QAIRT/QNN showed a different symptom of the same root
cause: `Exception 0xc00000fd` (STATUS_STACK_OVERFLOW) in HTP runtime init.

- Measured after the fix: **4B on NPU at 15.2 tok/s (0.2 s first token)** —
  faster than the Adreno GPU (13.2 tok/s) and far faster than CPU. Verified
  end-to-end through the OpenAI server from WSL2.
- Remaining limit: the Hexagon HTP has ~3 GB vmem (`vmem 3145728000` in the
  load log), so the 27B fails at graph compute with `dspqueue_read failed:
  0x00000072` — a memory limit, not a driver bug (same class as
  ggml-org/llama.cpp#26123).
- New probe `windows/scripts/diagnostics/probe-geniex-npu-driver.ps1`: checks
  the **active** CDSP `libcdsprpc.dll` (matched by Hexagon-NPU device driver
  version, so stale DriverStore copies cannot falsify the verdict) for the
  `dspqueue_*` symbols. Reporting-only, never throws on a negative. Documented
  in `docs/windows-builds.md` § Script Reference.
- Docs updated: measured envelope now NPU-first; troubleshooting table covers
  the pre-fix `dlsym` failure, the QAIRT stack overflow, and the post-fix HTP
  memory limit.

## 2026-08-31 — GenieX on-device OpenAI server for Snapdragon (docs + host tooling)

New page [`docs/geniex-local-ai-setup.md`](docs/geniex-local-ai-setup.md):
run Qualcomm GenieX (BSD-3-Clause) so a coding agent inside **WSL2** talks to a
local OpenAI-compatible API backed by the Windows host's **Adreno GPU** (or
Hexagon NPU). WSL2 has no NPU/GPU passthrough, so the server runs on Windows
and WSL2 reaches it at `127.0.0.1:18181` via mirrored networking.

- Deployed and measured live on a Lenovo Snapdragon X (2026-08-31): GPU 4B at
  13.2 tok/s, clean output, verified end-to-end through the OpenAI API; the
  27B's usable quant window on the Adreno is ≤ ~13 GB (Q4_0 @ 16 GB OOMs with
  `CL_OUT_OF_RESOURCES -5`; IQ3_S @ 12 GB loads but 3-bit quality is unusable —
  whitespace output).
- **NPU root cause documented** (not just "broken"): both NPU backends fail
  against the installed Qualcomm CDSP/FastRPC driver (1.0.4175.2700,
  20.11.2024; `libcdsprpc.dll` v30.0.0140.1000):
  - llama.cpp Hexagon backend: `failed to dlsym dspqueue_create` — the driver
    exports only the older FastRPC API (`remote_handle_open`), not the
    `dspqueue_*` symbols the bundled backend needs (verified per-symbol).
  - QAIRT/QNN backend: `Exception 0xc00000fd` (STATUS_STACK_OVERFLOW) in the
    QNN v2.45.0 HTP runtime init — same stale-driver family, different symptom.
  - Fix is a **Qualcomm CDSP/FastRPC driver update** (Windows Update optional
    updates / Lenovo driver page); GenieX v0.5.0 is already the latest release.
    Until then `--compute gpu` is the working accelerated path.
- Also handled: SoX install + user-PATH for the serve warning; non-interactive
  chipset config (`geniex config set chipset qualcomm-snapdragon-x-elite`);
  local cache copy across Windows/WSL2 to avoid re-downloading 16 GB; the WSL2
  localhost port-shadowing trap that prevents the Windows server from binding.
- Docs wiring: `docs/INDEX.md`, `docs/index.rst` (toctree), `README.md`,
  `AGENTS.md` § GenieX on Snapdragon, and a `deps.json` entry under Host Build
  Infrastructure (BSD-3-Clause) — licence pages and curated SBOM regenerated.

## 2026-08-30 — rebuild window: GCC_PARALLEL_TARGETS validated (2 bugs found+fixed), F2 media validation, launcher server-death gap fixed

The tasks that needed a real rebuild, run and closed:

### GCC_PARALLEL_TARGETS validation — PASS, and it surfaced two real bugs

- **92fb9646 — the launch flag was silently dropped (the real "missed four
  times" cause).** No `ARG GCC_PARALLEL_TARGETS` in Dockerfile.toolchain and no
  `--build-arg` in the compiler-stage args, so a launch-time
  `GCC_PARALLEL_TARGETS=1` never reached the container and the sequential path
  won every time. Fixed: ARG + ENV in Dockerfile.toolchain (mirrors
  `GCC_HOST_BOOTSTRAP`), `append_optional_build_arg` forwarding in
  stage-defs.sh's compiler case (only when set; Dockerfile defaults stay
  authoritative), pinned by test-stage-defs.sh. Dry-runs now emit
  `--build-arg GCC_PARALLEL_TARGETS=1` when set, absent when not.
- **5e8b2470 — the first parallel launch collided on the dpkg apt lock.**
  The concurrent per-target `build-gcc.sh` invocations each ran their own
  "Installing build dependencies..." apt_install; two apt-get at once die on
  `/var/lib/apt/lists/lock`. Fixed: `GCC_SKIP_BUILD_DEPS=1` gates build-gcc.sh's
  apt step (deps already installed by `build_host_gcc`, which runs first) and
  the parallel driver exports it after the serial pre-pass. Sequential path
  unchanged.
- **Result:** local compiler build with `GCC_PARALLEL_TARGETS=1` GREEN —
  amd64 linked serially, arm64 + riscv64 cross-GCC concurrent (JOBS=16 each),
  both OK; two cross targets in ~531s wall vs ~984s sequential (~30% GCC-RUN
  saving, as documented). Full toolchain smoke 41/41 PASS, image
  `cross-compiler-amd64` loaded. This also validated TG1/TG3 (trimmed per-RUN
  mounts) and F2's toolchain call sites (`sccache gcc/g++` live).
- Follow-up logged: the ERR-trap in logging.sh `_install_trap` fired with
  `action` unbound under set -u when triggered outside the function's dynamic
  scope, masking the real apt error. Not in this wave.

### F2 media validation — PASS (sdk→media→android, amd64)

Full chain from sdk pushed for amd64. The one-resolver cache consolidation was
exercised in every media RUN: `compiler cache enabled:
launcher=/opt/scripts/core/sccache-launcher.sh`, **100 % C/C++ cache-hit
rate**, 27 artifact-verify OK, android built and pushed. modules.sh reorder and
the QNN-off fan-out path (litert/tvm/app-wheelhouse/genai with no zip) all ran
the new code without regression.

### 0371d164 — sccache-launcher server-death gap FOUND live + FIXED

The validation build caught a second failure class the guarded launcher did
not handle: the sccache **server died mid-build** under full concurrent-media
load and sccache reported `sccache: error: failed to execute compile / caused
by: Failed to send data to or receive data from server / failed to fill whole
buffer`. The launcher only bypassed on `sccache: encountered fatal error` (the
TryCompile ENOENT class), so it handed the dead-server error to ninja as a REAL
failure and killed the TVM step. Fixed by widening the bypass classification to
any sccache-prefixed internal error (`sccache: (encountered fatal error|error:|
caused by:)`) — safe because sccache prefixes only its own failures with
`sccache:`; a real compiler error is echoed un-prefixed and passes through.
Pinned by the new tests/test-sccache-launcher.sh (8 assertions incl. a
mutation case proving the old narrow match would NOT have bypassed). The media
rebuild running after this lands re-validates the fix live and restores the
TVM wheel lost to the dead server (the failure was non-fatal by design).

### QNN-LINUX fan-out validation — BLOCKED on the login-gated SDK

The real QAIRT zip is not on the host (removed after the PROVEN build per the
qnn-sdk README discipline; /tmp/qnn-sdk-extract now holds only a synthetic test
stub). Re-staging is the owner's move (qpm.qualcomm.com, EULA), then re-pin
`QNN_SDK_LINUX_ZIP_SHA256`. The no-zip fail-safe path across every framework
was validated by the media builds above.

## 2026-08-30 — second pass: --no-push chains SAFE (OCI-layout handoff) + source_module recursion fix

Backlog item C is closed: **full `--no-push` chains are no longer refused** —
every stage built locally is exported to an OCI layout and handed to the child
via `--build-context <parent-tag>=oci-layout://<dir>`, so a child's FROM never
resolves against the registry (the 2026-08-08 stale-parent bug). The android
image is additionally exported for the runtime lane, and the mid-chain resume
case stays refused (no locally-built prefix to serve).

- `01-core/cross-stage-build.sh` — `cross_local_handoff_enabled()`,
  `cross_ensure_local_context_workdir()` (per-run
  `${CROSS_CONTEXT_ROOT:-~/.cache/opencode/cross-stage-contexts}/cross-flow.*`,
  age-based orphan sweep), `cross_stage_context_dir()`; parent resolution in
  `_cross_stage_run_resolve_parent` appends the `--build-context` when the
  parent was built this run; `cross_stage_run` exports every local stage after
  the build, and android to `<workdir>/android-artifacts/<arch>`.
- `build-cross-chain.sh` — guard relaxed (full chain allowed, mid-chain
  refused; `CROSS_LOCAL_CONTEXT_HANDOFF=0` reverts, `CROSS_NO_PUSH_FORCE=1`
  bypasses), parse-time message + `--no-push` usage text updated,
  `run_runtime_stage` passes `ARTIFACT_CONTEXT_ROOT`+`ARTIFACT_CONTEXT_MODE=oci`
  to the helper under `--no-push`, `_chain_on_exit` reclaims the workdir.
- `01-core/modules.sh` — `source_module` resolves FRAMEWORK dirs before
  `${caller_dir}/${name}`. The old order made a bare
  `source` of ONNX's `build/lib/common.sh` (SCRIPT_DIR unset) resolve
  `source_module "common.sh"` to that very file — an infinite re-source loop
  ending in a stack-overflow SIGSEGV. All `source_module` names are 01-core
  modules, so the caller-local slot is now only a last resort.
- New suites: `tests/test-cross-oci-handoff.sh` (15 assertions — parent-context
  append, registry fallback when unbuilt, push=1 never, guard matrix incl.
  mutation-style refusal cases) and `tests/test-module-resolution.sh`
  (5 assertions — order, the ORT recursion shape under timeout, caller-local
  last resort; mutation-verified against the pre-fix `modules.sh`: 3/5 fail).
- Live-proven on the host: two-stage test build — stage B's `FROM` resolved
  from the exported layout (`--pull=false`, content marker verified), never
  the registry.
- Docs: AGENTS.md quick-ref, `docs/linux-cross-builds.md` § "--no-push full
  chains: FIXED", backlog C closed, archive entry.

## 2026-08-30 — Backlog sweep: F-entries closed (OpenCV-sccache refuted), one-resolver cache consolidation, QNN-LINUX fan-out wired

Three parallel threads, one day: the two remaining F-section items are gone
from the open backlog, the cache launcher resolution has exactly one resolver,
and the QNN-LINUX framework fan-out (GenAI/LiteRT/TVM/IREE) is wired on the
shared SDK module — all fail-safe by construction (no zip = byte-identical
existing behavior).

### OpenCV-sccache entry REFUTED, F2 DONE (docs/refactoring-backlog-archive-2026-08-30.md)

- **"sccache caches NOTHING in the OpenCV step" — closed by REFUTATION.** Log
  forensics on the staged-media* and media-arm64 logs showed the 2359 bypass
  messages the entry cited were the pre-UDS wrong-server bug (concurrent
  BuildKit steps reaching each other's sccache server on the fixed TCP port;
  `caused by: No such file or directory (os error 2)` — exactly what
  docs/build-cache-tiers.md § 5.1 already recorded as fixed by
  b4078ad1 + 4aa92fb6), and that the faults appeared in the ORT step too —
  not OpenCV-exclusive as claimed. Every post-UDS run has 0 bypass messages,
  including the 2026-08-30 QNN-LINUX arm64 media build, where OpenCV compiled
  all 1660 objects through the launcher and the sibling ffmpeg step recorded a
  99.64 % hit rate. No code change needed; the misdiagnosis is archived with
  the evidence so it is not re-discovered.
- **F2 — compiler-cache abstraction consolidation: DONE.** New
  `_resolve_compiler_cache_launcher()` in `01-core/compiler-cache.sh` routes
  every launcher decision through common.sh's `compiler_cache_launcher()`
  (all media/ORT callers) with an inline bootstrap fallback for the android
  preamble, which sources compiler-cache.sh standalone. Both paths implement
  the identical decision (guarded launcher > sccache > ccache, never empty);
  `setup_ccache` and `setup_sccache` both consume it; the
  verify-critical-fixes.sh gate still passes without edits. Pinned by the new
  suite `linux/scripts/tests/test-compiler-cache.sh` (8 assertions, incl.
  mutation checks and the "Rust keeps sccache-class on a ccache verdict"
  property). Behavior-identical by construction; a media run validates the
  stats lines.

### QNN-LINUX framework fan-out WIRED (validation build pending)

- **NEW `01-core/qnn-sdk.sh`** — shared QAIRT resolution + runtime staging,
  moved out of ORT's lib/common.sh (which now sources it and hard-requires the
  two functions). Unit-tested end-to-end against a synthetic QAIRT zip:
  resolution, sha256 verification, `libQnn*.so` + `hexagon-v*` staging, and
  the arm64/no-zip gates.
- `03-media/core/common.sh` — `media_common_init` loads `qnn-sdk.sh`
- `60-build-genai.sh` — stage QNN backend libs beside the GenAI install
- `build-litert.sh` — `TFLITE_ENABLE_QNN=ON -DQNN_HOME=<home>` + NPU=ON when
  a zip is staged (else the NPU=OFF/`QNN=OFF` defaults), in BOTH the cmake
  configure and the wheel `EXTRA_CMAKE_FLAGS`, plus post-install staging
- `tvm-config.sh` / `tvm.sh` — `USE_QNN=ON -DQNN_HOME=<home>` (else explicit
  `-DUSE_QNN=OFF`) in `append_tvm_cmake_args`, post-install staging in main;
  `tvm.sh` loads the module
- `build-app-wheelhouse.sh` — `IREE_TARGET_BACKEND_QNN=ON -DQNN_HOME=<home>`
  (else `OFF`); no runtime staging on Linux (wheel-only cross lane)
- `Dockerfile.media` — `linux/qnn-sdk` bind mount added to the litert, tvm
  and app-wheelhouse RUNs (was cpu/genai only)
- Every path is gated on a staged zip: no zip = today's behavior byte-for-byte
  (verified per-arch by the module tests). The validation build (staged QAIRT
  v2.49 on arm64) answers whether all five flags stay green and the libs land.


## 2026-08-30 — QNN-LINUX: Qualcomm QAIRT/QNN EP wired + PROVEN for Linux ARM64 (Snapdragon)

Wired the ONNX Runtime QNN execution provider onto the Linux `arm64` lane,
targeting Snapdragon NPU inference. Same opt-in contract as the Windows QNN
EP (#121): login-gated SDK zip dropped by hand in `linux/qnn-sdk/`; no zip =
QNN off with a notice. Different SDK from Windows: Linux AArch64 extracts to
`lib/aarch64-oe-linux-gcc11.2/`, not `aarch64-windows-msvc`.

**PROVEN on real SDK (2026-08-30):** staged QAIRT v2.49.0.260730,
`cross-media-arm64` build GREEN. `libonnxruntime_providers_qnn.so` compiled
and linked; 45 `libQnn*.so` backend libs + 7 `hexagon-v*` skel dirs staged
beside ORT; `verify-media-artifacts.sh onnxruntime-cpu` PASS; smoke suite 0
failures. The upstream QNN_ARCH_ABI risk is RESOLVED: ORT CMake accepts
`-DQNN_ARCH_ABI=aarch64-oe-linux-gcc11.2` (cache var, not hardcoded).

- `linux/qnn-sdk/README.md` — opt-in drop point + contract
- `.gitignore` — `linux/qnn-sdk/*` rule (symmetric with `windows/qnn-sdk/*`)
- `versions.env` — `QNN_SDK_LINUX_ZIP_SHA256` pinned to the staged zip's sha256
  (`32de9b5b...`, `# noforward`)
- `onnxruntime/build/lib/common.sh` — `resolve_qnn_sdk` (locate/verify/extract
  the SDK, QNN_OP_STFT canary) + `stage_qnn_runtime` (copy `libQnn*.so` +
  `hexagon-v*` skel beside ORT install). `info()` redirected to `stderr` (>&2)
  inside both functions to keep `$(...)` capture clean.
- `30-build-native.sh` — `resolve_qnn_sdk` called after oneDNN block; if
  arm64 + zip present, appends `onnxruntime_USE_QNN=ON` +
  `onnxruntime_QNN_HOME=<root>` + `QNN_ARCH_ABI=aarch64-oe-linux-gcc11.2`;
  stages runtime after finalize
- `Dockerfile.media` — `linux/qnn-sdk` bind-mounted at `/opt/scripts/qnn-sdk`
  on the `--step cpu` and `--step genai` RUNs
- `verify-media-artifacts.sh` — `onnxruntime-cpu` stage: if QNN provider .so
  is present, asserts `libQnn*.so` are staged beside it
- `docs/linux-cross-builds.md` — QNN EP section in the toggles area
- `docs/refactoring-backlog.md` — `A2. QNN-LINUX` items 1-6 DONE+PROVEN;
  framework fan-out (GenAI, LiteRT, TVM, IREE) OPEN
4a3f379c05bd3affa3d9b2550f1b2cb4f9b3


## 2026-08-29 — #135 closed: patched LLVM is default, workarounds removed

### `BUILD_PATCHED_LLVM=1` is now the DEFAULT (#135 item 1+3 DONE)

The patched clang toolchain (llvm#219275 + #219276, the `EH_LABEL` size fix) is
now the default toolchain. Changes:

- `Dockerfile.toolchain-builder`: `ARG BUILD_PATCHED_LLVM=0` → `1`
- `build-buildkit.ps1`: `patched-llvm` is the default target; new `-StockLlvm`
  switch opts out (for patch debugging only); `-PatchedLlvm` kept as a no-op
  for backwards compatibility
- `build-opencv-from-source.ps1`: both AArch64 workarounds REMOVED — the
  `+force-32bit-jump-tables` flag and the per-TU `/Ob1` pass for
  `median_blur.dispatch` / `multiview_calibration`. The patched toolchain fixes
  the root cause (EH_LABEL under `/EHa` emits a 4-byte nop counted as zero by
  `getInstSizeInBytes`).
- `BuildKit.PatchedLlvm.Tests.ps1`: updated for the new default
- `SourceBuild.CrossHelpers.Tests.ps1`: removed the /Ob1 selector test (the
  selector it tested no longer exists)
- `docs/failure-modes.md`: updated the AArch64 codegen section — root cause
  found, workarounds removed, patched toolchain is the fix


## 2026-08-29 — amd64 acceptance build GREEN (#134 closed)

### #134 amd64 acceptance PASSED — three build fixes

The amd64 rebuild verified the `TVM_COMMIT` LLVM 23 fix and closed #134.
Smoke gate: **192 passed / 0 failed / 1 skipped**. Arch gate: **1134/0**.

Three bugs surfaced during the build, all fixed:

1. **`Invoke-GitClone` commit-hash support** — `git clone --branch <hash>`
   fails for commit hashes ("Remote branch not found"). Added commit-hash
   detection: clone without `--branch`, then `git fetch --depth 1 origin <hash>`
   + `git checkout <hash>`. Mirrors the Linux lane's tvm.sh approach.

2. **`SETUPTOOLS_SCM_PRETEND_VERSION` for TVM_COMMIT** — when `TVM_COMMIT`
   (a 40-char hash) wins over `TVM_REF` (a tag), the pretend-version was set
   to the hash, which crashes `packaging.version.InvalidVersion`. Now falls
   back to the tag's version (`0.26.0`) when the resolved version is a hash.

3. **`ARCH_GATE_MIN_INSPECTED` amd64 floor** — 950 was calibrated against the
   PE-binary count (1134) but the same value gates the import-walk count
   (701). Same miscalibration that was fixed for arm64 (840→580). Corrected
   to 650.

4. **Smoke section 10 CPU floor** — floor was 5 but the CPU lane produces
   exactly 4 assertions (the 5th is a GPU-only CUDA check). Corrected to 4.


