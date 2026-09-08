# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Guarded, WITHOUT -Force (repo-wide nested-import rule): a forced nested
# re-import rebinds Shared into this module's private scope and unloads the
# caller's top-level import (the PS module-scoping trap).
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

function Resolve-ContainerImageValue {
    param(
        [AllowEmptyString()]
        [string]$Value = '',
        [string]$EnvironmentVariable = '',
        [AllowEmptyString()]
        [string]$DefaultValue = '',
        # Strip a single leading 'v' (tag style, e.g. 'v1.2.3' -> '1.2.3') from the
        # RESOLVED value. ADDITIVE: default behavior is unchanged; this exists so
        # every version gate (e.g. smoke-test's Get-ExpectedVersion) normalizes tags
        # through the same code path instead of re-implementing the trim.
        [switch]$TrimVPrefix
    )

    $resolved = $DefaultValue

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $resolved = $Value
    } elseif (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
        $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
            $resolved = $environmentValue
        }
    }

    if ($TrimVPrefix -and $null -ne $resolved) {
        $resolved = ([string]$resolved).TrimStart('v')
    }

    return $resolved
}

# Single source for the VS Build Tools root: Install-Vs.ps1 and the smoke test each
# probed for VsDevCmd.bat with their own (divergent) Program Files lists. Probes
# both PF roots, keyed on the file every caller actually needs (VsDevCmd.bat);
# honors VISUAL_STUDIO_VERSION with the same '18' fallback as Install-Vs.ps1.
# Returns the BuildTools root (string) or $null when not installed. ADDITIVE export.
function Resolve-VsBuildToolsRoot {
    param(
        [string]$VsMajor = ''
    )

    if ([string]::IsNullOrWhiteSpace($VsMajor)) {
        $VsMajor = if ($env:VISUAL_STUDIO_VERSION) { $env:VISUAL_STUDIO_VERSION } else { '18' }
    }

    foreach ($programFiles in @('C:\Program Files', 'C:\Program Files (x86)')) {
        $candidate = Join-Path $programFiles ("Microsoft Visual Studio\{0}\BuildTools" -f $VsMajor)
        if (Test-Path (Join-Path $candidate 'Common7\Tools\VsDevCmd.bat')) {
            return $candidate
        }
    }

    return $null
}

function Initialize-ContainerImageTempDirectory {
    param(
        [string]$TempDir = 'C:\temp'
    )

    return (Resolve-DirectoryPath -Path $TempDir)
}

function Clear-PendingFileHandle {
    # GC + finalizer drain + a no-op child process to flush lingering async file
    # handles before a docker layer commit (the CUDA installer leaves handles
    # behind that otherwise make the immediately-following Remove-Item/commit flaky).
    # BEST-EFFORT by contract: this flush must NEVER fail a build. A transient
    # process-spawn flake once surfaced as "'cmd.exe' is not recognized" under
    # EAP=Stop and killed a green sdk stage 4.5 min in (2026-08-03; cmd.exe and
    # PATH were verified healthy) — hence the full path + try/catch.
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    try {
        & (Join-Path $env:SystemRoot 'System32\cmd.exe') /c 'ver > nul' 2>&1 | Out-Null
    } catch {
        Write-Warning "Clear-PendingFileHandle: no-op child spawn failed ($($_.Exception.Message)) — continuing (best-effort flush)"
    }
    $global:LASTEXITCODE = 0
}

function Sync-ContainerProcessPath {
    param(
        [string[]]$AdditionalPaths = @()
    )

    $entries = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $addPathEntries = {
        param(
            [AllowEmptyString()]
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return
        }

        foreach ($entry in $Value -split ';') {
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }

            $expandedEntry = [Environment]::ExpandEnvironmentVariables($entry.Trim())
            if ([string]::IsNullOrWhiteSpace($expandedEntry)) {
                continue
            }

            $normalizedEntry = $expandedEntry.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
            if ($seen.Add($normalizedEntry)) {
                $entries.Add($expandedEntry)
            }
        }
    }

    & $addPathEntries $env:PATH

    foreach ($scope in @([EnvironmentVariableTarget]::Machine, [EnvironmentVariableTarget]::User)) {
        & $addPathEntries ([Environment]::GetEnvironmentVariable('Path', $scope))
    }

    foreach ($path in $AdditionalPaths) {
        & $addPathEntries $path
    }

    $resolvedPath = $entries.ToArray() -join ';'
    [Environment]::SetEnvironmentVariable('Path', $resolvedPath, 'Process')
    $env:PATH = $resolvedPath

    return $resolvedPath
}

