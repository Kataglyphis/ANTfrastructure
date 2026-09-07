# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

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
    .PARAMETER ExpectedSha256
        Optional full-content SHA256 pin (hex, case-insensitive; canonical values live in
        linux/scripts/01-core/versions.env *_SHA256 keys). A mismatch is treated like any
        transient failure and retried (CDN truncation IS transient); a mismatch on the final
        attempt throws with both hashes in the message. Empty = no content verification
        beyond ExpectSignature, preserving existing call sites unchanged.
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
                    $actual = (Get-FileHash -Algorithm SHA256 -Path $DestinationPath).Hash
                    if (-not [string]::Equals($actual, $ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "SHA256 mismatch: expected $ExpectedSha256 but got $actual (truncated/tampered download)"
                    }
                }
                if ($attempt -gt 1) { Write-Host "  download OK on attempt ${attempt}: $label" }
                return
            }
            throw 'downloaded file is missing or empty'
        } catch {
            $msg = $_.Exception.Message
            if (Test-Path $DestinationPath) { Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue }
            if ($attempt -ge $MaxAttempts) { throw "Download failed after $MaxAttempts attempt(s) [$label]: $msg" }
            # HTTP 429 is a RATE LIMIT, not a blip: 3s/6s/12s backoff retries
            # into the same closed window and burns all attempts in ~20s —
            # measured 2026-08-17, four 429s from GitHub codeload killed a merge
            # chain 55 minutes in. A 429 needs a WAIT, not persistence: one
            # minute per prior attempt, so the limiter can actually reset.
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
    Parses a versions.env file into an ordered key/value dictionary.
.DESCRIPTION
    Canonical parser for the repo's single source of truth
    (linux/scripts/01-core/versions.env): blank lines and #-comments are skipped,
    each remaining line is split on the FIRST '=', keys/values are trimmed and
    surrounding quotes stripped from values. Replaces the hand-rolled copies that
    used to live in Import-Versions.ps1, build.ps1, Test-Container.ps1 and
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

# --------------------------------------------------------------------------
# sccache -- single implementation of "read the counters without ever failing".
#
# This lives here, in the module both WindowsBuild.Common and
# WindowsSourceBuild.Common already import, because the three former copies
# (WindowsCMake.Common's inline pre/post-build dumps, WindowsBuild.Common's
# Show-SccacheStats and WindowsSourceBuild.Common's Write-SccacheStats) sat in
# modules with no import edge between them. Only the *sink* differs per caller
# (build-log + Context / pipeline step / Write-Host), so the sink stays with the
# caller and only the invocation is shared.
# --------------------------------------------------------------------------

function Test-SccacheRemoteConfigured {
    # True when any sccache remote backend is configured. Shared by the cmake
    # launcher wiring (Invoke-CmakeConfigure) and the end-of-build stats dump --
    # without a remote there is no cache, so neither should activate.
    #
    # SCCACHE_FORCE_LOCAL=1 overrides that for ONE purpose: measuring sccache's
    # LOCAL DISK backend on its own. It is a diagnostic escape hatch, not a
    # supported build mode -- a local-only cache dies with the RUN's container
    # unless SCCACHE_DIR points at a cache mount, which is exactly why this gate
    # exists. Added 2026-08-16 for backlog #99: clearing the endpoint to isolate
    # the disk level silently disabled sccache entirely (`Compile requests 0`),
    # so the experiment measured nothing and looked like a clean run.
    if ($env:SCCACHE_FORCE_LOCAL -eq '1') { return $true }

    return (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_WEBDAV_ENDPOINT)) -or
        (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_BUCKET)) -or
        (-not [string]::IsNullOrWhiteSpace($env:SCCACHE_REDIS_ENDPOINT))
}

