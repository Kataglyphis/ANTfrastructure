#requires -Version 7.0
<#
.SYNOPSIS
    Shared host-side runner for the diagnostic probe Dockerfiles
    (backlog #102 — replaces the near-identical bodies of
    Invoke-SccacheWriteProbe.ps1 and Invoke-OpencvVideoProbe.ps1).

.DESCRIPTION
    Solves a probe Dockerfile via buildctl, Tees the full output to
    out\windows-build-logs\, prints the verdict lines, and FAILS CLOSED when the
    probe did not actually execute.

    The fail-closed machinery lives here and ONLY here on purpose. Both pieces
    were bugs once, and both got fixed twice in parallel while the runners were
    clones:
      * PROBE_NONCE — without a unique value per invocation the RUN is served
        from the layer cache (`#6 CACHED`) and the runner reprints an OLD
        verdict as if it were a fresh measurement. `--no-cache` is NOT the
        alternative: on this lane it EMPTIES the cache mounts (backlog #96).
      * `probe complete` marker — a solve can succeed with the probe never
        executing; without the marker check that reads as a clean run.

.PARAMETER ProbeScript
    Script under windows/scripts/diagnostics/ (e.g. Test-Sccache2726Repro.ps1,
    or archive/probe-x.ps1). Runs it through the shared Dockerfile.probe —
    the normal way to run a probe since the 2026-08-21 consolidation.

.PARAMETER Dockerfile
    Filename under windows/ (e.g. Dockerfile.sccache-write-probe) — only for
    the few probes with a bespoke Dockerfile (special ENV/mount shapes).
    Mutually exclusive with -ProbeScript.

.PARAMETER BaseImage
    Image the probe runs against. Probes measure a specific artifact — pass the
    image the question is ABOUT, not whatever happens to be newest.

.PARAMETER BuildArg
    Extra KEY=VALUE build-args (array). PROBE_NONCE is always added here.

.PARAMETER VerdictPattern
    Regex for the "--- verdict lines ---" summary printed after the solve.

.PARAMETER LogName
    Log filename under out\windows-build-logs\.
#>
[CmdletBinding()]
param(
    [string]$ProbeScript = '',
    [string]$Dockerfile = '',
    [Parameter(Mandatory)][string]$BaseImage,
    [string[]]$BuildArg = @(),
    [string]$VerdictPattern = '\[ OK \]|\[FAIL\]',
    [string]$LogName = '',
    [string]$BuildCtl = ''
)

$ErrorActionPreference = 'Stop'
# THREE levels up: this script lives at windows\scripts\diagnostics\.
#
# It was two until 2026-08-23. #108 (473e4359, "windows/scripts directory
# convention - build/ host/ diagnostics/") moved the file one level deeper and
# did not update this line, so $repoRoot became <repo>\windows and every solve
# since then passed --local dockerfile=<repo>\windows\windows -- a doubled
# segment that fails with "invalid local: resolve ... The system cannot find the
# file specified". That is every probe through this shared runner.
#
# The assertion below is the actual fix: counting levels is what broke, so the
# result is now VERIFIED against a file that only exists at the real repo root.
# A future move fails here with one clear line instead of a cryptic buildctl
# path error.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not (Test-Path (Join-Path $repoRoot 'windows\Dockerfile.probe'))) {
    throw ("repo root resolved to '$repoRoot', which does not contain windows\Dockerfile.probe. " +
           'This script moved without its level count being updated - fix the Split-Path chain above.')
}

if ([string]::IsNullOrWhiteSpace($ProbeScript) -eq [string]::IsNullOrWhiteSpace($Dockerfile)) {
    throw 'pass exactly ONE of -ProbeScript (shared Dockerfile.probe) or -Dockerfile (bespoke probe Dockerfile)'
}
if ($ProbeScript) {
    # $PSScriptRoot IS the diagnostics dir (repo layout) or the flat mount —
    # no re-derivation, same dual-layout rule as the resolver below (#108).
    $probePath = Join-Path $PSScriptRoot $ProbeScript
    if (-not (Test-Path $probePath)) { throw "-ProbeScript '$ProbeScript' not found at $probePath" }
    $Dockerfile = 'Dockerfile.probe'
    $BuildArg = @("PROBE_SCRIPT=$ProbeScript") + $BuildArg
    if (-not $LogName) { $LogName = (Split-Path $ProbeScript -Leaf) -replace '\.ps1$', '.log' }
}

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
# Central candidate walk instead of the pasted Stevedore-then-PATH block that
# used to live in every runner (backlog #101).
if (-not $BuildCtl) {
    $BuildCtl = Get-PreferredToolPath -CommandName 'buildctl' -CandidatePaths @(
        "$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe')
}
if (-not $BuildCtl) { throw 'buildctl.exe not found (Stevedore bin or PATH).' }

if (-not $LogName) { $LogName = ($Dockerfile -replace '^Dockerfile\.', '') + '.log' }
$logDir = Join-Path $repoRoot 'out\windows-build-logs'
$null = New-Item -ItemType Directory -Force -Path $logDir
$log = Join-Path $logDir $LogName

$bkArgs = @(
    'build',
    '--frontend', 'dockerfile.v0',
    '--local', "context=$repoRoot",
    '--local', "dockerfile=$repoRoot\windows",
    '--opt', "filename=$Dockerfile",
    '--opt', 'image-resolve-mode=local',
    '--opt', "build-arg:BASE_IMAGE=$BaseImage",
    '--opt', "build-arg:PROBE_NONCE=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())",
    '--progress', 'plain'
)
foreach ($extra in $BuildArg) {
    if ($extra -notmatch '^[^=]+=') { throw "-BuildArg '$extra' is not in KEY=VALUE form" }
    $bkArgs += @('--opt', "build-arg:$extra")
}
# No --output: a probe's product is its stdout, not an image.

Write-Host "==> buildctl ($Dockerfile, base=$BaseImage) -> $log" -ForegroundColor Cyan
& $BuildCtl @bkArgs 2>&1 | Tee-Object -FilePath $log
$code = $LASTEXITCODE

Write-Host "`n--- verdict lines ---" -ForegroundColor Cyan
Select-String -Path $log -Pattern $VerdictPattern | ForEach-Object { '  ' + $_.Line.Trim() }

Write-Host "`nfull log: $log"
if ($code -ne 0) { throw "probe solve failed (exit $code) - see $log" }
if (-not (Select-String -Path $log -Pattern 'probe complete' -Quiet)) {
    throw "probe did not execute (no 'probe complete' marker) - the RUN was likely CACHED; see $log"
}
