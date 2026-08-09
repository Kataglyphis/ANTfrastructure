# Fresh Windows Host Bring-Up (BK lane + repo gates)

Goal: take a **fresh Windows 11 machine** to (1) a green
`.\windows\build-buildkit.ps1 -Gpu` on the preferred BuildKit/containerd lane
and (2) working repo gates (lint / tests / preflight) — using only this
checklist and the sections it links. Every step names its shell
(**[admin]** / **[non-admin]**) and ends with a verify command. Deep rationale
lives in [Windows Build Image](windows-builds.md); this page is the ordered
path through it, not a replacement.

> **Check yourself against the machine, not against this page.**
> `windows/scripts/verify-host-setup.ps1` asserts every claim below and prints
> a fix for each failure. Run it **first** (to see what a fresh box still
> needs), **last** (to confirm bring-up), and after any host change:
>
> ```pwsh
> pwsh -File windows\scripts\verify-host-setup.ps1 -SccacheEndpoint http://<lan-ip>:5000
> ```
>
> It needs no admin (Defender exclusions are reported UNKNOWN rather than
> skipped, so their absence cannot look like success) and exits 1 on any
> failure.
>
> **`pwsh`, never `powershell`, and that includes the ADMIN window.** Every
> script here carries `#requires -Version 7.0`; under Windows PowerShell 5.1
> they refuse with a `#requires` message and change nothing. That refusal is
> easy to miss: wrapped in a command that collects only the pipeline stream it
> looks exactly like "the script ran and did nothing" — it cost two round trips
> on 2026-08-08 against `apply-buildkitd-gcpolicy.ps1`, whose effect
> (`reservedSpace` in the deployed toml) then silently stayed at the old value.
> **Verify the effect, not the exit.**
>
> Do not hardcode a pwsh path. On this host pwsh 7 is the **MSIX/Store** build
> under `C:\Program Files\WindowsApps\Microsoft.PowerShell_<version>_x64__…\`,
> not the MSI at `C:\Program Files\PowerShell\7\` — the path carries the
> version and moves on every update. Resolve it with `(Get-Command pwsh).Source`
> (app-execution aliases occasionally fail to resolve under elevation; fall back
> to a recursive search of `WindowsApps` for `Microsoft.PowerShell_*`). **This page and that script are two views of one contract — change
> them together.** The reason it exists: until 2026-08-07 the CNI section here
> handed fresh hosts a `.conf` template that silently broke the entire nerdctl
> lane, and it read as authoritative for days. Prose cannot be executed; that
> is the whole failure mode this guards.

Phases:

- **A** — one-time host provisioning **[admin]**
- **B** — repo checkout + gate tooling **[non-admin]**
- **C** — build-service tuning **[admin]** (debug flags, log limit, GC policy, Defender, sccache/dufs)
- **D** — per-boot / per-run checks
- **E** — first build + verification

> **Fast path for Phase A5 + C: `setup-new-host.ps1`.** Once the interactive
> steps are done (A1 Stevedore+reboot, A2 docker-users + a new shell, A3
> services, B0 Git/B1 repo), a single elevated run of
> `windows\scripts\setup-new-host.ps1` does the *entire* scriptable half — CNI
> `.conflist` authored from the **live** `vEthernet (nat)` subnet (magic
> constants removed: it derives `network/prefix` + gateway at runtime), then
> `apply-containerd-config.ps1` (debug flags, teardown env var, Defender
> exclusions, `.conf` derive), `apply-buildkitd-gcpolicy.ps1` + the step-log
> env var, the patched runhcs shim (built from hcsshim source if no `-ShimPath`
> is given — Go installed via scoop as needed — then deployed), and dufs
> (scooped if missing, started serving the cache dir, ONLOGON task registered,
> machine `SCCACHE_WEBDAV_ENDPOINT` set to the host's LAN IP).
>
> ```pwsh
> pwsh -File windows\scripts\setup-new-host.ps1 -ReportOnly   # plan first (safe, non-admin)
> pwsh -File windows\scripts\setup-new-host.ps1               # admin - bring the host to green
> pwsh -File windows\scripts\setup-new-host.ps1 -ShimPath C:\src\hcsshim\containerd-shim-runhcs-v1.exe
> ```
>
> It is idempotent and refuses to run while a build is live (unless `-Force`).
> The rest of A5/C below is what the script does by hand — read it to
> understand, run the script to execute.

> **⚠️ FIRST CHECK on any Windows host doing container builds.**
> The build-`COPY`-commit failure `hcsshim::ActivateLayer 0x20` (buildkit) /
> `mkdir \\?\Volume{<GUID>}\C:.` — "Der Verzeichnisname ist ungültig" (docker
> legacy) hits BOTH engines, deterministically, and survives `-NoCache`,
> service restarts, Defender exclusions, a full store reset and a reboot.
> **Root cause (corrected 2026-08-09): a FAULTY AMD ADRENALINE installation**
> — a clean reinstall fixed it, while GPU-disable never did. The earlier
> suspicion of an AMD RDNA3.5/RDNA4 / upstream microsoft/Windows-Containers
> #623 hardware defect was a MISDIAGNOSIS. Probe and repair order:
> **(1)** `pwsh -File windows\scripts\probe-build-copy.ps1` (the committed
> 3-layer RUN+COPY probe; assets in `windows/diagnostics/probe-build-copy/`
> — run it before trusting a new host), then **(2)** **repair/reinstall AMD
> Adrenaline** and probe again. Do NOT disable the GPU.
> `toggle-rdna4-gpu.ps1` is obsolete as a fix. NOT an ISO/OS problem: on an
> affected box `sfc`/`DISM` report 0 components corrupt. The Linux cross lane
> and all repo gates are unaffected. Remaining-valid diagnostics: while
> build-COPY fails in both engines (ApplyDiff), `docker run` + `docker commit`
> still works (CommitLayer OK) — so the classic lane's run+commit stages stay
> viable once a FROM image exists; full bootstrap still needs a healthy host
> (every Dockerfile has a COPY).
>
> **Latest state (2026-08-09, end of session — the deeper story the Adrenaline
> fix opened):** with Adrenaline fixed + pristine Stevedore the buildkit lane
> on the discovered host STILL refused multi-level commits (any layer writing
> into an existing parent dir: `ActivateLayer 0x20` at snapshotter reimport,
> identical on buildkit 0.32.0 and 0.32.2, on `windowcon`/`native`/`windowssvm`
> snapshotter names). It was only cleared by a **Windows in-place repair
> upgrade** (official ISO, same build 26200/25H2, "keep files and apps") —
> after it **every layer commits**, including writes into existing dirs. Only
> the FINAL export (reimport of the committed snapshot) still trips 0x20 on
> that host, where Defender's engine (`MsMpEng`) is unkillable by design and
> the identical Stevedore+OS stack builds the BK lane fine on the working
> machine. Order on a host with this symptom: probe → reinstall AMD Adrenaline
> → probe → if commits still fail, **in-place-repair Windows → probe** → BK
> lane commits; residual export 0x20 = host-residual (classic lane or the
> healthy host).

---

## Phase A — One-time host provisioning [admin]

### A1. Install Stevedore, reboot

```pwsh
winget install stevedore     # or: choco install stevedore; custom dir: --custom="INSTALLDIR=D:\Stevedore"
```

**Reboot** afterwards — this enables the Windows Containers feature. Details
and the custom-INSTALLDIR path substitution: [Windows Build Image](windows-builds.md)
§ Prerequisites.

> Path quirk: Stevedore puts `docker.exe`, `buildctl.exe`, `nerdctl.exe` and
> `containerd.exe` under `<INSTALLDIR>\bin\`, but `dockerd.exe` and
> `buildkitd.exe` at the install root. When in doubt, trust the service
> ImagePath in the registry, not a hand-typed path.

Verify:

```pwsh
Get-Service stevedore, containerd, buildkitd          # all three must exist
& "$env:ProgramFiles\Stevedore\bin\docker.exe" version
```

### A2. docker-users group membership

The installer normally adds the installing user; the group grant is what makes
**non-admin** builds possible (dockerd's and buildkitd's named pipes are ACL'd
to `docker-users`; containerd's pipe stays admin-only by upstream design).

```pwsh
net localgroup docker-users $env:USERNAME /add        # only if missing
```

Log out/in after a group change. Verify (non-admin shell):

```pwsh
whoami /groups | Select-String docker-users           # must match
& "$env:ProgramFiles\Stevedore\bin\buildctl.exe" --addr npipe:////./pipe/buildkitd debug workers
```

### A3. Services running, reboot-safe

```pwsh
Get-Service stevedore, containerd, buildkitd | Set-Service -StartupType AutomaticDelayedStart
Start-Service stevedore, containerd, buildkitd
```

Verify: `Get-Service stevedore, containerd, buildkitd` → all `Running`.

### A4. Conditional dockerd fixes (only on the matching symptom)

- **`stevedore` service won't start / 1053 timeout** → a stale Docker Desktop
  `C:\ProgramData\docker\config\daemon.json` conflicts with the service's
  `--host` flags. Remove/rename it: [Windows Build Image](windows-builds.md)
  § Stevedore Setup Fixes, Fix 1.
- **`docker build` fails `runtime "com.docker.hcsshim.v1" binary not installed`**
  → apply Fix 2 (re-register with `--default-runtime=io.containerd.runhcs.v1`).
  Note: current Stevedore releases may not need this — the reference host runs
  WITHOUT the flag; apply it only when the symptom appears.

Verify: `& "$env:ProgramFiles\Stevedore\bin\docker.exe" info` succeeds.

### A5. CNI nat conf (required — RUN steps have NO network without it)

`nat.exe` already ships in `C:\Program Files\containerd\cni\bin`; only the
conf is missing on a fresh host. Install it as a **`.conflist`** (plugin-list
form), NOT a bare `.conf` — see the format note below — using the subnet from
[Windows Build Image](windows-builds.md) § Getting it going, step 2. The
`ipam.subnet`/`GW` values MUST match the live `vEthernet (nat)` adapter
(`ipconfig`), and dockerd restarts can silently re-create that network on a
new subnet (the driver's preflight fail-fasts on drift with the exact fix).

```javascript
// C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist
{
    "cniVersion": "0.3.0",
    "name": "nat",
    "plugins": [
        {
            "type": "nat",
            "master": "Ethernet",
            "ipam": {
                "subnet": "<subnet of the vEthernet (nat) adapter>",   // DERIVE, don't copy: see below
                "routes": [ { "GW": "<the adapter's own IP>" } ]
            },
            "capabilities": { "portMappings": true, "dns": true }
        }
    ]
}
```

**No magic subnets — derive them.** Every example number shipped in these docs
(`172.31.32.0/20`, etc.) was a snapshot of ONE host and went stale; the only
correct values are the live adapter's. `setup-new-host.ps1` derives them
automatically; to do it by hand:

```pwsh
$n = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -eq 'vEthernet (nat)' }
$n.IPAddress, $n.PrefixLength     # adapter IP + prefix -> GW + subnet (e.g. 172.21.32.1 / 20 -> subnet 172.21.32.0/20)
```

The `ipam.subnet`/`GW` MUST match that live `vEthernet (nat)` adapter
(`ipconfig`), and dockerd restarts can silently re-create that network on a
new subnet (the driver's preflight fail-fasts on drift with the exact fix).

**Install BOTH forms — conf AND conflist (corrected 2026-08-07, same day, after
the conflist-only state cost a launched chain).** Same content, two filenames:

- **`0-containerd-nat.conflist`** is required by **nerdctl**, which cannot parse
  a bare `.conf` — it indexes `plugins[0]` with no length check and PANICS with
  `index out of range [0] with length 0`, both in `network create`
  (`netutil_windows.go:40`) and in `run` (`container_network_manager.go:857`).
- **`0-containerd-nat.conf`** is required by **buildkitd**. With only the
  conflist present, BuildKit RUN steps get **no network adapter at all**: a probe
  container showed an empty `ipconfig`, DNS failed, and a raw TCP connect to a
  literal GitHub IP returned *"unreachable network"*. The containerd debug log
  showed the `HcsCreateComputeSystem` spec for `buildkitsandbox` with no
  networking block. Restoring the `.conf` and `Restart-Service buildkitd -Force`
  fixed it on the spot: IPv4 `172.31.44.107`, gateway `172.31.32.1`, DNS
  `192.168.188.1`, `github.com` resolved.

The earlier claim here that "containerd and BuildKit read either form" was
wrong. The 2026-08-07 conversion fixed nerdctl and silently killed the buildctl
lane; it went unnoticed because no chain build ran in between. Keep both files,
and **when you edit one, edit both** — `build-buildkit.ps1` fail-fasts on a
missing `.conf` (`Get-CniConfFormIssue`), but nothing detects the two drifting
apart in content.

Verify:

```pwsh
Test-Path 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conflist'  # True (nerdctl)
Test-Path 'C:\Program Files\containerd\cni\conf\0-containerd-nat.conf'      # True (buildkitd)
ipconfig | Select-String -Context 0,4 'vEthernet \(nat\)'                   # subnet matches the conf
```

The drift guard reads either name (`Get-CniNatSubnetDrift` checks `.conflist`
then `.conf`) — note its contract is "file absent = nothing to judge", so a
conf under any OTHER name turns the guard into a silent no-op.

**Verify nerdctl works too** (ADMIN shell — nerdctl opens containerd's pipe,
which is Administrator-only; `buildctl` stays non-admin because `buildkitd`
has `--group docker-users` and containerd has no equivalent). This is the
fastest confirmation that the conflist is correct, because nerdctl is the
component that is picky about it:

```pwsh
nerdctl --namespace buildkit run --rm --network nat `
    docker.io/local/kataglyphis:bk-windows-base cmd /c ipconfig
```

