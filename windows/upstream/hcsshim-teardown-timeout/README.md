# Upstream submission: configurable hcsshim teardown timeouts

Everything needed to file the `microsoft/hcsshim` issue and PR that would let
this project retire its locally patched shim. Kept in-tree because the local
patch is a maintenance liability: **every Stevedore/containerd update silently
overwrites it and brings the defect back.**

| File | What it is |
|---|---|
| [`ISSUE.md`](ISSUE.md) | Issue text: symptom, 117 s measurement, environment, repro, and the full list of falsified theories |
| [`PR.md`](PR.md) | PR description: what changes, why, verification, reviewer notes |
| [`0001-shim-configurable-teardown-timeouts.patch`](0001-shim-configurable-teardown-timeouts.patch) | `git format-patch` output, applies to `microsoft/hcsshim` `main` |

Background and the full defect history: `docs/windows-builds.md` § BuildKit lane.

## The two patches are NOT the same thing

Do not confuse them:

- **The deployed local patch** raises the constants in place to 45 min / 100 min.
  It is what currently runs on the reference host as
  `C:\Program Files\Stevedore\bin\containerd-shim-runhcs-v1.exe`
  (patched **25 329 664** bytes vs stock **23 279 616**; the original is kept
  alongside as `.exe.orig`).
- **The upstream patch here** keeps the defaults at 30 s and makes them
  overridable by environment variable. It changes nothing unless a host opts in
  - which is what makes it acceptable upstream, and also means that **a shim
  built from this patch needs the environment variables set or it behaves
  exactly like the stock one.**

## Submitting

```bash
git clone https://github.com/Microsoft/hcsshim
cd hcsshim
git checkout -b feature/configurable-teardown-timeout
git am /path/to/0001-shim-configurable-teardown-timeouts.patch
go build ./cmd/containerd-shim-runhcs-v1        # verify
gofmt -l cmd/containerd-shim-runhcs-v1/task_hcs.go
go vet ./cmd/containerd-shim-runhcs-v1/
```

Then open the issue from `ISSUE.md`, open the PR from `PR.md`, and cross-link
them. Worth also commenting on microsoft/Windows-Containers#547 with the 117 s
measurement - that report is closed unresolved and describes the same symptom
family, and an independent second reporter gives the case weight.

**Open the PR as a draft** (the arrow next to *Create pull request* →
*Create draft pull request*). It is not mergeable and requests no reviewers, but
CI still runs - which is the cheapest way to get the repo's own golangci-lint,
build and test matrix to confirm the patch. Flip it to *Ready for review* after.

Microsoft uses a **CLA bot**, not DCO - no `Signed-off-by` needed; the bot
comments on the PR and you accept once across all Microsoft repos. Note the
commit carries a `Co-Authored-By: Claude` trailer, which will be publicly
visible upstream; drop it with `git commit --amend` if you would rather it were
not.

Verified before commit, against `81e2e01` with Go 1.26.5 (`windows/amd64`):
`go build` succeeds, `gofmt -l` and `go vet` clean,
`golangci-lint run --config .golangci.yml ./cmd/containerd-shim-runhcs-v1/...`
with the CI-pinned **v2.11** reports **0 issues**, and the new
`Test_resolveTeardownTimeouts` (7 cases) passes. `git apply --check` is clean
against pristine upstream.

Known gap, stated in `PR.md` rather than hidden: the 117 s / four-canary
measurements come from the constants-in-place build, not from this exact
env-var build.

## If the PR is accepted

Once a released hcsshim carries the knob, the local patch can be retired in
favour of configuration on the containerd service:

```pwsh
# admin; the shim inherits containerd's environment
Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\containerd `
  -Name Environment -Type MultiString `
  -Value @('CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=45m')
Restart-Service containerd -Force
```

Setting the teardown timeout alone is enough: the patch derives the task-close
timeout as `2*teardown + 30s` (here 90m30s, covering the 100 min the local patch
sets by hand). Set `CONTAINERD_SHIM_RUNHCS_V1_TASK_CLOSE_TIMEOUT` only to
override that derivation.

Until then the binary-size check after every Stevedore update stays mandatory.

## Rebuilding the local 45 min shim

The recipe that produced the currently deployed binary, kept here because the
scratchpad clone it was built in is temporary:

```pwsh
scoop install go
git clone https://github.com/Microsoft/hcsshim
cd hcsshim
# cmd\containerd-shim-runhcs-v1\task_hcs.go:
#   const tearDownTimeout = 30 * time.Second   ->  45 * time.Minute   (in close())
#   const timeout         = 30 * time.Second   -> 100 * time.Minute   (in DeleteExec())
# Leave the 30s timer in the SIGKILL path alone - it guards the hosting UVM
# (ht.host != nil) and is not part of process isolated teardown.
go build .\cmd\containerd-shim-runhcs-v1
# admin, and no shim process may be running:
#   Stop-Service buildkitd, containerd
#   copy the exe over C:\Program Files\Stevedore\bin\ (keep the .orig)
#   Start-Service containerd, buildkitd
# containerd does NOT need a restart for the swap itself - the shim is spawned
# per container - but nothing may hold the file while you replace it.
```
