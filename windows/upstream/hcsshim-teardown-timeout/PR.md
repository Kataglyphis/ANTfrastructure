# PR: shim: make container teardown timeouts configurable

Target repo: `microsoft/hcsshim`
Base: `main` (prepared against `81e2e01`)
Branch: `feature/configurable-teardown-timeout`
Patch: [`0001-shim-configurable-teardown-timeouts.patch`](0001-shim-configurable-teardown-timeouts.patch)

---

## What this changes

`cmd/containerd-shim-runhcs-v1/task_hcs.go` hardcodes three 30 second limits
around container teardown:

- `hcsTask.close()` waits 30s for a graceful shutdown, then 30s for a terminate
  (`const tearDownTimeout`).
- `hcsTask.DeleteExec()` waits 30s for container resource cleanup
  (`const timeout`, "waiting for task to be closed").

This PR turns them into package-level values that can be overridden by
environment variable, which the shim inherits from containerd:

| Variable | Bounds | Default |
|---|---|---|
| `HCSSHIM_TASK_TEARDOWN_TIMEOUT` | each wait in `hcsTask.close` | `30s` |
| `HCSSHIM_TASK_CLOSE_TIMEOUT` | the cleanup wait in `hcsTask.DeleteExec` | `30s` |

**Defaults are unchanged**, so behaviour is byte-for-byte identical unless a
host opts in. Values are Go duration strings. An unset, empty, unparseable or
non-positive value falls back to the default rather than failing the shim,
because parsing happens during package initialization, before the shim's
logging is available.

The PR also logs how long a successful shutdown actually took. That duration is
exactly what an operator needs to size the timeout for their workload, and it is
currently not observable at all.

The 30s timer in the `SIGKILL` path is deliberately left alone: it guards the
hosting UVM (`ht.host != nil`) and plays no part in process isolated teardown.

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

and the failure survives fresh snapshots and host reboots, because the
unflushed hive deltas live inside `sandbox.vhdx` and are never completed.

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

## Verification

Built from this patch with Go 1.26.5, `windows/amd64`:

- `gofmt -l` clean, `go vet ./cmd/containerd-shim-runhcs-v1/` clean,
  `go build ./cmd/containerd-shim-runhcs-v1` succeeds.
- Functionally verified on the reference host with the equivalent change
  (constants raised in place rather than read from the environment, same code
  paths): **four consecutive fresh `--no-cache` OpenCV container builds
  finalized and exported directly**, exports 28.6 s / 28.6 s / 28.1 s / 27.1 s,
  no `0x3`. Before the change, that host had never once produced a direct
  OpenCV export - it needed a workaround that avoided finalizing the snapshot
  at all.
- The fourth run was performed after a service restart, a build-cache prune and
  a detach/reattach of the disk holding the checkout, confirming the fix does
  not depend on warm runtime state.

## Host / repro environment

| | |
|---|---|
| Host | Windows 11 Pro, build 26200 |
| Base image | `ltsc2025` |
| Isolation | process |
| containerd | 2.3.3 |
| buildkitd | v0.32.0 (`f5d08d5`) |
| Workload class | source builds (OpenCV, ONNX Runtime GenAI, TVM, GStreamer) |

Note that Win11 24H2+ with `ltsc2025` images in process isolation is an
officially supported combination per the Microsoft version-compatibility
documentation, so this is not a host/image build mismatch.

## Related

- microsoft/Windows-Containers#547 - same symptom family (ltsc2025 process
  isolation, ~10 min shutdown, locked resources); closed unresolved. That report
  also saw it with a matched 26100/26100 build, which is why a build mismatch
  can be ruled out as the cause.

## Notes for reviewers

- An environment variable was chosen over a `runhcsopts.Options` field to keep
  the change small and avoid regenerating the proto. If you would rather have
  this as a runtime option in containerd's config (or as an OCI annotation for
  per-container control), say so and I will rework it - the mechanism is not the
  point, the ability to not lose a scratch is.
- Arguably the deeper fix is that expiry of these timers should not leave a
  snapshot unrecoverable at all. Making the limits configurable is the smallest
  change that lets affected hosts stop losing data today.
