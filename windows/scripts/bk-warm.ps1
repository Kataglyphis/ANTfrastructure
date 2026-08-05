# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# WARM-solve payload for the BuildKit lane (see docs/windows-builds.md
# § BuildKit/containerd lane): runs a heavy build, then hands its artifact
# delta off over WebDAV (Export-BuildHandoff). The driver runs the enclosing
# solve with NO exporter, so this container's snapshot is never finalized and
# the host's lost-shutdown-notification defect never fires. This script exists
# so every warm RUN in the Dockerfiles is a one-liner instead of a repeated
# five-statement pwsh block.

#requires -Version 7.0
[CmdletBinding()]
param(
    # Handoff name (tar becomes <endpoint>/bkhandoff/<Name>.tar).
    [Parameter(Mandatory)][string]$Name,
    # The build entry point to run before exporting.
    [Parameter(Mandatory)][string]$BuildScript,
    # Arguments for the build entry point, e.g. '-ResumeFrom','OpenCV'.
    [string[]]$BuildArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 0x3-ROOT-CAUSE PROBE (2026-08-05, best-effort): the shim injects
# WaitToKillServiceTimeout=2147483647 (infinite) into every container —
# containerd debug log shows heavy containers' HCS shutdown notifications
# time out even after a settled exit, i.e. SOME in-container service hangs
# shutdown forever. Override to 5s so shutdown force-kills laggard services
# inside its 30s window; the pre-exit dump below names running services so
# the culprit can be identified and stopped explicitly once known.
try {
    foreach ($cs in 'HKLM:\SYSTEM\CurrentControlSet\Control', 'HKLM:\SYSTEM\ControlSet001\Control') {
        Set-ItemProperty -Path $cs -Name 'WaitToKillServiceTimeout' -Value '5000' -ErrorAction Stop
    }
    Write-Host 'bk-warm probe: WaitToKillServiceTimeout -> 5000ms'
} catch { Write-Host "bk-warm probe: WaitToKillServiceTimeout override failed: $($_.Exception.Message)" }

$t0 = Get-Date
# Child pwsh with -File, NOT `& $BuildScript @BuildArgs`: array splatting binds
# strictly BY POSITION, so a leading-dash element like '-ResumeFrom' arrives as
# the VALUE of parameter 1 ("positional parameter cannot be found" under
# CmdletBinding). -File re-parses the argv into named parameters.
& pwsh -NoProfile -ExecutionPolicy Bypass -File $BuildScript @BuildArgs
$exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
if ($exitCode) { throw "bk-warm: build '$BuildScript' failed (exit $exitCode)" }

# No -DisableNameChecking: every exported function uses an approved verb (the
# three build-*-all wrappers import this module bare and warn-free).
Import-Module (Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1') -Force
Export-BuildHandoff -Since $t0 -Name $Name

# Pre-exit diagnostics (best-effort): running services + non-baseline
# processes at the moment of exit — the shutdown-hang culprit must be in
# this list (compare a hanging exit's dump vs a clean one's).
try {
    $svc = Get-Service | Where-Object { $_.Status -eq 'Running' } | Select-Object -ExpandProperty Name
    Write-Host ("bk-warm exit dump: running services: " + ($svc -join ', '))
    $procs = Get-Process | Where-Object { $_.ProcessName -notin @('pwsh', 'Idle', 'System', 'smss', 'csrss', 'wininit', 'services', 'lsass', 'svchost', 'fontdrvhost', 'CExecSvc', 'conhost') } | Select-Object -ExpandProperty ProcessName -Unique
    Write-Host ("bk-warm exit dump: non-baseline processes: " + ($procs -join ', '))
} catch { Write-Host "bk-warm exit dump failed: $($_.Exception.Message)" }

# Reaching EOF IS success (same contract as every build script: pwsh -Command
# propagates the last native exit code otherwise).
exit 0