Expect an IPv4 address inside the conf's subnet with the nat gateway. Two
warnings are normal and harmless (`default network named "nat" does not have an
internal nerdctl ID`, and a `failed to remove hosts file` on exit). If instead
you get `panic: runtime error: index out of range [0] with length 0`, the config
is still in bare-`.conf` form.

If `nerdctl` is "not recognized": `C:\Program Files\Stevedore\bin` is on the
MACHINE path, so only shells opened AFTER the Stevedore install see it — open a
new window rather than editing `$env:Path`.

Full recipe set (interactive shell into an image, `nerdctl build`, the
`ENTRYPOINT` trap, zombie cleanup): [Windows Build Image](windows-builds.md)
§ nerdctl lane.

---

## Phase B — Repo checkout + gate tooling [non-admin]

### B1. Git for Windows + clone

Install Git for Windows (`winget install Git.Git`). The gates run under **Git
Bash** (`C:\Program Files\Git\bin\bash.exe`) — do NOT rely on a bare `bash` on
PATH, which on many hosts resolves to `System32\bash.exe` (WSL).

```pwsh
git clone --recurse-submodules git@github.com:Kataglyphis/Kataglyphis-ContainerHub.git
cd Kataglyphis-ContainerHub
git config core.hooksPath .githooks      # pre-commit runs the same checks CI enforces
git config core.longpaths true           # deep vendored trees; host LongPathsEnabled=1 recommended too
```

