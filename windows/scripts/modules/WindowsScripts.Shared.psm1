# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest


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

    # @() around Where-Object: .Count on an empty pipeline's AutomationNull throws under StrictMode.
    if ($Value -is [array] -and $Value.Count -gt 0) {
        $allStrings = @($Value | Where-Object { $_ -isnot [string] }).Count -eq 0
        if ($allStrings) {
            return @($Value)
        }
        return @($Value | ForEach-Object { "$_" })
    }

    if ($Value -is [string]) {
        return @($Value)
    }

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

    return @("$Value")
}

function Invoke-DownloadWithRetry {
    <#
    .SYNOPSIS
        Download a URL to a file with retries + exponential backoff.
    .DESCRIPTION
        WebClient (no curl on PATH needed, file:// for offline tests), TLS 1.2, a browser UA; partial files removed between tries.
    .PARAMETER Url
        Source URL (http/https, or file:// in tests).
    .PARAMETER DestinationPath
        Full path to write to (parent directory is created if missing).
    .PARAMETER MaxAttempts
        Total attempts before giving up (default 4).
    .PARAMETER InitialDelaySeconds
        Backoff before the 2nd attempt, doubling up to 30 (default 3); tests pass 0.
    .PARAMETER Headers
        Optional extra request headers (name -> value).
    .PARAMETER Description
        Human label for the log lines (defaults to the URL).
    .PARAMETER ExpectSignature
        'MZ' or 'PK' magic bytes; an HTML error page served in place of the binary is retried like a blip.
    .PARAMETER ExpectedSha256
        Optional SHA256 pin from versions.env; a mismatch is retried (CDN truncation is transient), fatal on the last try.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaxAttempts = 4,
        [int]$InitialDelaySeconds = 3,
        [hashtable]$Headers = @{},
        [string]$Description = '',
        [ValidateSet('', 'MZ', 'PK')][string]$ExpectSignature = '',
        [string]$ExpectedSha256 = ''
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
                if ($ExpectedSha256) {
                    Assert-FileSha256 -Path $DestinationPath -Expected $ExpectedSha256 -Label $label
                }
                if ($attempt -gt 1) { Write-Host "  download OK on attempt ${attempt}: $label" }
                return
            }
            throw 'downloaded file is missing or empty'
        } catch {
            $msg = $_.Exception.Message
            if (Test-Path $DestinationPath) { Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue }
            if ($attempt -ge $MaxAttempts) { throw "Download failed after $MaxAttempts attempt(s) [$label]: $msg" }
            # A 429 is a rate limit, not a blip: short backoff burns every attempt, so wait a minute per prior attempt.
            $wait = $delay
            if ($msg -match '\b429\b|Too Many Requests') {
                $wait = 60 * $attempt
                Write-Host "  download attempt $attempt/$MaxAttempts rate-limited (429) [$label] -- backing off ${wait}s to let the limiter reset"
            } else {
                Write-Host "  download attempt $attempt/$MaxAttempts failed [$label]: $msg -- retrying in ${wait}s"
            }
            if ($wait -gt 0) { Start-Sleep -Seconds $wait }
            $delay = [Math]::Min($delay * 2, 30)
        }
    }
}

<#
.SYNOPSIS
    Verify a file against an optional SHA256 pin: a mismatch is FATAL, an absent pin is a warning.
.PARAMETER Path
    File to hash.
.PARAMETER Expected
    Hex SHA256 pin (case-insensitive). Empty = unverified, with a warning.
.PARAMETER Label
    Human name for the file used in the messages (defaults to the path).
.PARAMETER PinName
    The versions.env key the pin belongs to, named in the messages.
#>
function Assert-FileSha256 {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Expected = '',
        [string]$Label = '',
        [string]$PinName = ''
    )

    $what = if ($Label) { $Label } else { $Path }
    $pinRef = if ($PinName) { " ($PinName)" } else { '' }
    $expectedSha = "$Expected".Trim()
    if (-not $expectedSha) {
        Write-Warning "$what SHA256 is empty$pinRef - using it UNVERIFIED (pin it in versions.env)."
        return
    }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
    if (-not [string]::Equals($actual, $expectedSha, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$what SHA256 mismatch: expected $expectedSha, got $actual"
    }
    Write-Host "$what SHA256 verified$pinRef."
}

