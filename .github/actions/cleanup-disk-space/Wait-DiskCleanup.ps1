#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Blocks until cleanup-disk-space's background run has ended, prints its log, and never fails the job it only serves.

[CmdletBinding()]
param(
    # Where the background run keeps disk-cleanup.{pid,log,err.log,done}.
    [string]$StateDir = $env:RUNNER_TEMP,
    [double]$TimeoutMinutes = 60,
    [double]$PollSeconds = 2
)

$ErrorActionPreference = 'Continue'

function Get-StatePath([string]$Name) { Join-Path $StateDir "disk-cleanup.$Name" }

# The start time rules out a recycled pid.
function Test-CleanupAlive([string]$PidLine) {
    $parts = @($PidLine.Trim() -split '\s+')
    if ($parts.Count -lt 2) { return $false }
    $proc = Get-Process -Id ([int]$parts[0]) -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return $false }
    return ($proc.StartTime.ToUniversalTime().Ticks -eq [long]$parts[1])
}

$pidFile = Get-StatePath 'pid'
if (-not $StateDir -or -not (Test-Path -LiteralPath $pidFile)) {
    Write-Host 'No background disk cleanup to wait for.'
    exit 0
}

$pidLine = Get-Content -LiteralPath $pidFile -Raw
$doneFile = Get-StatePath 'done'
$start = Get-Date
$deadline = $start.AddMinutes($TimeoutMinutes)
$timedOut = $false
while (-not (Test-Path -LiteralPath $doneFile) -and (Test-CleanupAlive $pidLine)) {
    if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
    Start-Sleep -Seconds $PollSeconds
}
$waited = [int]((Get-Date) - $start).TotalSeconds

Write-Host '::group::background disk cleanup log'
foreach ($name in 'log', 'err.log') {
    $f = Get-StatePath $name
    if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f | ForEach-Object { Write-Host $_ } }
}
Write-Host '::endgroup::'

if (Test-Path -LiteralPath $doneFile) {
    Write-Host "background disk cleanup done ($((Get-Content -LiteralPath $doneFile -Raw).Trim())); waited $waited s for it"
} elseif ($timedOut) {
    Write-Host "::warning::The background disk cleanup is still running after $TimeoutMinutes min; the job goes on beside it."
} else {
    Write-Host '::warning::The background disk cleanup exited without its done marker; its log is above.'
}

Set-Content -LiteralPath (Get-StatePath 'waited') -Value "$waited"
Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value 'ANTF_DISK_CLEANUP=done' }
exit 0