- The `external/` submodule (DocumANTation Sphinx theme) is **optional for
  building images** — it is only needed for `cd docs && make html`. A plain
  clone builds the Windows chain fine.
- **Line endings:** `.gitattributes` pins the load-bearing files, so
  `core.autocrlf=true` (the Windows default, and what the reference host uses)
  is tolerated. The preflight `crlf-guard` check catches any `*.sh` that went
  CRLF in the working tree; after editing media `.psm1`/`.ps1` files confirm
  `git diff` shows only your change, not a whole-file EOL flip
  (AGENTS.md § Windows Build Invariants).

Verify: `git config core.hooksPath` prints `.githooks`; `git status` is clean.

### B2. PowerShell 7 (pwsh)

Everything on this lane requires pwsh 7 (`#Requires -Version 7.0` in every
script; owner policy — see AGENTS.md).

```pwsh
winget install Microsoft.PowerShell
```

Verify: `pwsh -NoProfile -c '$PSVersionTable.PSVersion'` → 7.x.

### B3. PSScriptAnalyzer + Pester (the PowerShell gates)

CI parity pins (`.github/workflows/windows-scripts.yml`): PSScriptAnalyzer
**1.25.0**, Pester **>= 5.7**. `Invoke-Tests.ps1` FAILS (never silently
skips) when Pester >= 5 is missing.

