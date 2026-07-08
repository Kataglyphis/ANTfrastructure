# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Resolve-ContainerImageValue {
    param(
        [AllowEmptyString()]
        [string]$Value = '',
        [string]$EnvironmentVariable = '',
        [AllowEmptyString()]
        [string]$DefaultValue = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentVariable)) {
        $environmentValue = [Environment]::GetEnvironmentVariable($EnvironmentVariable)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
            return $environmentValue
        }
    }

    return $DefaultValue
}

function Initialize-ContainerImageTempDirectory {
    param(
        [string]$TempDir = 'C:\temp'
    )

    return (Resolve-DirectoryPath -Path $TempDir)
}

function Resolve-ContainerDirectoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Resolve-DirectoryPath -Path $Path)
}

function Resolve-ContainerNormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Resolve-NormalizedPath -Path $Path)
}

function Assert-ContainerPathExists {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$Description = $Path,

        [ValidateSet('Any', 'Leaf', 'Container')]
        [string]$PathType = 'Any'
    )

    $pathExists = switch ($PathType) {
        'Leaf' { Test-Path -LiteralPath $Path -PathType Leaf }
        'Container' { Test-Path -LiteralPath $Path -PathType Container }
        default { Test-Path -LiteralPath $Path }
    }

    if (-not $pathExists) {
        throw "${Description} not found at ${Path}"
    }

    return $Path
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

Export-ModuleMember -Function @(
    'Resolve-ContainerImageValue',
    'Initialize-ContainerImageTempDirectory',
    'Resolve-ContainerDirectoryPath',
    'Resolve-ContainerNormalizedPath',
    'Assert-ContainerPathExists',
    'Sync-ContainerProcessPath',
    'Assert-ContainerCommandAvailable',
    # Re-exported from WindowsScripts.Shared (imported above) so a caller gets these via a
    # single Import-Module -- no "import Shared last" ordering dance / nested -Force clobber.
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)