<#
.SYNOPSIS
    A pin from the environment, else from this hub's versions.env; throws rather than let the newest release win.
.PARAMETER Name
    The versions.env key, e.g. CARGO_AUDIT_VERSION.
.PARAMETER VersionsEnvPath
    Defaults to the versions.env beside this module in the hub checkout.
#>
function Get-ANTfrastructurePin {
    param(
        [Parameter(Mandatory)][string]$Name,
        # modules -> scripts -> windows -> the hub root.
        [string]$VersionsEnvPath = (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env')
    )
    $fromEnv = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv }
    if (Test-Path $VersionsEnvPath) {
        $pins = ConvertFrom-VersionsEnv -Path $VersionsEnvPath
        if ($pins.Contains($Name) -and -not [string]::IsNullOrWhiteSpace($pins[$Name])) { return $pins[$Name] }
    }
    throw ("$Name is not set and could not be read from $VersionsEnvPath. " +
           'It pins a tool whose verdict decides a gate; unpinned, the newest release would.')
}

<#
.SYNOPSIS
    Parses a versions.env file into an ordered key/value dictionary.
.DESCRIPTION
    Skips blanks and #-comments, splits on the first '=', trims and unquotes; parsed, never sourced.
.PARAMETER Path
    Path to the versions.env file (must exist).
.OUTPUTS
    [OrderedDictionary] in file order; test membership with .Contains, as it has no .ContainsKey.
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
    $null when no directory matches Filter; the caller decides if that is fatal, as TensorRT ships flat zips.
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

# --- sccache stats (the invocation is shared, each caller keeps its own sink) ---

function Test-SccacheRemoteConfigured {
    # No remote means no cache that outlives the RUN; SCCACHE_FORCE_LOCAL=1 is a diagnostic for the disk level only.
    if ($env:SCCACHE_FORCE_LOCAL -eq '1') { return $true }

    return (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_WEBDAV_ENDPOINT)) -or
        (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_BUCKET)) -or
        (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_REDIS_ENDPOINT))
}