```pwsh
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force
Install-Module Pester -MinimumVersion 5.7 -Scope CurrentUser -Force -SkipPublisherCheck
```

Verify:

```pwsh
Get-Module -ListAvailable PSScriptAnalyzer, Pester | Select-Object Name, Version
```

### B4. Python for preflight/sync — dodge the Windows Store stub

On a fresh Win11, `python3` on PATH is the **Microsoft Store stub** (opens the
Store instead of running). `preflight.sh` provides the escape hatch
`PREFLIGHT_PYTHON`; the simplest working setup is uv:

```pwsh
scoop install uv          # or: winget install astral-sh.uv (install scoop first: https://scoop.sh)
uv python install 3.14    # puts python3.14.exe into %USERPROFILE%\.local\bin
```

Verify:

```pwsh
uv run --no-project python -V                              # Python 3.x
& "$env:USERPROFILE\.local\bin\python3.14.exe" -V          # if installed via uv python install
```

### B5. shellcheck / hadolint / actionlint — nothing to install

The preflight lint gates **auto-bootstrap** these: a PATH copy is used when
present, otherwise the pinned release from `versions.env` is downloaded once
into a version-keyed cache dir and SHA256-verified (`lint-shell.sh`,
`lint-dockerfiles.sh`, `lint-workflows.sh`). First run needs network; a failed
bootstrap fails the gate loudly (no silent skip).

