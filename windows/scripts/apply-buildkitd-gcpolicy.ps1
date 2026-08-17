#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Deploys windows\buildkitd.toml to C:\ProgramData\buildkitd\buildkitd.toml,
# re-registers the buildkitd service with an explicit --config flag (keeping
# --debug — permanent owner decision, see AGENTS.md) and restarts it.
#
# RUN FROM AN ADMIN SHELL, and NEVER while a build is running — the service
# restart kills every in-flight solve. The script refuses if it sees a live
# buildctl process unless -Force is passed.
#
# Verify afterwards: buildctl debug workers -v  (GC Policy rules must show
# reservedSpace=200GB — not the computed defaults maxUsedSpace=100GB /
# minFreeSpace=187GB that caused the 2026-08-04 VS-layer eviction).

[CmdletBinding()]
param(
    [string]$ConfigDest = 'C:\ProgramData\buildkitd\buildkitd.toml',
    # Skip the live-build guard (you are SURE nothing is solving right now).
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an elevated (admin) shell: service re-registration needs it.'
}

$src = Join-Path (Split-Path $PSScriptRoot -Parent) 'buildkitd.toml'
if (-not (Test-Path $src)) { throw "repo config not found: $src" }

if (-not $Force) {
    $live = @(Get-Process buildctl -ErrorAction SilentlyContinue)
    if ($live.Count -gt 0) {
        throw ("{0} live buildctl process(es) found (pids: {1}) — a service restart kills their solves. " -f $live.Count, (($live | ForEach-Object Id) -join ', ')) +
            'Wait for the build to finish, or pass -Force if they are stale.'
    }
}

$svc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\buildkitd' -ErrorAction Stop
$binPath = $svc.ImagePath
Write-Host "current ImagePath: $binPath"

New-Item -ItemType Directory -Force -Path (Split-Path $ConfigDest -Parent) | Out-Null
Copy-Item $src $ConfigDest -Force
Write-Host "deployed $src -> $ConfigDest"

if ($binPath -notmatch '--config') {
    # Insert --config right after the exe path, preserving every existing flag
    # (--debug stays — owner decision). ImagePath format: "C:\...\buildkitd.exe" --debug --run-service ...
    if ($binPath -match '^(?<exe>"[^"]+"|\S+)\s*(?<rest>.*)$') {
        $newBin = '{0} --config {1} {2}' -f $Matches['exe'], $ConfigDest, $Matches['rest']
    } else {
        throw "cannot parse ImagePath: $binPath"
    }
    Write-Host "re-registering: $newBin"
    & sc.exe config buildkitd binPath= $newBin | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed (exit $LASTEXITCODE)" }
} else {
    Write-Host '--config already present in ImagePath; config file replaced in place.'
}

# -Force: without it Restart-Service refuses when dependent services hang off
# buildkitd (reported live 2026-08-05); -Force stops/restarts them along.
Restart-Service buildkitd -Force
Write-Host 'buildkitd restarted.' -ForegroundColor Green

# Show the effective GC rules so the change is verifiable at a glance.
# Inline ON PURPOSE (#101 reviewed 2026-08-17): elevated repair/maintenance
# tool — keep it module-free so it works with a half-broken checkout. Same
# rationale as probe-build-copy and reset-container-locks.
$buildctl = @("$env:ProgramFiles\Stevedore\bin\buildctl.exe", 'D:\Stevedore\bin\buildctl.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($buildctl) {
    & $buildctl debug workers -v 2>&1 | Select-String -Pattern 'GC Policy|reserved|maxUsedSpace|minFreeSpace|keepDuration|all=|filters' | ForEach-Object { $_.Line } | Write-Host
} else {
    Write-Host 'buildctl not found for verification — run: buildctl debug workers -v' -ForegroundColor Yellow
}
