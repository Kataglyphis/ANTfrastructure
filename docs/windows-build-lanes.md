<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Windows build lanes — BuildKit, nerdctl and classic docker

Three ways to build the Windows image, what each can and cannot do, and the
host-level failures specific to each. **Use the BuildKit/containerd lane**
(`windows/build-buildkit.ps1`); the other two are documented because you will
still meet them.

| Lane | Driver | Shell | Status |
|---|---|---|---|
| BuildKit + containerd | `windows\build-buildkit.ps1` → `buildctl` | non-admin | **Preferred since 2026-08** |
| nerdctl | `nerdctl --namespace buildkit` | **admin** | Run / inspect / administer; can also build |
| docker classic | `windows\build.ps1` | non-admin | **No longer a bootstrap fallback** — cannot build `base` |

What lives elsewhere:

- **What is in the image, and how to build it** → [`windows-builds.md`](windows-builds.md)
- **CPU, memory and cache budgets** → [`windows-build-resources.md`](windows-build-resources.md)
- **Setting a host up from scratch** → [`windows-host-setup.md`](windows-host-setup.md)
- **A specific error message** → [`failure-modes.md`](failure-modes.md)
- **Rules you must not regress** → [`windows-build-invariants.md`](windows-build-invariants.md)
## Build isolation and CPU parallelism

**Policy (build.ps1 `-Isolation`, default `auto`): process isolation is always
preferred and used automatically wherever the host can support it.** `auto`
runs the ~10s commit probe (`windows/scripts/diagnostics/test-process-isolation-commit.ps1`)
once per (host build, docker version) — verdict cached in
`out\windows-build-logs\isolation-probe-cache.json` — and:

- **probe passes** → every `docker build` and `docker run` gets
  `--isolation process`: full host CPUs everywhere, no 2-CPU cap. (This is the
  normal state on a Windows **Server** host whose build matches the base image
  — the recommended build environment.)
- **probe fails** (the wcifs layer-commit bug, present on client-build hosts
  mismatched against the Server base image) → falls back to `hyperv` with a
  loud warning, and everything below applies.

`-Isolation process|hyperv` forces either mode (forcing `process` on a host
where the probe fails will kill every stage at its first layer commit).

Under Hyper-V, build containers are given only **2 logical CPUs**, so
`Get-BuildJobCount` — `min(ProcessorCount, memGB / memPerJob)` — pins every
in-container `ninja -j` to 2 no matter how many cores the host has. That is the
difference between a ~1-hour and a ~6-hour ONNX/CUDA compile, so the heavy
**media-core** stage does **not** use `docker build` at all.

Two properties of `docker commit` that the run+commit path has to correct for
(both fixed 2026-08-07):

- **`commit` captures the CONTAINER's config, including `Cmd`** — which here is
  the build-script argv the stage was launched with. Left alone,
  `local/kataglyphis:windows-media` (and `windows-torch`, which inherits it)
  ship a `CMD` that RE-RUNS the GStreamer build, so a debugging
  `docker run -it local/kataglyphis:windows-media` starts recompiling over
  `C:\runtime` instead of giving you a shell. The driver now commits with
  `--change 'CMD ["pwsh"]'`. The FINAL image was never affected — a Dockerfile
  `ENTRYPOINT` resets an inherited `CMD` — which is exactly why it stayed
  invisible for so long.
- **A committed layer cannot be shrunk later**, so package-manager scratch has
  to be cleared INSIDE the container before the commit. The classic lane now
  passes `-ScrubAfter` to the media branch and merge/GStreamer runs, matching
  what the BuildKit lane already did on every compile RUN (`Clear-BuildScratch`:
  pip cache, `~\.nuget`, `%TEMP%`, INetCache). Source trees were never the
  issue — each leaf build script removes its own via `Remove-SourceBuildTree`.
  The toolchain stage is deliberately excluded on both lanes: its CPython tree
  at `C:\temp\cpython` IS the deliverable.

## BuildKit/containerd lane (PREFERRED, `windows/build-buildkit.ps1`)

**This is the lane to use from 2026-08 on** — full host CPUs on every stage,
process-isolated layer commits, and real per-stage layer caching, with the
docker-classic run+commit lane kept as the always-working fallback. **Status
2026-08-06: GREEN end-to-end and DE-WARMED** — the host snapshotter defect
(`ExportLayer 0x3`) is fixed at the root by a patched runhcs shim, so the
lane runs DIRECT solves everywhere and the warm/materialize pattern is
retired (full writeup, proof and maintenance rule in the Roadmap section's
entry; the shim is a LOCAL patch that every Stevedore update reverts).
`bk-winamd64` builds in ~44 min hot, and heavy RUN steps bind-mount their
per-file script closures instead of inheriting COPY layers. Probes on
2026-08-03 established that BOTH docker-classic limits are absent on the
buildkitd+containerd path on this same host (and the chain was then rebuilt
from base on this lane the same day — VS2026, CUDA, CPython and the media
compiles all ran as plain process-isolated layers):

| Probe | Result |
|---|---|
| process-isolated RUN + layer commit via buildctl | **works** (the wcifs `ActivateLayer 0x20` bug is a docker-writer artifact) |
| CPUs visible in a buildkit RUN step | **NPROC=32** (no 2-CPU cap) |
| container networking | none by default → **works after installing the CNI nat conf** (`C:\Program Files\containerd\cni\conf\0-containerd-nat.conf`; `nat.exe` ships in `...\cni\bin`) |
| stage handoff (`FROM` a locally built image) | **works** with fully-qualified store names (`docker.io/local/...`) + `--opt image-resolve-mode=local` (buildkit normalizes bare names to docker.io/ and otherwise tries the real registry) |

Consequences: every stage can be a plain build — the heavy compiles run as
`*-built` Dockerfile targets (toolchain-builder `built`, media-builder
`media-<branch>-built`, merge-builder `built`) with real per-stage layer
caching, and the run+commit machinery is unnecessary on this lane. The classic
lane is untouched: `build.ps1` pins `--target builder` / `--target merge`, so
docker never executes those targets.

### Getting it going — Stevedore + BuildKit host setup (from scratch)

> The end-to-end fresh-machine sequence (including the GC-policy deploy, the
> permanent debug flags, and the repo-gate tooling that this section does not
> cover) lives in [Fresh Windows Host Bring-Up](windows-host-setup.md).

