# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

# Common helper functions for Windows build scripts
# These functions are shared across all WindowsXxx.Common.psm1 modules

<#
.SYNOPSIS
    Ensures a directory exists and returns its normalized path.
.DESCRIPTION
    Creates the directory if it does not exist and returns the fully resolved path.
.PARAMETER Path
    The path to ensure exists.
.OUTPUTS
    [string] The fully qualified path to the directory.
#>
function Resolve-DirectoryPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    return (Resolve-Path $Path).Path
}

<#
.SYNOPSIS
    Creates a formatted timestamp string.
.DESCRIPTION
    Returns a timestamp using the specified format (default ISO 8601).
.PARAMETER Format
    A .NET DateTime format string.
.OUTPUTS
    [string] The formatted timestamp.
#>
function New-Timestamp {
    param(
        [string]$Format = 'yyyy-MM-ddTHH:mm:ss'
    )

    return (Get-Date).ToString($Format)
}

<#
.SYNOPSIS
    Creates a timestamped file path.
.DESCRIPTION
    Combines a directory, optional prefix, timestamp, and extension into a file path.
.PARAMETER Directory
    The target directory.
.PARAMETER Prefix
    Optional file name prefix.
.PARAMETER Extension
    File extension (default: .log).
.PARAMETER Format
    Timestamp format (default: yyyyMMdd-HHmmss).
.OUTPUTS
    [string] The full path to the timestamped file.
#>
function New-TimestampedFilePath {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [string]$Prefix = '',
        [string]$Extension = '.log',
        [string]$Format = 'yyyyMMdd-HHmmss'
    )

    $ts = New-Timestamp -Format $Format
    $name = if ($Prefix) { "$Prefix-$ts$Extension" } else { "$ts$Extension" }
    return Join-Path $Directory $name
}

<#
.SYNOPSIS
    Normalizes a file system path.
.DESCRIPTION
    Returns a fully qualified, normalized path without trailing slashes.
.PARAMETER Path
    The path to normalize.
.OUTPUTS
    [string] The normalized path.
#>
function Resolve-NormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    return $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

<#
.SYNOPSIS
    Converts a value to a list of command-line parameters.
.DESCRIPTION
    Transforms hashtables, arrays, or strings into an array of strings suitable for process arguments.
    Switch parameters (boolean $true) produce only the key, $false values are omitted.
.PARAMETER Value
    The value to convert (hashtable, array, string, or other).
.PARAMETER Prefix
    Parameter prefix (default: '-').
.OUTPUTS
    [string[]] Array of argument strings.
#>
function ConvertTo-ParameterList {
    param(
        [Parameter(Mandatory)]
        $Value,
        [string]$Prefix = '-'
    )

    if ($null -eq $Value) { return @() }

    # If it's already an array, check for mixed types. Wrap the Where-Object result in
    # @() so .Count is safe on an empty pipeline under Set-StrictMode -Version Latest
    # (a bare `(...).Count` on the AutomationNull from an all-string array throws).
    if ($Value -is [array] -and $Value.Count -gt 0) {
        $allStrings = @($Value | Where-Object { $_ -isnot [string] }).Count -eq 0
        if ($allStrings) {
            return @($Value)
        }
        # Mixed types - convert all elements to strings
        return @($Value | ForEach-Object { "$_" })
    }

    # If it's a single string, return as single-element array
    if ($Value -is [string]) {
        return @($Value)
    }

    # If it's a hashtable, convert key-value pairs
    if ($Value -is [hashtable]) {
        $result = @()
        foreach ($key in $Value.Keys) {
            $v = $Value[$key]
            if ($null -eq $v) { continue }

            if ($v -is [bool]) {
                if ($v) {
                    $result += "$Prefix$key"
                }
                # false booleans are omitted
            } elseif ($v -is [array]) {
                foreach ($item in $v) {
                    $result += "$Prefix$key"
                    $result += "$item"
                }
            } else {
                $result += "$Prefix$key"
                $result += "$v"
            }
        }
        return $result
    }

    # Fallback: convert to string
    return @("$Value")
}

<#
.SYNOPSIS
    Resolves and validates a workspace path.
.DESCRIPTION
    Returns a fully qualified, normalized workspace path.
    Throws if the path does not exist.
.PARAMETER Path
    The workspace path to resolve.
.OUTPUTS
    [string] The resolved workspace path.
#>
function Resolve-WorkspacePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Workspace path does not exist: $Path"
    }
    return (Resolve-Path $Path).Path
}

Export-ModuleMember -Function @(
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'New-TimestampedFilePath',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList',
    'Resolve-WorkspacePath'
)

