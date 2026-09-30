# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Guarded, no -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

function Resolve-ContainerImageValue {
    param(
        [AllowEmptyString()]
        [string]$Value = '',
        [string]$EnvironmentVariable = '',
        [AllowEmptyString()]
        [string]$DefaultValue = '',
        # Strip a leading 'v' from the resolved value, so every version gate trims tags the same way.
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

# One probe for Install-Vs.ps1 and the smoke test, so they cannot disagree on the Program Files roots.
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
    # Flushes installer-held handles before a layer commit; best-effort, since a spawn flake must never fail a build.
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
    The family CI container image reference, composed from ANTfrastructure's versions.env.
.DESCRIPTION
    Twin of linux/scripts/ci-image-ref.sh. No -RepoRoot: the answer comes from the ANTfrastructure the caller imported.
    A missing key throws, as an empty ref fails far from the cause in `docker run`.
.PARAMETER Windows
    Compose the Windows image reference instead of the Linux one.
.PARAMETER TargetArch
    With -Windows, arm64 composes the arm64 cross bundle; refused without -Windows.
.PARAMETER VersionsEnvPath
    Override the versions.env location. For tests; leave unset in production.
.OUTPUTS
    [string] '<IMAGE_REGISTRY_PREFIX>:<tag>'; no sample here, as verify_ci_image_refs.py reads comments too.
#>
function Get-CiImageReference {
    param(
        [switch]$Windows,
        [ValidateSet('amd64', 'arm64')][string]$TargetArch = 'amd64',
        [string]$VersionsEnvPath = ''
    )
    if ($TargetArch -eq 'arm64' -and -not $Windows) { throw '-TargetArch arm64 needs -Windows: only Windows has an arm64 cross bundle' }

    if ([string]::IsNullOrWhiteSpace($VersionsEnvPath)) {
        $hubRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
        $VersionsEnvPath = Join-Path $hubRoot 'linux/scripts/01-core/versions.env'
    }

    if (-not (Test-Path -LiteralPath $VersionsEnvPath -PathType Leaf)) {
        throw ("ANTfrastructure versions.env not found at $VersionsEnvPath. " +
            'If the whole directory is missing, the submodule is not checked out: ' +
            'git submodule update --init --recursive third_party/ANTfrastructure')
    }

    $versions = ConvertFrom-VersionsEnv -Path $VersionsEnvPath
    $tagKey = if (-not $Windows) { 'CI_IMAGE_LINUX_TAG' } elseif ($TargetArch -eq 'arm64') { 'CI_IMAGE_WINDOWS_ARM64_TAG' } else { 'CI_IMAGE_WINDOWS_TAG' }

    foreach ($key in @('IMAGE_REGISTRY_PREFIX', $tagKey)) {
        if (-not $versions.Contains($key) -or [string]::IsNullOrWhiteSpace($versions[$key])) {
            throw ("$key is not set in $VersionsEnvPath. That file is the fleet-wide owner " +
                'of the CI image tags; a missing key means the ANTfrastructure pin predates ' +
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
    # Re-exported from WindowsScripts.Shared, so one Import-Module suffices.
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    'ConvertFrom-VersionsEnv',
    'Expand-ArchiveSubdirectory'
)

