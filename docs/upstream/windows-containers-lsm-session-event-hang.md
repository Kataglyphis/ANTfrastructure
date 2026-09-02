<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Upstream issue draft — file at microsoft/Windows-Containers

Ready-to-file text for the container **boot** hang.

File as a NEW issue. Do **not** frame it as re-opening
[#547](https://github.com/microsoft/Windows-Containers/issues/547) — its own
reporter closed it on 2024-12-20 because it stopped reproducing for him, and he
had narrowed it to the IIS image. The live neighbour is
[hcsshim#2566](https://github.com/microsoft/hcsshim/issues/2566) (open,
unanswered, same 26200-host / ltsc2025-image pairing, different symptom); a
short comment there pointing at the new issue is worth more than a comment on
547. Upstream state verified 2026-09-02.

Companion drafts: [`hcsshim-lost-shutdown-notification-issue.md`](hcsshim-lost-shutdown-notification-issue.md)
(the teardown half, not yet filed) and `../../windows/upstream/hcsshim-teardown-timeout/`
(the shim-timeout PR this project runs on, filed as hcsshim#2855).

**Everything below the line is the issue text. Do not paste this header.**

---

## Title

Process-isolated ltsc2025 containers: LSM service start deadlocks in
`CEventDispatcher::WaitForSessionState` on an event that is never signalled

## TL;DR

Process-isolated `servercore:ltsc2025` containers on this Windows 11 26200 host
deadlock for ~141 s at service start. LSM blocks in
`CEventDispatcher::WaitForSessionState` on an auto-reset event that is never
set. Two dumps 30 s apart hold a byte-identical stack at 0.000 s thread CPU —
captured, not inferred.

The same build step, unchanged, across the transition:

| when | identical `RUN` step |
|---|---|
| 2026-08-30 17:29 | 3.441 s |
| 2026-08-31 04:32 | 4.521 s |
| 2026-09-01 11:36 | **144.7 s** |
| 2026-09-01 19:38 | **143.7 s** |
| 2026-09-02 00:24 | **143.9 s** |

- Requires ltsc2025 **and** process isolation **and** the servercore service
  set. Same host, same day: ltsc2022 process-isolated 1.8 s, ltsc2025 under
  Hyper-V 3.5 s, nanoserver ~2 s.
- A **second, older** defect on this host loses the container exit
  notification, so teardown runs to its timeout. On record here since
  2026-08-04 and filed as
  [hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855) on 2026-08-06.
  It escalated from filesystem-heavy containers to *every* container at the
  same time the start deadlock appeared. With the stock 30 s timeout the
  teardown is truncated and the scratch layer is corrupted
  (`hcsshim::ExportLayer 0x3`); with it raised, a trivial step costs 441 s.
- Full user-mode dumps of the deadlock available on request. Single host — no
  second machine here.

## Symptom

- SCM logs `7022 The LSM service hung on starting` at 140.07 s. LSM = Local
  Session Manager.
- LSM stays `START_PENDING` for the container's life, reporting
  `NOT_STOPPABLE, IGNORES_SHUTDOWN`. Of 121 services it is the only one neither
  RUNNING nor STOPPED.
- Boot continues once SCM times LSM out.
- The command itself then runs correctly; its output appears in `docker logs`.

Two independent measurements bracket the stall, and they agree:

| | |
|---|---|
| SCM `7022` timeout, in-container event log | 140.07 s |
| step start → container's first output (3 runs) | 143.7 / 143.9 / 144.7 s |
| same step, same command, before the regression | 4.521 s |

144.7 − 140.07 ≈ 4.6 s, which is the healthy 4.5 s. **The LSM timeout accounts
for the entire regression** — nothing else in the boot got slower. "~141 s"
below refers to that timeout.

## Wait stack

Two full user-mode dumps of the silo's `svchost.exe -k DcomLaunch -p`, 30 s
apart, byte-identical, waiting thread at 0.000 s user time:

```
ntdll!NtWaitForSingleObject+0x14
KERNELBASE!WaitForSingleObjectEx+0xaf
lsm!CEventDispatcher::CEventListEntry::WaitForSessionEvent+0x1e
lsm!CEventDispatcher::WaitForSessionState+0x285
lsm!CService::Start+0x8e6
lsm!ServiceMain+0xbd
svchost!ServiceStarter+0x3cd
sechost!ScSvcctrlThreadA+0x27
```

Reproduces on every container instance examined.

## The waited object

From a separate live attach (handle data is absent from the dumps), read from
**R10** of the thread whose stack shows `lsm!CService::Start` — the x64 syscall
stub does `mov r10,rcx`, so R10 still holds argument 1:

```
process           svchost.exe   (silo, pid 15900, thread 6)
waited handle     0x338
kernel object     0xffffe0831a1b57e0
  Type            Event
  Event Type      Auto Reset
  Event is        Waiting        <- for the container's whole life
  HandleCount     2
  PointerCount    65537
```

`NtQuerySystemInformation(SystemExtendedHandleInformation)` matched on that
object pointer attributes exactly one handle to any process: LSM itself. The
enumeration does see silo processes — it found LSM's handle that way.

Limits of that measurement: `HandleCount` is 2 and the enumeration accounts for
one. The second handle was not identified (LSM holding it twice is the simple
explanation, unproven). So no *other process* held a handle at snapshot time;
this does not prove nothing else can signal the event.

If you reproduce this: do not read the first `KERNELBASE!WaitForSingleObjectEx`
in the process — every service process has one, the SCM dispatcher's idle wait
in `sechost!ScDispatcherLoop`, and it names a different object. `kb` arg columns
are home-space reconstructions and are unreliable here. Bind the frame to the
thread, then read R10.

## Controls

Same machine, same runtime, same day, same `RUN echo` step:

| Configuration | Startup stall | Total step |
|---|---|---|
| `servercore:ltsc2025`, **process** isolation | **~141 s** | **441.3 s** |
| `servercore:ltsc2022`, process isolation | none | 1.8 s |
| `servercore:ltsc2025`, **Hyper-V** isolation | none | 3.5 s |
| `nanoserver:ltsc2025`, process isolation | none | ~2 s |

Startup stall is the defect; the 441.3 s total also contains the 300 s teardown
timeout, which only the failing row reaches.

The stall requires ltsc2025 **and** process isolation **and** the servercore
service set together. ltsc2022 — older user-mode on the identical 26200 kernel —
is unaffected, so process isolation as such is not broken here. Hyper-V gives
the image its own matching kernel. nanoserver has no LSM.

Hyper-V is a control, not a workaround: BuildKit 0.32 has no per-step isolation
option, and Hyper-V containers here are limited to a small fixed CPU count.

## Falsified

Each with an explicit experiment:

- **Host session broker** — host LSM measured idle and ~20 s into a stall does
  nothing in between; the only differing frame is a COM GC worker, and no thread
  enters `ContainerSessionServer::AskForSession`. The container-side stack has
  zero RPC frames (`rpcrt4`, `ContainerSessionClient`, `AskForSession`). The
  container's LSM is blocked in its own dispatcher, not on the host.
- **Something upstream in the silo boot** — `smss`, `csrss`, `wininit` and
  `services` are PPL and refuse a read-only attach (`Win32 error 0n5`). Their
  descendants are reachable and idle-healthy during the stall: `lsass` in
  `lsasrv!ServiceDispatcherThread`, RPCSS in `rpcss!CTime::Sleep`,
  `fontdrvhost` in `fontdrvhost!ServerRequestLoop` — frames reached only after
  their parents completed. With 120 of 121 services settled, the silo boots
  normally around LSM.
- **Windows Defender** — reproduces with RTP off; platform 4.18.26070.9
  unchanged on disk since 2026-08-05; engine version constant across the working
  and failing periods.
- **Container networking** — CNI ADD succeeds with matching IP and gateway;
  `--network none` stalls identically.
- **Windows Update inside the container** — image committed with `wuauserv` and
  `UsoSvc` at `Start=4` stalls identically.
- **Disabling LSM** — image committed with `LSM Start=4` (verified with `sc qc`)
  removes the startup stall but keeps the teardown symptom.
- **Disk** — 515 GB free; `disk` event 51 appears only on *successful*
  teardowns.
- **VBS/HVCI, hypervisor scheduler type, boot type** — identical at the last
  working boot and every failing one.
- **New KB or driver** — the Setup event log has zero entries between
  2026-08-28 and 2026-09-01, and every driver binary predates the last healthy
  build. The one change to this build chain in that period — a base-image
  digest and three toolchain pins on 2026-08-26 — is bounded out under Onset.
- **GPU** — discrete GPU disabled (`CM_PROB_DISABLED`) throughout.

## Environment

| | |
|---|---|
| Host | Windows 11 Pro 25H2, build **10.0.26200.9278**, AMD Ryzen 9 9950X |
| Image | `mcr.microsoft.com/windows/servercore:ltsc2025`, digest `sha256:eeaa17aefe5d949f03b1db17182f5855cf40e757533468cf5b50e07c7c385ada` |
| Image user-mode build | **10.0.26100.9278** — from the dump: silo `lsm.dll`, `ntdll.dll`, `KERNELBASE.dll` |
| Isolation | process |
| Runtimes | reproduces through containerd 2.3.3 + BuildKit 0.32.2 **and** dockerd 29.7.2 |

Supported per the
[version-compatibility documentation](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility):
the Windows 11 client table marks Windows Server 2025 base images as supported
in process isolation from Windows 11 24H2 onwards.

This host runs a locally patched `containerd-shim-runhcs-v1` making hcsshim's
hard-coded 30 s teardown timeout configurable
([microsoft/hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855)), set
to 5 min. It affects only the teardown wait — the 300 s above. The ~141 s
startup stall, the wait stack and every control are independent of it, and the
stall reproduces through stock dockerd with no patched shim involved.

## Reproduction

```pwsh
docker run --rm --isolation=process mcr.microsoft.com/windows/servercore:ltsc2025 cmd /c echo hi
```

## Onset

The two symptoms have different histories.

**The lost exit notification is not new.** It has been recorded on this host
since 2026-08-04, root-caused to host-side silo teardown on 2026-08-06 against
a measured 117 s worst case, and mitigated since then by a locally patched shim
raising `tearDownTimeout` from 30 s — filed upstream the same day as
hcsshim#2855. Through 2026-08-30 it tripped only on filesystem-heavy containers
(OpenCV, ONNX Runtime GenAI, TVM, GStreamer); trivial containers did not. The
mitigation was not continuous: Stevedore/containerd updates silently restore
the stock binary, and it was re-deployed on 2026-08-09, 2026-08-21 and
2026-08-28.

**The service-start deadlock is new.** No LSM stall is recorded on this host
before 2026-09-01; the dumps above are from 2026-09-02.

**What changed around 2026-08-31.** The teardown timeout began firing on every
container including `RUN echo` — a change of scope, not a first occurrence —
and container start acquired the ~141 s floor. The identical build step
measured 3.441 s (2026-08-30 17:29) and 4.521 s (2026-08-31 04:32), then
144.7 s (2026-09-01 11:36), 143.7 s and 143.9 s.

**Bounds, and what is ruled out.** A reboot at 2026-08-31 15:12:59 sits inside
the transition, but nothing was measured between 04:46:06 and 15:19:18 that
day, so the artifacts bound the change to that ~10.5 h window rather than
isolating the reboot as its trigger. The Setup event log has zero entries
between 2026-08-28 and 2026-09-01.

The last change to this build chain was 2026-08-26: the base image digest moved
`d5bbb830` → `eeaa17ae` (the digest in the Environment table above) along with
three toolchain pins. That is **not** the trigger — the chain rebuilt and ran on
`eeaa17ae` through 2026-08-31 03:23, and the 4.521 s healthy measurement above
is from that image at 04:32, five days after the bump.

What changed remains unidentified.

## Teardown half

After the entrypoint exits — output present in `docker logs`, `docker top`
showing the process gone — the container stays `Running` until force-stopped;
the runtime waits for a shutdown notification that never arrives. `docker stop`
force-terminates in 91 s. Same shape as #547.

Shared root cause is unproven: disabling LSM does not fix the teardown. Both are
silo lifecycle transitions that fail to signal.

This half drives the wall-clock cost, since a build runtime pays it per step.
Measured on the same `RUN echo`: **2841.2 s** at a 45 min timeout, **441.3 s** at
5 min. hcsshim#2855 makes that wait configurable; it does not address why the
notification is lost.

## Related reports

- [Windows-Containers#547](https://github.com/microsoft/Windows-Containers/issues/547)
  — same shape of teardown symptom, but not an unresolved case. Its reporter
  closed it on 2024-12-20 after it stopped reproducing on Docker Desktop 4.37.0;
  a Microsoft engineer could not reproduce it on `10.0.26100.2605`; it had been
  narrowed to the **IIS** image. This report is base `servercore`, no IIS,
  current runtimes, with a wait stack.
- [hcsshim#2566](https://github.com/microsoft/hcsshim/issues/2566) — open and
  unanswered. Different symptom (`PrepareLayer` fails `0xc0370112`; Hyper-V
  fails there too, unlike here), same pairing: Windows 11 25H2 / 26200 host,
  ltsc2025 / 26100 image, with "LTSC 2022 works fine" as the reporter's
  workaround — the same discriminator, on another machine.

Neither repository has an existing issue mentioning LSM or `WaitForSessionState`.

## Artifacts and limitations

Observed on **one host only**; no second Windows machine is available here. The
evidence is a captured deadlock rather than a timing anomaly: two dumps 30 s
apart, byte-identical stack, 0.000 s thread CPU.

Available on request: two full user-mode dumps of the silo's
`svchost.exe -k DcomLaunch` taken 30 s apart during the hang (~30 MB each), and
the `cdb` transcripts behind every number above. The state is reproducible on
demand in about three minutes, so further commands can be run inside the hang.

If reproduction fails on a build-matched host, please ask for the dumps rather
than closing.

## Reproducing the diagnosis

Open source; needs an elevated shell and the WinDbg package (`cdb.exe` ships in
it):

- [`capture-lsm-waitstack.ps1`](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/blob/main/windows/scripts/diagnostics/capture-lsm-waitstack.ps1)
  — dumps the silo's svchosts twice, 30 s apart.
- [`find-lsm-event-holder.ps1`](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/blob/main/windows/scripts/diagnostics/find-lsm-event-holder.ps1)
  — starts its own container, attaches non-invasively during the hang, resolves
  the waited object and its holders.

Two traps: silo processes report empty `Win32_Process.ExecutablePath` and
`.CommandLine` even to an elevated caller, so the silo must be found through the
process tree (fresh `wininit.exe` → its `services.exe` → their `svchost`s); and
dumps written by an elevated collector are SYSTEM-owned, so grant read access
before analysing them unelevated.

## What would help

1. **Symbolicate the wait.** With private symbols for `lsm.dll`
   `10.0.26100.9278`, `lsm!CEventDispatcher::WaitForSessionState+0x285` should
   name the awaited session-state transition.
2. **Name the signaller.** What sets that event inside a silo, and when does it
   not run? No other process held a handle at snapshot time, which points at
   another thread in the same `svchost` or the kernel's session path — an
   inference from one snapshot, not a measurement.
3. **Confirm whether the build pairing below is expected to work.**

In process isolation the user-mode binaries come from the image and the kernel
from the host, so the deadlock sits across:

| | build |
|---|---|
| blocked `lsm.dll` (from the image) | `10.0.26100.9278` |
| `ntdll.dll` / `KERNELBASE.dll`, same silo | `10.0.26100.9278` |
| host kernel and session components | `10.0.26200.9278` |

A 26100 user-mode session stack on a 26200 kernel — same revision, different
base build. Documented as supported, and this exact pairing ran at ~4.5 s per
container here until 2026-08-31. Offered as a lead because the two
configurations that remove the
stall are exactly the two that remove this pairing: ltsc2022 replaces the
user-mode side, Hyper-V supplies a matching kernel. If recent servicing changed
a session-notification contract on the 26200 side, a 26100 `lsm.dll` waiting on
a state now reached differently would present exactly this way.

Untested here — it needs private symbols or a second machine.
