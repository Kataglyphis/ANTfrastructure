<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Upstream issue draft — file at microsoft/Windows-Containers

Ready-to-file text for the container **boot** hang, with the wait-stack that
[#547](https://github.com/microsoft/Windows-Containers/issues/547) was missing.
File as a NEW issue (547 is closed) and cross-link it; also comment on 547 so
its reporter and watchers see it.

Companion drafts: [`hcsshim-lost-shutdown-notification-issue.md`](hcsshim-lost-shutdown-notification-issue.md)
(the teardown half) and `../../windows/upstream/hcsshim-teardown-timeout/`
(the shim-timeout PR this project runs on).

**Everything below the line is the issue text. Do not paste this header.**

---

## Title

Process-isolated ltsc2025 containers: LSM service start deadlocks in
`CEventDispatcher::WaitForSessionState` on an event that is never signalled

## What this costs

A container-based build toolchain on this host went from **~8 seconds per
build step to ~47 minutes per build step**, overnight, with no change to the
images or the toolchain. Every process-isolated `servercore:ltsc2025` container
now spends ~141 s stuck during startup, and then does not exit on its own when
its command finishes.

## Expected vs actual

**Expected:** `docker run --isolation=process servercore:ltsc2025 cmd /c echo hi`
starts, prints, and exits in a few seconds — as it did on this machine until
2026-08-31, and as it still does under Hyper-V isolation today.

**Actual:** the container takes ~141 s to reach the point where it can run the
command, and afterwards stays `Running` until it is force-stopped.

## Symptom

The startup stall is a **service-start deadlock**, not slow progress. Inside
the container:

- SCM logs `7022 The LSM service hung on starting` — LSM is the **Local Session
  Manager**, the service that tracks session state
- LSM then stays `START_PENDING` for the container's entire life. A scan of all
  121 services finds it as the **only** one that is neither RUNNING nor
  STOPPED; it reports `NOT_STOPPABLE, IGNORES_SHUTDOWN`
- the rest of the boot continues once SCM times LSM out — which is where the
  ~141 s goes

The same host runs `nanoserver:ltsc2025` and **Hyper-V-isolated** ltsc2025
containers with no stall at all, so this is specific to the process-isolation
silo (the shared-kernel container object; Hyper-V isolation runs its own
kernel in a utility VM and is unaffected).

## The wait

Two full memory dumps of the silo's `svchost.exe -k DcomLaunch -p`, taken
**30 s apart**, carry a **byte-identical** stack, and the waiting thread
reports **0.000 s user time**. This is a fully static wait — nothing is
progressing slowly:

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

The stack reproduces on every container instance we looked at.

## The object being waited on

A separate run, with a live non-invasive attach during the hang, resolves the
object. All values below are from that **one** container instance (handle
values differ per instance; the shape does not):

```
process           svchost.exe -k DcomLaunch -p   (pid 32204)
waited handle     0xe0
kernel object     0xffffe083b49d9d60
  Type            Event
  Event Type      Auto Reset
  Event is        Waiting        <- never signalled, for the container's whole life
  HandleCount     2
  PointerCount    65530
```

`HandleCount` reads 2, so we checked who else holds it: a system-wide handle
enumeration (`NtQuerySystemInformation(SystemExtendedHandleInformation)`),
matched on the kernel object pointer, finds **exactly one holder in the same
run — LSM itself**. The enumeration does see silo processes; it found LSM's own
handle that way. So the second reference is kernel-side accounting, not another
process.

**That is the useful part of this report:** since no other process holds a
handle to this event, whatever should signal it is either another thread inside
the same `svchost` or the kernel's own session path. It cannot be a service
that failed to start.

Two smaller notes: frame arguments suggest the awaited state is `4`
(`WaitForSessionState`'s second argument) — heuristic, not verified. And
handles inside a silo resolve as `Name <none>` from outside, so the event
cannot be named from user mode; the `lsm!CEventDispatcher` frames are the
precise pointer into your code instead.

## Environment

| | |
|---|---|
| Host | Windows 11 Pro 25H2, build 26200.9278, AMD Ryzen 9 9950X |
| Container image | `mcr.microsoft.com/windows/servercore:ltsc2025` (digest-pinned) |
| Isolation | process (Hyper-V isolation unaffected) |
| Runtimes | reproduces through **both** containerd 2.3.3 + BuildKit 0.32.2 **and** dockerd 29.7.2 |

Host and image are a supported combination per the version-compatibility
documentation (Win11 24H2+ with ltsc2025 in process isolation). Reproducing
through two independent runtimes places the defect below both of them.

## Reproduction

```pwsh
docker run --rm --isolation=process mcr.microsoft.com/windows/servercore:ltsc2025 cmd /c echo hi
```

The command itself runs correctly — its output appears — but the start costs
~141 s and the container does not exit afterwards (see "The teardown half").

## When it started

Until a reboot at **2026-08-31 15:12:59** this host started these containers in
~8 s total. Every boot since reproduces the stall, and further reboots do not
clear it. **Nothing was installed at that boot**: the Setup event log has zero
entries between 2026-08-28 and 2026-09-01. We have not been able to identify
what changed.

## What is NOT the cause

Each ruled out with an explicit experiment, so nobody has to repeat them:

- **Windows Defender** — reproduces with real-time protection OFF; platform
  4.18.26070.9 unchanged on disk since 2026-08-05; engine version constant
  across the working and the failing period.
- **Container networking** — CNI ADD succeeds with matching IP and gateway, and
  `--network none` stalls identically.
- **Windows Update inside the container** — an image committed with `wuauserv`
  and `UsoSvc` set to `Start=4` stalls identically.
- **Disabling LSM itself** — an image committed with `LSM Start=4` (verified
  with `sc qc`, not just `reg query`) removes the startup stall but still shows
  the teardown symptom below, so LSM is not the whole story.
- **Disk** — 515 GB free; the `disk` event 51 we do see appears only on
  *successful* teardowns.
- **VBS/HVCI, hypervisor scheduler type, boot type** — identical at the last
  working boot and at every failing one.
- **A new KB or driver** — none installed on the onset day; all driver binaries
  date to a cumulative update that predates the last working build.
- **GPU** — the discrete GPU is disabled (`CM_PROB_DISABLED`) throughout.

## The teardown half

The same host also shows the symptom [#547](https://github.com/microsoft/Windows-Containers/issues/547)
reported and that was closed unresolved: after the container's entrypoint exits
— its output is in `docker logs`, and `docker top` shows the process is gone —
the container stays `Running` until force-stopped, because the runtime waits
for a shutdown notification that never arrives. `docker stop` force-terminates
it in 91 s.

Whether the two halves share one root cause is **unproven**: disabling LSM does
not fix the teardown. But both are silo lifecycle transitions that fail to
signal, so they may well be one defect.

This half is what makes the cost above so extreme, because a build runtime
waits out its whole teardown timeout on every step. With the stock 30 s
hcsshim timeout, that truncation permanently corrupts the scratch layer
(`hcsshim::ExportLayer 0x3`); with the timeout raised, every step pays it in
full. Measured on the same trivial `RUN echo` step: **2841.2 s** with a 45 min
timeout, **441.3 s** with a 5 min one — the same static wait, priced
differently.

## Reproducing the diagnosis

These scripts are open source and need only an elevated shell plus the WinDbg
package (`cdb.exe` ships inside it):

- [`capture-lsm-waitstack.ps1`](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/blob/main/windows/scripts/diagnostics/capture-lsm-waitstack.ps1)
  — dumps the silo's first svchosts twice, 30 s apart: the static-wait proof.
- [`find-lsm-event-holder.ps1`](https://github.com/Kataglyphis/Kataglyphis-ContainerHub/blob/main/windows/scripts/diagnostics/find-lsm-event-holder.ps1)
  — starts its own container, attaches non-invasively during the hang, and
  resolves the waited object and every holder of it.

Two traps worth knowing if you write your own: silo processes report **empty**
`Win32_Process.ExecutablePath` and `.CommandLine` even to an elevated caller,
so the silo has to be found through the process tree (a fresh `wininit.exe` →
its `services.exe` → their `svchost`s); and dumps written by an elevated
collector are SYSTEM-owned, so grant read access before analysing them
unelevated.

## What would help

With private symbols, the `lsm!CEventDispatcher::WaitForSessionState` path
should show which session-state transition is awaited and what is supposed to
set that event inside a silo. Given that no other process holds a handle to it,
the question we cannot answer from outside is: which in-process thread or
kernel session path signals it normally, and why does that never happen in a
silo — while the identical image and command complete in seconds under Hyper-V
isolation on the same machine?
