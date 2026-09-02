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

---

## Title

Process-isolated ltsc2025 containers: LSM service start deadlocks in
`CEventDispatcher::WaitForSessionState` on an unsignalled session event

## Summary

On a Windows 11 25H2 host, **every** process-isolated `servercore:ltsc2025`
container stalls ~141 s during boot. The stall is a service-start deadlock in
LSM, not slow progress:

- inside the container, SCM logs `7022 The LSM service hung on starting`
- LSM then stays `START_PENDING` for the container's whole life — a scan of all
  121 services finds it as the **only** one not RUNNING or STOPPED, reported
  `NOT_STOPPABLE, IGNORES_SHUTDOWN`
- the rest of the boot proceeds after SCM times it out

The same host runs `nanoserver:ltsc2025` and **Hyper-V-isolated** ltsc2025
containers with no stall, so this is specific to the process-isolation silo.

## The wait

Two full dumps of the silo's `svchost.exe -k DcomLaunch -p`, taken **30 s
apart**, carry a byte-identical stack, and the thread reports **0.000 s user
time** — a completely static wait:

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

A live (non-invasive) attach during the hang adds the object. The handle
argument recovered from the frame is `0x338`, and that object is:

```
Handle 338
  Type              Event
  GrantedAccess     0x1f0003 (QueryState, ModifyState, Synch, ...)
  HandleCount       2
  PointerCount      65537
  Name              <none>
  Event Type        Auto Reset
  Event is          Waiting          <- never signalled
```

Two facts worth the reader's attention: the event is **unsignalled** for the
container's whole lifetime, and its **HandleCount is 2** — a second holder
exists, i.e. the component expected to signal it is present and simply never
does. Frame arguments also suggest the awaited state is `4`
(`WaitForSessionState`'s second argument) — heuristic, not verified.

Handles inside the silo resolve as `Name <none>` from outside, so the event
cannot be named from user mode; the `lsm!CEventDispatcher` frames are the
precise pointer into your code.

## Environment

| | |
|---|---|
| Host | Windows 11 Pro 25H2, build 26200.9278, AMD Ryzen 9 9950X |
| Container image | `mcr.microsoft.com/windows/servercore:ltsc2025` (digest-pinned) |
| Isolation | process (Hyper-V isolation unaffected) |
| Runtimes | reproduces through **both** containerd 2.3.3 + BuildKit 0.32.2 **and** dockerd 29.7.2 |

Host/image combination is supported per the version-compatibility docs
(Win11 24H2+ with ltsc2025 in process isolation).

## Reproduction

```pwsh
docker run --rm --isolation=process mcr.microsoft.com/windows/servercore:ltsc2025 cmd /c echo hi
```

The command runs (its output appears), but the container start costs ~141 s and
the container then does not exit on its own — see "Related" below.

## Onset

The host built these containers with ~8 s total per container until a reboot at
2026-08-31 15:12:59; every boot since reproduces the stall. Nothing was
installed at that boot (the Setup event log has **zero** entries between
2026-08-28 and 2026-09-01), and reboots do not clear it.

## What is NOT the cause

Each ruled out with an explicit experiment, so nobody repeats them:

- **Windows Defender** — reproduces with real-time protection OFF; platform
  4.18.26070.9 unchanged on disk since 2026-08-05; engine version constant
  across the working and failing periods.
- **Container networking** — CNI ADD succeeds with matching IP/gateway, and
  `--network none` stalls identically.
- **Windows Update inside the container** — an image committed with
  `wuauserv` and `UsoSvc` set to `Start=4` stalls identically.
- **Disabling LSM itself** — an image committed with `LSM Start=4` (verified
  with `sc qc`) still shows the teardown symptom below, so LSM is not the whole
  story.
- **Disk** — 515 GB free; `disk` event 51 appears only on *successful*
  teardowns.
- **VBS/HVCI, hypervisor scheduler type, boot type** — identical at the last
  working boot and at every failing one.
- **A new KB or driver** — none installed on the onset day; all driver binaries
  date to a cumulative update that predates the last working build.
- **GPU** — the discrete GPU is disabled (CM_PROB_DISABLED) throughout.

## Related: the teardown half

The same hosts show the symptom [#547](https://github.com/microsoft/Windows-Containers/issues/547)
reported and that was closed unresolved: after the container's entrypoint exits
(its output is in `docker logs`, and `docker top` shows no such process), the
container stays `Running` until force-stopped, and the runtime waits for a
shutdown notification that never arrives. `docker stop` force-terminates in
91 s. Whether the two share one root cause is **unproven** — disabling LSM does
not fix the teardown — but both are silo lifecycle transitions failing to
signal, so they may well be one defect.

Practical impact: every build step in a container-based toolchain pays the
runtime's whole teardown timeout. With the stock 30 s hcsshim timeout that
truncates real teardowns and permanently corrupts the scratch layer
(`hcsshim::ExportLayer 0x3`); with the timeout raised, each step pays it in
full. Measured here: one trivial `RUN echo` step took **2841.2 s** with a 45 min
timeout and **441.3 s** with a 5 min one — the same static wait, priced
differently.

## Reproducing the diagnosis

Both scripts are in this project and need only an elevated shell plus the
WinDbg package (`cdb.exe` ships inside it):

- `windows/scripts/diagnostics/capture-lsm-waitstack.ps1` — dumps the silo's
  first svchosts twice, 30 s apart, proving the wait is static.
- `windows/scripts/diagnostics/name-lsm-wait-object.ps1` — non-invasive live
  attach during the hang; enumerates handles and stacks.

Two traps worth knowing: silo processes report **empty**
`Win32_Process.ExecutablePath`/`CommandLine` even to an elevated caller, so the
silo must be found through the process tree (a fresh `wininit.exe` → its
`services.exe` → their `svchost`s); and dumps written by an elevated collector
are SYSTEM-owned, so grant read access before analysing them unelevated.

## What would help

The `lsm!CEventDispatcher::WaitForSessionState` path with private symbols
should show which session-state transition is awaited and which component
signals it inside a silo. Given HandleCount 2, that component holds the event
and is running — it just never sets it.
