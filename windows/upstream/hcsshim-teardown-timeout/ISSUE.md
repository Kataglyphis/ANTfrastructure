# Issue: 30s hardcoded teardown timeout permanently corrupts scratch on filesystem-heavy WCOW containers

Target repo: `microsoft/hcsshim`
Labels to suggest: `windows`, `bug`

---

## Summary

`cmd/containerd-shim-runhcs-v1/task_hcs.go` gives a container 30 s to shut down
and 30 s to terminate before it stops waiting. On Windows Server (process
isolated) containers with heavy filesystem churn, host-side teardown legitimately
needs **minutes**. When the shim gives up mid-flush, the container's scratch is
left in a state the platform will not export, and the damage is **permanent** -
it survives fresh snapshots and host reboots.

Every later finalize of that snapshot fails with:

```
hcsshim::ExportLayer <path>: The system cannot find the path specified. (0x3)
```

## Measurement

On the reference host, a single OpenCV build container:

```
01:16:08  HcsShutDownComputeSystem returns (milliseconds)
01:18:05  completion notification / waitBackground
          => 117 s of host-side teardown
```

The shim's limits are 30 s (shutdown wait) + 30 s (terminate wait), plus a third
30 s in `DeleteExec` ("waiting for task to be closed"). All three expire long
before the work is done, so the container is terminated while its registry hives
are still being flushed into `sandbox.vhdx`. Because those deltas live *inside*
the vhdx and are only completed on a clean shutdown, the scratch is incomplete
forever.

Calm containers (a trivial `cmd` container, CPython, LiteRT, Torch, an ONNX
ninja build) never trip it. The filesystem-heavy class (OpenCV, ONNX Runtime
GenAI, TVM, GStreamer) trips it deterministically.

## Environment

| | |
|---|---|
| Host | Windows 11 Pro, build 26200 |
| Base image | `ltsc2025` |
| Isolation | process |
| containerd | 2.3.3 |
| buildkitd | v0.32.0 (`f5d08d5`) |

Win11 24H2+ with `ltsc2025` images in process isolation is an officially
supported combination per the Microsoft version-compatibility documentation, so
this is not a host/image build mismatch. microsoft/Windows-Containers#547
reports the same symptom family with a matched 26100/26100 build.

## Reproduction

1. Process-isolated WCOW container, `ltsc2025` base.
2. Run a workload that churns the filesystem hard - a from-source build of a
   large C++ project (OpenCV is a reliable specimen; TVM is **not** - it was
   tried as a canary and produced false negatives).
3. Let the container exit normally.
4. Finalize / export the snapshot.

Expected: export succeeds. Actual: `ExportLayer ... (0x3)`, deterministically,
on every retry, on fresh snapshots built from the same content, and after a host
reboot.

## What is NOT the cause

Ruled out with explicit experiments, so nobody repeats them:

- **Not the container's processes.** All silo processes exit. Overriding the
  `WaitToKillServiceTimeout` the shim injects (`2147483647`) down to 5 s inside
  the payload: exit 0 published, `HcsShutDownComputeSystem` returned in ms, both
  notifications still lost, same `0x3`.
- **Not lingering services.** A full pre-exit teardown - `sccache --stop-server`,
  killing `msdtc` and `AggregatorHost`, `Stop-Service` on 11 non-essential
  services, with an exit dump proving they were gone - produced identical loss
  and identical `0x3`.
- **Not antivirus.** Reproducible with Defender exclusions in place for
  `buildkitd.exe`, `containerd.exe`, `C:\ProgramData\containerd` and
  `C:\ProgramData\buildkitd`. (The exclusions do cure a *separate* family of
  sharing-violation flakes.)
- **Not disk pressure.** Reproduced with 74 GB free.
- **Not a settle/delay problem.** Adding a settle period before exit changes
  nothing.
- **Not zombie silos.** Admin forensics showed both canary compute systems
  *were* eventually cleaned up. Teardown arrives too late, not never - the
  damage is already done by then. 22 orphaned `bindflt` filter instances in
  `Detached` state on dead `VhdHardDisk` volumes show the filter-stack teardown
  not completing cleanly.

## Prior art

Searched before filing. Nothing in this repo names `tearDownTimeout`. The
closest reports:

- [#1056](https://github.com/microsoft/hcsshim/issues/1056) *timeout waiting for
  notification* (open since 2021) - same symptom family, but on
  Docker/WS2019/Kubernetes and with no layer-level aftermath reported.
- [#696](https://github.com/microsoft/hcsshim/issues/696) *docker build freeze at
  exportLayer phase* - a hang in `os.RemoveAll` during export, a different
  mechanism.
- [Windows-Containers#547](https://github.com/microsoft/Windows-Containers/issues/547)
  *Process Isolation ws2025 - container fails to shutdown gracefully* - the same
  underlying phenomenon (ltsc2025 process isolation, ~10 min shutdown, resources
  left locked, reboot required), reported as a slow-shutdown annoyance and
  **closed unresolved**. It does not mention the shim timeout or the resulting
  `ExportLayer 0x3`. It also reproduced with a matched 26100/26100 build, ruling
  out a host/image build mismatch.
- [#1488](https://github.com/microsoft/hcsshim/pull/1488) /
  [#1554](https://github.com/microsoft/hcsshim/pull/1554) introduced the
  terminate-after-shutdown-timeout fallback that this report is about. The path
  was added deliberately; the fixed 30 s limit on it has not been revisited.

What appears to be new here is the causal chain connecting them - slow teardown
→ fixed 30 s → terminate mid-flush → permanently unexportable scratch - and the
first actual measurement of the teardown duration.

## Fix

Raising the two constants and rebuilding the shim resolves it completely:
**four consecutive fresh `--no-cache` OpenCV builds finalized and exported
directly**, exports 28.6 s / 28.6 s / 28.1 s / 27.1 s, no `0x3`. That host had
never produced a single direct OpenCV export before.

A PR making the limits configurable (defaults unchanged at 30 s) is prepared -
see [`PR.md`](PR.md) / the accompanying patch.

Two suggestions beyond the timeout itself:

1. **Log the actual teardown duration on the success path.** It is currently not
   observable, which is a large part of why this was so hard to attribute: the
   symptom appears much later, in an unrelated export operation, with an error
   that says "path not found".
2. **Consider whether timer expiry should be able to leave a snapshot
   permanently unexportable at all.** Making the limit configurable lets
   affected hosts stop losing data today, but the failure mode itself seems
   worth hardening.
