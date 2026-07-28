# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

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

function Invoke-DownloadWithRetry {
    <#
    .SYNOPSIS
        Download a URL to a file with retries + exponential backoff.
    .DESCRIPTION
        Hardened replacement for the raw Invoke-WebRequest / WebClient.DownloadFile calls
        scattered across the build + setup scripts, any one of which could fail the whole
        multi-hour build on a single transient network blip. Uses System.Net.WebClient (no
        curl-on-PATH assumption; follows redirects), TLS 1.2, a browser User-Agent, optional
        extra headers, and validates the result is non-empty. Retries MaxAttempts times with
        exponential backoff (InitialDelaySeconds, doubling, capped at 30s), removing a
        partial file between attempts, and throws after the last attempt.

        Testable offline via file:// URLs (WebClient supports them), so the retry/verify
        logic is covered without network access.
    .PARAMETER Url
        Source URL (http/https, or file:// in tests).
    .PARAMETER DestinationPath
        Full path to write to (parent directory is created if missing).
    .PARAMETER MaxAttempts
        Total attempts before giving up (default 4).
    .PARAMETER InitialDelaySeconds
        Backoff before the 2nd attempt; doubles each retry, capped at 30 (default 3).
        Tests pass 0 to avoid sleeping.
    .PARAMETER Headers
        Optional extra request headers (name -> value).
    .PARAMETER Description
        Human label for the log lines (defaults to the URL).
    .PARAMETER ExpectSignature
        Optional magic-byte guard: 'MZ' (PE .exe/.dll) or 'PK' (ZIP container). A response
        whose first bytes don't match (e.g. an HTML error page served by a flaky aka.ms/CDN
        redirect in place of the binary) is rejected and RETRIED like any transient failure --
        the exact HTML-instead-of-binary class that broke CPython's nuget bootstrap.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 3,
        [hashtable]$Headers = @{},
        [string]$Description = '',
        [ValidateSet('', 'MZ', 'PK')][string]$ExpectSignature = ''
    )
    $label = if ([string]::IsNullOrWhiteSpace($Description)) { $Url } else { $Description }
    $destDir = Split-Path -Parent $DestinationPath
    if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    $delay = $InitialDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            try {
                $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)')
                foreach ($k in $Headers.Keys) { $wc.Headers.Add($k, $Headers[$k]) }
                $wc.DownloadFile($Url, $DestinationPath)
            } finally { $wc.Dispose() }
            if ((Test-Path $DestinationPath) -and ((Get-Item $DestinationPath).Length -gt 0)) {
                if ($ExpectSignature) {
                    $fs = [System.IO.File]::OpenRead($DestinationPath)
                    try { $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte() } finally { $fs.Dispose() }
                    $sigOk = switch ($ExpectSignature) {
                        'MZ' { ($b0 -eq 0x4D) -and ($b1 -eq 0x5A) }   # PE executable (.exe / .dll)
                        'PK' { ($b0 -eq 0x50) -and ($b1 -eq 0x4B) }   # ZIP container (.zip)
                    }
                    if (-not $sigOk) { throw "expected a $ExpectSignature-signature file but got first bytes ${b0},${b1} (likely an HTML error page served in place of the binary)" }
                }
                if ($attempt -gt 1) { Write-Host "  download OK on attempt ${attempt}: $label" }
                return
            }
            throw 'downloaded file is missing or empty'
        } catch {
            $msg = $_.Exception.Message
            if (Test-Path $DestinationPath) { Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue }
            if ($attempt -ge $MaxAttempts) { throw "Download failed after $MaxAttempts attempt(s) [$label]: $msg" }
            Write-Host "  download attempt $attempt/$MaxAttempts failed [$label]: $msg -- retrying in ${delay}s"
            if ($delay -gt 0) { Start-Sleep -Seconds $delay }
            $delay = [Math]::Min($delay * 2, 30)
        }
    }
}

<#
.SYNOPSIS
    Parses a versions.env file into an ordered key/value dictionary.
.DESCRIPTION
    Canonical parser for the repo's single source of truth
    (linux/scripts/01-core/versions.env): blank lines and #-comments are skipped,
    each remaining line is split on the FIRST '=', keys/values are trimmed and
    surrounding quotes stripped from values. Replaces the hand-rolled copies that
    used to live in load-versions.ps1, build.ps1, smoke-test-container.ps1 and
    Test-PatchesApplyClean.ps1.
.PARAMETER Path
    Path to the versions.env file (must exist).
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] key -> value in file order.
    NOTE: membership test is .Contains($key) -- OrderedDictionary has no .ContainsKey.
#>
function ConvertFrom-VersionsEnv {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $versions = [ordered]@{}
    foreach ($rawLine in (Get-Content $Path)) {
        $line = $rawLine.Trim()
        if (-not $line -or $line -match '^#') { continue }
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $versions[$parts[0].Trim()] = $parts[1].Trim().Trim('"', "'")
        }
    }
    return $versions
}

<#
.SYNOPSIS
    Expands a .zip archive and returns the top-level directory it unpacked to.
.DESCRIPTION
    Shared "extract, then locate the versioned subdirectory" pattern used by the
    vcpkg / cuDNN / TensorRT setup scripts (each archive wraps its payload in a
    single versioned root folder). Creates DestinationPath when missing, expands
    the archive into it, and returns the full path of the first directory matching
    Filter -- or $null when none matches (the caller decides whether that is
    fatal; TensorRT legitimately ships flat-layout zips).
.PARAMETER ArchivePath
    Path to the .zip archive.
.PARAMETER DestinationPath
    Directory to expand into (created when missing).
.PARAMETER Filter
    Directory-name wildcard to locate (default '*').
.OUTPUTS
    [string] Full path of the matched directory, or $null.
#>
function Expand-ArchiveSubdirectory {
    param(
        [Parameter(Mandatory)]
        [string]$ArchivePath,
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        [string]$Filter = '*'
    )

    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    Expand-Archive -Path $ArchivePath -DestinationPath $DestinationPath -Force
    $subdir = Get-ChildItem -Path $DestinationPath -Directory -Filter $Filter -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($subdir) { return $subdir.FullName }
    return $null
}

Export-ModuleMember -Function @(
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    'ConvertFrom-VersionsEnv',
    'Expand-ArchiveSubdirectory'
)


# --------------------------------------------------------------------------
# Restored from 04e1e07 (pre-refactor): functions still consumed by
# downstream Build-Windows.ps1 scripts (Kataglyphis-Inference-Engine).
# --------------------------------------------------------------------------
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

function Resolve-NormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolved = [System.IO.Path]::GetFullPath($Path)
    return $resolved.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

Export-ModuleMember -Function Resolve-WorkspacePath, Resolve-NormalizedPath