function Get-SccacheStatsText {
    <#
    .SYNOPSIS
        Returns sccache's counter dump as string lines, or $null when there is
        nothing to read. Never throws and never fails a build: stats are
        diagnostics, not a gate.
    .PARAMETER Advanced
        Query --show-adv-stats instead of --show-stats.
    .PARAMETER RequireRemote
        Return $null unless a remote backend is configured. Without a remote
        there is no cache worth reporting, and querying would spawn a local
        sccache server as a side effect.
    .OUTPUTS
        [string[]] when sccache ran (possibly empty), $null when it was skipped.
    #>
    param(
        [switch]$Advanced,
        [switch]$RequireRemote
    )

    if ($RequireRemote -and -not (Test-SccacheRemoteConfigured)) { return $null }

    $sccacheCmd = Get-Command 'sccache.exe' -ErrorAction SilentlyContinue
    if (-not $sccacheCmd) { $sccacheCmd = Get-Command 'sccache' -ErrorAction SilentlyContinue }
    if (-not $sccacheCmd) { return $null }

    $flag = if ($Advanced) { '--show-adv-stats' } else { '--show-stats' }
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        # cmd.exe routing: sccache may write diagnostics to stderr, which PS 5.1 under
        # EAP=Stop escalates into a terminating NativeCommandError even through 2>&1.
        $global:LASTEXITCODE = 0
        cmd.exe /c """$($sccacheCmd.Source)"" $flag 2>&1" | ForEach-Object { $lines.Add([string]$_) }
        if ($LASTEXITCODE -ne 0) { $lines.Add("(sccache $flag exited $LASTEXITCODE -- stats unavailable)") }
    } catch {
        $lines.Add("(sccache $flag failed: $($_.Exception.Message))")
    }

    return @($lines)
}

function Limit-DiagnosticLogs {
    # Retention for the log directories the diagnostics/drivers Tee into
    # (backlog #30): growth was unbounded (28 MB day-one), which made
    # per-run forensics harder. Never-swallow-logs means KEEP plenty -
    # retention trims the tail, not the incident.
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
    # One owner for the diagnostics' log-persistence convention (backlog #8):
    # <repo>\out\build-logs\<name>-<timestamp>.log, directory created,
    # retention applied. Test-BuildCopy.ps1 alone keeps its inline copy BY
    # DESIGN - it must run module-free on a fresh host (first-script rule).
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
    # The end-of-build sink every in-container source build wants (backlog #3):
    # STDERR survives BuildKit's 2MiB step-log clip, so hit-rates stay
    # measurable even when the stdout tail is gone (AGENTS.md: caching must be
    # MEASURED; never-swallow-logs). The name states the sink deliberately -
    # the sink-stays-with-the-caller doctrine above still holds for every
    # other consumer; this is the one sink shared by many callers.
    param(
        [switch]$Advanced,
        [switch]$RequireRemote,
        [string]$Prefix = 'sccache-stats| '
    )
    foreach ($line in @(Get-SccacheStatsText -Advanced:$Advanced -RequireRemote:$RequireRemote | Where-Object { $null -ne $_ })) {
        [Console]::Error.WriteLine("$Prefix$line")
    }
}

# --------------------------------------------------------------------------
# Visual Studio / MSVC discovery -- single vswhere-based implementation.
#
# Replaces the copy that WindowsCMake.Common's Get-SanitizerRuntimeDlls kept
# inline (flagged "Near-duplicate of Get-VsInstallPath ... Merge candidate")
# alongside WindowsSourceBuild.Common's Get-VsInstallPath/Get-MsvcToolsRoot.
# The throwing-vs-silent split between those two callers is load-bearing and is
# preserved as the -AllowMissing switch, NOT resolved in favour of either:
#   * source builds need the hard failure (no VS means no build),
#   * the sanitizer-DLL probe must degrade quietly (a missing VS install just
#     means one fewer clang_rt root to search).
# --------------------------------------------------------------------------

function Get-VisualStudioInstallPath {
    <#
    .SYNOPSIS
        Returns the Visual Studio installation path(s) with VC Tools x86/x64.
    .PARAMETER AllowMissing
        Return $null (or an empty array with -All) instead of throwing when
        vswhere.exe or a qualifying VS installation is absent.
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

    # -nologo suppresses the "Visual Studio Locator version ..." banner vswhere
    # prints on stdout ahead of the value. Without it the banner comes back as
    # the first "installation path" -- which is how the pre-consolidation
    # Get-VsInstallPath could return a banner string that then produced
    # "No MSVC toolchain found under Visual Studio Locator version ...\VC\Tools\MSVC".
    # The Test-Path filter is the belt-and-braces half: only real directories survive.
    #
    # RETRY + FALLBACK (2026-08-03): in a freshly booted container, vswhere can
    # transiently return NOTHING (installer state under ProgramData not readable
    # yet ~seconds after boot) — reproduced once ~24s into a media-core run and
    # never again in warm containers (6/6 probes clean). Retry briefly, then fall
    # back to filesystem discovery of <PF>\Microsoft Visual Studio\<major>\<sku>
    # with VC\Tools\MSVC present, so a boot race costs seconds, not the stage.
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
    if ($vsPaths.Count -eq 0) {
        # Memoized (#78): under a dead vswhere every caller used to re-glob and
        # re-warn - one base build logged the warning x100. Resolve once per
        # process, warn once. (Process-scope cache: a VS install appearing
        # mid-process is not a supported scenario.)
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
            # Honour the pin (#78): newest-first is right for a dev host, but in
            # the pinned images a VS major promotion must never float in via the
            # fallback. Prefer the VISUAL_STUDIO_VERSION major when present;
            # warn loudly when the pin resolves to nothing (pre-promotion class
            # of the documented vcpkg/VS-toolset rejection).
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
        Returns the VC\Tools\MSVC\<version> directories of the discovered Visual
        Studio installation(s), newest version first.
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
        # Sorted descending so callers taking the first entry get the NEWEST
        # toolset. Get-SanitizerRuntimeDlls previously took an unsorted
        # "-First 1" here, i.e. the alphabetically oldest toolset.
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
        Extracted from build.ps1's final-stage app-ref resolution so the tag
        filtering/sorting is unit-testable with canned ls-remote text: dereference
        markers (^{}) are dropped, refs/tags/ is stripped, only plain v?N(.N)* tags
        are considered, and the highest [version] wins. Returns '' (never throws)
        when nothing matches — callers fall back to their pinned ref.
    .PARAMETER LsRemoteOutput
        Raw `git ls-remote --tags <repo>` output lines ("<sha>\t<ref>" per line).
    #>
    param([string[]]$LsRemoteOutput)
    if (-not $LsRemoteOutput) { return '' }
    # Tab filter FIRST: a tab-less line (warning banner, blank) would make the
    # [1] index out-of-bounds — a StrictMode throw that violates the documented
    # "never throws" contract.
    $tags = @($LsRemoteOutput | Where-Object { $_ -match "`t" } |
            ForEach-Object { ($_ -split "`t")[1] } |
            Where-Object { $_ -and $_ -notmatch '\^\{\}$' } |
            ForEach-Object { $_ -replace '^refs/tags/', '' } |
            # At least one dot required: single-component release tags (e.g. 'v5')
            # are not semver and are deliberately ignored - [version]'5' throws
            # inside Sort-Object, which would violate the never-throws contract.
            Where-Object { $_ -match '^v?\d+(\.\d+)+$' } |
            Sort-Object { [version]($_ -replace '^v', '') })
    if ($tags.Count -eq 0) { return '' }
    return $tags[-1]
}


# --- PATH and tool resolution ------------------------------------------------
# Generic helpers every Windows build script re-invents: put a directory FIRST
# on PATH (de-duplicating it), and pick a tool from explicit candidate paths
# before falling back to whatever `Get-Command` finds. The ordering matters on
# a CI runner where several CMake/LLVM installs coexist and the one on PATH is
# not the one the build expects.

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
        Candidate paths first, then PATH. Returns $null when nothing matches,
        unless -Required is given.

    .DESCRIPTION
        -Required restores the throwing behaviour that Resolve-PreferredTool
        used to provide. That function was deleted on 2026-08-21 as "fully dead
        (zero callers anywhere)" — the audit only looked inside THIS repo, and
        BeschleunigerBallett's scripts/windows/Invoke-ClangClDebug.ps1 was
        calling it three times. It has been broken since. The lesson is in the
        switch rather than in a restored duplicate: one resolver, two
        behaviours, so a consumer never has to hand-roll the throwing half.

        Without -Required a caller that ignores the $null gets a confusing
        downstream failure instead of the name of the tool it is missing —
        which is what happened here — so prefer -Required whenever the tool is
        not genuinely optional.
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

function Assert-Elevated {
    <#
    .SYNOPSIS
        Throws (or, with -Interactive, prompts and exits) unless the current
        process runs elevated. One home for the admin gate that existed as 13
        hand-rolled copies with 9 different messages (2026-08-21 audit).
        NB the module-free repair tools (reset-container-locks,
        repair-windows-componentstore) keep their inline check BY DESIGN —
        a wedged-stack repair must not depend on a module import.
    #>
    param(
        [string]$Reason = '',
        [switch]$Interactive
    )
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }
    $msg = if ($Reason) { "Run ELEVATED ($Reason)." } else { 'Run ELEVATED.' }
    if ($Interactive) {
        Write-Host $msg -ForegroundColor Red
        Read-Host 'Enter'
        exit 1
    }
    throw $msg
}

# ── Tool guards ───────────────────────────────────────────────────────────────
# Assert-Command lived as a private copy in windows/scripts/rust/
# New-MsixPackage.ps1, windows/scripts/build/Test-Container.ps1 and a
# consumer's Build-Windows.ps1, all three identical. One home now.
#
# There is deliberately NO general Resolve-Executable here. Both the
# ContainerHub scripts above and the consumer carried one, and all of them
# `Get-ChildItem -Recurse` the whole Windows Kits tree to find an SDK tool.
# WindowsMsix.Common's Resolve-WindowsSdkToolPath already does that job
# properly - honouring an explicit override, then VsDevCmd's
# WindowsSdkVerBinPath / WindowsSdkBinPath / WindowsSDKVersion, and only then
# scanning, newest version first, without recursing. Adding a fourth variant
# here would have been the opposite of consolidating; use that one.

function Assert-Command {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$InstallHint
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name not found. $InstallHint"
    }
}

# PowerShell twin of linux/scripts/02-toolchain/rust/version_util.sh
# --normalize, with ONE deliberate difference: the bash side falls back to
# 0.1.0.0 for anything it cannot parse (it runs unattended in an image build),
# while this THROWS - a packaging step handed a malformed version should stop,
# not silently ship 0.1.0.0.
#
# Named ConvertTo-* rather than the consumer's original Normalize-Version:
# "Normalize" is not an approved PowerShell verb, and an unapproved one in a
# SHARED module makes Import-Module warn in every consumer that loads it.
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
    'ConvertTo-NormalizedVersion',
    # Add-DirectoryToPath: internal helper of Add-DirectoriesToPath (unexported
    # 2026-08-21, zero external callers). Resolve-PreferredTool was deleted the
    # same day as "fully dead (zero callers anywhere)" — WRONG, and left
    # BeschleunigerBallett's Invoke-ClangClDebug.ps1 broken at three call sites
    # until 2026-09-06. That audit grepped this repo only. Grep every consumer
    # under D:\GitHub before deleting anything from an exported surface; the
    # throwing behaviour now lives on as Get-PreferredToolPath -Required.
    'Add-DirectoriesToPath',
    'Get-PreferredToolPath',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry',
    'ConvertFrom-VersionsEnv',
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


# --------------------------------------------------------------------------
# Restored from 04e1e07 (pre-refactor): functions still consumed by
# downstream Build-Windows.ps1 scripts (OmniAccelerANT).
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