function Get-SccacheStatsText {
    <#
    .SYNOPSIS
        sccache's counter dump as lines, $null when there is nothing to read; never throws, stats are not a gate.
    .PARAMETER Advanced
        Query --show-adv-stats instead of --show-stats.
    .PARAMETER RequireRemote
        $null without a remote backend, since querying would spawn a local server as a side effect.
    .OUTPUTS
        [string[]] when sccache ran (possibly empty), $null when it was skipped.
    #>
    param(
        [switch]$Advanced,
        [switch]$RequireRemote
    )

    if ($RequireRemote -and -not (Test-SccacheRemoteConfigured)) { return $null }
    # Asking would start a server, and under Invoke-BuildCodeQL's tracer that server never lets the trace end.
    if ($env:KATAGLYPHIS_NO_SCCACHE) { return $null }

    $sccacheCmd = Get-Command 'sccache.exe' -ErrorAction SilentlyContinue
    if (-not $sccacheCmd) { $sccacheCmd = Get-Command 'sccache' -ErrorAction SilentlyContinue }
    if (-not $sccacheCmd) { return $null }

    $flag = if ($Advanced) { '--show-adv-stats' } else { '--show-stats' }
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        # Via cmd.exe: PS 5.1 under Stop makes sccache's stderr terminating even through 2>&1.
        $global:LASTEXITCODE = 0
        cmd.exe /c """$($sccacheCmd.Source)"" $flag 2>&1" | ForEach-Object { $lines.Add([string]$_) }
        if ($LASTEXITCODE -ne 0) { $lines.Add("(sccache $flag exited $LASTEXITCODE -- stats unavailable)") }
    } catch {
        $lines.Add("(sccache $flag failed: $($_.Exception.Message))")
    }

    return @($lines)
}

function Limit-DiagnosticLogs {
    # Keeps plenty: retention trims the tail, never the incident.
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$Keep = 60
    )
    if (-not (Test-Path $Directory)) { return }
    $logs = @(Get-ChildItem -Path $Directory -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($logs.Count -le $Keep) { return }
    $stale = @($logs | Select-Object -Skip $Keep)
    $stale | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host ("log retention: removed {0} log(s) older than the newest {1} in {2}" -f $stale.Count, $Keep, $Directory)
}

function Get-DiagnosticLogPath {
    # Test-BuildCopy.ps1 keeps an inline copy on purpose: it must run module-free on a fresh host.
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Name,
        [int]$Keep = 60
    )
    $dir = Join-Path $RepoRoot 'out\build-logs'
    $null = New-Item -ItemType Directory -Force -Path $dir
    Limit-DiagnosticLogs -Directory $dir -Keep $Keep
    return Join-Path $dir ("{0}-{1}.log" -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Write-SccacheStatsToStderr {
    # Stderr survives BuildKit's 2MiB step-log clip, so hit rates stay measurable when the stdout tail is gone.
    param(
        [switch]$Advanced,
        [switch]$RequireRemote,
        [string]$Prefix = 'sccache-stats| '
    )
    foreach ($line in @(Get-SccacheStatsText -Advanced:$Advanced -RequireRemote:$RequireRemote | Where-Object { $null -ne $_ })) {
        [Console]::Error.WriteLine("$Prefix$line")
    }
}

# --- Visual Studio / MSVC discovery (-AllowMissing: source builds throw, the sanitizer-DLL probe degrades quietly) ---

function Get-VisualStudioInstallPath {
    <#
    .SYNOPSIS
        Returns the Visual Studio installation path(s) with VC Tools x86/x64.
    .PARAMETER AllowMissing
        Return $null (an empty array with -All) instead of throwing when vswhere or a VS install is absent.
    .PARAMETER All
        Return every qualifying installation instead of only the latest.
    #>
    param(
        [switch]$AllowMissing,
        [switch]$All
    )

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        if ($AllowMissing) { if ($All) { return @() } else { return $null } }
        throw "vswhere.exe not found at $vswhere - Visual Studio Installer missing"
    }

    # -nologo, or the banner returns as the first path; retries then a filesystem fallback, as a fresh container's vswhere can return nothing.
    $selector = if ($All) { @() } else { @('-latest') }
    $vsPaths = @()
    foreach ($attempt in 1..3) {
        $vsPaths = @(& $vswhere -nologo @selector -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim() } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Container })
        if ($vsPaths.Count -gt 0) { break }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    # A probe that found nothing is not the caller's failure: GitHub's pwsh shell exits the step with a stale $LASTEXITCODE.
    $global:LASTEXITCODE = 0
    if ($vsPaths.Count -eq 0) {
        # Memoized per process, so a dead vswhere globs and warns once instead of per caller.
        if (-not (Test-Path 'Variable:script:VsFilesystemFallbackCache')) {
            $globbed = @(Get-ChildItem -Path @(
                    "$env:ProgramFiles\Microsoft Visual Studio",
                    "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
                ) -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+$' } |
                Get-ChildItem -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'VC\Tools\MSVC') -PathType Container } |
                Sort-Object FullName -Descending |
                Select-Object -ExpandProperty FullName)
            # The VISUAL_STUDIO_VERSION pin first, so a VS major promotion never floats in through the fallback.
            if ($globbed.Count -gt 0 -and $env:VISUAL_STUDIO_VERSION) {
                $pinned = @($globbed | Where-Object { $_ -match [regex]::Escape("\$($env:VISUAL_STUDIO_VERSION)\") })
                if ($pinned.Count -gt 0) {
                    $globbed = @($pinned) + @($globbed | Where-Object { $_ -notin $pinned })
                } else {
                    Write-Warning "VS filesystem fallback: no install matches the VISUAL_STUDIO_VERSION=$env:VISUAL_STUDIO_VERSION pin - resolving newest ($($globbed[0])). If a VS major was just promoted, expect the vcpkg/VS-toolset rejection class."
                }
            }
            if ($globbed.Count -gt 0) {
                Write-Warning "vswhere returned no installation; using filesystem fallback: $($globbed[0]) (memoized for this process)"
            }
            $script:VsFilesystemFallbackCache = $globbed
        }
        $vsPaths = $script:VsFilesystemFallbackCache
    }

    if ($vsPaths.Count -eq 0) {
        if ($AllowMissing) { if ($All) { return @() } else { return $null } }
        throw 'No Visual Studio installation with VC Tools x86/x64 found via vswhere'
    }

    if ($All) { return $vsPaths }
    return $vsPaths[0]
}

function Get-MsvcToolsRoots {
    <#
    .SYNOPSIS
        The VC\Tools\MSVC\<version> directories of the discovered VS installation(s), newest first.
    .PARAMETER AllowMissing
        Return an empty array instead of throwing when nothing is found.
    .PARAMETER All
        Search every qualifying VS installation, not just the latest.
    #>
    param(
        [switch]$AllowMissing,
        [switch]$All
    )

    $vsPaths = @(Get-VisualStudioInstallPath -AllowMissing:$AllowMissing -All:$All)
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($vsPath in $vsPaths) {
        if ([string]::IsNullOrWhiteSpace($vsPath)) { continue }
        $msvcRoot = Join-Path $vsPath 'VC\Tools\MSVC'
        # Descending, so a caller taking the first entry gets the newest toolset.
        foreach ($dir in @(Get-ChildItem -Path $msvcRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            $roots.Add($dir.FullName)
        }
    }

    if ($roots.Count -eq 0 -and -not $AllowMissing) {
        $firstVsPath = @($vsPaths) | Select-Object -First 1
        throw "No MSVC toolchain found under $firstVsPath\VC\Tools\MSVC"
    }

    return @($roots)
}

function Resolve-LatestVersionTag {
    <#
    .SYNOPSIS
        Picks the highest semantic version tag out of `git ls-remote --tags` output.
    .DESCRIPTION
        Only plain v?N(.N)+ tags count; returns '' and never throws when none match, so callers fall back to their pin.
    .PARAMETER LsRemoteOutput
        Raw `git ls-remote --tags <repo>` output lines ("<sha>\t<ref>" per line).
    #>
    param([string[]]$LsRemoteOutput)
    if (-not $LsRemoteOutput) { return '' }
    # Tab filter first: indexing [1] of a tab-less line throws under StrictMode.
    $tags = @($LsRemoteOutput | Where-Object { $_ -match "`t" } |
            ForEach-Object { ($_ -split "`t")[1] } |
            Where-Object { $_ -and $_ -notmatch '\^\{\}$' } |
            ForEach-Object { $_ -replace '^refs/tags/', '' } |
            # At least one dot: [version]'5' throws inside Sort-Object.
            Where-Object { $_ -match '^v?\d+(\.\d+)+$' } |
            Sort-Object { [version]($_ -replace '^v', '') })
    if ($tags.Count -eq 0) { return '' }
    return $tags[-1]
}


# --- PATH and tool resolution (candidates before PATH: runners carry several CMake/LLVM installs) ---

function Add-DirectoryToPath {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path $Directory)) {
        return
    }

    $resolvedDirectory = (Resolve-Path $Directory).Path
    $currentEntries = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $remainingEntries = @($currentEntries | Where-Object { $_ -ne $resolvedDirectory })
    $env:PATH = (@($resolvedDirectory) + $remainingEntries) -join ';'
}

function Add-DirectoriesToPath {
    param([string[]]$Directories)

    foreach ($directory in $Directories) {
        Add-DirectoryToPath $directory
    }
}

function Get-PreferredToolPath {
    <#
    .SYNOPSIS
        Candidate paths first, then PATH; $null when nothing matches, unless -Required.
    .DESCRIPTION
        Prefer -Required unless the tool is optional: an ignored $null fails later without naming the tool.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CommandName,
        [string[]]$CandidatePaths = @(),
        [switch]$Required
    )

    foreach ($candidate in $CandidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ($Required) {
        $searched = if ($CandidatePaths.Count -gt 0) {
            "Looked at: $($CandidatePaths -join ', '), then PATH."
        }
        else {
            'Looked at PATH only (no candidate paths were supplied).'
        }
        throw "Required tool '$CommandName' not found. $searched"
    }

    return $null
}

function Resolve-BuildCtlPath {
    <#
    .SYNOPSIS
        The one owner of the Stevedore buildctl candidate list.
    .PARAMETER BuildCtl
        An already-resolved path to honour unchanged (empty = resolve).
    #>
    param([string]$BuildCtl = '')

    if ($BuildCtl) { return $BuildCtl }
    return (Get-PreferredToolPath -CommandName 'buildctl' -CandidatePaths @(
            "$env:ProgramFiles\Stevedore\bin\buildctl.exe",
            'D:\Stevedore\bin\buildctl.exe'
        ) -Required)
}

function Test-Elevated {
    <#
    .SYNOPSIS
        The BOOLEAN half of the admin gate: is this process elevated?
    .DESCRIPTION
        For callers that branch on the answer; the module-free repair tools keep an inline check on purpose.
    .OUTPUTS
        [bool] $true when the current identity is in the Administrators role.
    #>
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Assert-Elevated {
    <#
    .SYNOPSIS
        Throws (with -Interactive: prompts and exits) unless the process runs elevated.
    #>
    param(
        [string]$Reason = '',
        [switch]$Interactive
    )
    if (Test-Elevated) { return }
    $msg = if ($Reason) { "Run ELEVATED ($Reason)." } else { 'Run ELEVATED.' }
    if ($Interactive) {
        Write-Host $msg -ForegroundColor Red
        Read-Host 'Enter'
        exit 1
    }
    throw $msg
}

# ── Tool guards (for SDK tools use WindowsMsix.Common's Resolve-WindowsSdkToolPath, not a recursive scan) ──

function Assert-Command {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$InstallHint
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name not found. $InstallHint"
    }
}

# Twin of version_util.sh --normalize, but throws where bash falls back to 0.1.0.0: packaging must not ship a bad version.
function ConvertTo-NormalizedVersion {
    param([Parameter(Mandatory)][string]$RawVersion)

    $segments = $RawVersion.Split('.')
    if ($segments.Count -eq 3) { return "$RawVersion.0" }
    if ($segments.Count -ne 4) {
        throw "Version '$RawVersion' is invalid. Use Major.Minor.Build or Major.Minor.Build.Revision"
    }
    return $RawVersion
}

Export-ModuleMember -Function @(
    'Assert-Command',
    'Assert-Elevated',
    'Test-Elevated',
    'ConvertTo-NormalizedVersion',
    # Before removing an export, see docs/consumer-inventory.md § Why a grep was not enough
    'Add-DirectoriesToPath',
    'Get-PreferredToolPath',
    'Resolve-BuildCtlPath',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    'Assert-FileSha256',
    'ConvertFrom-VersionsEnv',
    # OxidANT's Build-Windows.ps1 pins cargo-audit and cargo-deny with it (CON55).
    'Get-ANTfrastructurePin',
    'Expand-ArchiveSubdirectory',
    'Test-SccacheRemoteConfigured',
    'Get-SccacheStatsText',
    'Write-SccacheStatsToStderr',
    'Limit-DiagnosticLogs',
    'Get-DiagnosticLogPath',
    'Get-VisualStudioInstallPath',
    'Get-MsvcToolsRoots',
    'Resolve-LatestVersionTag'
)


# Consumed by OmniAccelerANT's Build-Windows.ps1 with no in-repo caller: see docs/consumer-inventory.md § Why a grep was not enough
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