function Assert-ContainerCommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command not found on PATH: $Name"
    }

    return $command.Source
}

<#
.SYNOPSIS
    The family CI container image reference, composed from ContainerHub's versions.env.
.DESCRIPTION
    The PowerShell twin of linux/scripts/ci-image-ref.sh, and the same contract:
    versions.env owns IMAGE_REGISTRY_PREFIX + CI_IMAGE_LINUX_TAG / CI_IMAGE_WINDOWS_TAG,
    the four container composite actions carry the composed value as their `image:`
    input DEFAULT, and this exists for the callers that cannot omit an input because
    they are not calling an action -- a local lane driver, a `docker run`, a sweep script.

    It takes NO consumer repo root, deliberately, where every other entry point in this
    repo does. versions.env is resolved from THIS module's own location, so the answer
    always comes from the ContainerHub the caller actually imported -- i.e. that
    consumer's pinned submodule. A -RepoRoot parameter would imply a per-consumer answer
    and there is not one; worse, it would let two roots disagree about one fleet.

    A missing key THROWS rather than returning an empty string: an empty image reference
    reaches `docker run` as "run the argument after it as an image" and fails a long way
    from the cause. Parsed, never sourced -- versions.env is inert KEY=value data.
.PARAMETER Windows
    Compose the Windows image reference instead of the Linux one.
.PARAMETER VersionsEnvPath
    Override the versions.env location. For tests; leave unset in production.
.OUTPUTS
    [string] e.g. 'ghcr.io/kataglyphis/kataglyphis_beschleuniger:latest-cross'
#>
function Get-CiImageReference {
    param(
        [switch]$Windows,
        [string]$VersionsEnvPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($VersionsEnvPath)) {
        $hubRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
        $VersionsEnvPath = Join-Path $hubRoot 'linux/scripts/01-core/versions.env'
    }

    if (-not (Test-Path -LiteralPath $VersionsEnvPath -PathType Leaf)) {
        throw ("ContainerHub versions.env not found at $VersionsEnvPath. " +
            'If the whole directory is missing, the submodule is not checked out: ' +
            'git submodule update --init --recursive third_party/ContainerHub')
    }

    $versions = ConvertFrom-VersionsEnv -Path $VersionsEnvPath
    $tagKey = if ($Windows) { 'CI_IMAGE_WINDOWS_TAG' } else { 'CI_IMAGE_LINUX_TAG' }

    foreach ($key in @('IMAGE_REGISTRY_PREFIX', $tagKey)) {
        if (-not $versions.Contains($key) -or [string]::IsNullOrWhiteSpace($versions[$key])) {
            throw ("$key is not set in $VersionsEnvPath. That file is the fleet-wide owner " +
                'of the CI image tags; a missing key means the ContainerHub pin predates ' +
                'the convention.')
        }
    }

    return ('{0}:{1}' -f $versions['IMAGE_REGISTRY_PREFIX'], $versions[$tagKey])
}

Export-ModuleMember -Function @(
    'Resolve-ContainerImageValue',
    'Resolve-VsBuildToolsRoot',
    'Initialize-ContainerImageTempDirectory',
    'Clear-PendingFileHandle',
    'Sync-ContainerProcessPath',
    'Assert-ContainerCommandAvailable',
    'Get-CiImageReference',
    # Re-exported from WindowsScripts.Shared (imported above) so a caller gets these via a
    # single Import-Module -- no "import Shared last" ordering dance / nested -Force clobber.
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    'ConvertFrom-VersionsEnv',
    'Expand-ArchiveSubdirectory'
)

