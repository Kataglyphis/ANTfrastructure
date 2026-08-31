# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# GUARDED, without -Force (ROOT FIX 2026-08-05): this script is `&`-invoked
# FROM MODULE SCOPE by Import-CanonicalVersions, and a forced re-import from
# there unloads the CALLER's top-level Shared and rebinds it into the module's
# private session state — Shared exports (Resolve-DirectoryPath & friends)
# went CommandNotFound at the caller's top level and killed the gstreamer
# merge-warm solve twice. The entry-script case (Dockerfile.base's bake RUN,
# fresh pwsh) still imports normally: nothing is loaded there yet. See
# AGENTS.md invariant "-Force only at ENTRY-script top level".
# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedModulePath }

# TEMP_DIR is baked container ENV; on a host shell it may be unset — skip
# instead of letting Join-Path throw under EAP=Stop (found by the 2026-08-05
# root-fix repro).
if ([string]::IsNullOrWhiteSpace($env:TEMP_DIR)) {
    Write-Host 'TEMP_DIR not set -- skipping versions.env load'
    return
}
$versionsFile = Join-Path $env:TEMP_DIR 'versions.env'
if (-not (Test-Path $versionsFile)) {
    Write-Host 'versions.env not found -- skipping'
    return
}

# PRECEDENCE (2026-08-07): a value already in the PROCESS environment WINS over
# the file. In a container RUN the process environment is where Dockerfile
# ARG/ENV values live — i.e. the values the driver just forwarded from the
# CURRENT versions.env — while the file on disk may be the copy baked into the
# base image at ITS build time. Overwriting unconditionally (the old behaviour)
# meant the stale file silently beat the fresh args, which is exactly why every
# media stage had to re-COPY versions.env, and that re-COPY is what made any pin
# edit invalidate the whole media chain (~75 min of ONNX for a Windows-only
# LLVM pin, measured today).
#
# With the file demoted to a gap-filler, the COPY can go and each branch gets
# its versions as build-args instead — see Get-MediaBranchVersionArg.
#
# The BASE build is unaffected: nothing sets these in its process environment at
# that point, so every key still gets baked into the Machine environment there.
# An explicit override on the command line now also survives, which is the
# behaviour one would expect anyway.
Write-Host "Loading versions from: $versionsFile"
$versions = ConvertFrom-VersionsEnv -Path $versionsFile
# DISCRIMINATOR (refined 2026-08-07, same day, after watching it run): "already
# in the process environment" is NOT the same as "explicitly provided". The base
# image bakes every versions.env key into the MACHINE environment, and a Windows
# container inherits that into every process — so a naive process-env check kept
# all 116 keys and silently disabled the refresh path for the ~106 that no
# Dockerfile ARG covers.
#
# A Dockerfile ARG/ENV override is distinguishable: it makes the PROCESS value
# differ from the MACHINE value. Inherited-but-not-overridden keys are identical
# in both, and those the file may still refresh — which is what preserves the
# original purpose of this script inside a container.
$kept = 0
foreach ($name in $versions.Keys) {
    $value = $versions[$name]
    $fromProcess = [Environment]::GetEnvironmentVariable($name, 'Process')
    $fromMachine = [Environment]::GetEnvironmentVariable($name, 'Machine')
    $isExplicitOverride = (-not [string]::IsNullOrWhiteSpace($fromProcess)) -and ($fromProcess -ne $fromMachine)
    if ($isExplicitOverride) {
        # PERSIST the winning value (2026-08-19): an override wins the RUN
        # *and* gets baked. Leaving Machine untouched silently un-baked the
        # nine #50 ARG-mirrored keys from the BASE image itself - the base
        # stage declares them as ARGs before this bake RUN, so during the
        # bake they sit in the process env, Machine is empty, and this
        # branch skipped them (SCCACHE_GIT_REV missing from every post-#50
        # image; probes grew a C:\temp\versions.env fallback). The image
        # should record what it was actually built with.
        [Environment]::SetEnvironmentVariable($name, $fromProcess, 'Machine')
        if ($fromProcess -ne $value) {
            Write-Host "  $name = $fromProcess  (kept + baked: build-arg/ENV beats the file's '$value')"
        }
        $kept++
        continue
    }
    [Environment]::SetEnvironmentVariable($name, $value, 'Machine')
    [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    Write-Host "  $name = $value"
}
Write-Host "versions.env loaded ($kept key(s) explicitly overridden by build-arg/ENV and left untouched)"

