# Upstream submission: configurable hcsshim teardown timeouts

> **FILED 2026-08-06 as a DRAFT:**
> [microsoft/hcsshim#2855](https://github.com/microsoft/hcsshim/pull/2855)
> from `Kataglyphis/hcsshim:feature/configurable-teardown-timeout`.
> The issue from `ISSUE.md` is NOT filed yet, and neither is the comment on
> Windows-Containers#547.

Everything needed to file the `microsoft/hcsshim` issue and PR that would let
this project retire its locally patched shim. Kept in-tree because the local
patch is a maintenance liability: **every Stevedore/containerd update silently
overwrites it and brings the defect back.**

| File | What it is |
|---|---|
| [`ISSUE.md`](ISSUE.md) | Issue text: symptom, 117 s measurement, environment, repro, and the full list of falsified theories |
| [`PR.md`](PR.md) | PR description: what changes, why, verification, reviewer notes |
| [`0001-shim-configurable-teardown-timeouts.patch`](0001-shim-configurable-teardown-timeouts.patch) | `git format-patch` output, applies to `microsoft/hcsshim` `main` |

Background and the full defect history: `docs/windows-build-lanes.md` § BuildKit lane.

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

## Submitting (HISTORICAL — the PR is already open)

> This recipe was for the ORIGINAL submission and is kept as the record of
> how #2855 was produced. Do NOT run it again — that would produce a
> duplicate PR. Current actions live in the status header above (the
> unfiled ISSUE.md + the Windows-Containers#547 comment).

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

**hcsshim enforces BOTH a CLA and DCO.** The README only advertises the
Microsoft CLA bot, but the PR checks include a `DCO` gate that fails without a
`Signed-off-by` trailer matching the commit author - confirmed the hard way on
#2855, which went up red and needed an amend. Always commit with `-s`:

```bash
git commit -s ...          # or: git commit --amend --no-edit -s && git push --force-with-lease
```

The CLA bot comments separately; you accept once across all Microsoft repos.

Note the commit also carries a `Co-Authored-By: Claude` trailer, publicly
visible upstream. Drop it with an amend + force-push if you would rather it were
not - fine to do while the PR is still a draft.

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
```

Then install it with the repo script (admin; it keeps `.orig` and a timestamped
backup, and refuses while a build or a shim process is alive):

```pwsh
pwsh -File windows\scripts\deploy-shim-patch.ps1 -ShimPath .\containerd-shim-runhcs-v1.exe

# for a build made from the UPSTREAM patch, which is inert without the env var:
pwsh -File windows\scripts\deploy-shim-patch.ps1 -ShimPath .\containerd-shim-runhcs-v1.exe `
     -ServiceEnvironment CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT=45m

pwsh -File windows\scripts\deploy-shim-patch.ps1 -ReportOnly     # what is installed?
pwsh -File windows\scripts\deploy-shim-patch.ps1 -Restore .orig  # back to stock
```

containerd does NOT need a restart for the swap itself - the shim is spawned per
container - but nothing may hold the file while you replace it, which is why the
script stops the services.

**Verification trap, learned 2026-08-06:** the shim logs its effective timeout at
**Debug** level, and that does not reach containerd's log on this setup, so a
quiet log proves nothing. `nerdctl run` is also not a usable probe here - it
panics on the CNI `nat` network. The reliable check is behavioural: an OpenCV
canary teardown takes ~117 s, so with a 30 s timeout it MUST fail with `0x3`;
a clean finalize+export is therefore proof that the longer timeout is live.
