#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# cleanup-disk-space's hide mode: the PATH entries under its removal roots leave PATH for the job's later steps; nothing is deleted.

[CmdletBinding()]
param(
    # The directories the cleanup deletes; a root may hold a wildcard (C:\hostedtoolcache\Python\*\x86).
    [Parameter(Mandatory)][string[]]$Roots,
    [string]$PathValue = $env:PATH,
    [string]$EnvFile = $env:GITHUB_ENV
)

$ErrorActionPreference = 'Stop'

# Under a root means the root itself or below it, never a sibling that shares its prefix (C:\tools\boost2).
function Test-UnderRoot([string]$Entry) {
    $e = [Environment]::ExpandEnvironmentVariables($Entry).TrimEnd('\')
    foreach ($root in $Roots) {
        $r = $root.TrimEnd('\')
        if ($e -like $r -or $e -like "$r\*") { return $true }
    }
    return $false
}

if (-not $EnvFile) { throw 'GITHUB_ENV is not set, so a shorter PATH cannot reach the later steps' }

$entries = @($PathValue -split ';' | Where-Object { $_ })
$kept = @($entries | Where-Object { -not (Test-UnderRoot $_) })
$hidden = @($entries | Where-Object { Test-UnderRoot $_ })
foreach ($h in $hidden) { Write-Host "  off PATH: $h" }
Write-Host "cleanup-disk-space hide: $($hidden.Count) of $($entries.Count) PATH entries lie under a directory the cleanup deletes; nothing was deleted."
Add-Content -LiteralPath $EnvFile -Value "PATH=$($kept -join ';')"