[Stevedore](https://github.com/slonopotamus/stevedore) ships the whole engine
family in one install: `docker.exe`/`buildctl.exe` under
`C:\Program Files\Stevedore\bin\`, plus the `stevedore` (dockerd), `containerd`
and `buildkitd` services. Everything below is one-time, admin unless noted.

0. **Install Stevedore** (MSI from the releases page) and put yourself in the
   **`docker-users`** local group (log out/in afterwards) — dockerd's and
   buildkitd's named pipes are ACL'd to that group, which is what makes
   non-admin builds possible. containerd's own pipe stays admin-only (only
   `nerdctl` needs it; `docker`/`buildctl` don't).

1. **Services**: all three must run; set them to delayed-auto so reboots
   self-heal:

   ```powershell
   Get-Service stevedore, containerd, buildkitd | Set-Service -StartupType AutomaticDelayedStart
   Start-Service stevedore, containerd, buildkitd
   ```

   buildkitd's service must carry `--group docker-users` in its ImagePath
   (Stevedore's default registration does:
   `buildkitd.exe --run-service --service-name buildkitd --group docker-users`).

   **Known dockerd boot-failure pitfall:** a stale
   `C:\ProgramData\docker\config\daemon.json` whose `hosts` entry conflicts
   with the service's `--host` flags prevents the `stevedore` service from
   starting at all (took a debugging session to find, 2026-08-03). If dockerd
   won't start, rename that file first.

2. **CNI networking** (without it every RUN that downloads anything fails with
   "remote name could not be resolved"): `nat.exe` already ships in
   `C:\Program Files\containerd\cni\bin`; install the conf (admin):

   **Install BOTH forms — the two clients disagree and each one silently breaks
   without its own.** Same content, two filenames:

   | File | Needed by | Symptom when missing |
   |---|---|---|
   | `0-containerd-nat.conf` (single-plugin) | **buildkitd** | RUN steps get **no network adapter at all** — empty `ipconfig`, `Could not resolve host`, and a raw TCP connect to a literal IP fails with *unreachable network* |
   | `0-containerd-nat.conflist` (plugin-LIST) | **nerdctl** | panics: indexes `plugins[0]` with no length check → `index out of range [0] with length 0`, in `network create` and again in `run` |

   > **CORRECTION (measured 2026-08-07).** This guide previously claimed
   > *"containerd and BuildKit read either form"*. **That is false**, and it cost
   > a launched chain. Converting the `.conf` to a `.conflist` on 2026-08-07
   > fixed nerdctl and silently killed buildkitd's container networking; nobody
   > noticed because no chain build ran in between. A probe container showed an
   > empty `ipconfig` and *unreachable network* on a raw TCP connect, and the
   > containerd debug log confirmed the `HcsCreateComputeSystem` spec for
   > `buildkitsandbox` carried Storage, MappedDirectories and MappedPipes but
   > **no networking block**. Restoring the `.conf` and restarting buildkitd
   > fixed it immediately (IPv4 `172.31.44.107`, gateway `172.31.32.1`, DNS
   > `192.168.188.1`, `github.com` resolved).
   >
   > `build-buildkit.ps1` now fail-fasts on this in milliseconds
   > (`Get-CniConfFormIssue`). Note the subnet-drift guard does **not** catch it:
   > it compares subnets of whichever file it finds and passed green throughout.
   > Different failure, different check. **When you edit one file, edit both.**

   ```javascript
   // C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist
   {
       "cniVersion": "0.3.0",
       "name": "nat",
       "plugins": [
           {
               "type": "nat",
               "master": "Ethernet",
               "ipam": {
                   "subnet": "<subnet of the vEthernet (nat) adapter>",   // DERIVE, don't copy (see below)
                   "routes": [ { "GW": "<that adapter's IPv4>" } ]
               },
               "capabilities": { "portMappings": true, "dns": true }
           }
       ]
   }
   ```

   **No magic subnets.** `setup-new-host.ps1` authors this file from the live
   `vEthernet (nat)` adapter (derived network/prefix + gateway) — the literals in
   older copies of these docs (`172.31.32.0/20` etc.) were snapshots of one host
   and are stale on any other. To derive by hand:
   `Get-NetIPAddress | ? InterfaceAlias -eq 'vEthernet (nat)'` → adapter IP is
   the GW, and `subnet` = network/prefix of that address.

   After writing it, verify with BOTH clients — a BuildKit RUN step that fetches
   something, and `nerdctl --namespace buildkit run --rm --network nat
   <image> cmd /c ipconfig` (admin). The second is the picky one and therefore
   the better test of this file.

   **Subnet drift warning:** dockerd recreates the `nat` HNS network with a NEW
   subnet on service restarts, silently orphaning this conf (containers then get
   unroutable IPs). `build-buildkit.ps1` fail-fasts on the mismatch at preflight
   with the exact fix; re-sync the conf to `ipconfig`'s `vEthernet (nat)` values
   (`setup-new-host.ps1 -ReportOnly` re-derives and shows any drift) and
   `Restart-Service buildkitd -Force` (plain `Restart-Service` refuses when
   dependent services exist).
3. **Windows Defender exclusions** for `C:\ProgramData\containerd` (and the
   buildkit state dir) — layer extraction races the scanner otherwise.
4. **REQUIRED for the compile stages: disable the per-step log limit.**
   buildkitd clips each RUN step's log at 2 MiB (`[output clipped, log limit
   2MiB reached]`) — and on Windows buildkitd v0.32 this is not cosmetic: after
   the clip the container's stdio pipe stops being drained, every process
   blocks on its next write, and the step **deadlocks silently** (reproduced
   twice on 2026-08-03: media-core froze ~3 min in, right at the clip, with two
   zombie ninja processes at 0 % CPU). ONNX's warning flood alone exceeds 2 MiB
   in minutes, so heavy stages cannot survive the default. One-time (admin; do
   it while no build is running — the restart kills in-flight solves, though
   buildkitd's layer cache survives):

   ```powershell
   Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd `
     -Name Environment -Type MultiString `
     -Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1','BUILDKIT_STEP_LOG_MAX_SPEED=-1')
   Restart-Service buildkitd -Force
   ```

   (`-1` = unlimited; the driver tees everything to per-stage files under
   `out\windows-build-logs\` anyway, so disk is the only cost.)
5. **sccache** (non-admin): serve a cache dir over WebDAV — e.g.
   [dufs](https://github.com/sigoden/dufs): `dufs C:\sccache-cache -p 5000 -A`
   — and export `SCCACHE_WEBDAV_ENDPOINT=http://<host-LAN-IP>:5000`; the
   compile scripts pick it up inside RUN steps (same endpoint serves both
   lanes, so the classic chain pre-warms BK builds and vice versa).
   **dufs does NOT survive reboots** (cost a failed run on 2026-08-04, and
   the warm/materialize handoff also rides this server — without it the BK
   media solves fail fast). Make it logon-persistent once:
   `schtasks /Create /TN dufs-sccache /TR "\"%USERPROFILE%\scoop\shims\dufs.exe\" C:\sccache-cache -A -p 5000" /SC ONLOGON`
   — or restart manually after a reboot and verify
   `(Invoke-WebRequest http://<host-LAN-IP>:5000 -Method Head).StatusCode`
   returns 200. Verified:
   BK's NAT'd containers reach the host's LAN IP fine.

6. **Verify** before the first long build (non-admin):

   ```pwsh
   & "$env:ProgramFiles\Stevedore\bin\buildctl.exe" --addr npipe:////./pipe/buildkitd debug workers   # worker: windows/amd64
   # network smoke: any tiny Dockerfile whose RUN resolves a hostname; or just start
   # the chain - build-buildkit.ps1's preflight guards (buildkitd reachability +
   # CNI subnet drift) fail fast with the exact fix if something is off.
   ```

Launch:

```pwsh
$env:SCCACHE_WEBDAV_ENDPOINT = 'http://<host>:5000'
.\windows\build-buildkit.ps1 -Gpu                        # full chain from base
.\windows\build-buildkit.ps1 -Stages toolchain           # one stage
.\windows\build-buildkit.ps1 -Gpu -FinalTar out\bk-winamd64.tar  # + docker-loadable export
```

> **AMD RDNA4-GPU host (RX 9xxx)?** An ENABLED RDNA4 dGPU makes every
> process-isolated RUN-layer finalize fail with `hcsshim::ActivateLayer 0x20`
> (docker/for-win#14977; A/B-proven 2026-08-10 — see
> `docs/windows-host-setup.md` and § RDNA4 dGPU layer-lock (A/B history and
> diagnostics) below). The
> preflight gate `Assert-NoActiveRdna4Gpu` refuses to start while it is
> enabled. Build window: elevated
> `pwsh -File windows\scripts\host\toggle-rdna4-gpu.ps1 -Disable` → build (display
> falls back to the iGPU) → re-enable with the same script (default action).
> Two extra facts that save hours: failed finalizes WEDGE hcs state until a
> reboot (don't A/B anything on a wedged host), and the severity moved with
> Windows updates (post-KB5101684 even tiny RUN layers trip — expect patch
> days to change behavior). After every Adrenalin/Windows update, re-check in
> ~2 min with `windows\scripts\diagnostics\test-rdna4-layer-lock.ps1` (elevated) —
> its GONE verdict is the signal the workaround can be retired.

Remaining gotchas (why the classic lane still exists): images land in the
CONTAINERD store (`docker.io/local/kataglyphis:bk-*`) and are invisible to
docker's windowsfilter store — running/pushing via docker needs the `-FinalTar`
export (or push straight from the BK lane with `-PushRef <ref>`, which needs a
prior `docker login` in the invoking shell). **Inspecting, running and even
building them works via Stevedore's nerdctl in an ELEVATED shell** — the full
recipe set is § nerdctl lane below.

When validating lane parity, compare each `bk-*` image's payload against the
classic tag (the same scripts and Dockerfile targets run in both lanes).

Housekeeping and sharing:

- **Never kill a solve mid-finalize — and if a snapshot is already poisoned,
  `-NoCache` the stage rather than editing the source (measured 2026-08-07).**
  A chain was deliberately aborted (`Stop-Process buildctl`) at 23 GB free to
  escape the disk danger band. The abort was the right call — the documented
  alternative is a run that dies at 4.8 GB and leaves *two* poisoned snapshots —
  but the kill itself left a **half-committed snapshot**, and the next run died
  three times on it, deterministically, with identical IDs:

  ```text
  failed to commit 3p059m2d68o… to o47dumb0ovs4… during finalize:
  failed to reimport snapshot: hcsshim::ImportLayer failed in Win32:
  cannot create a file when that file already exists          ← 0xb7
  ```

  What does NOT work: the transient-retry engine (the failure is deterministic,
  so it just burns all three attempts), and `buildctl prune` (495 MB returned —
  this debris is not a reclaimable cache record, exactly as the `CACHE-BUST`
  comments in `setup-scoop-tools.ps1` already noted).

  What DOES work, and it is cheap:

  ```pwsh
  .\windows\build-buildkit.ps1 -Gpu -Stages sdk -NoCache   # the affected stage ONLY
  ```

  That works for a top-level stage because `-Stages sdk` already narrows the
  run. It does NOT work inside `media`: `-Stages media -NoCache` re-does all
  four media-core sub-stages plus litert plus tvm plus merge, so a single
  poisoned `media-core-built-opencv` used to cost the whole fan-out. Use
  **`-NoCacheStage`** (added 2026-08-14, backlog #64) — substring-matched
  against the stage label shown in the build output and in the log filename:

  ```pwsh
  .\windows\build-buildkit.ps1 -Gpu -Stages media -NoCacheStage opencv
  .\windows\build-buildkit.ps1 -Gpu -NoCacheStage media-merge,torch   # several
  ```

  For a one-off build-arg that no driver parameter covers, `-BuildArg
  'KEY=VALUE'` forwards to every solve (validated as `KEY=VALUE`, applied last so
  it wins over a stage's computed value). The Dockerfile must declare a matching
  `ARG` for it to do anything — BuildKit warns when it does not.

  Chain-wide `-NoCache` still overrides it. Each matched stage announces itself
  (`-NoCacheStage match -> --no-cache for THIS stage only`), and an entry that
  matched **no** stage **fails the run at the end** — printing only on a match
  would have meant a typo printed nothing at all while every stage built from
  cache and the owner believed a poisoned snapshot had been busted. Under
  `-ConcurrentAux` the flag is forwarded to the child drivers, since litert and
  tvm are built by those children and a parent-only flag would be a silent
  no-op for exactly the branches it targets.

  Re-running the RUN produces a new layer digest (its output is not
  bit-identical), so every chain ID beneath it is fresh and the poisoned
  snapshot is no longer in the path. The stage that had failed 3× exported
  cleanly: `[bk:Dockerfile.nvidia] OK`, `Done in 00:17:10`, `exporting layers
  346.1s`. **Prefer this over the in-file cache-bust technique** — identical
  effect, costs one stage re-run, and leaves no comment archaeology in the
  source. Reach for a source-level bust only when the debris sits in a layer
  `-Stages` cannot isolate.

  **Corollary worth internalising: let a doomed solve fail cleanly instead of
  killing it.** A finalize that fails on its own leaves nothing behind; a kill
  during finalize leaves this.
<a id="store-gc"></a>

- **Store GC — treat as MANDATORY OPS, not housekeeping.** buildkitd's store
  grows unbounded by default; iterating on the chain stacks full image
  generations (30–40 GB each) in the containerd store on every rebuild cycle.
  On 2026-08-03 disk exhaustion sabotaged one day THREE ways, each wearing a
  different costume: `hcsshim::ExportLayer 0x3` ("path not found") at snapshot
  finalize, a process-spawn flake surfacing as `'cmd.exe' is not recognized`,
  and finally an honest `ExportLayer 0x70` (disk full) — only the last one
  names the disease. If a Windows BK build fails in ANY weird hcsshim way,
  **check free disk first.** Cleanup levers, non-admin first:
  `buildctl prune --all` (build cache only), `docker image prune -f` (the
  classic lane's dangling generations — 91 GB reclaimed that day); the bk-*
  image generations themselves need admin (`nerdctl --namespace buildkit rmi`,
  or stop buildkitd+containerd and delete their state dirs for a full reset —
  dockerd may stop with containerd: `Start-Service stevedore` afterwards).
  **WIRED 2026-08-04, ACTIVE ON THIS HOST since 2026-08-05** (service
  re-registered with `--config`, rules verified via `buildctl debug workers
  -v`: reservedSpace ≈215 GB / minFree ≈27–32 GB / cachemount tier 21 GB/168h).
  Same admin session also added Defender exclusions for `buildkitd.exe`,
  `containerd.exe`, `C:\ProgramData\containerd` and `C:\ProgramData\buildkitd`
  — the 2026-08-05 night grind traced a family of finalize/export sharing-
  violation flakes to something racing the hcs scratch dirs (see the BK retry
  bullet in the roadmap). Originally wired after GC evicted the VS Build
  Tools layer between two runs (root cause, from `buildctl debug workers -v`:
  with no config file
  buildkitd runs computed defaults — `maxUsedSpace 100GB`, `minFreeSpace
  187GB`; the warm chain's cache is ~237GB on a 91%-full disk, so BOTH
  triggers fired on every GC pass and everything reclaimable — including the
  multi-hour VS layer — was evicted the moment a build's references dropped).
  The policy lives in the repo at `windows/buildkitd.toml` (three tiers; the
  load-bearing knob is `reservedSpace = 200GB`, below which GC never prunes —
  that is what protects the ~35GB VS-class layers; v0.32 key names are
  `reservedSpace`/`maxUsedSpace`/`minFreeSpace`, NOT the legacy
  `gckeepstorage`). Deploy/refresh it with
  `windows\scripts\host\apply-buildkitd-gcpolicy.ps1` from an admin **pwsh 7**
  shell (`pwsh -File …`; the script carries `#requires -Version 7.0`, and
  under Windows PowerShell 5.1 it refuses with a `#requires` message that is
  easy to read as "it ran and did nothing" — cost a round trip 2026-08-08,
  and matches the repo-wide rule that 5.1 appears only in the base bootstrap
  RUN) — it
  copies the toml to `C:\ProgramData\buildkitd\`, re-registers the service
  with `--config` (keeping `--debug`) and restarts buildkitd, so NEVER run it
  while a build is solving (it refuses when it sees a live buildctl unless
  `-Force`). Verify with `buildctl debug workers -v`. Keep real disk headroom
  by pruning the classic docker lane (`docker image prune -f`), not by
  shrinking `reservedSpace`. Manual fallback between chains:
  `buildctl --addr npipe:////./pipe/buildkitd prune --keep-storage 200000`.
  **Unit trap (cost a command on 2026-08-06):** `--keep-storage` is a `float`
  in **MB** and buildctl v0.32 accepts NO unit suffix — `200gb`/`250GB` die
  with `invalid value ... strconv.ParseFloat: invalid syntax`. 200 GB is
  `200000`. Same for `--keep-storage-min` and `--free-storage`. Confirm with
  `buildctl prune --help` before scripting it.
- **`--keep-storage` is the WRONG lever here — use `--free-storage`
  (measured 2026-08-06).** On buildkitd v0.32/WCOW,
  `prune --keep-storage 200000` against a 445.61 GB store returned
  `Total: 0B` — nothing deleted at all, despite `du` reporting
  `Reclaimable: 445.61GB` and every record `InUse: false`. The flags map to
  the same knobs as the gcpolicy (`--keep-storage` → maxUsedSpace,
  `--keep-storage-min` → reservedSpace, `--free-storage` → minFreeSpace) and
  only **`--free-storage`** actually drove a prune. Working invocation:

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd prune --free-storage 240000    # MB
  ```

- **`--free-storage` is a MINIMUM-FREE TARGET, not an amount to delete
  (measured 2026-08-06/07 night).** The daemon prunes until the host has that
  many MB free and then stops — so on a disk that ALREADY exceeds the target
  it deletes nothing, however much is reclaimable. Measured: at 198.5 GB free
  with 150.5 GB `Private` in the store, `prune --free-storage 200000` removed
  **77 MB**; the identical command with `900000` (more than the disk can ever
  offer) removed the full **150.48 GB**. This is also why the earlier runs
  looked like the flag "stops at the Private slice" — they were hitting their
  target, not a ceiling. **Rule: to drain everything unpinned, ask for more
  free space than the disk physically has.** It cannot over-delete: `Shared`
  records stay pinned regardless (next bullet), so an absurd target is safe.

- **A store that no prune lever can touch, with `du` reporting
  `Reclaimable: 0B` (measured 2026-08-08).** Store at 207.63 GB against
  `reservedSpace = 200GB` (= **214.75 GB**; the toml takes GiB); all 37 records
  read `Reclaimable: false` and **every** lever returned `Total: 0B`:

  > **SETTLED 2026-08-08, and it is NOT `reservedSpace`.** The cause is
  > **`Shared: true`** — records pinned by containerd IMAGE TAGS, which prune
  > can never take (see the `Private`/`Shared` bullet below; that note was
  > right all along and got overlooked twice in one day). Decisive
  > measurement: store 109.06 GB reporting `Reclaimable: 109.06GB` under a
  > **42.95 GB** reserve — far ABOVE the reserve, everything nominally
  > reclaimable — still pruned **0 B**, with `du -v` showing `Shared: true` on
  > every record. `Reclaimable` reports the LEASE state, not what prune will
  > hand back.
  >
  > Why the reserve looked causal: lowering it to 150GB coincided with an
  > admin `nerdctl rmi` of eight stage tags, and *that* is what released
  > 98.83 GB (C: 85.1 → 139.1 GB). Two changes, one observation, wrong one
  > credited. **Check `du -v` for `Shared` before touching the GC policy** —
  > the lever for `Shared` is `nerdctl rmi` / `image prune -f`, and it costs
  > you the stage images, so decide deliberately.

  ```text
  buildctl prune                                        Total: 0B
  buildctl prune --free-storage 950000                  Total: 0B   # > disk size
  buildctl prune --all --keep-storage-min 0 ...         Total: 0B
  buildctl prune-histories                              Total: 0B   # listed, freed nothing
  ```

  None of those is broken; the reserve simply forbade the work. **Check
  `reservedSpace` against `du`'s Total BEFORE reaching for a prune flag** —
  if Total < reservedSpace there is nothing any flag can do, and the only
  levers are `nerdctl rmi` (frees the containerd image store, a *separate*
  store — it took 66.5 → 85.0 GB here while buildkit's 207.63 GB did not
  move by a byte) or editing the policy and restarting buildkitd.

- **FULL LIQUIDATION playbook — when the store has accreted ~1 TB and no
  surgical lever pays (measured 2026-08-20/21, store at 1,098 GB real).**
  After weeks of chain iterations the surgical levers converge on zero: probe
  tags rmi'd (+17 GB — they share the spine), `prune-histories` emptied,
  buildkitd restarted, naked `prune` → `Total: 0B`, all 182 records
  `Reclaimable: false` (the Shared/lease mechanism above — the 13 live chain
  tags weave the whole store together). At that point the ECONOMIC move is
  reset-and-rebuild, not archaeology:
  1. `windows/scripts/host/reset-container-stores.ps1` (elevated; stops
     services, RENAMES `containerd`/`buildkitd`/`Docker` state dirs to
     `.bak-<stamp>`, restarts, re-deploys the GC toml). The rename frees
     NOTHING by itself.
  2. Delete the `.bak` trees. **NOT with `takeown /R` + `icacls /T`** — three
     full tree walks over millions of windowsfilter files (hours). The fast
     path is robocopy in backup mode, which bypasses the
     SYSTEM/TrustedInstaller ACLs entirely and runs 32-way parallel
     (3–5× faster; plain `Remove-Item` fails outright on `Files\bootmgr`
     etc.):
     ```pwsh
     robocopy C:\empty-dir $bak /MIR /B /R:0 /W:0 /NFL /NDL /NJH /NJS /NP /MT:32
     Remove-Item -LiteralPath $bak -Recurse -Force   # empty husk
     ```
  3. One overnight ride rebuilds the chain. The sccache WebDAV store lives
     OUTSIDE the container stores and survives, so the "cold" rebuild runs
     compile-warm (~3–4 h, measured 3h14 on 2026-08-20) and the store
     restarts at a lean ~150–250 GB instead of 1 TB.
  Prevention (the reason it got this big): buildkit GC never prunes NAMED
  images, and every ride re-tags the full chain — superseded generations
  accumulate silently. Release probe/diag tags promptly
  (`apply-elevated-window.ps1` step 3) and expect a reset every few weeks of
  heavy iteration until the ride wrapper learns to untag its predecessors.

- **Size `reservedSpace` against FREE space, not total disk (2026-08-08).**
  The "~20-25 % of the disk" rule of thumb assumes the disk is mostly
  buildkit's. On a host where it is not, it produces an arithmetically
  unsatisfiable policy:

  ```text
  disk 930.8 GB - non-buildkit content ~637 GB = ~294 GB available to buildkit
  reservedSpace 214.75 GB                      =>  ~79 GB of working room
  highest stage disk floor (sdk)                    60 GB
  a heavy media layer's scratch, which GC may not touch   6-10 GB
  ```

  So the chain consumed room, GC was structurally unable to give any back, and
  the stage gate refused at 53.5 GB mid-media — read at the time as a disk
  problem, actually a policy one. `reservedSpace` is **150GB** now (the floor
  this file and `buildkitd.toml` already prescribed), which still exceeds the
  ~120-150 GB fresh chain spine it exists to protect and leaves ~144 GB of
  working room. Note the invariant: **`reservedSpace` + the highest stage disk
  floor must fit in the space actually available to buildkit.**

- **Prune can only ever take the `Private` slice — `Shared` is pinned by the
  image tags.** Same run: 445.61 GB → 371.77 GB, i.e. **exactly the 73.84 GB
  that `du` called `Private`**, and it stopped there (C: 31.6 → 93.3 GB free).
  The remaining 371.77 GB were all `Shared` — held by the ten `bk-*` stage
  tags in the containerd namespace, not by each other. Freeing those means
  `nerdctl --namespace buildkit rmi` (admin) FIRST, and that is not free
  disk: those tags are the hot chain, so deleting them buys GB at the price
  of a cold 5–6 h rebuild. Decide deliberately. Diagnose before pruning with

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd du --format '{{json .}}'   # then sort by Size, read Shared/InUse
  ```

  A healthy store looks like this one did: `InUse: 0` everywhere (nothing
  pinned by a live solve) but most bytes `Shared: true` (pinned by tags).
  Note also that a single chain generation is NOT waste — the "iterating
  stacks 30–40 GB generations" failure mode means DUPLICATE generations of
  the same stage tag; ten distinct stage tags of one chain are the asset.

- **A SUPERSEDED lineage hides whole duplicate copies of your most expensive
  layers — the single biggest reclaim on this host (266 GB, 2026-08-06/07
  night).** After a cache-bust rebuilds `base`/`sdk`/`toolchain`, the older
  stage tags downstream of the OLD base still exist and still pin their own
  full copy of every layer beneath them. They look innocent (distinct tag
  names, no duplicates in `nerdctl images`) because the duplication is one
  level down, in the RECORDS. Measured with 10 tags and a 384 GB store:

  ```text
  setup-cuda.ps1          109.5 GB  in 3 copies
  setup-scoop-tools.ps1    88.5 GB  in 3 copies
  setup-vs.ps1             69.1 GB  in 2 copies
  ```

  One copy per cache-bust — 267 GB of the 384 GB was the base spine held
  three times over. **Diagnose** by grouping the verbose record list by the
  script each record ran and reading `Last used`: records from a superseded
  lineage carry an older date than the current chain's rebuild.

  ```pwsh
  buildctl --addr npipe:////./pipe/buildkitd du -v     # group by Description, read "Last used"
  ```

  **Fix:** admin `nerdctl --namespace buildkit rmi` on the stage tags of the
  superseded lineage, wait ~30 s for the containerd GC, then prune. Identify
  them by lineage, not by age: a stage tag is dead when its ancestor stage was
  rebuilt after it (compare image IDs against the current chain, and the stage
  logs in `out\windows-build-logs\` for the rebuild times). Deleting them costs
  nothing that a failed chain was not going to rebuild anyway. **Before
  deleting a tagged FINAL image, verify the registry copy** —
  `docker manifest inspect ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64`
  — so the local one is not the only one. Sequence that produced the 266 GB:
  prune (42.4 GB) → drop canary tags + prune (15.7 GB) → drop the 6 superseded
  stage tags + prune (109.7 GB) → prune with a target above disk capacity
  (150.5 GB). C: 4.8 → 271.3 GB free, with the current lineage untouched.
<a id="vhdx-backed-checkouts"></a>

- **VHDX-backed checkouts — the reclaim lever that is NOT the store.** When the
  repo (or the store) lives on a dynamically-expanding VHDX, that file only
  ever grows: deleting data inside the guest leaves the blocks allocated in the
  host file. Measured on the reference host 2026-08-06: **270.1 GB physical for
  16.1 GB of live data**, i.e. ~254 GB of dead blocks that no `buildctl prune`
  can ever touch — while C: had silently fallen to **11.7 GB free**, deep
  inside the "hcsshim gets weird before it admits disk-full" band. Lever
  (ADMIN, never while a build solves):

  ```pwsh
  pwsh -File windows\scripts\host\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx -ReportOnly   # look first
  pwsh -File windows\scripts\host\compact-host-vhdx.ps1 -VhdxPath C:\cataglyphis-EXTREME.vhdx               # then act
  ```

  **ReFS caveat — measured, do not re-probe:** `Optimize-VHD -Mode Full` ran 42 s
  on that disk, reported success, and reclaimed **0.2 GB**. Compaction can only
  release blocks the guest reports free via UNMAP/TRIM; NTFS guests do that
  reliably, ReFS guests essentially do not. The script detects the guest
  filesystem and warns BEFORE spending the downtime. On ReFS the only reliable
  reclaim is rebuilding the VHDX around its live data (12 GB copy on this host).
  The same run still freed **19.4 GB on C:** — from killing a wedged `buildctl`
  and stopping buildkitd/containerd, which released pinned scratch. That half
  works on any filesystem, which is why the script does both.

  **When compaction returns ~nothing, rebuild instead:**
  `windows\scripts\host\rebuild-host-vhdx.ps1` creates a fresh disk, mirrors the
  live data into it, compares file count AND byte totals, and only then hands
  over the drive letter. It runs in two phases on purpose, because they have
  very different requirements:

  ```pwsh
  pwsh -File windows\scripts\host\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -ReportOnly
  pwsh -File windows\scripts\host\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -CopyOnly    # safe with everything open
  pwsh -File windows\scripts\host\rebuild-host-vhdx.ps1 -VhdxPath C:\my.vhdx -SwapOnly `
       -VerifyPath D:\GitHub\Kataglyphis-ContainerHub -LogPath C:\rebuild.log -RetireOld
  ```

  The COPY phase touches nothing live. The SWAP phase detaches the volume and
  therefore requires that NOTHING holds a handle on it — no shell whose current
  directory is on it, no editor with the checkout open, no agent session. Run
  it from a shell on another drive, and give it a `-LogPath` off the volume.
  **This is not hypothetical:** an unattended `wsl --unmount`/detach on this
  disk on 2026-08-06 pulled D: out from under a running session and killed it.
  The script therefore refuses rather than forces the detach, and keeps the
  verified copy for a later `-SwapOnly` run. The old disk is kept as `.old`
  unless `-RetireOld` is passed — until it is deleted, NO space is reclaimed.
- **Cross-host / CI cache**: `build-buildkit.ps1 -ExportCacheRef <registry-ref>`
  / `-ImportCacheRef <ref>` wire buildkit's registry cache (`mode=max`) once
  registry auth works from buildkitd — a second machine then rebuilds the chain
  from cache instead of from source.

## nerdctl lane (admin): run, inspect, build

**Both possibilities exist and both are supported.** Verified end-to-end on the
reference host 2026-08-07. Use whichever fits the job:

| | `buildctl` (via `build-buildkit.ps1`) | `nerdctl` |
|---|---|---|
| Shell | **non-admin** | **admin, always** |
| Builds the chain | ✅ this is the production lane | ✅ works, but see "why the chain still uses buildctl" |
| Run / exec into an image | ✗ | ✅ the reason to reach for it |
| Image store admin (`images`, `rmi`) | ✗ | ✅ only way to reach the containerd store |

### One-time host requirements

1. **The CNI nat config must be a `.conflist`** — see host-setup § A5. With a
   bare `.conf`, nerdctl PANICS (`index out of range [0] with length 0`); it is
   the single thing that made nerdctl unusable here until 2026-08-07.
2. **Admin shell.** Not negotiable and not a configuration mistake: nerdctl
   opens `\\.\pipe\containerd-containerd`, which is Administrator-only.
   `buildkitd` ships `--group docker-users` (which is exactly why `buildctl`
   runs unelevated); **containerd has no equivalent** — verified against its
   full flag set and default config, `--address` only moves the pipe, it does
   not change who may open it. nerdctl opens that client for *every* subcommand,
   including `build --output type=tar`, so no output mode avoids it.
   **Do not attempt pipe-ACL hacks**: the ACL is recreated on every containerd
   restart, and containerd access is effectively machine-admin. The legitimate
   route is an upstream containerd feature request.
3. **A fresh shell.** `C:\Program Files\Stevedore\bin` is on the MACHINE PATH,
   so shells opened before Stevedore was installed will not find `nerdctl`.
   Reopen the window rather than patching `$env:Path`.
4. **`--namespace buildkit` on every command.** The `bk-*` images live in
   containerd's `buildkit` namespace; the default namespace looks empty.

### Recipes

```powershell
# --- inspect the store -------------------------------------------------------
nerdctl --namespace buildkit images
nerdctl --namespace buildkit ps -a

# --- interactive shell INSIDE a finished image (the main win) -----------------
# NOTE: no trailing command. The final image's ENTRYPOINT (entrypoint.cmd) loads
# VsDevCmd and then starts pwsh by itself.
nerdctl --namespace buildkit run --rm -it --network nat docker.io/local/kataglyphis:bk-winamd64

# once inside: verify what actually shipped
#   python -c "import cv2, onnxruntime; print(cv2.__version__)"
#   where.exe nvcc ; gst-inspect-1.0 --version

# --- one-shot command in an image WITHOUT an entrypoint ----------------------
nerdctl --namespace buildkit run --rm --network nat docker.io/local/kataglyphis:bk-windows-base cmd /c ipconfig

# --- one-shot command in an image WITH an entrypoint: override it -------------
nerdctl --namespace buildkit run --rm --entrypoint pwsh --network nat docker.io/local/kataglyphis:bk-winamd64 -NoProfile -Command "python -c 'import cv2; print(cv2.__version__)'"

# --- build (admin) -----------------------------------------------------------
# BUILDKIT_HOST is REQUIRED on Windows: nerdctl has no unix-socket default to
# fall back to, and without it the build fails to reach buildkitd.
$env:BUILDKIT_HOST = 'npipe:////./pipe/buildkitd'
nerdctl --namespace buildkit build -t local/kataglyphis:my-tag --progress plain <context-dir>

# --- housekeeping (the 266 GB lever) -----------------------------------------
nerdctl --namespace buildkit rmi docker.io/local/kataglyphis:<obsolete-tag>
```

### Why the chain still uses `buildctl`

`nerdctl build` is a wrapper that hands the solve to the same `buildkitd`. Using
it for the chain would cost, and gain nothing:

- **every build would need elevation** — the background/unattended runs this
  project depends on are non-admin today;
- **`--opt image-resolve-mode=local`** is load-bearing for stage handoff (the
  `bk-*` tags resolve from the containerd store instead of attempting a registry
  pull) and is not exposed by `nerdctl build`;
- the driver's transient-retry engine, per-stage logs and preflight gates
  (`Assert-DiskHeadroom`, `Assert-ShimPatch`) are keyed to `buildctl`.

So: **`buildctl` builds the chain, nerdctl inspects and runs its results.**

### Traps (each one cost time on 2026-08-07)

- **Passing a command to an image that has an `ENTRYPOINT`** appends it as
  entrypoint ARGUMENTS. On `bk-winamd64` that exits `255` immediately. Use no
  command, or `--entrypoint`.
- **A killed `nerdctl run` leaves a zombie**, and `nerdctl rm -f` on it can then
  BLOCK for up to 45 minutes — the patched shim waits for teardown instead of
  force-terminating (correct for builds, painful interactively). Recovery:
  `Get-Process containerd-shim-runhcs-v1,CExecSvc | Stop-Process -Force`, then
  `rm -f` again. Safe only when the container did no real filesystem work.
- **Exit code `3221225786`** (`0xC000013A`) means the container was Ctrl+C'd,
  not that the image is broken.
- **Two harmless warnings** on every run: `default network named "nat" does not
  have an internal nerdctl ID` (true — containerd created it) and
  `failed to remove hosts file` at exit. Ignore both.
- **Diagnosing a "hung" nerdctl**: check `containerd-debug.log` for the task's
  exit Span before assuming the container is stuck — it has usually exited
  already and only cleanup is blocked.

Roadmap (**mounts PROBED WORKING on Windows buildkitd v0.32, 2026-08-03** —
both `--mount=type=bind` and `--mount=type=cache` execute correctly in RUN
steps; the remaining work is the Dockerfile surgery):

- **`RUN --mount=type=bind` for build scripts**: DONE 2026-08-04 (single-file
  mounts probed working on WCOW buildkitd v0.32). The BK lane's `*-bk` stages
  in Dockerfile.media-builder + the merge builder's warm/built stages carry NO
  script/patch COPY layers — every RUN bind-mounts exactly its transitive
  script closure at `C:\bkmnt` and passes `-ScriptDir C:\bkmnt`. Editing a
  build script now re-runs ONLY the RUNs that mount it (an OpenCV fix no
  longer re-pays the 75-minute ONNX layer). Modules are mounted PER FILE too
  (2026-08-04): the in-container closure is exactly SourceBuild.Common +
  Shared + SourceBuild.Patches + SourceBuild.Cuda + Native.Common (plus
  Installer.Common for GStreamer) — the earlier whole-dir `modules/` mount
  let edits to the 24 host-only modules (BuildDriver, BuildKit, Flutter, …)
  bust every compile RUN. `load-versions.ps1` is mounted into every build RUN
  so the freshly COPY'd versions.env is re-read instead of the base image's
  baked (possibly stale) Machine env. The classic targets keep their baked
  COPYs (classic docker cannot `--mount`).
- **Concurrent aux branch solves**: available OPT-IN via
  `build-buildkit.ps1 -ConcurrentAux` (2026-08-04) — media-core stays the
  sequential long pole, then litert + tvm build side by side via child
  drivers on half the media memory budget each. Measure host RAM headroom
  before making it the default. Two costs to know: (a) children run a single
  media branch, so the GStreamer merge is gated on all three branches being
  requested and runs only in the parent (children print `[bk:merge] skipped`);
  (b) `MEMORY_LIMIT_GB` is baked as ENV in the media `common` stage, so
  TOGGLING -ConcurrentAux (which halves the aux budget) changes that ENV and
  invalidates the aux branches' compile RUNs — pick a mode and stay in it.
- **Registry push**: available via `build-buildkit.ps1 -PushRef <ref>`
  (2026-08-04) — re-solves the final image from cache with a push exporter;
  needs a prior `docker login` in the invoking shell (buildctl forwards the
  client credential store).
- **`RUN --mount=type=cache` for a local sccache dir** (WebDAV stays as the
  cross-lane L2): kills the HTTP round-trip on ~5000 compiles per stage.
  Probed working. CAUTION (2026-08-04): cache mounts get CLONED whenever the
  record is locked — fine for an L1 compile cache (worst case: cold clone,
  WebDAV L2 still hits), but never rely on two solves seeing the same instance.

  **CORRECTED 2026-08-08 — the wiring is NOT just `SCCACHE_DIR`.** This entry
  used to say "wiring = set SCCACHE_DIR to the cache mount", which alone does
  nothing: with a remote configured sccache runs in single-level *legacy* mode
  and the disk backend is simply not in the chain. Two tiers need the explicit
  chain variable (verified against mozilla/sccache `docs/Configuration.md`):

  ```text
  SCCACHE_MULTILEVEL_CHAIN = disk,webdav      # left-to-right = fast-to-slow
  SCCACHE_DIR              = <the cache mount target>
  SCCACHE_CACHE_SIZE       = <cap for the L0 disk tier>
  SCCACHE_WEBDAV_ENDPOINT  = <unchanged>
  ```

  Read-through/write-through with automatic backfill; each level keeps its own
  variables. `SCCACHE_MULTILEVEL_WRITE_ERROR_POLICY` defaults to `l0` (a write
  failure on the local tier fails; remote-tier write errors are tolerated).

  > **DISABLED SINCE 2026-08-16 — this describes the layout we want back, not
  > the one in effect.** `SCCACHE_MULTILEVEL_CHAIN` now defaults to `""` in both
  > media Dockerfiles, so the WebDAV remote is the sole cache. The L0 tier lives
  > on a BuildKit cache mount, and on Windows those lose writes once the
  > directory holds objects an EARLIER RUN wrote. The `l0` write-error policy
  > above is what turned that into a total failure: with L0 broken, nothing ever
  > reached the remote either (`L1 writes 0`). Measurement, cause and the
  > re-enable recipe: backlog #99.

  **Version dependency this creates:** multi-tier landed in sccache **v0.16.0**
  (2026-06-19; implemented 2026-04-17, PR #2581). The image installs sccache
  from the FLOATING scoop block — measured **0.17.0** in the 2026-08-08 chain,
  so it works today. But the moment this wiring lands, sccache stops being a
  tool the build merely invokes and becomes one whose VERSION gates a feature:
  on an older sccache the chain variable is ignored and the L1 silently does
  nothing, with no error. Pin `sccache` alongside llvm/ninja/nasm if this is
  wired — the same argument that pinned those three.
- **sccache for the merge/GStreamer builder**: DONE 2026-08-04 —
  build-gstreamer-from-source.ps1 sets `CC/CXX='sccache clang-cl'` for meson
  when the remote backend is configured (this build previously ran fully
  uncached, ~30 min hot, because the merge builder never wired the endpoint).
- **Automatic transient retry in the BK driver**: DONE 2026-08-04, extended
  2026-08-05 — Invoke-BkStage retries once on `Activate/PrepareLayer 0x20` /
  ttrpc / shim-task / `rpc Unavailable` failures AND on the hcs-temp
  finalize/export flake family discovered in the 2026-08-05 night grind:
  `failed to reimport snapshot` (GetFileAttributesEx not-found variant) and
  `failed to write compressed diff` (SystemTemp\hcs* sharing violation — the
  retry saved the sdk export live that night). Two hard-won caveats:
  (a) `ImportLayer 0xb7 "already exists"` on IDENTICAL source/target
  chain-IDs across attempts is NOT transient — it is persistent snapshotter
  debris from an earlier low-disk finalize failure; non-admin remedy is a
  deliberate CACHE-BUST of the layer above it (any content change to the
  COPY'd/mounted file → new chain-IDs sidestep the debris; see
  setup-scoop-tools.ps1's 2026-08-05 header comment for the live example).
  (b) disk-full also surfaces as `failed to write compressed diff` — check
  free space before trusting the transient classification. Root causes
  addressed since: gcpolicy active + Defender exclusions for
  buildkitd/containerd (below) + ≥40 GB free-disk discipline.
- **Per-library media-core split**: DONE, and escalated on 2026-08-04 from
  4 RUN layers to **4 chained SOLVES** (targets `media-core-built-onnx` →
  `-opencv` → `-ffmpeg` → `media-core-built`, image handoffs via the
  `MEDIA_CORE_*_IMAGE` ARGs; build-buildkit.ps1 drives them in order). An
  FFmpeg-only change still recompiles nothing else — and each library's
  export is now independent of the others' finalize behavior.
<a id="defect-solved"></a>

- **🎯 DEFECT SOLVED (2026-08-06, patched runhcs shim).** ROOT CAUSE: the
  entire ExportLayer-0x3 family was hcsshim's hardcoded
  `const tearDownTimeout = 30 * time.Second` in
  `cmd/containerd-shim-runhcs-v1/task_hcs.go` (`close()`: shutdown wait +
  terminate wait; plus the 30 s "waiting for task to be closed" in
  `DeleteExec`). Heavy-churn WCOW silo teardown needs MINUTES — measured
  **117 s** for the OpenCV specimen (HcsShutDownComputeSystem 01:16:08 →
  notification 01:18:05) — so the stock shim terminated mid-hive-flush and
  left the scratch vhdx permanently unexportable. FIX DEPLOYED: shim built
  from hcsshim@main (81e2e01) with the constants raised to 45 min/100 min
  (zero cost on the happy path — the timer only matters when it would have
  killed the build), installed to `C:\Program Files\Stevedore\bin\
  containerd-shim-runhcs-v1.exe` (original preserved as `.exe.orig`;
  replacement needs admin + no running shim processes; containerd itself
  needs NO restart — the shim spawns per container). PROOF: first-ever
  direct OpenCV finalize+export on this host (`bk-canary-shim-opencv`,
  28.6 s export, no 0x3), confirmed per the 3× OPENCV canary rule
  (`bk-canary-shim-opencv{,2,3}` all clean, --no-cache). The lane is
  DE-WARMED since 2026-08-06: direct solves everywhere, warm/materialize
  retired (payload scripts kept in tree as the rollback path, c9586c1^).
  **MAINTENANCE:** any Stevedore/containerd update overwrites the patched
  shim — `build-buildkit.ps1`'s `Assert-ShimPatch` preflight catches it before
  the build starts. Since 2026-08-07 the check is a **SHA256 comparison**
  against the hash `deploy-shim-patch.ps1` recorded when it installed the
  binary (`C:\ProgramData\kataglyphis\shim-patch.json`), which is exact and
  cannot rot as hcsshim moves; the older size table (patched 25 332 736 for the
  env-var build, 25 329 664 for the fixed-constant build, vs stock 23 279 616)
  survives only as the fallback for a host that has not run the deploy script
  since. **Run `deploy-shim-patch.ps1` once to record the hash** — until then
  the gate warns that it is still guessing. `-ReportOnly` shows the recorded
  hash, whether the live binary still matches, the backups and the service
  environment; the same script re-installs. Rebuild recipe: scoop go + `git clone
  microsoft/hcsshim` + apply the in-tree patch + `go build
  .\cmd\containerd-shim-runhcs-v1`. **Upstream submission is FILED as a DRAFT
  PR: [microsoft/hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855)**,
  materials in-tree at `windows/upstream/hcsshim-teardown-timeout/` (issue
  text, PR description, `git format-patch`). It makes all four fixed 30 s
  limits in the binary configurable — the two in `task_hcs.go` plus the
  crash-recovery wait in `delete.go` — with **defaults unchanged at 30 s**.

  **ENV VAR NAMES — get these exactly right:**

  ```text
  CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT    e.g. 45m
  CONTAINERD_SHIM_RUNHCS_V1_TASK_CLOSE_TIMEOUT  optional; defaults to 2x teardown + 30s
  ```

  They follow the shim's existing house convention (`..._WAIT_DEBUGGER`). An
  earlier draft of this document named them `HCSSHIM_TASK_*` — those were
  INVENTED and never existed in any build. Setting a wrong name is silent:
  the shim falls back to 30 s and the defect returns with no error anywhere.
  Set them on the containerd SERVICE (the shim inherits its environment);
  `deploy-shim-patch.ps1 -ServiceEnvironment` merges them in. Note the
  upstream patch is NOT the same as a fixed-constant build: with the defaults
  it behaves exactly like stock, so a shim built from it and no env var set
  is a shim with the bug. Verify BEHAVIOURALLY with an OpenCV canary — the
  shim logs its effective timeout at Debug level, which does not reach
  containerd's log, so a quiet log proves nothing. Getting the PR merged is
  what retires the binary-size check after every Stevedore update.
  The historical bullets below are preserved for diagnosis value.
- **DEFECT PARTIALLY TAMED, NOT GONE (2026-08-05, de-warming attempted and
  ROLLED BACK same evening).** Sequence of record: (1) with the Defender
  exclusions active, a fresh `--no-cache` heavy TVM→IREE canary FINALIZED
  AND EXPORTED CLEAN (`bk-canary-0x3` — a finalize class that used to fail);
  (2) on that evidence the lane was de-warmed to direct solves; (3) the
  FIRST direct OpenCV finalize failed `ExportLayer 0x3` with the original
  signature, deterministic across retries → **OpenCV/GenAI-class churn
  still trips the defect; TVM was the wrong canary specimen.** The Defender
  exclusions remain load-bearing (they cured the hcs-temp finalize/export
  FLAKE family and evidently moved TVM-class finalizes to reliable) but do
  NOT cure the core defect. The warm/materialize pattern was RESTORED from
  git history within minutes — the preserved rollback path worked exactly
  as designed. LESSON: any future de-warming attempt must canary with
  **OpenCV** (the deterministic trigger), not TVM: same recipe as below but
  `--opt target=media-core-warm-opencv` + `--opt
  build-arg:MEDIA_CORE_ONNX_IMAGE=<current onnx tag>`; clean export three
  times in a row before touching the architecture.
  **Canary recipe (after any AV/OS/hcsshim change):**
  `buildctl build ... --opt filename=Dockerfile.media-builder --opt
  target=media-core-warm-opencv --no-cache --output
  type=image,name=docker.io/local/kataglyphis:bk-canary-0x3 --opt
  build-arg:BASE_IMAGE=docker.io/local/kataglyphis:bk-windows-toolchain
  --opt build-arg:MEDIA_CORE_ONNX_IMAGE=docker.io/local/kataglyphis:bk-windows-media-core-onnx
  --opt build-arg:MEMORY_LIMIT_GB=16 --opt
  build-arg:SCCACHE_WEBDAV_ENDPOINT=<endpoint>` (plus the standard --local/
  --opt image-resolve-mode=local flags). Clean export = that class is safe;
  `ExportLayer 0x3` at "exporting layers" = defect present, keep
  warm/materialize. Historical writeup below preserved for diagnosis value.
- **IN-CONTAINER MITIGATIONS EXHAUSTED (2026-08-05 late night, two more
  OpenCV canaries).** The shim injects `WaitToKillServiceTimeout=2147483647`
  into every container; overriding it to 5 s at payload start (probe R1)
  changed nothing — exit 0 is published instantly, `HcsShutDownComputeSystem`
  returns in ms, and the shutdown AND terminate notifications are still lost
  (30 s + 30 s timeouts in the containerd debug log), then `ExportLayer 0x3`.
  Probe R2 additionally stopped/killed every non-baseline resident before
  exit (sccache server, msdtc, AggregatorHost, SysMain, DiagTrack, UsoSvc,
  WinRM + 7 more services — verified stopped in the exit dump): same loss,
  same 0x3. Together with the earlier settle falsification this proves the
  hang is HOST-side (silo/wcifs teardown of heavy-churn scratches), not
  anything running inside the container. Upstream fingerprint:
  microsoft/Windows-Containers#547 (ltsc2025 process isolation, ~10-min
  shutdown, resources stay locked, closed unresolved). NOTE (corrected
  2026-08-06): Win11 24H2+ hosts running ltsc2025 images process-isolated
  is OFFICIALLY SUPPORTED per the version-compatibility doc (the strict
  build-match rule was relaxed for this combination) — so this is a
  reportable platform bug in a supported configuration, not an off-label
  artifact; #547 saw the same hang on a matched-build 26100 host.
  CONSEQUENCE: warm/materialize is the standing architecture on this class
  of host, not a temporary workaround. Do NOT burn more canaries on
  in-container theories; the only genuine escape hatches are a platform fix
  (Windows CU) or the containerd 2.x CimFS/UnionFS snapshotter lane (bypasses
  wcifs entirely — experimental for WCOW, unproven with the BuildKit worker).
  UPDATE 2026-08-06: the CimFS lane was TESTED AND FALSIFIED on containerd
  v2.3.3 (plugin+differ both "ok"): buildkitd with
  `--containerd-worker-snapshotter=cimfs` dies on the FIRST build step with
  `scratch snapshot without any parents isn't supported` — the cimfs
  snapshotter cannot create parentless scratch snapshots, which BuildKit
  needs even to load the Dockerfile context. CimFS is pull/run-only today;
  do not retry until a containerd release notes BuildKit/build support.
  (STALE-NOTE corrected 2026-08-21: an earlier revision claimed a teardown
  probe remained in `bk-warm.ps1` — it does not; the file is a 55-line
  arg-forward + Export-BuildHandoff wrapper, and all solves are direct,
  so there are no warm layers to cache-bust either.)
- **HISTORICAL (2026-08-04, worked around via warm/materialize) —
  GenAI/OpenCV snapshot finalize
  (`ExportLayer 0x3`, disk fine)**: those two layers deterministically fail BOTH finalize paths on
  buildkitd v0.32/containerd, on every fresh snapshot. A 17-probe bisection
  (2026-08-04) falsified: poisoned cache records, layer depth (14 stacked
  trivial layers export fine), defective ONNX parent (trivial layers on it
  export fine), file/dir content (a GenAI layer whose ENTIRE diff was deleted
  before step end still fails), lingering compiler daemons, vctip, bare
  .NET-Framework CLR (`MSBuild -version` layer exports clean), pending-delete
  zombies, and build-tree deletion (`KEEP_BUILD_ARTIFACTS=1` still fails).
  Clean under identical conditions: ONNX (ninja, 100-min layer), cpython
  (MSBuild), LiteRT (bazel), every trivial probe. TVM+IREE joined the failing
  set later the same morning (cmake+ninja like the clean ONNX — no build-system
  pattern survives).

  **Root-cause finding (containerd debug log, 2026-08-04 07:59):** the snapshot
  commit RACES a failing container teardown. Timeline: task exits → shim
  cleanup starts → an HCS operation inside that cleanup fails with
  `HCS_E_INVALID_STATE` (0xC0370105, "Containervorgang ist im aktuellen
  Zustand ungültig") → containerd logs `commit snapshot` **70 ms after** the
  cleanup began → 13 s later `ExportLayer` fails 0x3. The scratch VHDX is
  never cleanly released by the half-failed teardown, so the export finds no
  layer paths. Fits the clean/toxic split: layers whose containers exit with
  residual processes + heavy dirty IO (15–25-min compiles) hit the bad
  teardown state; calm exits don't.

  **How to capture the debug evidence again (admin):** set the service
  ImagePaths via registry (sc.exe quoting mangles them in PowerShell):
  `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\containerd' -Name
  ImagePath -Value '"C:\Program Files\Stevedore\bin\containerd.exe"
  --run-service --service-name containerd --log-level debug --log-file
  C:\ProgramData\containerd\containerd-debug.log'` (analog `buildkitd` with
  `--debug` before `--run-service`), `Restart-Service containerd -Force`,
  `Start-Service buildkitd, stevedore`, and
  `icacls <log> /grant "<user>:(R)"` to read it non-elevated. **Policy: debug
  logging stays PERMANENTLY ON on this host** (owner decision 2026-08-04) so
  the next snapshotter incident carries its evidence immediately. The log
  grows unbounded — if it gets large, truncate it (admin:
  `Clear-Content C:\ProgramData\containerd\containerd-debug.log`) rather than
  disabling the flags.

  **All host-level mitigations were exhausted (2026-08-04):** quiesce tail,
  msdtc/WMI stops, and a **full host reboot with a fresh container** all hit
  the identical double-timeout + 0x3 signature. Host processes show the
  container's processes DO die — the HCS shutdown *notification* is what
  never arrives (vmcompute → hcsshim callback), after which the scratch is
  never cleanly released. buildkitd v0.32 has no Hyper-V isolation option.
  **Genuine platform defect** (Win11 host 26200 + ltsc2025 + process
  isolation + heavy-churn layers; GenAI/OpenCV/TVM/GStreamer-class builds
  trip it — ONNX/cpython/LiteRT/torch never did). Worth reporting upstream:
  hcsshim (lost shutdown notification) + buildkit (commit proceeds into a
  known-failed teardown).

  **WORKING SOLUTION — the warm/materialize pattern (BK lane is GREEN
  end-to-end since 2026-08-04, `bk-winamd64` built in 44 min hot):** exploit
  BuildKit's LAZY finalization — a snapshot is only finalized when a child
  step or an exporter needs it. Per heavy library:
  1. **Warm solve** (`media-core-warm-<lib>` / merge `warm`; driver runs it
     via `Invoke-BkStage -NoOutput`): the build runs normally on the scratch;
     the artifact delta (C:\runtime + cpython site-packages, CreationTime >
     step start) leaves as ONE tar over the sccache dufs server
     (`Export-BuildHandoff`). No exporter + no child step ⇒ the toxic
     snapshot is never finalized ⇒ the defect never fires.
  2. **Materialize solve** (`media-core-built-<lib>` / merge `built`,
     exported as the handoff image): a calm seconds-long container downloads
     + extracts the tar (`Import-BuildHandoff`) — clean teardown, clean
     finalize, clean image export.
  Hard-won transport constraints baked into the helpers
  (WindowsSourceBuild.Common.psm1): cache mounts are NOT usable as the
  handoff channel (BuildKit clones them under lock — warm and materialize
  are not guaranteed the same instance; also directory RENAMES fail on
  them); call System32 tar/curl by full path (scoop-git's MSYS GNU tar
  resolves first and parses `C:\` as a hostname); pre-create every parent
  directory before extracting (bsdtar's long-path mode does not, and
  C:\runtime does not exist in a fresh materialize container); stage-local
  `ARG SCCACHE_WEBDAV_ENDPOINT` + ENV in every warm/materialize stage (ARGs
  do not cross FROM boundaries). ONNX/LiteRT keep their direct solves — they
  never trip the defect. Re-test the direct path after host OS or
  buildkitd/hcsshim upgrades: a 15-min tvm direct solve is the canary.
  Upstream issue: ready-to-file draft + preserved debug-log evidence in
  `docs/upstream/hcsshim-lost-shutdown-notification-issue.md` (+
  `containerd-debug-evidence-2026-08-04.log`).
- **Concurrent branch solves** (litert + tvm in parallel buildctl calls) —
  RAM-gated; both branches are memory-bound, so measure before enabling.
## The 125-layer budget (classic lane)

Docker's layer-chain depth is hard-capped at **125**; exceeding it fails with
`max depth exceeded` when the FIRST container of the next stage is created —
i.e. the failure lands one stage *after* the image that overspent. The classic
builder emits a layer **per instruction, metadata included** (28 separate `ENV`
lines in the merge Dockerfile cost 28 layers; consolidating them into one big
`ENV` took the merge builder from 114 → 86 layers on 2026-08-03, and the final
image from a 125 cap-hit to ~108).

Rules of thumb:

- One consolidated `ENV` per Dockerfile stage (same-instruction `${}` refs
  don't resolve — write derived paths as literals).
- Batch flat-file `COPY`s with multi-source form when the destination matches.
- After adding instructions anywhere in the chain, audit headroom:

  ```pwsh
  docker inspect <tag> --format '{{len .RootFS.Layers}}'   # per chain image
  ```

The BuildKit lane is far less exposed (metadata instructions are config-only
there), but the exported images still obey the cap when loaded into docker.

**Why `docker build` can't be fixed on this host.** The classic Windows builder
offers no working CPU lever, all verified with a ~6-second repro (a Dockerfile
that writes a dummy layer):

| Attempt | Result |
|---|---|
| `docker build --cpu-count N` | rejected — "unknown flag" |
| `docker build --cpuset-cpus 0-15` | build fails |
| `docker build --isolation process` | container sees all 32 CPUs **but cannot commit any layer** — `hcsshim::ActivateLayer failed 0x20 "file used by another process"`, even for a 100 MB dummy layer |

The `ActivateLayer` failure is **not** Windows Defender, Windows Search, or
SysMain — all were ruled out by disabling each and re-running the repro. It is a
container-filter / Docker-Engine level defect with process isolation on this
host, so `--isolation process` is unusable for building (every build dies at the
first commit). Hyper-V isolation commits reliably but is stuck at 2 CPUs. **Do
not add `--isolation process` to any `docker build`.**

**The run+commit path (how media-core gets its cores).** `docker run` — unlike
`docker build` — *does* honor `--cpu-count` under Hyper-V (verified: `docker run
--isolation hyperv --cpu-count 16` → `NUMBER_OF_PROCESSORS=16`), and a Hyper-V
container commits fine via `docker commit`. So `build.ps1` builds media-core as:

1. `docker build` a thin **builder image** (`Dockerfile.media-builder --target media-core`) —
   toolchain + all media-core scripts/patches, no heavy RUN, so its cheap COPY
   layers commit fine under Hyper-V.
2. `docker run --isolation hyperv --cpu-count $MediaCoreCpus --memory
   ${MediaMemoryGb}g <builder> pwsh -File build-media-core-all.ps1` — runs
   the whole ONNX → GenAI → OpenCV → FFmpeg chain in one container at the full
   CPU count. `Get-BuildJobCount` sees `--cpu-count` as `ProcessorCount`, so ONNX
   compiles at `min(cpu-count, memGB/4)` (e.g. `-j14` at `-MediaCoreCpus 16
   -MediaMemoryGb 56`).
3. `docker commit` the container to `local/kataglyphis:windows-media-core` — a
   drop-in replacement for the old `Dockerfile.media-core` output.

`Invoke-MediaBranchRunCommit` in `build.ps1` implements this via the generic
`Invoke-RunCommitStage` helper; tune it with `-MediaCoreCpus` (default: the host's
logical processor count, `[Environment]::ProcessorCount`) and `-MediaMemoryGb`
(default 0 = auto-detect from host RAM minus `-HostReserveGb`).

**Which stages use run+commit.** The same `Invoke-RunCommitStage` path is used for
every **CPU-bound** stage, so they all build at `-MediaCoreCpus` cores instead of
the 2-CPU `docker build` cap:

| Stage | Builder Dockerfile | Run step (the heavy compile) |
|-------|--------------------|------------------------------|
| toolchain | `Dockerfile.toolchain-builder` (clones CPython + writes props) | `build-toolchain-all.ps1` (`PCbuild\build.bat`) |
| media-core | `Dockerfile.media-builder --target media-core` | `build-media-core-all.ps1` (ONNX→GenAI→OpenCV→FFmpeg) |
| media-litert | `Dockerfile.media-builder --target media-litert` | `build-litert-all.ps1` (LiteRT→LiteRT-LM) |
| media-tvm | `Dockerfile.media-builder --target media-tvm` | `build-media-tvm-all.ps1` (TVM → IREE) |
| media merge | `Dockerfile.media-merge-builder` (fan-in `COPY --from` + env) | `build-gstreamer-from-source.ps1` |

The **merge stage splits**: the fan-in (`COPY --from` of the three branch trees)
*must* be a `docker build` because `docker run` can't `COPY --from`, but it is only
IO so 2 CPUs is fine; the CPU-bound GStreamer compile then runs via run+commit.
`docker commit` preserves the builder image's ENV, so each result image is a
drop-in replacement for the old single-Dockerfile output.

### RDNA4 dGPU layer-lock (A/B history and diagnostics)

**Diagnostic / partial-alternative on hosts where build-`COPY` is broken.**
Measured 2026-08-09 — root cause RESOLVED 2026-08-10: the ENABLED AMD RDNA4
dGPU locks fresh container layers (full A/B history + falsification list at
the end of this subsection — since 2026-08-24 THIS doc owns that story and
AGENTS.md's Common Failure Modes rows link here; build with the dGPU disabled
via `toggle-rdna4-gpu.ps1` — the earlier "Adrenaline reinstall fixes it,
GPU-disable does not" verdict is SUPERSEDED):
on a host where *every* `docker build`/`buildctl build` `COPY` commits fail
(`hcsshim::ActivateLayer 0x20` on buildkit, `mkdir \\?\Volume{<GUID>}\C:.` on the
docker legacy builder — while `FROM`+`RUN` layers commit fine), the **`CommitLayer`
path via `docker run` + `docker commit` still works** and is a 30-second probe:

```pwsh
docker run --name probe-rc mcr.microsoft.com/windows/servercore:ltsc2025 cmd /c echo hi
docker commit probe-rc local/test:probe-rc      # rc 0 = CommitLayer OK; only ApplyDiff (build COPY) is broken
docker rm -f probe-rc
```

Committed version of the build probe: `pwsh -File
windows\scripts\diagnostics\probe-build-copy.ps1 -Heavy` (assets in
`windows/scripts/diagnostics/probe-build-copy/`; only a `-Heavy`-green verdict counts
— the light lanes stay green on hosts whose heavyweight RUN-layer finalize is
broken).

So the classic lane's **CPU-bound run+commit stages remain viable** on such a host.
Caveat: the chain cannot bootstrap end-to-end there, because the FROM images
(base/sdk/merge fan-in) themselves contain `COPY` steps that still break — every
repo Dockerfile has at least one `COPY`. Use the healthiest host for a full chain;
the run+commit path only rescues the heavy compile stages once a starting image
exists.

**2026-08-09 follow-up (SUPERSEDED 2026-08-10 — kept as history; the same-boot
A/B proved the enabled RDNA4 dGPU is the holder and the "cures" below
coincided with patch/reboot changes):**
- A **faulty AMD Adrenaline installation** (GPU + chipset) was blamed for the
  general `0x20` family; **reinstalling Adrenaline** (not GPU-disable)
  appeared to fix it.
- The buildkit-snapshotter residual — "any layer writing into an existing
  parent dir" refused, identical on buildkit 0.32.0 and 0.32.2, on all
  snapshotter names (`windows`/`native`/`windows-uvm`; see the
  `[worker.containerd]` note in `windows/buildkitd.toml`) — was cleared by a
  **Windows in-place repair upgrade** (official ISO, same build, keep
  files+apps): after it every layer commits.
- Residual on that host: only the **final export** (reimport of the committed
  snapshot) still trips `0x20`, where the Defender engine (`MsMpEng`) is
  unkillable by design and the identical Stevedore+OS stack builds the BK lane
  fine on the working machine. ⇒ host-residual; use the classic lane there or
  the healthy host.

**The full A/B history and falsification list (moved here from AGENTS.md's
Common Failure Modes "AMD Radeon host" row on 2026-08-24 — this doc owns the
story now):**

- **2026-08-09 final verdict of that day (measured; superseded as a root-cause
  claim the next day, kept as history):** "the BK build lane is UNUSABLE ON
  THE DISCOVERED HOST" — the reimport/double-activation `0x20` persisted
  identically on buildkit 0.32.0 AND a throwaway v0.32.2 daemon (instrumented
  A/B, pristine Stevedore reinstall, every host lever tried incl. AMD
  GPU-disable + driver/chipset reinstall); read as host-level
  hcs/windows-snapshotter behavior, NOT engine/config/OS-version (the working
  machine is the same 26200 build). dockerd (classic lane) committed the same
  shapes fine there, and `nerdctl run` of pre-built images was unaffected.
  Practical note that survives: buildkit 0.32.x includes the upstream retry
  fix (#5885) — it does not help a persistently-held VHD. HVCI/Memory
  Integrity was falsified too (off + reboot + retest = identical `0x20`).
- **2026-08-10 morning: LIGHT-probe-green but NOT chain-green.** The fixed
  3-layer probe (now exporting `type=image,...,unpack=true`, the same output
  path as `build-buildkit.ps1`) passed commit + export + unpack — but the real
  chain's first COPY after the heavy pwsh-install RUN died deterministically
  (`ActivateLayer 0x20` at child finalize/reimport, FRESH snapshot IDs under
  `-NoCache` — not poisoned cache). This is why probe verdict discipline says
  only a `-Heavy`-green `probe-build-copy.ps1` verdict counts.
- **RESOLVED 2026-08-10 by same-boot A/B: the holder is the ENABLED RDNA4 dGPU
  itself (RX 9070 XT + Adrenalin), upstream docker/for-win#14977 (RDNA3.5/4,
  open).** Disable the dGPU → tiny AND heavy RUN-layer finalize green, first
  try; enable → red. Severity tracks the WINDOWS PATCH LEVEL: pre-KB5101684
  only heavyweight RUN layers tripped (light probes green — exactly why the
  host looked probe-healthy while the chain died); post-KB5101684 even
  10-byte RUN layers fail. COPY-only layers finalize fine either way (no
  container involved). The 2026-08-09 Adrenaline-reinstall and in-place-repair
  "fixes" above are SUPERSEDED as root-cause claims — each coincided with a
  patch-level/reboot change that moved the trigger threshold.
- **Falsified on the way (all still-red):** Defender (full exclusion set incl.
  the snapshotter root + `MsMpEng.exe`; realtime-off blocked by tamper
  protection), WSearch/SysMain, daemon bounces, vmcompute restart, non-core
  minifilter detaches (no third-party filters exist on C:), fresh IDs under
  `--no-cache`, settle delays, reboots, nanoserver base, split solves.
- **Failed finalizes additionally WEDGE hcs state until a REBOOT** (survives
  service bounces + vmcompute restarts; after one red finalize even tiny RUN
  finalizes fail). This cascade is what made every earlier session's A/Bs
  contradict each other — after ANY red finalize, REBOOT before further A/Bs;
  a wedged host falsifies every experiment.
- **Order of operations on any weird host:** (1)
  `windows\scripts\diagnostics\probe-build-copy.ps1 -Heavy` (the committed
  probe; only `-Heavy`-green counts), (2) RDNA4 dGPU present? elevated
  `toggle-rdna4-gpu.ps1 -Disable` → re-probe `-Heavy` → build → re-enable
  (display falls back to the iGPU; DirectML-on-host is unavailable during the
  window; `build-buildkit.ps1`'s `Assert-NoActiveRdna4Gpu` preflight enforces
  this — `-SkipHostChecks` overrides, and a verified-healthy host can bypass
  just this gate via `-SkipRdna4Gate`), (3) after ANY red finalize: REBOOT
  before further A/Bs.
- The docker-classic legacy builder's `COPY` defect on that host is presumably
  the same interaction (untested with the GPU off). And note the probe itself
  had two pwsh bugs masking all of this until 2026-08-10 (the ArgQuoting traps
  in AGENTS.md § Windows Build Invariants).

The `litert`/`tvm` aux branches **also** run+commit at `-MediaCoreCpus` cores (via
their `Dockerfile.media-builder` targets): media-core is already committed when they
run, so the whole CPU/RAM budget is free — e.g. `~j19` at 32 CPU / 39 g on this host
(still memory-bound per the note below). `base`/`sdk` are the only stages that never
exceed 2 CPUs — they're network/install-bound (no benefit from more).

> **NOTE — parallelism is memory-bound, not core-bound.** `Get-BuildJobCount =
> min(cpu-count, MEMORY_LIMIT_GB / per-job-GB)`. ONNX is ~4 GB/job, so at 48 GB it
> runs `~j12` whether you give it 16 or 32 cores; extra cores only speed the
> lighter TUs (FFmpeg, CPython, GStreamer). True `j32` on ONNX needs ~128 GB RAM,
> which this host does not have — so on the ONNX long pole, **RAM is the ceiling,
> not cores.**

**Trade-off:** a single `docker run` has no per-stage layer cache, so a mid-chain
failure used to re-run the whole chain (unlike a multi-`RUN` `docker build`, where
each completed step is cached). The persistent **sccache** remote (below) covers
recompilation, so in practice only uncached objects rebuild. Regression symptom
for the whole mechanism: `ninja -j2` in `out\windows-build-logs\media-core.log`,
or an `ActivateLayer` error on any commit.

**Resume after a mid-chain failure:** on a non-transient run failure, build.ps1
now PRESERVES the container (it holds every completed stage's output in
`C:\runtime`) and prints the recovery recipe:

```powershell
docker commit <container> <result-tag>-partial
docker container rm -f <container>
docker run --isolation hyperv --cpu-count <N> --memory <M>g --name <container> `
    <result-tag>-partial pwsh -NoProfile -ExecutionPolicy Bypass `
    -File C:\temp\scripts\<payload>.ps1 -ResumeFrom '<failed stage>'
docker commit <container> <result-tag> ; docker container rm -f <container>
```

`-ResumeFrom` (all three `build-*-all.ps1` payloads → `Invoke-SourceBuildChain
-StartAt`) skips the stages before the named one; an unknown name throws instead
of silently rebuilding from scratch. Pick the stage from the last
`=== <label> stage: ... ===` banner in the run log. Do NOT `docker start` the
failed container — that re-runs the original chain command from the beginning.

**Root cause (fully diagnosed).** The commit failure is the **`wcifs`** minifilter
(Windows Container Isolation FS) refusing to detach the process-isolation layer on
container teardown — dockerd's `panic.log` shows
`hcsshim::UnprepareLayer failed ... ERROR_FLT_DO_NOT_DETACH (0x801f0010)`, which
leaves the layer files locked so the subsequent commit's `ActivateLayer` fails
`0x20`. The trigger is an **OS-class mismatch**: the host is a Windows **client**
build (26200 / 25H2) but the only base image is Windows **Server** `servercore:ltsc2025`
(build 26100). A client-kernel `wcifs` will not detach a Server layer. This is
below Docker *and* below containerd — it reproduces identically for `docker build`,
`docker run`+`commit`, the containerd snapshotter, and `nerdctl commit`, on the
newest stack (Docker 29.5.3 / containerd 2.3.1 / hcsshim 1.2.1). It is **not**
contradicted by Microsoft's host≥image compatibility matrix: the matrix governs
whether the image can *run* under process isolation (it does — the `RUN` step
executes), not layer *commit/teardown*. The only real fixes are environmental:
build on a **matching build-26100 host** (Windows 11 24H2 or Windows Server 2025),
or wait for a Windows/hcsshim fix.

## Re-testing process isolation on new versions (is the bug gone yet?)

After **any** Docker Engine / containerd / hcsshim / Windows / base-image upgrade,
re-check whether `docker build --isolation process` can commit a layer again — if
it can, the *entire* Windows build (not just media-core) could run at full CPU
count and the run+commit workaround could be retired. A durable, self-contained
probe lives under `windows/scripts/diagnostics/`:

```pwsh
.\windows\scripts\diagnostics\test-process-isolation-commit.ps1
```

It records the current Docker/containerd/host build numbers, runs a `docker run
--isolation process` control (expected: PASS), then builds a tiny ~100 MB probe
layer with `docker build --isolation process` (`Dockerfile.isolation-probe`) and
prints a clear verdict:

- **`BUG GONE` (exit 0):** the commit succeeded — process isolation is usable for
  `docker build`. Follow the on-screen next steps (switch heavy stages to
  process isolation, re-run the full build to confirm parity, then retire
  `Invoke-RunCommitStage` and update this doc + the host-quirks notes).
- **`BUG PRESENT` (exit 1):** the known `wcifs`/`ActivateLayer 0x20` failure still
  occurs — keep the run+commit workaround.
- **exit 2:** the build failed with a *different* signature — investigate; do not
  assume it is fixed.

To test a hypothetical newer *matching-build* base image, pass `-Base <image>`.
Baseline history: Docker 29.5.3 / containerd 2.3.1 / host build 26200 with
`servercore:ltsc2025` measured **BUG PRESENT**; the 2026-08-21 re-probe (after a
Stevedore reinstall) measured **BUG GONE — process isolation commits fine**, which
is the current baseline AGENTS.md § Isolation policy operates on. Re-probe (delete
the probe cache first) rather than trusting either verdict after any Docker/
containerd/host update.

**The 2026-08-21 incident — how a broken PROBE manufactured a "host defect"
(the ProbeShell story; moved here from AGENTS.md § Isolation policy on
2026-08-24 — no other doc carried it before):** the probe's own
`Dockerfile.isolation-probe` set `SHELL ["pwsh", ...]` on the PUBLIC
`servercore` base — which ships Windows PowerShell 5.1 only — so every `RUN`
died with `hcs::System::CreateProcess ... The system cannot find the file
specified`, for a reason that had nothing to do with wcifs. The driver read
that manufactured verdict as a host defect and silently fell back to Hyper-V:
**2 CPUs on a 32-core host**, behind a warning that looked legitimate. After
the Dockerfile fix, the SAME host re-probed **BUG GONE — process isolation
commits fine** (the current baseline above). Regression guard:
`windows/scripts/tests/Dockerfile.ProbeShell.Tests.ps1` — no `pwsh` SHELL on a
public base before pwsh is installed; comments do not count as an install.

Two operational lessons from that incident:

- **`BUILD FAILED (exit 1) but NOT with the known signature -- investigate` in
  the probe log means the VERDICT IS WORTHLESS, not that the host is broken.**
  Trust the driver's Hyper-V-fallback warning only after reading the probe log
  (`out\windows-build-logs\isolation-probe.log`) — the probe distinguishes the
  known `wcifs`/`ActivateLayer 0x20` signature from every other failure
  exactly so that an unrelated breakage cannot masquerade as the known bug
  (the exit-2 verdict in the list above is the same rule seen from the exit
  code).
- **Force a re-probe by deleting the cached verdict.** The verdict is cached
  per host build + docker version in
  `out\windows-build-logs\isolation-probe-cache.json`; a stale (or
  manufactured) verdict lives there until the file is deleted. Recipe after
  any fix or doubt: delete the cache file, re-run the probe, read the log.

## Run-side wcifs symptoms (process isolation)

The same `wcifs` filter that breaks layer *commits* on this host/base skew also
breaks **runtime file operations inside image-layer directories** of
process-isolated containers (surfaced 2026-07 building
Kataglyphis-Inference-Engine inside the image):

- **Create-then-rename of fresh files fails `ERROR_PATH_NOT_FOUND`**
  (deterministic in hot paths). This breaks `git init/clone/checkout` (*"could
  not write config file"*, *"unable to write new index file"*) and Dart's
  `File.renameSync` (e.g. the sqlite3 package's native-asset hook).
- Plain **copies and tar extractions** in the same directories succeed.
- Directories **created fresh in the sandbox** (e.g. `C:\foo`) are unaffected.
- **Bind mounts avoid the layer FS but are NOT a full fix** (verified 2026-07-16):
  on mounted paths, plain writes and cmd `copy`/`ren` work, but **Dart's
  `copySync`/`renameSync` fail with errno 3** (`bindFlt` rejects the Dart
  runtime's two-path file operations on this skewed host). Consumer recipe:
  bind-mount the sources, then junction the Dart/Flutter write dirs
  (`.dart_tool`, `build`) from the mounted workspace to **container-local**
  dirs (`mklink /J`, run inside the container) — Dart ops work in fresh
  sandbox dirs. A **Dev Drive** source additionally needs the container filters
  allow-listed once (elevated), then a remount:
  `fsutil devdrv setFiltersAllowed /volume D: "bindFlt,wcifs"`. The filter list
  is ONE quoted argument — the unquoted `bindFlt, wcifs` form previously written
  here is parsed as two arguments and fails with a bare syntax dump, which is
  the very trap
  [`windows-container-build-performance.md`](windows-container-build-performance.md)
  § *Transport B* documents. That page owns the full setup, verification and
  revert steps (including the reboot and the "allowed vs attached" distinction);
  do not restate them.
- **The bind-mount target must NOT already exist in the image** (verified
  2026-07-16): `--mount target=C:\workspace` (a baked image dir) fails at
  container creation with `hcs::CreateComputeSystem ... Die Anforderung wird
  nicht unterstützt`, while the same source mounted to a fresh target
  (`target=C:\ws-mnt`) works. Version-matched CI runners mount over existing
  dirs fine — consider not pre-creating `C:\workspace` in the image, or adopt a
  fresh-target convention on skewed hosts.
- `docker cp` into a **running** Windows container silently copies nothing, and
  against a **stopped** container it triggers the ActivateLayer lock. Use
  `tar -cf - . | docker exec -i <container> tar -xf - -C <dir>` instead.

The run-side variant has its own "is the bug gone yet?" probe, mirroring the
commit-side one — re-run it after any Docker / containerd / hcsshim / Windows /
base-image upgrade:

```pwsh
.\windows\scripts\diagnostics\test-layer-rename.ps1
```

It renames files in a fresh sandbox dir (CONTROL, expected PASS) and in an
image-layer dir (`C:\Windows\Temp`; VERDICT, **expected FAIL today**) and prints
**BUG GONE** (exit 0) / **BUG PRESENT** (exit 1) / unexpected-signature (exit 2).
Pass `-Base <image>` to probe the built developer image's own layers.

---

## Driver behaviour and lane selection (from AGENTS.md)

The preflight gates, isolation policy, lane reality check and the classic
lane's run+commit path — the operational half an agent needs before launching
or debugging a chain.


**Fresh Windows machine?** The ordered host bring-up (Stevedore, CNI conf, debug flags, GC policy, Defender exclusions, dufs/sccache, gate tooling) is `docs/windows-host-setup.md` — follow it instead of reconstructing the sequence from the sections below. Once the interactive steps are done (Stevedore + reboot + docker-users + repo clone), the **scriptable half of bring-up is ONE elevated run**: `windows/scripts/host/setup-new-host.ps1` authors the CNI `.conflist` from the **live** `vEthernet (nat)` subnet (magic subnet literals are gone from the docs), derives the `.conf`, applies containerd config + GC policy + step-log env, builds+deploys the patched runhcs shim when missing (Go via scoop), and installs/starts/registers dufs + the machine `SCCACHE_WEBDAV_ENDPOINT`. Run `-ReportOnly` first; it is idempotent and refuses while a build is live.

All stages use **Ninja+clang-cl+lld-link** (not MSBuild/VS generator). The Windows container toolchain is **containerd + BuildKit + nerdctl** (preferred since 2026-08; full CPUs + real layer caching), with docker-classic run+commit as the always-working fallback. Role split — each tool where its pipe ACL allows:

| Task | Tool | Shell |
|---|---|---|
| Build the chain | `windows\build-buildkit.ps1` → `buildctl` (buildkitd pipe is docker-users) | non-admin |
| Inspect / run the `bk-*` images | `nerdctl --namespace buildkit` (containerd pipe is admin-only upstream — no `--group` option exists; never attempt pipe-ACL hacks) | **admin** |
| Publish via docker / classic-lane ops | Stevedore's `docker.exe` (`-FinalTar` bridges the containerd→docker store gap; registry push directly from the BK lane is available via `build-buildkit.ps1 -PushRef <ref>`, needs a prior `docker login`) | non-admin |

**Isolation policy: process isolation is always preferred** — build.ps1's `-Isolation auto` (default) runs the ~10s commit probe (`windows/scripts/diagnostics/test-process-isolation-commit.ps1`, verdict cached per host build + docker version) and uses `--isolation process` for every `docker build`/`docker run` when the host can commit process-isolated layers (full CPUs everywhere); it falls back to `hyperv` with a warning on wcifs-skew hosts. **TRUST THAT WARNING ONLY AFTER READING THE PROBE LOG** (`out\windows-build-logs\isolation-probe.log`): a probe log line `BUILD FAILED (exit 1) but NOT with the known signature -- investigate` means the verdict is worthless — the probe itself broke, not the host — and taking it at face value silently costs the full CPU count (the 2026-08-21 ProbeShell incident: `docs/windows-build-lanes.md` § Re-testing process isolation on new versions). A stale verdict lives in `out\windows-build-logs\isolation-probe-cache.json` — delete it to force a re-probe. **sccache is required by default for the media stages** (fail-fast when `-SccacheEndpoint`/`SCCACHE_WEBDAV_ENDPOINT` is missing or unreachable; `-NoSccache` overrides). The gate is media-only (`Assert-SccacheEndpoint`'s `$compileStages = @('media')` in `WindowsBuildDriver.Common.psm1`) — the toolchain stage (MSBuild/ClangCL CPython) has no sccache wiring, so toolchain-only builds are not blocked on an endpoint they never use. **AMD RDNA4-GPU hosts (RX 9xxx): the BK preflight also runs `Assert-NoActiveRdna4Gpu`** — an ENABLED RDNA4 dGPU makes every process-isolated RUN-layer finalize fail (`ActivateLayer 0x20`, docker/for-win#14977; A/B-proven 2026-08-10), so the chain builds with the dGPU disabled (`toggle-rdna4-gpu.ps1 -Disable` → build → re-enable; display falls back to the iGPU; the toggle resolves ALL RDNA4 hazard SKUs by default and takes `-NoPrompt` for automation). A verified-healthy host (green `probe-build-copy.ps1 -Heavy` with the dGPU enabled, e.g. after a driver fix) can bypass just this gate via `-SkipRdna4Gate` — unlike `-SkipHostChecks` it leaves the disk/shim gates armed. **The BK preflight also runs `Assert-BuildkitdStepLogEnv`**: it refuses to launch while the buildkitd service env lacks `BUILDKIT_STEP_LOG_MAX_SIZE=-1` (a Stevedore repair once wiped it and the 2 MiB step-log clip buried verdicts for a day — never swallow logs); fix elevated between runs via `setup-new-host.ps1` or the registry Multi-String + `Restart-Service buildkitd`; `-SkipStepLogGate` bypasses ONLY this gate for one launch when no admin is at hand (the 2 MiB clip then stays active — restore ASAP). Details + the wedge-cascade warning: [`failure-modes.md`](failure-modes.md) § "`hcsshim::ActivateLayer 0x20` on an AMD Radeon host".

**LANE REALITY CHECK (measured 2026-08-21, after a Stevedore reinstall — read this before choosing a lane):**
- **The classic lane can no longer build `base` — it is not a fallback any more**
  (twelve `windows/Dockerfile.*` use BuildKit-only `RUN --mount`; `build.ps1`
  never sets `DOCKER_BUILDKIT`). Use `build-buildkit.ps1`; reviving the classic
  lane is a deliberate decision — do not "just add `-SkipHostChecks`" →
  `docs/windows-host-setup.md` § Phase R.
- **The BK lane cannot bootstrap `base` from an EMPTY/damaged containerd content
  store** (`--opt image-resolve-mode=local` forbids fetching the public pinned
  base; repair is an admin re-seed pull) → `docs/windows-host-setup.md` § Phase R.
- **After a Stevedore REINSTALL the patched shim has NO local rollback** — the
  `.exe.orig` and every `.exe.bak-*` are stock too, so it must be REBUILT and
  re-deployed → `docs/windows-host-setup.md` § Phase R.
- **A reinstall also wipes the buildkitd service `Environment` and the dufs
  `dufs-sccache-l2` task plus its serve directory** — re-create the serve
  directory BEFORE running `setup-dufs-service.ps1` →
  `docs/windows-host-setup.md` § Phase R.

**BuildKit/containerd lane (PREFERRED, `windows/build-buildkit.ps1`):** the driver builds the same Dockerfiles via buildctl, selecting the `*-built` targets (toolchain-builder `built`, media-builder `media-<branch>-built`, merge-builder `built`) that run the heavy compile scripts as plain LAYERS — no run+commit, real per-stage caching; heavy-lane RUN steps bind-mount their script closures (per-file) instead of COPY. **MAINTENANCE: every Stevedore/containerd update overwrites the patched runhcs shim** — `Assert-ShimPatch` fails the BK lane's preflight on it, comparing the live binary's SHA256 against the hash `deploy-shim-patch.ps1` recorded at install time (`C:\ProgramData\kataglyphis\shim-patch.json`; the size table is only the fallback for hosts that never re-ran the deploy script). Check with `deploy-shim-patch.ps1 -ReportOnly`, re-deploy, and re-run one OPENCV canary after any update. Rollback path if it ever 0x3s again: warm/materialize from git history (`c9586c1^`), payload scripts still in tree. The Defender exclusions stay — they cure the hcs-temp FLAKE family (they were never the 0x3 root cause). Lane history, the shim root cause and all measurements: `docs/windows-build-lanes.md` § BuildKit/containerd lane. **Getting it going (one-time setup + launch): see `docs/windows-build-lanes.md` § BuildKit/containerd lane.** Requirements: buildkitd service (docker-users group) + `C:\Program Files\containerd\cni\conf\0-containerd-nat.conf` (without it RUN steps have no network) — and the conf's `ipam.subnet` MUST match the live `vEthernet (nat)` adapter: dockerd restarts recreate the nat HNS network on a new subnet and silently orphan the conf. `build-buildkit.ps1` fail-fasts on that drift with the exact fix. Gotchas: results live in the CONTAINERD store as `docker.io/local/kataglyphis:bk-*` (fully-qualified on purpose — buildkit normalizes FROM refs to docker.io/ and stage handoff needs `--opt image-resolve-mode=local` to match); they are INVISIBLE to docker (separate windowsfilter store) — export with `-FinalTar`, or push straight from the lane with `-PushRef` (needs a prior `docker login`). The classic lane is unaffected: build.ps1 pins `--target builder`/`--target merge` so docker never executes the `built` stages.

The paragraph below describes the docker-classic HYPERV fallback state:

**`docker build` is capped at 2 CPUs on this host — the heavy media-core stage builds via `docker run --cpu-count N` + `docker commit` instead.** Hyper-V-isolated build containers get only **2 logical CPUs**, and `docker build` has **no working lever** to raise it: `--cpu-count` is rejected, `--cpuset-cpus` fails the build, and `--isolation process` exposes all CPUs but **cannot commit any layer** here (`hcsshim::ActivateLayer 0x20`). `docker run`, however, **does** honor `--cpu-count` under Hyper-V and commits fine — so `build.ps1` builds every **CPU-bound** stage via a generic run+commit path (`Invoke-RunCommitStage`): **media-core** (`Dockerfile.media-builder --target media-core` + `build-media-core-all.ps1`), **toolchain**/CPython (`Dockerfile.toolchain-builder` + `build-toolchain-all.ps1`), and the **media merge / GStreamer** stage (`Dockerfile.media-merge-builder` + `build-gstreamer-from-source.ps1`; the fan-in `COPY --from` stays a `docker build` since `docker run` can't `COPY --from`, but the GStreamer compile runs+commits). `-MediaCoreCpus` defaults to `[Environment]::ProcessorCount` — but parallelism is **memory-bound**: `Get-BuildJobCount = min(cpu-count, memGB/perJob)` regardless of cores, and the defaults ARE the max (worked numbers: `docs/windows-build-resources.md` § Maximum resource envelope). `base`/`sdk` stay at 2 CPUs by design (network/install-bound). The `litert`/`tvm` aux branches also run+commit at `-MediaCoreCpus` (`Dockerfile.media-builder --target media-litert` + `build-litert-all.ps1`; `--target media-tvm` + `build-media-tvm-all.ps1`, the TVM → IREE chain) — media-core is already committed then, so the full CPU/RAM budget is free (still memory-bound). All three branch builders are targets of the ONE consolidated `Dockerfile.media-builder`, and the schedule is strictly sequential (a former `-ConcurrentMedia` overlap mode was removed — overlapping starved the media-core long pole).

**Mid-chain failure recovery (run+commit):** a non-transient failure inside a
run+commit stage now PRESERVES the container (only transient retries clean it
up) and prints a resume recipe: `docker commit <container> <tag>-partial`, then
re-run the payload from the partial image with `-ResumeFrom '<stage>'`
(`Invoke-SourceBuildChain -StartAt` skips the completed stages), then commit to
the real tag. Do NOT `docker start` the failed container — that re-runs the
whole chain from scratch.

**Determinism:** the final stage uses the versions.env `APP_REF` pin by
default; pass `-LatestApp` to build.ps1 to resolve the app repo's newest
release tag at build time (the old always-on behavior). All local intermediate
tags come from the `$script:ImageTag` table / `Get-MediaBranchTag` at the top
of build.ps1 — never type a `local/kataglyphis:windows-*` literal elsewhere.

**Orchestr-ANT-ion app stage (`windows/Dockerfile.torch`):** the Windows mirror
of `linux/Dockerfile.torch`, a real chain stage between media and final
(`media -> torch -> final`): it assembles the app env at `APP_REF` on the
windows-media image (tag `local/kataglyphis:windows-torch`, app-venv
healthcheck), and `windows/Dockerfile` (final) builds FROM it — the assembly
logic lives in exactly one place. App-only iteration:
`.\windows\build.ps1 -Stages torch,final` (minutes, never a compile-chain
rebuild); `-TorchBaseImage ghcr.io/...:winamd64` iterates on the published
image on hosts without local chain images.

See `docs/windows-builds.md` § Build Commands for the full Windows build sequence (base → [nvidia/sdk] → toolchain → media → torch → final) and `docs/windows-stevedore-and-docker.md` § Stevedore Setup Fixes for post-install fixes.
