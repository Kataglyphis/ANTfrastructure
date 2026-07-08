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
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 3,
        [hashtable]$Headers = @{},
        [string]$Description = ''
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

Export-ModuleMember -Function @(
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)

