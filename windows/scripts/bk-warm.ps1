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

$t0 = Get-Date
& $BuildScript @BuildArgs
$exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
if ($exitCode) { throw "bk-warm: build '$BuildScript' failed (exit $exitCode)" }

Import-Module (Join-Path $PSScriptRoot 'modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
Export-BuildHandoff -Since $t0 -Name $Name

# Reaching EOF IS success (same contract as every build script: pwsh -Command
# propagates the last native exit code otherwise).
exit 0
