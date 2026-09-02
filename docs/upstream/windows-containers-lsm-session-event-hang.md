<!--
Copyright (c) 2025 Kataglyphis
SPDX-License-Identifier: MIT
-->

# Upstream issue draft — file at microsoft/Windows-Containers

Ready-to-file text for the container **boot** hang, with the wait-stack no
existing report has.

File as a NEW issue. Do **not** frame it as re-opening
[#547](https://github.com/microsoft/Windows-Containers/issues/547) — its own
reporter closed it on 2024-12-20 because it stopped reproducing for him, and he
had narrowed it to the IIS image. The live neighbour is
[hcsshim#2566](https://github.com/microsoft/hcsshim/issues/2566) (open,
unanswered, same 26200-host / ltsc2025-image pairing, different symptom); a
short comment there pointing at the new issue is worth more than a comment on
547. Verified 2026-09-02.

Companion drafts: [`hcsshim-lost-shutdown-notification-issue.md`](hcsshim-lost-shutdown-notification-issue.md)
(the teardown half) and `../../windows/upstream/hcsshim-teardown-timeout/`
(the shim-timeout PR this project runs on).

**Everything below the line is the issue text. Do not paste this header.**

---

## Title

Process-isolated ltsc2025 containers: LSM service start deadlocks in
`CEventDispatcher::WaitForSessionState` on an event that is never signalled

## What this costs

Overnight, with no change to the images or the toolchain, every trivial step of
a container-based build toolchain on this host went from **~8 seconds to
441 seconds** — a 55× regression, measured on the same `RUN echo`. Two separate
things went wrong, and both are below the runtime:

- every process-isolated `servercore:ltsc2025` container now spends **~141 s
  deadlocked during startup** before it can run anything — that is the defect
  this report documents, and the rest of the report is about it;
- afterwards the container does not exit on its own when its command finishes,
  so the runtime waits out its teardown timeout — the remaining 300 s.

The 441 s figure is the *good* case, and it exists only because this host runs
a patched runtime with a raised teardown timeout. With the stock hcsshim 30 s
timeout the teardown is cut short and the scratch layer is corrupted
(`hcsshim::ExportLayer 0x3`), so the build step does not complete correctly at
all. Either way the machine is unusable for its purpose.

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

## What still works on the same host

Three controls against the failing case, all on the same machine, same runtime,
same day, same trivial `RUN echo` step:

| Configuration | Startup stall | Total step |
|---|---|---|
| `servercore:ltsc2025`, **process** isolation | **~141 s** | **441.3 s** |
| `servercore:ltsc2022`, process isolation | none | 1.8 s |
| `servercore:ltsc2025`, **Hyper-V** isolation | none | 3.5 s |
| `nanoserver:ltsc2025`, process isolation | none | ~2 s |

**Read the middle column, not the last one.** The ~141 s startup stall is the
defect this report is about, and it is the number the stack below explains. The
441.3 s total additionally contains a 300 s teardown timeout that only the
failing row ever reaches — see "The teardown half" for what that is and why the
other three rows never pay it.

So the stall needs **ltsc2025 _and_ process isolation _and_ the full servercore
service set** together. An ltsc2022 container — an older user-mode image on the
identical 26200 host kernel — is unaffected, which rules out "process isolation
is broken on this host" as such. Hyper-V isolation runs the same ltsc2025 image
against its own kernel in a utility VM and is fine, and nanoserver lacks the
service set (and with it LSM's role) entirely.

Hyper-V isolation is not a usable workaround here, for two reasons unrelated to
the defect: BuildKit 0.32 has no per-step isolation option, so a Dockerfile
build cannot request it; and Hyper-V containers on this host are limited to a
small fixed CPU count, which is disqualifying for a compiler toolchain build.
It is reported above as a **control**, to localise the defect — not as a
mitigation.

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

## Not the host's session broker

The host's own LSM was measured twice — idle, and again ~20 s into a container's
stall — and it does **nothing** in between: the only stack frame that differs is
a COM garbage-collection worker, and no thread enters
`ContainerSessionServer::AskForSession` while the container hangs. Matching
that, the container-side stack contains **no RPC frames at all** (0 hits for
`rpcrt4`, `ContainerSessionClient`, `AskForSession`).

So the container's LSM is not blocked asking the host for a session. It is
blocked inside its **own** `CEventDispatcher`, waiting for a session state that
should be reached locally. Recording this because it is the obvious first
hypothesis and it is wrong.

## Not something upstream in the silo boot

The obvious second hypothesis is that LSM waits legitimately — that `smss`,
`csrss`, `wininit` or `services` is stuck first and LSM is only the messenger.
Those four are protected processes (PPL) and refuse even a read-only debugger
attach (`Win32 error 0n5`), so they cannot be checked directly from user mode.

Their descendants can be, and they are all healthy: during the stall, the
silo's `lsass.exe` sits in `lsasrv!ServiceDispatcherThread`, its RPCSS
`svchost.exe` in `rpcss!CTime::Sleep`, and `fontdrvhost.exe` in
`fontdrvhost!ServerRequestLoop` — ordinary idle waits, all reached only after
their parents did their work. Together with the service scan (LSM the only one
of 121 not RUNNING or STOPPED), the silo boot evidently proceeds normally
around LSM rather than stalling before it.

## The object being waited on

This comes from a **separate live attach** to a later container instance, not
from the two dumps above — handle data is absent from the dumps. Read from
**R10 of the blocked thread** (the x64 syscall stub does `mov r10,rcx`, so R10
still holds argument 1), taken from the thread whose stack actually shows
`lsm!CService::Start`:

```
process           svchost.exe   (silo, pid 15900, thread 6)
waited handle     0x338
kernel object     0xffffe0831a1b57e0
  Type            Event
  Event Type      Auto Reset
  Event is        Waiting        <- never signalled, for the container's whole life
  HandleCount     2
  PointerCount    65537
```

A system-wide handle enumeration
(`NtQuerySystemInformation(SystemExtendedHandleInformation)`) matched on that
kernel object pointer attributes **exactly one handle to any process, and that
process is LSM itself**. The enumeration does see silo processes — it found
LSM's own handle that way — so this is not an artifact of silo processes being
invisible to it.

Stated no more strongly than the capture supports: at the moment of the
snapshot, no process other than LSM held a handle to this event. The object's
`HandleCount` of 2 is not accounted for by that enumeration; we did not
determine what the second handle is (LSM holding it twice is the simple
explanation, but we have not shown it). We therefore have **not** proven that
nothing else can signal the event — only that no other process was holding it.

A warning for anyone reproducing this, because it cost us a retraction: do
**not** take the first `KERNELBASE!WaitForSingleObjectEx` in the process. Every
service process has one — the SCM dispatcher's own idle wait in
`sechost!ScDispatcherLoop` — and reading it names the wrong object entirely.
`kb`'s "args to child" columns are home-space reconstructions and are not
trustworthy here either. Bind the frame to the thread, then read R10.

## Environment

| | |
|---|---|
| Host | Windows 11 Pro 25H2, build **10.0.26200.9278**, AMD Ryzen 9 9950X |
| Container image | `mcr.microsoft.com/windows/servercore:ltsc2025`, digest `sha256:eeaa17aefe5d949f03b1db17182f5855cf40e757533468cf5b50e07c7c385ada` |
| Image user-mode build | **10.0.26100.9278** — read from the dump: the silo's `lsm.dll`, `ntdll.dll` and `KERNELBASE.dll` all report this |
| Isolation | process (Hyper-V isolation unaffected) |
| Runtimes | reproduces through **both** containerd 2.3.3 + BuildKit 0.32.2 **and** dockerd 29.7.2 |

Host and image are a supported combination per the
[version-compatibility documentation](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility):
the Windows 11 client table marks Windows Server 2025 base images as supported
in process isolation, "from Windows 11 24H2 onwards". Reproducing through two
independent runtimes places the defect below both of them.

**One disclosure, so no number here is a surprise later.** This host runs a
locally patched `containerd-shim-runhcs-v1` that makes hcsshim's hard-coded
30 s teardown timeout configurable (proposed upstream at
[microsoft/hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855)); it is
set to 5 min here. That patch affects **only** how long the runtime waits during
teardown — it is what turns the teardown symptom into the 300 s in the table
above. The ~141 s startup stall, the LSM wait stack, and every control
measurement are independent of it, and the startup stall reproduces identically
through stock dockerd with no patched shim in the picture at all.

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
reported: after the container's entrypoint exits
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

## Related reports

Being precise about these, because two of them are easy to mis-cite:

- [Windows-Containers#547](https://github.com/microsoft/Windows-Containers/issues/547)
  — same *shape* of teardown symptom, but **not** an unresolved case to re-open.
  Its reporter closed it himself on 2024-12-20: it stopped reproducing for him
  after upgrading to Docker Desktop 4.37.0, a Microsoft engineer could not
  reproduce it on `10.0.26100.2605`, and by then he had narrowed it to the
  **IIS** image rather than base servercore. This report is a different and
  wider case: base `servercore`, no IIS, current runtimes, plus a wait stack.
- [hcsshim#2566](https://github.com/microsoft/hcsshim/issues/2566) — **open and
  unanswered**, and the nearest thing to independent corroboration. Different
  symptom (`PrepareLayer` fails `0xc0370112`, and Hyper-V fails there too, which
  it does not here), but the same pairing: a **Windows 11 25H2 / 26200 host**
  running an **ltsc2025 / 26100** image, with "LTSC 2022 works fine" as the
  reporter's workaround — the same discriminator measured above, on a machine
  that is not mine.

A search of both repositories finds no existing issue mentioning LSM or
`WaitForSessionState`.

## Artifacts, and one limitation stated plainly

**This has only been observed on the single host described above.** I have no
second Windows machine to test on. I am flagging that up front because #547 died
by exactly that route — a failed reproduction attempt read as a negative result.
The evidence here is a captured deadlock, not a timing anomaly: two dumps 30 s
apart with a byte-identical stack and 0.000 s of thread CPU cannot be a slow
machine.

I still have the raw material and will hand it over gladly:

- two full user-mode dumps of the silo's `svchost.exe -k DcomLaunch` taken 30 s
  apart during the hang (~30 MB each), plus the `cdb` transcripts behind every
  number in this report
- happy to attach them here, send them privately, or run any command you want
  inside the hang — the state is reproducible on demand in about three minutes

If reproduction fails on your build-matched host, **please ask for the dumps
rather than closing**; they contain the deadlock itself.

The teardown half is a separate defect and is written up separately against
hcsshim; it appears here only because it shares the silo-lifecycle shape and
because it dominates the wall-clock cost quoted at the top.

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

Concretely, I am asking for three things:

1. **Symbolicate the wait.** With private symbols for `lsm.dll`
   `10.0.26100.9278`, `lsm!CEventDispatcher::WaitForSessionState+0x285` should
   name which session-state transition is being awaited.
2. **Name the signaller.** What is supposed to set that event inside a silo, and
   under what conditions does it not run? Since no other *process* held a handle
   at the time of the snapshot, the most likely candidates are another thread in
   that same `svchost` or the kernel's session path — but that is an inference
   from one snapshot, not a measurement, and you can settle it in seconds where
   I cannot.
3. **Say whether the pairing below is expected to work.**

That third point is the one lead I have, and I offer it as a lead, not a
finding. In process isolation the container's user-mode binaries come from the
**image**, and the kernel comes from the **host**. So the deadlock is:

| | build |
|---|---|
| the `lsm.dll` that is actually blocked (from the image) | `10.0.26100.9278` |
| `ntdll.dll` / `KERNELBASE.dll` in that same silo | `10.0.26100.9278` |
| host kernel and session components | `10.0.26200.9278` |

That is a 26100 user-mode session stack running against a 26200 kernel — same
revision, different base build. The documentation blesses this combination, and
until 2026-08-31 this host ran it at ~8 s per container. I raise it only because
the two things that make the stall go away are precisely the two that remove
that pairing: **ltsc2022** swaps the user-mode side for one that predates it,
and **Hyper-V isolation** gives the image its own matching kernel. If the
August servicing round changed a session-notification contract on the 26200
side, a 26100 `lsm.dll` waiting forever for a state that is now reached
differently would look exactly like this.

I have not been able to test that hypothesis: it needs either private symbols
or a second machine, and I have neither.
