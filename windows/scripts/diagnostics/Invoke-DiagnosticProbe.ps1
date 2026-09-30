#requires -Version 7.0
<#
.SYNOPSIS
    Shared host-side runner for the diagnostic probe Dockerfiles; fails closed when the probe did not execute.
.DESCRIPTION
    A fresh PROBE_NONCE stops a CACHED replay of an old verdict (--no-cache would empty the cache mounts).
    A solve without the 'probe complete' marker fails, since a probe that never ran would read as clean.
.PARAMETER ProbeScript
    Script under windows/scripts/diagnostics/, run through Dockerfile.probe; it must be in the build context.
.PARAMETER Dockerfile
    Bespoke probe Dockerfile under windows/; mutually exclusive with -ProbeScript.
.PARAMETER BaseImage
    The image the question is about, not whatever happens to be newest.
.PARAMETER BuildArg
    Extra KEY=VALUE build-args; PROBE_NONCE is always added.
.PARAMETER VerdictPattern
    Regex for the verdict lines printed after the solve.
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
# Three levels up, verified against a repo-root file so a future move fails here, not in buildctl.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not (Test-Path (Join-Path $repoRoot 'windows\Dockerfile.probe'))) {
    throw ("repo root resolved to '$repoRoot', which does not contain windows\Dockerfile.probe. " +
           'This script moved without its level count being updated - fix the Split-Path chain above.')
}

if ([string]::IsNullOrWhiteSpace($ProbeScript) -eq [string]::IsNullOrWhiteSpace($Dockerfile)) {
    throw 'pass exactly ONE of -ProbeScript (shared Dockerfile.probe) or -Dockerfile (bespoke probe Dockerfile)'
}
if ($ProbeScript) {
    # $PSScriptRoot is the diagnostics dir in both layouts.
    $probePath = Join-Path $PSScriptRoot $ProbeScript
    if (-not (Test-Path $probePath)) { throw "-ProbeScript '$ProbeScript' not found at $probePath" }
    $Dockerfile = 'Dockerfile.probe'
    $BuildArg = @("PROBE_SCRIPT=$ProbeScript") + $BuildArg
    if (-not $LogName) { $LogName = (Split-Path $ProbeScript -Leaf) -replace '\.ps1$', '.log' }
}

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
Import-Module (Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1') -Force
$BuildCtl = Resolve-BuildCtlPath -BuildCtl $BuildCtl

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