### B6. Run all three gates

```pwsh
pwsh -File windows/scripts/Invoke-Lint.ps1                 # parse gate + PSScriptAnalyzer
pwsh -File windows/scripts/tests/Invoke-Tests.ps1          # harness + Pester suites
```

```bash
# Git Bash (not WSL bash):
PREFLIGHT_PYTHON="uv run --no-project python" bash linux/scripts/preflight.sh
```

Verify: all three exit 0. Preflight's check list (incl. `crlf-guard`,
`version-snapshot`, hadolint, actionlint) is the single source of the no-build
gate list — see AGENTS.md § Validation.

---

## Phase C — Build-service tuning [admin]

Do C1–C3 in this order: C1 and C2 are plain registry edits, C3
(`apply-buildkitd-gcpolicy.ps1`) preserves the existing flags, adds
`--config`, and performs the one buildkitd restart. **Never restart buildkitd
while a build is solving.**

### C1. Permanent debug flags on containerd + buildkitd (owner policy)

Debug logging stays PERMANENTLY ON on build hosts, so the next snapshotter
incident carries its evidence immediately (owner decision 2026-08-04; if the
log grows huge, truncate it — never disable the flags). Recipe and rationale:
[Windows Build Image](windows-builds.md) § BuildKit/containerd lane ("How to
capture the debug evidence again").

**Use the script — it is the source of truth for the containerd side:**

```pwsh
pwsh -File windows\scripts\apply-containerd-config.ps1 -ReportOnly   # inspect, no admin needed
pwsh -File windows\scripts\apply-containerd-config.ps1               # admin; restarts containerd
```

containerd runs with **no `config.toml`** here — every setting lives in the
service's `ImagePath`/`Environment` registry values, which is why it needs a
script to be reproducible at all (buildkitd has `buildkitd.toml` +
`apply-buildkitd-gcpolicy.ps1`; this is the missing counterpart, added
2026-08-07). It owns three things a fresh host must have: the debug flags
below, `CONTAINERD_SHIM_RUNHCS_V1_TEARDOWN_TIMEOUT` (the runhcs shim inherits
the SERVICE environment — a shim built from the upstream patch keeps its 30 s
defaults and silently reverts to the `ExportLayer 0x3` defect without it), and
the load-bearing Defender exclusions. Never run it while a build is solving.

The manual equivalent, if you want to see what it does — set via registry,
because `sc.exe` quoting mangles these in PowerShell:

```pwsh
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\containerd' -Name ImagePath `
  -Value '"C:\Program Files\Stevedore\bin\containerd.exe" --run-service --service-name containerd --log-level debug --log-file C:\ProgramData\containerd\containerd-debug.log'
# buildkitd: insert --debug before --run-service in ITS ImagePath (exe path may be
# the install ROOT, not bin\ — read the current value first and keep every flag):
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' | Select-Object -Expand ImagePath
```

Restart containerd (`Restart-Service containerd -Force`, then
`Start-Service buildkitd, stevedore` — both depend on it). Verify (reference
host state):

```pwsh
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\containerd').ImagePath   # contains --log-level debug --log-file ...
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd').ImagePath    # contains --debug
```

### C2. Disable buildkitd's per-step log limit (REQUIRED for compile stages)

Without this, heavy steps deadlock silently at the 2 MiB clip
([Windows Build Image](windows-builds.md) § Getting it going, step 4):

```pwsh
Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd `
  -Name Environment -Type MultiString `
  -Value @('BUILDKIT_STEP_LOG_MAX_SIZE=-1','BUILDKIT_STEP_LOG_MAX_SPEED=-1')
```

(The restart comes with C3.) Verify after C3:

```pwsh
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd').Environment
```

### C3. Deploy the GC policy + build-history cap (REQUIRED — not optional tuning)

Skipping this cost this project twice: buildkitd's computed defaults evicted
the multi-hour VS Build Tools layer between two runs, and unlimited build
history pinned a 414 GB store at `Reclaimable: 0B`. The repo policy
(`windows/buildkitd.toml`: three GC tiers, `reservedSpace = 200GB`, plus the
`[history] maxAge/maxEntries` cap) is deployed by:

```pwsh
pwsh -File windows\scripts\apply-buildkitd-gcpolicy.ps1    # admin; refuses while a build runs
```

**Sizing on a different disk:** the toml's literals assume a ~930 GB C:.
Reproduce the INVARIANTS, not the numbers — `reservedSpace` must exceed the
fresh chain spine (~120–150 GB; rule of thumb 20–25 % of the disk, floor
150 GB), `maxUsedSpace` ≈ 1.5× reservedSpace, `minFreeSpace` ≥ 25–30 GB
always, `[history]` unchanged everywhere. The sizing rationale lives as a
comment block in `windows/buildkitd.toml` itself. **Re-run the apply script
after every repo-side toml change** — deploy is a copy, nothing syncs
automatically (this host ran a stale copy for hours after the `[history]`
section landed).

Full story: [Windows Build Image](windows-builds.md) § BuildKit/containerd
lane, "Store GC" bullet. Verify:

```pwsh
& "$env:ProgramFiles\Stevedore\bin\buildctl.exe" debug workers -v | Select-String 'reservedSpace|maxUsedSpace|minFreeSpace'
# must show reservedSpace=200GB tiers, NOT the computed defaults (maxUsedSpace 100GB / minFreeSpace 187GB)
```

### C4. Windows Defender exclusions — LOAD-BEARING, not hygiene

These exclusions are load-bearing: without them the realtime scanner races
container churn and finalize/export operations flake constantly (the
hcs-temp sharing-violation family). They also tame — but do NOT cure — the
`ExportLayer 0x3` heavy-churn finalize defect (TVM-class finalizes became
reliable with them; OpenCV-class still trips it, which is why the
warm/materialize pattern stays — full story: windows-builds.md § roadmap).
Skipping this step on a new machine makes builds flaky across the board.
The full set (the § Getting it going step-3 list plus the process exclusions
added 2026-08-05 after the hcs-temp sharing-violation flake family):

```pwsh
Add-MpPreference -ExclusionPath "C:\ProgramData\containerd"
Add-MpPreference -ExclusionPath "C:\ProgramData\buildkitd"
Add-MpPreference -ExclusionPath "C:\ProgramData\nerdctl"
Add-MpPreference -ExclusionPath "C:\temp"
Add-MpPreference -ExclusionProcess "buildkitd.exe"
Add-MpPreference -ExclusionProcess "containerd.exe"
Add-MpPreference -ExclusionProcess "dockerd.exe"
```

Also exclude your repo checkout directory (antivirus file locks during
FetchContent/cargo are a documented failure family — see the note at the top
of [Windows Build Image](windows-builds.md)). Verify (admin — non-admin
reads print "N/A"):

```pwsh
Get-MpPreference | Select-Object -Expand ExclusionPath
Get-MpPreference | Select-Object -Expand ExclusionProcess
```

### C5. sccache / dufs WebDAV server (REQUIRED for the media stages)

This server is load-bearing twice: it is the compile cache (sccache WebDAV
backend) AND the transport for the warm/materialize handoff tars (the
`bkhandoff/` subdir) that neutralize the `ExportLayer 0x3` snapshotter defect
— **without it the BK media solves fail fast**. `setup-new-host.ps1` automates
all of it (scoop install if missing, cache dir, start, ONLOGON task,
machine-level endpoint env with the host's LAN IP — never localhost). By hand
(non-admin, except the machine-env line):

```pwsh
scoop install dufs
mkdir C:\sccache-cache
dufs C:\sccache-cache -A -p 5000                 # keep it running

# endpoint = the host's LAN IP (ipconfig), NEVER localhost — containers must reach it:
[Environment]::SetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT','http://<host-LAN-IP>:5000','Machine')  # admin; or pass -SccacheEndpoint per run
```

**dufs does NOT survive reboots.** Either make it logon-persistent once —

```pwsh
schtasks /Create /TN dufs-sccache /TR "\"%USERPROFILE%\scoop\shims\dufs.exe\" C:\sccache-cache -A -p 5000" /SC ONLOGON
```

— or accept restarting it manually after every reboot (the reference host does
the latter; then the Phase-D check below is what saves you). Verify:

```pwsh
(Invoke-WebRequest http://<host-LAN-IP>:5000 -Method Head -UseBasicParsing).StatusCode   # 200
[Environment]::GetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT','Machine')               # set (new shells inherit)
```

---

## Phase D — Per-boot / per-run checks

Run these before every chain launch (30 seconds; each one has cost a real run):

1. **dufs up + endpoint reachable?**
   `(Invoke-WebRequest $env:SCCACHE_WEBDAV_ENDPOINT -Method Head -UseBasicParsing).StatusCode`
   → 200. A reboot kills a manually-started dufs (cost a run on 2026-08-04).
2. **Services running?** `Get-Service stevedore, containerd, buildkitd` → all
   `Running`.
3. **Disk headroom ≥ 40 GB free — now gated automatically.**
   Both drivers refuse to start below the floor (`Assert-DiskHeadroom`;
   override with `-SkipHostChecks`, raise/lower with `-MinFreeGb`), and the
   BuildKit lane additionally verifies the patched runhcs shim is still
   installed (`Assert-ShimPatch` — a Stevedore update silently restores the
   stock binary, and the first heavy media finalize then dies with
   `ExportLayer 0x3` hours into the run). Both were manual checks here until
   2026-08-07; on 2026-08-06 a chain ran 2.5 h and died of a disk shortage
   disguised as a missing `ninja`.
   The disk gate checks **every drive the build uses** — C: (the layer stores)
   plus the repo checkout's drive, which on a VHDX-backed checkout has its own
   exhaustion mode that a C:-only check cannot see (§ VHDX-backed checkouts in
   [windows-builds.md](windows-builds.md)).
   The shim gate compares the live binary's **SHA256** against the hash
   `deploy-shim-patch.ps1` recorded when it installed the patch (state file:
   `C:\ProgramData\kataglyphis\shim-patch.json`); a Stevedore update overwriting
   the binary is then an unambiguous hard failure. Hosts that have not yet
   re-run the deploy script fall back to the older file-size heuristic and get a
   warning telling them so — **run `deploy-shim-patch.ps1` once to record the
   hash.** `-ReportOnly` prints the recorded hash and whether it still matches.
   `(Get-PSDrive C).Free / 1GB` — below ~25 GB free, hcsshim gets "weird"
   *before* an honest disk-full error (`ExportLayer 0x3`/`0x70`, spawn
   flakes). Reclaim levers, non-admin first: `buildctl prune --free-storage <MB>`
   (see the target trap below), then `buildctl prune-histories`,
   `buildctl prune --free-storage <MB>`, `docker image prune -f`; the full
   playbook is [Windows Build Image](windows-builds.md) § Store GC. Two traps
   that make the levers look broken: `--free-storage` is a **minimum-free
   target**, so it deletes nothing once the disk is already above it (ask for
   more free space than the disk has to drain everything unpinned), and a
   **superseded lineage** of stage tags can pin whole duplicate copies of the
   base spine — the biggest single reclaim measured on this host (266 GB).
   **If the checkout or the store lives on a dynamically-expanding VHDX**,
   the store levers cannot see the biggest pool: dead blocks in the VHDX
   itself (270 GB physical for 16 GB of data on the reference host). Check
   it — the report costs nothing and stops nothing:

   ```pwsh
   pwsh -File windows\scripts\compact-host-vhdx.ps1 -VhdxPath <your.vhdx> -ReportOnly   # admin
   ```

   Without `-ReportOnly` it stops the build services, compacts and restores
   the disk — **admin, and never while a build solves.** Read the ReFS
   caveat in § Store GC first: on ReFS guests compaction reclaims ~nothing,
   and the reclaim that does work is `rebuild-host-vhdx.ps1`, which rebuilds
   the disk around its live data. Run its `-CopyOnly` phase whenever you like
   — it touches nothing live — but the swap detaches the volume, so nothing
   may hold a handle on it: no shell sitting in the checkout, no editor, no
   agent session. Losing that volume mid-session is how a working session
   died on 2026-08-06.
4. **CNI subnet drift** — if dockerd/the host restarted since the last run,
   expect it; `build-buildkit.ps1`'s preflight fail-fasts with the exact fix
   (see Phase A5).
5. **Debug log size** — `C:\ProgramData\containerd\containerd-debug.log`
   grows unbounded; if it is huge, truncate (admin:
   `Clear-Content C:\ProgramData\containerd\containerd-debug.log`), never
   disable the flags.

---

## Phase E — First build + verification

### E1. Optional inputs, expectations

- **TensorRT (GPU lane, optional):** drop the NVIDIA EULA zip into
  `windows\downloads\` if you have one; **without it the build skips TensorRT
  gracefully** — the zip-less state is the normal state of the reference
  host's GPU lane (AGENTS.md § TensorRT Setup). Do not wait on it.
- **Cost:** cold full chain ≈ 5–6 h (≈ 2.5 h in the media fan-out); hot
  rebuild of the whole BK chain ≈ 44 min. Parallelism is memory-bound —
  ~35–45 % average CPU during compiles is the expected signature, not a
  fault ([Windows Build Image](windows-builds.md) § Maximum resource
  envelope; 32 CPU / 39 GB is the verified max on the 64 GB reference host).
- **Logs:** per-stage under `out\windows-build-logs\`.
- **Warm/materialize is normal:** heavy media libraries build in "warm"
  solves (no exported image) and materialize in a second calm solve — that
  two-step pattern in the log is the designed workaround for the host
  snapshotter defect, not a failure.
- **Transient retries are automatic:** the driver retries the known flake
  families (ActivateLayer 0x20, hcs-temp finalize/export). On any OTHER weird
  hcsshim failure: check free disk first (AGENTS.md § Common Failure Modes).

### E2. Launch (non-admin)

```pwsh
# endpoint via machine env (C5) or explicitly:
.\windows\build-buildkit.ps1 -Gpu                                    # full chain
.\windows\build-buildkit.ps1 -Gpu -SccacheEndpoint http://<LAN-IP>:5000
.\windows\build-buildkit.ps1 -Gpu -FinalTar out\bk-winamd64.tar      # + docker-loadable tar
```

The driver's preflight verifies buildkitd reachability and CNI subnet before
solving. Single-stage iteration: `-Stages toolchain` etc.

### E3. Verify the images exist (admin — containerd's pipe)

```pwsh
& "$env:ProgramFiles\Stevedore\bin\nerdctl.exe" --namespace buildkit images
# expect docker.io/local/kataglyphis:bk-winamd64 and the bk-windows-* stage tags
```

### E4. Smoke test — on the GPU lane ALWAYS pass -ExpectGpu

Without `-ExpectGpu`, a broken CUDA env is silently SKIPPED instead of failed
([Windows Build Image](windows-builds.md) § Smoke Testing). Two routes:

```pwsh
# (a) via docker after a -FinalTar export (loads as local/kataglyphis:winamd64):
& "$env:ProgramFiles\Stevedore\bin\docker.exe" load -i out\bk-winamd64.tar
& "$env:ProgramFiles\Stevedore\bin\docker.exe" run --memory 48g --rm --isolation process `
  local/kataglyphis:winamd64 pwsh -File C:\temp\scripts\smoke-test-container.ps1 -ExpectGpu

# (b) directly from the containerd store (admin shell):
& "$env:ProgramFiles\Stevedore\bin\nerdctl.exe" --namespace buildkit run --rm `
  docker.io/local/kataglyphis:bk-winamd64 pwsh -File C:\temp\scripts\smoke-test-container.ps1 -ExpectGpu
```

Expected: the § Smoke Testing baseline (167 passed / 0 failed / 1 skipped on
the GPU lane; the single skip is GPU device passthrough, blocked by host/base
OS-build skew).

### E5. Publish (optional, non-admin)

```pwsh
& "$env:ProgramFiles\Stevedore\bin\docker.exe" login ghcr.io      # once, same shell
.\windows\build-buildkit.ps1 -Gpu -PushRef ghcr.io/kataglyphis/kataglyphis_beschleuniger:winamd64
```

---

## Classic-lane fallback

If the BK lane is unavailable, `windows\build.ps1 -Gpu` (docker-classic,
Hyper-V run+commit) works with only Phases A, B and C4/C5 — see
[Windows Build Image](windows-builds.md) § Build Commands and § Stevedore
Setup Fixes.
