# Upstream issue draft — file at microsoft/hcsshim (cross-reference moby/buildkit)

Status: READY TO FILE (2026-08-04). Not yet submitted.
Where: https://github.com/microsoft/hcsshim/issues/new (primary),
cross-ref in https://github.com/moby/buildkit/issues (secondary ask below).

---

## Title

Process-isolated WCOW: HCS shutdown notification never delivered after
heavy-IO builds; scratch never released; snapshot commit permanently fails
with `hcsshim::ExportLayer 0x3`

## Environment

- Host: Windows 11 Pro, build 10.0.26200
- Guest image: `mcr.microsoft.com/windows/servercore:ltsc2025`
  (`sha256:d5bbb83057f6bc2b6aeba5d01ec80a53003aba9bc84a6b1ebe780570cd52558a`)
- containerd (Stevedore distribution) + BuildKit v0.32.0 (`buildctl`),
  windows snapshotter, **process isolation**
- Repro rate: 100 % for specific build workloads (11+ occurrences), 0 % for
  others — fully deterministic per workload, survives a host reboot with a
  fresh container

## Symptom

`buildctl` solves fail at layer finalize:

```
failed to commit <active> to <name> during finalize: failed to reimport
snapshot: hcsshim::ExportLayer failed in Win32: Das System kann den
angegebenen Pfad nicht finden. (0x3)
```

## Debug-log timeline (containerd --log-level debug) — two independent runs

```
07:58:52.681 level=error msg="timed out while waiting for container shutdown"  error="hcsshim: timeout waiting for notification" timeout=30s
07:59:22.681 level=error msg="timed out while waiting for container terminate" error="hcsshim: timeout waiting for notification" timeout=30s
07:59:23.15x shim cleanup: HcsWaitForOperationResult fails with
             "Der angeforderte virtuelle Computer- oder Containervorgang ist
             im aktuellen Zustand ungültig." (HCS_E_INVALID_STATE,
             resultDocument Error -1070137083)
07:59:23.178 level=debug msg="commit snapshot" key=n4yps6... name=svgf6...
07:59:36.235 level=debug msg="snapshotter error" error="failed to reimport
             snapshot: hcsshim::ExportLayer ... (0x3)"
```

Second run, identical shape: shutdown timeout 08:26:52 → terminate timeout
08:27:22 → commit 08:27:22.826 → ExportLayer 0x3 at 08:27:35.631.

**Host process inspection immediately after the timeouts shows NO surviving
container processes** — every process in the silo exited; only the HCS
completion notification never reached hcsshim. The scratch layer is then
never cleanly deactivated/released, and every subsequent ExportLayer of that
snapshot fails 0x3, indefinitely (retries minutes or hours later, and even
after buildkitd/containerd restarts, still fail on that snapshot).

## Trigger matrix (~20 controlled probes)

Fails 100 % (fresh snapshot each time): cmake/MSBuild ONNXRuntime-GenAI
(~7 min, ~4 GB diff), cmake+ninja OpenCV (~21 min), cmake+ninja TVM+IREE
(~15 min), meson/ninja GStreamer (~30 min).

Succeeds 100 %: 100-minute ninja ONNXRuntime build (12 GB diff!), MSBuild
cpython build, bazel LiteRT build (24 min), pip-heavy torch app assemble,
`MSBuild.exe -version`, 14 stacked trivial layers.

Ruled out by probes: layer content (a failing build whose ENTIRE file diff
was deleted before step end still fails), lingering compiler daemons (killed
before exit — still fails), msdtc/WMI services (stopped — still fails), 30 s
quiesce sleep + volume flush, host reboot + fresh container, cache
poisoning, layer depth, parent-layer integrity, .NET Framework CLR startup
alone.

## Two distinct problems

1. **hcsshim/HCS**: the shutdown/terminate notification is lost although all
   silo processes exited (both 30 s waits time out back-to-back). Ask:
   what makes HCS drop the notification for these containers (host 26200 vs
   ltsc2025 guest skew? wcifs churn volume?), and could hcsshim fall back to
   polling system state instead of relying solely on the callback?
2. **containerd windows snapshotter / BuildKit** (secondary, cross-ref):
   the snapshot commit proceeds ~70 ms into a teardown that demonstrably
   failed; the resulting 0x3 surfaces far from the root cause, and the cache
   record becomes permanently unreclaimable ("shared", pinned by an orphaned
   lease that only a buildkitd restart frees). Ask: fail fast or
   deactivate/retry the scratch when teardown reported failure.

## Workaround in production (for other affected users)

Exploit BuildKit's lazy finalization: run the heavy build in a solve with NO
exporter (its snapshot is never finalized), move the artifacts out through a
side channel (we use one tar over a LAN WebDAV server), and materialize them
in a calm, short-lived container whose snapshot finalizes normally. Details:
`docs/windows-build-lanes.md` § BuildKit/containerd lane in
https://github.com/Kataglyphis/ContainerHub.

Full containerd debug logs and per-probe build logs available on request.
