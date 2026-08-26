<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Common failure modes — symptom lookup

**Start from the error message.** Every entry below is keyed by what you
actually see, then names the cause and the fix. All of them were hit live in
this repo; the dates are when.

Two neighbours, so you land on the right page:

- **A rule you must not break** while editing the Windows chain →
  [`windows-build-invariants.md`](windows-build-invariants.md).
- **A host that was never set up correctly** (rather than one that broke) →
  [`windows-host-setup.md`](windows-host-setup.md) for Windows,
  [`linux-host-setup.md`](linux-host-setup.md) for Linux.

> Several rows here point at *deeper* write-ups in
> [`windows-builds.md`](windows-builds.md) and its sibling pages. This page is
> the triage index: enough to recognise the failure and act, with a link when
> the full history matters.

## Contents

**Linux and cross-lane**

- [`exec format error` on a foreign-arch build](#exec-format-error-on-a-foreign-arch-build)
- [`no space left on device`](#no-space-left-on-device)
- [Stale downstream images](#stale-downstream-images)
- [`no active session` / `grpc: the client connection is closing` mid-chain](#no-active-session--grpc-the-client-connection-is-closing-mid-chain)
- [`registry_pin_ref` fails on a fresh push](#registry_pin_ref-fails-on-a-fresh-push)
- [Terminal freeze during a long build](#terminal-freeze-during-a-long-build)

**Windows: the layer store (hcsshim)**

- [`hcsshim::ActivateLayer 0x20` on an AMD Radeon host](#hcsshimactivatelayer-0x20-on-an-amd-radeon-host)
- [`ExportLayer 0x3`, spawn flakes, `ExportLayer 0x70` — disk exhaustion in costume](#exportlayer-0x3-spawn-flakes-exportlayer-0x70--disk-exhaustion-in-costume)
- [`ExportLayer 0x3` at finalize of a heavy media layer, disk is fine](#exportlayer-0x3-at-finalize-of-a-heavy-media-layer-disk-is-fine)
- [`hcsshim::ActivateLayer failed (0x20)` during build](#hcsshimactivatelayer-failed-0x20-during-build)
- [`ActivateLayer 0x20 "file used by another process"` on commit](#activatelayer-0x20-file-used-by-another-process-on-commit)
- [`ImportLayer ... (0xb7) "already exists"` — deterministic, burns the retry budget](#importlayer--0xb7-already-exists--deterministic-burns-the-retry-budget)
- [`ImportLayer ... (0xb7)` on the SAME chain-IDs across retries](#importlayer--0xb7-on-the-same-chain-ids-across-retries)
- [`failed to reimport snapshot` / `failed to write compressed diff` — the hcs-temp flake family](#failed-to-reimport-snapshot--failed-to-write-compressed-diff--the-hcs-temp-flake-family)
- [Finalize dies `unknown stream ID 9` on a Windows Update `.msu`](#finalize-dies-unknown-stream-id-9-on-a-windows-update-msu)
- [`exporting layers` prints nothing for 20+ minutes](#exporting-layers-prints-nothing-for-20-minutes)
- [A stage fails instantly with `exit code: 1` and zero container output](#a-stage-fails-instantly-with-exit-code-1-and-zero-container-output)

**Windows: container networking**

- [`Could not resolve host: github.com` seconds into the first downloading RUN](#could-not-resolve-host-githubcom-seconds-into-the-first-downloading-run)
- [`The remote name could not be resolved` — CNI nat subnet drift](#the-remote-name-could-not-be-resolved--cni-nat-subnet-drift)
- [nerdctl DNS failure in build](#nerdctl-dns-failure-in-build)

**Windows: buildkitd and the store**

- [A BK compile step freezes silently after `[output clipped, log limit 2MiB reached]`](#a-bk-compile-step-freezes-silently-after-output-clipped-log-limit-2mib-reached)
- [`buildctl prune` returns `Total: 0B` no matter what you pass](#buildctl-prune-returns-total-0b-no-matter-what-you-pass)
- [`buildctl` local export dies `file already closed` on a Windows rootfs](#buildctl-local-export-dies-file-already-closed-on-a-windows-rootfs)

**Windows: Stevedore and the docker service**

- [`cannot access containerd socket ... Zugriff verweigert` (non-admin)](#cannot-access-containerd-socket--zugriff-verweigert-non-admin)
- [`runtime "com.docker.hcsshim.v1" binary not installed`](#runtime-comdockerhcsshimv1-binary-not-installed)
- [`failed to create TTRPC connection`](#failed-to-create-ttrpc-connection)
- [Stevedore service won't start (1053 timeout)](#stevedore-service-wont-start-1053-timeout)
- [`error getting credentials - err: exit status 1`](#error-getting-credentials---err-exit-status-1)
- [`failed to extract layer ... failed to find link target` pulling servercore](#failed-to-extract-layer--failed-to-find-link-target-pulling-servercore)

**Windows: build content and toolchain**

- [Windows media build crawls; `Building with ninja -j2`](#windows-media-build-crawls-building-with-ninja--j2)
- [Rust smoke test: "rustup could not choose a version of cargo/rustc"](#rust-smoke-test-rustup-could-not-choose-a-version-of-cargorustc)
- [A GitLab download "succeeds" with HTTP 200 but is a few KB](#a-gitlab-download-succeeds-with-http-200-but-is-a-few-kb)
- [`TVM: llvm-config.exe not found on PATH`](#tvm-llvm-configexe-not-found-on-path)
- [`lld-link: error: undefined symbol` for template instantiations after a green compile](#lld-link-error-undefined-symbol-for-template-instantiations-after-a-green-compile)
- [meson cross: `Summary section 'Build environment' already have key 'host cpu'`, then `Subproject "subprojects/glib" required but not found`](#meson-cross-summary-section-build-environment-already-have-key-host-cpu-then-subproject-subprojectsglib-required-but-not-found)


---

## Linux and cross-lane

### `exec format error` on a foreign-arch build

**Symptom.** `exec format error`

**Cause.** QEMU/binfmt not registered after host reboot

**Fix.** `linux/host-config/setup-rootless-binfmt.sh` — NOT the tonistiigi container: that installs into the wrong namespace under rootless nerdctl (see § Prerequisites; this row prescribed exactly that dead-end until 2026-08-24)

### `no space left on device`

**Symptom.** `no space left on device`

**Cause.** Disk full from cached images/artifacts

**Fix.** In order: (1) `linux/host-config/prune-safe.sh` (spares compile caches), (2) `nerdctl rmi` of specific already-pushed tags, (3) `nerdctl system prune -a -f` ONLY with no chain running — it deletes ALL non-container-referenced images INCLUDING tagged cross-stage locals (bit us mid-run 2026-08-18; registry-pinned handoffs survived via re-pull)

### Stale downstream images

**Symptom.** Stale downstream images

**Cause.** Base image rebuilt but downstream not refreshed

**Fix.** Use `--verify-chain` or rebuild from replaced stage

### `no active session` / `grpc: the client connection is closing` mid-chain

**Symptom.** `no active session` / `grpc: the client connection is closing` / `DeadlineExceeded` mid-chain (cache reads, layer export, pushes)

**Cause.** buildkitd session rot after ~1-2 h of parallel load (BKD1, bit 6× on 2026-08-19/20)

**Fix.** Let the worker retries absorb one-offs; on a repeat: stop chain → `systemctl --user restart buildkit.service` → relaunch (cache mounts provably survive; builds fast-forward)

### `registry_pin_ref` fails on a fresh push

**Symptom.** `registry_pin_ref` fails on fresh push

**Cause.** Registry hasn't propagated the new manifest

**Fix.** Now uses `retry()` with 5 attempts; wait a few seconds and retry

### Terminal freeze during a long build

**Symptom.** Terminal freeze during long build

**Cause.** Build output overwhelms terminal

**Fix.** Use `setsid` / `disown` for very long builds

---

## Windows: the layer store (hcsshim)

### `hcsshim::ActivateLayer 0x20` on an AMD Radeon host

**Symptom.** Windows-container layer commit/finalize dies `hcsshim::ActivateLayer 0x20` on an **AMD Radeon host** (buildkit `failed to import/reimport snapshot`, on ANY layer writing into an existing parent dir; docker-classic legacy dies `mkdir \\?\Volume{<GUID>}\C:.` invalid dir name) — BOTH lanes, process AND Hyper-V isolation

**Cause.** **RESOLVED 2026-08-10: an ENABLED AMD RDNA4 dGPU (RX 9xxx + Adrenalin) locks freshly-written container layers** (upstream docker/for-win#14977, open; same-boot A/B-proven). Failed finalizes additionally WEDGE hcs state until a REBOOT (survives service bounces + vmcompute restart).

**Fix.** Probe with `probe-build-copy.ps1 -Heavy` (only a `-Heavy`-green verdict counts), then build inside the `toggle-rdna4-gpu.ps1 -Disable` window — `build-buildkit.ps1` enforces that via `Assert-NoActiveRdna4Gpu`. **After ANY red finalize, reboot before testing anything else**: a wedged host falsifies every later experiment. Full A/B history and the superseded 2026-08-09 verdict: [`windows-build-lanes.md`](windows-build-lanes.md#rdna4-dgpu-layer-lock-ab-history-and-diagnostics).

### `ExportLayer 0x3`, spawn flakes, `ExportLayer 0x70` — disk exhaustion in costume

**Symptom.** ANY weird hcsshim failure on the BK lane: `ExportLayer 0x3` (path not found) at finalize, spawn flakes (`'cmd.exe' is not recognized`), `ExportLayer 0x70` (disk full)

**Cause.** **Disk exhaustion in costume** — the bk image generations stack 30–40 GB per rebuild cycle; only 0x70 names the disease (all three hit on 2026-08-03)

**Fix.** Check free disk FIRST. `buildctl prune --all` + `docker image prune -f` (non-admin); bk-* image generations need admin. Full playbook: docs/windows-build-lanes.md § Store GC.

### `ExportLayer 0x3` at finalize of a heavy media layer, disk is fine

**Symptom.** BK lane, disk is FINE: `failed to reimport snapshot: hcsshim::ExportLayer ... (0x3)` at finalize of a heavy media layer (GenAI/OpenCV class) — deterministic, every fresh snapshot, both finalize paths, survives host reboot

**Cause.** **ROOT CAUSE FOUND & FIXED 2026-08-06: the runhcs shim's hardcoded `tearDownTimeout = 30s`** (`cmd/containerd-shim-runhcs-v1/task_hcs.go`) terminates the heavy-churn silo teardown mid-hive-flush (real duration: **117 s measured** for OpenCV), permanently poisoning the scratch vhdx. Calm exits (ONNX ninja, cpython, LiteRT, torch) finish teardown under 30 s and never tripped it.

**Fix.** Solved at the root by a patched runhcs shim, already deployed. **The part to remember is the maintenance:** every Stevedore/containerd update overwrites it, so `deploy-shim-patch.ps1 -ReportOnly` belongs in your post-update routine — `Assert-ShimPatch` gates the BK lane on it by SHA256 — and one OpenCV canary should follow any update. `0x3` is deliberately excluded from the driver's transient-retry pattern: it must fail loudly. Root cause, constants and the rollback path: [`windows-build-lanes.md`](windows-build-lanes.md#defect-solved).

### `hcsshim::ActivateLayer failed (0x20)` during build

**Symptom.** `hcsshim::ActivateLayer failed (0x20)` during build

**Cause.** Windows Defender scanning new layer files + containerd snapshot contention

**Fix.** Exclude `C:\ProgramData\containerd`, `C:\ProgramData\nerdctl` from Windows Defender. Or use `docker.exe` instead of `nerdctl` for builds (Docker's layer manager is more resilient).

### `ActivateLayer 0x20 "file used by another process"` on commit

**Symptom.** `hcsshim::ActivateLayer failed ... 0x20 "file used by another process"` on commit

**Cause.** `--isolation process` was used for a `docker build` — it cannot commit layers on this host

**Fix.** Never pass `--isolation process`. Use Hyper-V (the default) for `docker build`; for CPUs use the `docker run --cpu-count N` + `docker commit` path. Not Defender/Search/SysMain (all ruled out).

### `ImportLayer ... (0xb7) "already exists"` — deterministic, burns the retry budget

**Symptom.** BK lane: `failed to commit … during finalize: failed to reimport snapshot: hcsshim::ImportLayer failed in Win32: cannot create a file when that file already exists` (**0xb7**), DETERMINISTIC — identical snapshot IDs on every attempt, burns the driver's whole retry budget

**Cause.** **A half-committed snapshot is in the way.** Prime cause, measured 2026-08-07: **killing `buildctl` mid-finalize leaves exactly this debris** (a chain was aborted deliberately at 23 GB free to escape the disk danger band, and the next run died three times on the same IDs). `prune` does NOT clear it — it is not a reclaimable BK cache record (495 MB returned, nothing relevant); the transient-retry engine cannot help either, because the failure is deterministic, not a flake.

**Fix.** **`-NoCache` on the affected stage only** — e.g. `.\windows\build-buildkit.ps1 -Gpu -Stages sdk -NoCache`. Re-running the RUN yields a NEW layer digest (its output is not bit-identical), hence fresh chain IDs downstream, and the poisoned snapshot is simply no longer in the path. **Verified 2026-08-07:** the stage that had failed 3× exported cleanly, `Done in 00:17:10`. Prefer this over the in-file `CACHE-BUST` comment technique (`setup-scoop-tools.ps1`, `build-toolchain-all.ps1`): same effect, costs one stage re-run, leaves NO trace in the source. Only reach for a source-level cache-bust when the debris sits in a layer you cannot isolate with `-Stages`. Corollary: **prefer letting a doomed solve fail cleanly over killing it** — a clean finalize failure leaves no debris, a kill does.

### `ImportLayer ... (0xb7)` on the SAME chain-IDs across retries

**Symptom.** BK lane: `hcsshim::ImportLayer failed ... (0xb7) "already exists"` on the SAME chain-IDs across retries

**Cause.** Persistent snapshotter debris from an earlier low-disk finalize failure — NOT transient, `buildctl prune` cannot reach it (0B reclaimable)

**Fix.** Non-admin sidestep: cache-bust the layer above (any content change to the COPY'd/mounted file → new chain-IDs; live example in `setup-scoop-tools.ps1`'s 2026-08-05 header). Admin fix: prune/GC under the active gcpolicy.

### `failed to reimport snapshot` / `failed to write compressed diff` — the hcs-temp flake family

**Symptom.** BK lane: `failed to reimport snapshot` / `failed to write compressed diff` at finalize/export

**Cause.** hcs-temp flake family (2026-08-05): realtime scanner racing `C:\WINDOWS\SystemTemp\hcs*` scratch, and/or low disk (<~25 GB free makes hcsshim "weird" before disk-full)

**Fix.** Auto-retried by the BK driver's transient pattern. Root remedies (applied 2026-08-05): Defender exclusions for buildkitd/containerd + their ProgramData dirs; keep ≥40 GB free; gcpolicy active. ALWAYS check free disk first — disk-full mimics the same message.

### Finalize dies `unknown stream ID 9` on a Windows Update `.msu`

**Symptom.** BK lane: a RUN finishes, then finalize dies `failed to reimport snapshot: Files/Windows/SoftwareDistribution/Download/<id>/Windows11.0-KB…-x64.msu: unknown stream ID 9`, byte-identical on every retry (same snapshot IDs — the RUN result is cached, only the finalize re-runs)

**Cause.** **Windows Update ran INSIDE the build container** (servercore ships `wuauserv` + `UsoSvc`, trigger-started, and the container has network) and dropped an `.msu` into the update spool during the RUN; BuildKit's Windows layer writer cannot carry that file's alternate stream. Measured 2026-08-25 on the amd64 `media-core-onnx` stage (150 s RUN, KB5120233)

**Fix.** **Prevention, not cleanup:** `Disable-ContainerWindowsUpdate` (Common.psm1) stops + disables both services and sets `NoAutoUpdate=1` as the first step of every build script (`Initialize-SourceBuildEnvironment`) and reports the spool count — an entry inherited from the parent image (1 item at RUN start on every media stage) is harmless, only a file written during the RUN lands in the diff. Nothing under `C:\Windows` is deleted by any script (protected-root rule). A layer that already carries a download is fixed by re-running its RUN with the guard in place (any module edit re-keys it); retrying the same cached RUN cannot help.

### `exporting layers` prints nothing for 20+ minutes

**Symptom.** BK lane: `exporting layers` (or the following `unpacking to …`) prints NOTHING for 20+ minutes after a heavy amd64 layer (the LiteRT-LM Bazel output is the measured case) — or the merge fan-in `COPY --from=media-core C:\runtime C:\runtime` sits silent for 10–15 minutes on a step that took 5 s the run before — and every daemon — buildkitd, containerd, vmcompute, wcifs — sits at 0.00 s CPU, no shim/container process is left, and `buildctl debug workers` still answers in <1 s

**Cause.** **Not a hang — a slow, mostly kernel-side layer export/unpack.** Measured 2026-08-24/25: `exporting layers 1216.3s done` after 20 idle-looking minutes, then `unpacking … 1277.0s done`, and the stage went `OK` at 58:08 (17 min of actual build); arm64 run 12 (2026-08-25): the fan-in COPY finished `DONE 847.4s` after 14 idle-looking minutes (run 11: 5.1 s), no eventlog entry, nothing written under the buildkitd root

**Fix.** **Wait.** Killing `buildctl` here is exactly the "mid-finalize" kill that manufactures the 0xb7 debris two rows up and costs a `-NoCache` re-run. Bound the wait (a watcher on the log's mtime) instead of judging by CPU: the export shows no user-mode activity by design.

### A stage fails instantly with `exit code: 1` and zero container output

**Symptom.** BK lane: a stage fails instantly with `exit code: 1` and **ZERO container output** — no script banner, no stderr, deterministic across retries

**Cause.** **Two solves racing on the same freshly-invalidated ancestor stage.** Measured 2026-08-07: a second `build-buildkit.ps1` was started while the main chain ran, right after a change to the `common` stage invalidated it for BOTH. Each solve tried to build the same new snapshot chain; one died before its process ever started, hence no output. NOT a script bug — a probe running the identical mounts, module import and `Initialize-SourceBuildScript` against the same base passed cleanly.

**Fix.** Do not run a second solve that shares an ancestor stage you just invalidated. `-ConcurrentAux` is safe because its two branches sit on an ALREADY-BUILT common ancestor. Wait for the running chain, then start the second build. If you must parallelise, first build the shared ancestor once on its own.

---

## Windows: container networking

### `Could not resolve host: github.com` seconds into the first downloading RUN

**Symptom.** BK lane, seconds into the first downloading RUN: `Could not resolve host: github.com` / `git clone failed (exit 128)`

**Cause.** **The CNI `.conf` is missing** — buildkitd then gives the container NO NETWORK ADAPTER AT ALL (not a DNS fault). Confirm in 30 s with a probe RUN: `ipconfig` prints nothing and a raw TCP connect to a literal IP fails *"unreachable network"*; the containerd debug log shows the `HcsCreateComputeSystem` spec with no networking block. Usual cause: someone "converted" `0-containerd-nat.conf` → `.conflist` to fix nerdctl (2026-08-07, cost a launched chain). The subnet-drift guard does NOT catch this and stays green.

**Fix.** Restore it (admin): `Copy-Item '…\0-containerd-nat.conflist' '…\0-containerd-nat.conf'`, edit to the single-plugin form, `Restart-Service buildkitd -Force`. **Keep BOTH files** — buildkitd needs `.conf`, nerdctl needs `.conflist`. `build-buildkit.ps1` now fail-fasts (`Get-CniConfFormIssue`) and `verify-host-setup.ps1` FAILs on a missing `.conf`.

### `The remote name could not be resolved` — CNI nat subnet drift

**Symptom.** BK RUN steps: `The remote name could not be resolved` (and even direct-IP queries time out)

**Cause.** **CNI nat subnet drift**: dockerd restarts recreate the `nat` HNS network on a new subnet; the static CNI conf then hands out IPs whose gateway doesn't exist

**Fix.** Update `ipam.subnet`/`GW` in `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` to match the live `vEthernet (nat)` adapter (`ipconfig`), then `Restart-Service buildkitd -Force` (admin). `build-buildkit.ps1`'s preflight guard detects this and prints the fix.

### nerdctl DNS failure in build

**Symptom.** nerdctl DNS failure in build

**Cause.** BuildKit container can't resolve hostnames on Windows without a CNI nat CONFIG (`--dns` and `--network host` unsupported)

**Fix.** Fixed 2026-08-03: install `0-containerd-nat.conf` into `C:\Program Files\containerd\cni\conf\` (nat.exe was already in ...\cni\bin) — buildkitd RUN steps then have full NAT+DNS. docker.exe remains the fallback.

---

## Windows: buildkitd and the store

### A BK compile step freezes silently after `[output clipped, log limit 2MiB reached]`

**Symptom.** BK compile step freezes silently minutes in (0 % CPU, zombie ninja, no log growth) right after `[output clipped, log limit 2MiB reached]`

**Cause.** **buildkitd step-log clip deadlock** (Windows buildkitd v0.32): after the 2 MiB clip the stdio pipe stops being drained; every process blocks on its next write. ONNX's warning flood hits the clip in ~3 min

**Fix.** Set service env `BUILDKIT_STEP_LOG_MAX_SIZE=-1` + `BUILDKIT_STEP_LOG_MAX_SPEED=-1` on buildkitd (registry MultiString `Environment`), `Restart-Service buildkitd -Force`. See docs/windows-build-lanes.md § Getting it going, step 3b.

### `buildctl prune` returns `Total: 0B` no matter what you pass

**Symptom.** `buildctl prune` returns `Total: 0B` no matter what you pass

**Cause.** **CHECK `du -v` FOR `Shared: true` FIRST — that is almost always the answer.** `Shared` records are pinned by containerd IMAGE TAGS and NO prune flag can take them; prune only ever gets the `Private` slice, and `Reclaimable` describes the LEASE state, not what prune will hand back. **`reservedSpace` is a red herring for this symptom.** Otherwise: refs pinned by BUILD HISTORY (every record incl. failed attempts pins its refs indefinitely) and/or by named `bk-*` image generations

**Fix.** In order: **(1)** `buildctl du -v` and look for `Shared: true` — those records are pinned by containerd image tags and no prune flag can take them, so the lever is an admin `nerdctl --namespace buildkit rmi` of dead stage tags. **(2)** Non-admin and safe mid-build: `buildctl prune --free-storage <MB>` — a minimum-free *target*, not an amount to delete. **(3)** `prune-histories` second, never first. **(4)** Look for a superseded lineage, the big hidden reclaim. The full decision procedure with every measurement: [`windows-build-lanes.md`](windows-build-lanes.md#store-gc).

### `buildctl` local export dies `file already closed` on a Windows rootfs

**Symptom.** `buildctl` local export of a Windows image dies `error from receiver: write ...\Boot\Fonts\<font>.ttf: file already closed` (nondeterministic file; every layer had already committed)

**Cause.** The `type=local` exporter cannot receive a full Windows rootfs client-side — NOT a host/commit defect (measured 2026-08-10 on a host whose `type=image,...,unpack=true` export of the same solve was green)

**Fix.** Export `type=image` (what `build-buildkit.ps1` and, since 2026-08-10, `probe-build-copy.ps1` do) or the tar-stream `type=docker,dest=<file>` (`-FinalTar`); never judge host health from a `type=local` export of a Windows image.

---

## Windows: Stevedore and the docker service

### `cannot access containerd socket ... Zugriff verweigert` (non-admin)

**Symptom.** `nerdctl ...`: `cannot access containerd socket ... Zugriff verweigert` (non-admin)

**Cause.** containerd's pipe is admin-only (its service lacks `--group docker-users`, unlike dockerd/buildkitd)

**Fix.** Use `docker.exe` (dockerd pipe) or `buildctl` (buildkitd pipe) — both are docker-users-accessible. nerdctl needs an elevated shell.

### `runtime "com.docker.hcsshim.v1" binary not installed`

**Symptom.** Stevedore docker build: `runtime "com.docker.hcsshim.v1" binary not installed`

**Cause.** Service default runtime uses `hcsshim-v1` shim which isn't shipped

**Fix.** Change to `runhcs-v1`: `sc config stevedore binPath="..." --default-runtime=io.containerd.runhcs.v1"` (see docs/windows-stevedore-and-docker.md § Fix 2)

### `failed to create TTRPC connection`

**Symptom.** Stevedore docker build: `failed to create TTRPC connection`

**Cause.** Shim binary mismatch (runhcs copied as hcsshim)

**Fix.** Remove the bad shim copy: `del "C:\Program Files\Stevedore\bin\containerd-shim-hcsshim-v1.exe"`. Apply Fix 2 instead.

### Stevedore service won't start (1053 timeout)

**Symptom.** Stevedore service won't start (1053 timeout)

**Cause.** Windows Defender blocking dockerd.exe OR stale daemon.json from Docker Desktop

**Fix.** `Add-MpPreference -ExclusionProcess "dockerd.exe"` AND delete `C:\ProgramData\docker\config\daemon.json`

### `error getting credentials - err: exit status 1`

**Symptom.** `error getting credentials - err: exit status 1`

**Cause.** wincred credential helper fails because dockerd runs as SYSTEM without interactive session

**Fix.** OK to ignore for public images (MCR, GitHub). Use `nerdctl pull` instead for images that need auth, or set `"credsStore":""` in docker config.

### `failed to extract layer ... failed to find link target` pulling servercore

**Symptom.** `failed to extract layer ... failed to find link target` when pulling servercore

**Cause.** containerd windows snapshotter can't handle certain Windows reparse points in the layer

**Fix.** Use `docker.exe pull` instead of `nerdctl pull`. Docker Engine's layer extraction handles reparse points correctly.

---

## Windows: build content and toolchain

### Windows media build crawls; `Building with ninja -j2`

**Symptom.** Windows media build crawls; `Building with ninja -j2` in `media-core.log`

**Cause.** media-core fell back to a 2-CPU `docker build` instead of the run+commit path

**Fix.** Ensure `Invoke-RunCommitStage` runs (`docker run --cpu-count $MediaCoreCpus`); `docker build` is 2-CPU-capped here and no flag raises it ([`windows-build-invariants.md`](windows-build-invariants.md) § Windows Build Invariants).

### Rust smoke test: "rustup could not choose a version of cargo/rustc"

**Symptom.** Rust smoke test fails: "rustup could not choose a version of cargo/rustc"

**Cause.** A **toolchain-less** rustup (proxy shims in `CARGO_BIN` that resolve no toolchain) — e.g. `rustup-init --default-toolchain none`, or an image from before the Cargokit fix

**Fix.** rustup WITH a stable default toolchain IS the sole provider (`setup-rust-toolchain.ps1`); `CARGO_BIN` on the rustup path is by design. Fix with `rustup default stable`; never add a second provider (no scoop rust) ([`windows-build-invariants.md`](windows-build-invariants.md) § Windows Build Invariants).

### A GitLab download "succeeds" with HTTP 200 but is a few KB

**Symptom.** A download from gitlab.freedesktop.org / code.videolan.org "succeeds" (HTTP 200) but is a few KB and extraction fails — e.g. GStreamer wraps "downloaded but extraction into X failed"

**Cause.** **Anubis anti-scraper**: browser User-Agents without JS get an HTML challenge page as a 200 (the shared `Invoke-DownloadWithRetry` sends a browser UA). Second variant: `.git` left in a GitLab `/-/archive/` URL serves HTML even to curl. Both burned a merge run on 2026-08-17.

**Fix.** Fetch via `Invoke-WrapDownload` (curl-native UA + gzip/bzip2 magic-byte check) and strip `.git` from GitLab archive URLs. Diagnosis in 10 s: read the first bytes — `<!doctype html>` = challenge page, not a corrupt archive.

### `TVM: llvm-config.exe not found on PATH`

**Symptom.** tvm stage: `TVM: llvm-config.exe not found on PATH` (#47 gate)

**Cause.** Scoop LLVM never ships llvm-config or dev libs — TVM was silently USE_LLVM=OFF (no CPU codegen) until 2026-08-17. NOT a broken PATH.

**Fix.** The self-heal in `build-tvm-from-source.ps1` builds a pinned minimal LLVM from source ([`windows-build-invariants.md`](windows-build-invariants.md) § Windows Build Invariants). If the gate throws, check the heal's download/SHA pin for the current `LLVM_WINDOWS_VERSION` — do NOT fall back to the official /MT dev tarball or USE_LLVM=OFF.

### `lld-link: error: undefined symbol` for template instantiations after a green compile

**Symptom.** Compile fully green, then `lld-link: error: undefined symbol` for template instantiations (`QkvToContext<...>`, `BiasSoftmaxImpl<double>`) at the DLL link — identical on every retry AND on a fresh cache mount

**Cause.** **the sccache nvcc path produced objects lacking arch/define-guarded instantiations during REAL compiles** — runs 10+11 with launcher failed identically, runs 5+12 bare-nvcc linked green. Poisoning is excluded on BOTH levels (run 11: fresh L0 mount; L2 turned out to hold only 9 probe entries — the chain's write-through never fed it). Minimal wrapped-vs-bare nm-diff repros (define-guard + arch-guard shapes; plain, ORT-ish and `--options-file` command lines, fresh disk-only cache) are all CLEAN — the loss needs real-ORT invocation complexity (untested: `-MD/-MF` depgen, `-forward-unknown-to-host-compiler`, quoted rsp defines, client concurrency). Same machinery also crashed the server on fused_moe (10054, upstream family #1098) and produced the `Severity::k0` phantom; arch-guard×preprocessing has upstream history (#2299)

**Fix.** CUDA is bare BY DEFAULT since 2026-08-10 night — the launcher is OPT-IN at the wiring site (`Invoke-CmakeConfigure` adds `CMAKE_CUDA_COMPILER_LAUNCHER` only under `SCCACHE_CUDA_LAUNCHER=1`; the earlier per-script opt-out env var leaked process-wide on the classic lane, review find). NEVER export that opt-in on a new sccache without all THREE canaries: verify-cuda-cache.ps1 + fused_moe compile + a full providers_cuda LINK (the miscompile is invisible until link). C/CXX launcher stays safe.

### meson cross: `Summary section 'Build environment' already have key 'host cpu'`, then `Subproject "subprojects/glib" required but not found`

**Symptom.** arm64 GStreamer merge (cross file + native file): `glib-2.86.3/meson.build:2777:0: Exception: Summary section 'Build environment' already have key 'host cpu'` right after glib's build-machine configure reached its summary, then `gstreamer| Subproject subprojects\glib-2.86.3 is buildable: NO (disabling)`, dozens of `Dependency 'libpcre2-8' is required but not found` re-tries, and finally `libnice-0.1.23/meson.build:214:4: Exception: Subproject "subprojects/glib" required but not found` → `gst-libs/gst/webrtc/nice/meson.build:16:14: ERROR: Subproject "subprojects/libnice" required but not found` (arm64 run 25, 2026-08-26). The host glib configured fine minutes earlier.

**Cause.** A meson bug (1.12.0 and `master`, checked 2026-08-26): `Interpreter.summary` is keyed by subproject NAME and shared by every nested interpreter, `Interpreter.subprojects` by `[machine][name]`. gstreamer core asks for `glib-2.0` with `native: true`, so glib's `meson.build` runs a second time for the build machine and its `summary({'host cpu': …})` collides with the host run's keys. meson disables glib(build); libnice's anonymous `dependency('', fallback: ['glib', 'libglib_dep'])` reaches glib by NAME (the `gio-2.0` lookup works through the override, the anonymous one cannot) and inherits the failure. Not a toolchain problem — the build-machine sanity checks link x64 via `/vctoolsdir`+`/winsdkdir` (backlog #128 runs 23–25 for the two earlier costumes of this chain).

**Fix.** `Invoke-MesonBuildSubprojectSummaryPatch` (defined in `build-gstreamer-from-source.ps1`, kept out of the modules because `/bkmods` is mounted whole into every media RUN and a module edit re-keys all branches on both lanes) patches the pip-installed `mesonbuild/interpreter/interpreter.py` before `meson setup`: `summary_impl` returns early in build-machine interpreters (`self.build.for_machine is MachineChoice.BUILD`, set only by `Build.copy_for_build_machine()`; summaries are cosmetic; amd64 never creates such an interpreter). Idempotent by marker; THROWS on layout drift so a newer meson cannot silently skip it and resurface as the libnice error two hours later. Fixture test `SourceBuild.MesonSummaryPatch.Tests.ps1`; upstream draft `out/upstream-issue-meson-summary-build-subproject.md`. If you see this on a meson newer than 1.12.0, check whether upstream fixed it before re-anchoring the regex.
