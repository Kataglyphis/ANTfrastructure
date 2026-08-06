# PR: shim: make container teardown timeouts configurable

Target repo: `microsoft/hcsshim`
Base: `main` (prepared against `81e2e01`)
Branch: `feature/configurable-teardown-timeout`
Patch: [`0001-shim-configurable-teardown-timeouts.patch`](0001-shim-configurable-teardown-timeouts.patch)

---

## What this changes

The shim hardcodes four 30 second limits around container teardown:

- `hcsTask.close()` waits 30 s for a graceful shutdown, then 30 s for a terminate
  (`const tearDownTimeout`, `task_hcs.go`).
- `hcsTask.DeleteExec()` waits 30 s for container resource cleanup
  (`const timeout`, "waiting for task to be closed", `task_hcs.go`).
- The `delete` command waits 30 s for a leftover compute system to finish
  terminating (`delete.go`).

This PR makes them configurable via environment variables, which the shim
inherits from containerd. The names follow the existing
`CONTAINERD_SHIM_RUNHCS_V1_WAIT_DEBUGGER`:

| Variable | Bounds | Default |
|---|---|---|
| `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT` | each wait in `hcsTask.close`, and the `delete` command's wait | `30s` |
| `CONTAINERD_SHIM_RUNHCS_V1_TASK_CLOSE_TIMEOUT` | the wait in `hcsTask.DeleteExec` | `30s`, or derived |

**Defaults are unchanged**, so behaviour is identical unless a host opts in.

`delete.go` takes the same bound rather than a knob of its own: it waits on the
same host-side work, and it runs precisely when the shim died with a container
still going down - so if anything a filesystem-heavy container is *more* likely
to be on the other end of that wait.

### The two knobs are coupled on purpose

`DeleteExec` waits on the channel that `close()` closes. A task close timeout
below `close()`'s worst case of `2*teardown` therefore abandons a teardown that
is *still making progress* - which is exactly the outcome these knobs exist to
prevent. Raising only the teardown timeout would silently not help.

So when the task close timeout is not set explicitly and the teardown timeout
has been raised above the default, the task close timeout is derived as
`2*teardown + 30s`. Setting it explicitly always wins. Leaving both unset
reproduces today's behaviour exactly.

An empty, unparseable or non-positive value is treated as unset: resolution
happens during package initialization, before logging exists, so a bad value
must not stop the shim from starting.

### Also

The PR logs how long a successful shutdown actually took. That duration is what
an operator needs in order to size the timeout for their workload, and it is
currently not observable at all.

### Deliberately out of scope

- The 30 s timer in the `SIGKILL` path: it guards the hosting UVM
  (`ht.host != nil`) and plays no part in process isolated teardown.
- `cmd/runhcs` - a separate binary, and it already allows 5 minutes.
- `cmd/containerd-shim-lcow-v2` - a different shim, though it carries the same
  30 s pattern in its `manager.go` and may deserve the same treatment.

## Why

Tearing down a Windows Server (process isolated) container is host-side work
whose cost scales with how much the container touched the filesystem: the layer
filter stack has to be detached and the container's registry hives flushed back
into its scratch. Most workloads finish in well under a second. Filesystem-heavy
ones do not.

**Measured on the reference host: 117 s for a single OpenCV build container.**
`HcsShutDownComputeSystem` returned in milliseconds; the completion notification
arrived 117 s later (01:16:08 → 01:18:05 in the containerd debug log).

With the hardcoded limits, the shim gives up at 30 s + 30 s and terminates the
container *while its scratch is still being written*. The result is not a lost
container - it is a **permanently damaged snapshot**: every subsequent finalize
of it fails with

```
hcsshim::ExportLayer <path>: The system cannot find the path specified. (0x3)
```

and the failure survives fresh snapshots and host reboots, because the unflushed
hive deltas live inside `sandbox.vhdx` and are never completed.

This is not a container-side problem. All silo processes do exit. Two
independent in-container mitigations were tried and both failed identically:

1. Overriding `WaitToKillServiceTimeout` (the shim injects `2147483647`) down to
   5 s in the payload - exit 0 published, `HcsShutDownComputeSystem` returned in
   milliseconds, both notifications still lost, same `0x3`.
2. A full pre-exit teardown: `sccache --stop-server`, killing `msdtc` and
   `AggregatorHost`, `Stop-Service` on 11 non-essential services, with an exit
   dump proving they were gone - identical loss, identical `0x3`.

Host-side forensics matched: no zombie silos (the compute systems *were*
eventually cleaned up - teardown arrives too late, not never), and 22 orphaned
`bindflt` filter instances in `Detached` state on dead `VhdHardDisk` volumes,
i.e. filter-stack teardown demonstrably not completing.

### Why a fixed timeout is the wrong shape here

Worth stating explicitly, because it is the difference from the Linux side of
the same problem space: on Linux the analogous grace periods (`SIGTERM` → wait →
`SIGKILL`) bound **the processes inside the container**, not a host-side storage
operation. The writable layer is an overlayfs `upperdir` that is already on disk;
there is no end-of-life serialization step, so `umount` costs the same whether
the container touched three files or three million, and killing at the wrong
moment cannot corrupt the layer.

WCOW has no equivalent property: hive flush *is* a durability-critical
serialization whose duration is unbounded in the workload. A fixed timeout on
such an operation is either too short or is not really a timeout. Making it
configurable is the smallest change that lets affected hosts stop losing data.

## Verification

Built and checked against `81e2e01` with Go 1.26.5, `windows/amd64`:

- `go build ./cmd/containerd-shim-runhcs-v1` succeeds.
- `gofmt -l` clean; `go vet ./cmd/containerd-shim-runhcs-v1/` clean.
- `golangci-lint run --config .golangci.yml ./cmd/containerd-shim-runhcs-v1/...`
  with the CI-pinned v2.11: **0 issues**.
- `go test ./cmd/containerd-shim-runhcs-v1/` passes - the whole package, not
  just the new test.
- New table-driven unit test `Test_resolveTeardownTimeouts` (7 cases: defaults,
  derivation, explicit override, each knob alone, malformed/negative, zero)
  passes, and asserts the coupling invariant directly.

Functionally verified on the reference host. **Five consecutive fresh
`--no-cache` OpenCV container builds finalized and exported directly**, no `0x3`
on any of them:

| Run | Build | Export |
|---|---|---|
| 1-3 | constants raised in place | 28.6 s / 28.6 s / 28.1 s |
| 4 | constants raised in place, after a service restart, a build-cache prune and a disk detach/reattach | 27.1 s |
| 5 | **this patch**, `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=45m` on the containerd service | 27.1 s |

Before the change that host had never once produced a direct OpenCV export; it
needed a workaround that avoided finalizing the snapshot at all, and direct
attempts failed with `0x3` deterministically across retries. Run 4 shows the fix
does not depend on warm runtime state. Run 5 exercises exactly the code in this
PR, including the environment plumbing.

Since the binary swap, containerd's log contains **no `timed out while waiting
for container ...` entry at all**, where the same log carried four such pairs on
the night before.

**Two honest limits on that evidence.** First, run 5 is a single data point for
the env-var path; a teardown that happened to complete under 30 s would look
identical to a working timeout, and the prior determinism of the failure is what
makes that unlikely rather than any direct measurement. Second, and more
tellingly: **the teardown duration for these runs could not be measured at all.**
The shim's shutdown path produces nothing in containerd's log at the levels this
host captures. The only reason a 117 s number exists is that the failing case
logged an error. That is precisely the gap the added duration log closes, and it
is why sizing this timeout is currently guesswork for anyone hitting it.

## Host / repro environment

| | |
|---|---|
| Host | Windows 11 Pro, build 26200 |
| Base image | `ltsc2025` |
| Isolation | process |
| containerd | 2.3.3 |
| buildkitd | v0.32.0 (`f5d08d5`) |
| Workload class | source builds (OpenCV, ONNX Runtime GenAI, TVM, GStreamer) |

Win11 24H2+ with `ltsc2025` images in process isolation is an officially
supported combination per the Microsoft version-compatibility documentation, so
this is not a host/image build mismatch.

## Prior art

Nothing in this repo names `tearDownTimeout` or asks for it to be configurable -
searched before filing. The neighbours, and how this differs:

- **[#1488](https://github.com/microsoft/hcsshim/pull/1488)** /
  **[#1554](https://github.com/microsoft/hcsshim/pull/1554)** *Call
  container.Terminate() on shutdown timeouts* - introduced exactly the fallback
  path this PR touches ("we weren't trying to force kill the container via
  Terminate after if we timed out waiting for it to complete"). The path was
  added deliberately; the fixed 30 s limit on it has not been revisited since,
  and configurability was not discussed in review.
- **[#1416](https://github.com/microsoft/hcsshim/pull/1416)** *wcow: support
  graceful termination of servercore containers* - precedent for adjusting WCOW
  termination timing to dodge a fixed platform timeout.
- **[#1056](https://github.com/microsoft/hcsshim/issues/1056)** *timeout waiting
  for notification* (open since 2021) - same symptom family, but on
  Docker/WS2019/Kubernetes, with no layer-level aftermath reported.
- **[#696](https://github.com/microsoft/hcsshim/issues/696)** *docker build
  freeze at exportLayer phase* - a hang in `os.RemoveAll` during export; a
  different mechanism, not a permanently unexportable scratch.
- **[Windows-Containers#547](https://github.com/microsoft/Windows-Containers/issues/547)**
  *Process Isolation ws2025 - container fails to shutdown gracefully* - the same
  underlying phenomenon (ltsc2025 process isolation, ~10 min shutdown, resources
  left locked, reboot required), reported as a slow-shutdown annoyance and
  closed unresolved. It does not mention the shim timeout or `ExportLayer 0x3`.
  That report also saw it with a matched 26100/26100 build, which is why a
  host/image build mismatch can be ruled out.

The contribution here is the causal chain none of them connect: slow ltsc2025
process-isolated teardown → fixed 30 s → terminate mid-flush → permanently
unexportable scratch - plus the first measurement of how long that teardown
actually takes.

## Notes for reviewers

- An environment variable was chosen over a `runhcsopts.Options` field to keep
  the change small and avoid regenerating the proto. If a runtime option in
  containerd's config, or an OCI annotation for per-container control, is
  preferred, say so and I will rework it - the mechanism is not the point.
- **Known limitation of that choice:** an environment variable is host-wide. It
  fits a dedicated build host, which is the case this comes from, but on a node
  running mixed workloads there is no way to grant the long timeout only to the
  containers that need it. An OCI annotation would give per-container control
  and is the natural answer if that matters to you.
- The derivation of the task close timeout is a judgement call. The alternative
  is to leave the two knobs independent and merely document that they are
  coupled - but then raising only the obvious one silently does nothing, which
  seemed like the worse failure mode. Happy to invert it if you disagree.
- Arguably the deeper fix is that expiry of these timers should not be able to
  leave a snapshot unrecoverable at all. Making the limits configurable is the
  smallest change that stops the data loss today.
