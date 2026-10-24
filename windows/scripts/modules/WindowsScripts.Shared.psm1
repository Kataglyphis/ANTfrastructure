# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

function Resolve-BuildValue {
    param([string]$Value = '', [string[]]$EnvironmentVariables = @(), [string]$DefaultValue = '')
    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }
    foreach ($name in $EnvironmentVariables) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $environmentValue = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) { return $environmentValue }
    }
    return $DefaultValue
}

Export-ModuleMember -Function Resolve-BuildValue


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

function Get-UrlFileName {
    param([Parameter(Mandatory)][string]$Url)
    return [uri]::UnescapeDataString(([uri]$Url).Segments[-1])
}

Export-ModuleMember -Function Get-UrlFileName

function Assert-DownloadedFile {
    param([string]$DestinationPath, [string]$ExpectSignature, [string]$ExpectedSha256, [string]$Label)
    if (-not (Test-Path $DestinationPath) -or (Get-Item $DestinationPath).Length -le 0) {
        throw 'downloaded file is missing or empty'
    }
    if ($ExpectSignature) {
        $fs = [System.IO.File]::OpenRead($DestinationPath)
        try { $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte() } finally { $fs.Dispose() }
        $sigOk = switch ($ExpectSignature) {
            'MZ' { ($b0 -eq 0x4D) -and ($b1 -eq 0x5A) }   # PE executable (.exe / .dll)
            'PK' { ($b0 -eq 0x50) -and ($b1 -eq 0x4B) }   # ZIP container (.zip)
        }
        if (-not $sigOk) { throw "expected a $ExpectSignature-signature file but got first bytes ${b0},${b1} (likely an HTML error page served in place of the binary)" }
    }
    if ($ExpectedSha256) { Assert-FileSha256 -Path $DestinationPath -Expected $ExpectedSha256 -Label $Label }
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
            Assert-DownloadedFile -DestinationPath $DestinationPath -ExpectSignature $ExpectSignature `
                -ExpectedSha256 $ExpectedSha256 -Label $label
            if ($attempt -gt 1) { Write-Host "  download OK on attempt ${attempt}: $label" }
            return
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

function Find-FirstTreeFile {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Filter,
        [Management.Automation.ActionPreference]$ScanErrorAction = 'SilentlyContinue')
    Get-ChildItem -LiteralPath $Root -Recurse -Filter $Filter -File -ErrorAction $ScanErrorAction | Select-Object -First 1
}

Export-ModuleMember -Function Find-FirstTreeFile

function Find-InstalledCompilerRtLibrary {
    param([Parameter(Mandatory)][string]$LlvmRoot, [string]$LibraryName = 'clang_rt.builtins-aarch64.lib')
    Find-FirstTreeFile -Root (Join-Path $LlvmRoot 'lib\clang') -Filter $LibraryName
}

Export-ModuleMember -Function Find-InstalledCompilerRtLibrary

# A reference keeps native tar output separate from the selected library path.
function Expand-CompilerRtLibrary {
    param([Parameter(Mandatory)][string]$ArchivePath, [Parameter(Mandatory)][string]$ExtractDirectory,
        [Parameter(Mandatory)][ref]$LibraryPath, [string]$LibraryName = 'clang_rt.builtins-aarch64.lib',
        [string]$ExpectedSha256 = '', [string]$PinName = 'LLVM_WINDOWS_AARCH64_RT_SHA256')
    $LibraryPath.Value = $null
    Assert-FileSha256 -Path $ArchivePath -Expected $ExpectedSha256 -Label 'aarch64 compiler-rt archive' -PinName $PinName
    # System32 bsdtar treats drive letters as paths; GNU tar can interpret them as remote hosts.
    $tarExe = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
    if (-not $tarExe) { throw 'No tar.exe found to extract the aarch64 compiler-rt archive.' }
    New-Item -ItemType Directory -Force -Path $ExtractDirectory | Out-Null
    & $tarExe -xf $ArchivePath -C $ExtractDirectory "*$LibraryName"
    $found = @(Find-FirstTreeFile -Root $ExtractDirectory -Filter $LibraryName)
    if ($found.Count -gt 0) { $LibraryPath.Value = $found[0].FullName }
}

Export-ModuleMember -Function Expand-CompilerRtLibrary

<#
.SYNOPSIS
    Mines clang_rt.builtins-aarch64.lib beside the installed x86_64 builtins.
#>
function Install-AArch64CompilerRt {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$DestinationDir,
        [string]$LibName = 'clang_rt.builtins-aarch64.lib',
        [string]$ExpectedSha256 = '',
        [string]$PinName = 'LLVM_WINDOWS_AARCH64_RT_SHA256',
        [string]$WorkDir = ''
    )

    if (-not (Test-Path $DestinationDir)) {
        throw "aarch64 compiler-rt destination '$DestinationDir' does not exist - refusing a misplaced lib."
    }
    if (-not $WorkDir) { $WorkDir = if ($env:TEMP_DIR) { $env:TEMP_DIR } else { $env:TEMP } }
    # Decode %2B to '+', the archive name the pin was measured on.
    $archiveName = [IO.Path]::GetFileName($Url) -replace '%2B', '+'
    $archive = Join-Path $WorkDir $archiveName
    $extract = Join-Path $WorkDir 'llvm-aarch64-rt'
    try {
        Invoke-DownloadWithRetry -Url $Url -DestinationPath $archive -Description 'aarch64 compiler-rt archive'
        $library = $null
        Expand-CompilerRtLibrary -ArchivePath $archive -ExtractDirectory $extract -LibraryPath ([ref]$library) `
            -LibraryName $LibName -ExpectedSha256 $ExpectedSha256 -PinName $PinName
        if (-not $library) { throw "$LibName not found inside $archive - upstream archive layout changed." }
        $dest = Join-Path $DestinationDir $LibName
        Copy-Item -LiteralPath $library -Destination $dest -Force
        return $dest
    } finally {
        Remove-Item -Path $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Install-AArch64CompilerRt

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

function Get-HostSettingValue {
    # A shell that started before a user or machine variable was set does not see it, so the registry scopes back up the process.
    param([Parameter(Mandatory)][string]$Name)
    foreach ($scope in 'Process', 'User', 'Machine') {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }
    return ''
}

function Get-TcpEndpointUri {
    param([AllowEmptyString()][string]$Url)
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or -not $uri.Host) { return $null }
    return $uri
}

function Test-TcpSocketReachable {
    # See docs/windows-builds.md § Shared Windows behavior: IPv6 refusal must not hide a listening IPv4 address.
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 2000)
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $clients = [System.Collections.Generic.List[System.Net.Sockets.TcpClient]]::new()
    try {
        $resolve = [System.Net.Dns]::GetHostAddressesAsync($HostName)
        if (-not $resolve.Wait($TimeoutMs)) { return $false }
        $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        foreach ($address in $resolve.Result) {
            $client = [System.Net.Sockets.TcpClient]::new($address.AddressFamily)
            $clients.Add($client)
            $pending.Add($client.ConnectAsync($address, $Port))
        }
        while ($pending.Count -gt 0) {
            $left = $TimeoutMs - [int]$clock.ElapsedMilliseconds
            if ($left -le 0) { return $false }
            $done = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), $left)
            if ($done -lt 0) { return $false }
            if ($pending[$done].IsCompletedSuccessfully) { return $true }
            $pending.RemoveAt($done)
        }
        return $false
    } catch {
        return $false
    } finally {
        foreach ($client in $clients) { $client.Dispose() }
    }
}

function Test-UrlPortOpen {
    # A malformed URL is closed, not an error.
    [CmdletBinding(DefaultParameterSetName = 'seconds')]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Url,
        [Parameter(Position = 1, ParameterSetName = 'seconds')][ValidateRange(0, 2147483)][int]$TimeoutSeconds = 3,
        [Parameter(ParameterSetName = 'milliseconds')][ValidateRange(0, 2147483647)][int]$TimeoutMs
    )
    $uri = Get-TcpEndpointUri -Url $Url
    if ($null -eq $uri) { return $false }
    $timeout = if ($PSCmdlet.ParameterSetName -eq 'milliseconds') { $TimeoutMs } else { $TimeoutSeconds * 1000 }
    return [bool](Test-TcpSocketReachable -HostName $uri.DnsSafeHost -Port $uri.Port -TimeoutMs $timeout)
}

function Initialize-BuildDirectory {
    param([Parameter(Mandatory)][string[]]$Path, [switch]$Empty, [string[]]$ChildDirectory = @())
    if ($Empty) {
        foreach ($directory in $Path) {
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop }
        }
    }
    $create = if ($ChildDirectory.Count) {
        foreach ($directory in $Path) { foreach ($child in $ChildDirectory) { Join-Path $directory $child } }
    } else { $Path }
    $null = New-Item -ItemType Directory -Force -Path $create -ErrorAction Stop
}

Export-ModuleMember -Function Initialize-BuildDirectory

function Invoke-WithProcessEnvironment {
    # Runs -ScriptBlock with -Environment set in this process, then puts every variable back; a child it starts inherits them.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Environment, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $priorEnv = @(Get-ChildItem Env: | Where-Object Name -In @($Environment.Keys))
    try {
        foreach ($environmentName in @($Environment.Keys)) { Set-Item -LiteralPath "Env:$environmentName" -Value $Environment[$environmentName] }
        & $ScriptBlock
    } finally {
        foreach ($environmentName in @($Environment.Keys)) { Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue }
        $priorEnv | ForEach-Object { Set-Item -LiteralPath "Env:$($_.Name)" -Value $_.Value }
    }
}

function Invoke-S5cmdWithKey {
    # s5cmd reads the S3 key from its environment, so this process holds it only while s5cmd runs.
    param(
        [Parameter(Mandatory)][string]$S5cmdPath,
        [Parameter(Mandatory)][string]$AccessKeyId,
        [Parameter(Mandatory)][string]$SecretAccessKey,
        [string]$Region = '',
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $awsEnv = @{ AWS_ACCESS_KEY_ID = $AccessKeyId; AWS_SECRET_ACCESS_KEY = $SecretAccessKey; AWS_REGION = $(if ($Region) { $Region } else { 'us-east-1' }) }
    Invoke-WithProcessEnvironment -Environment $awsEnv -ScriptBlock { & $S5cmdPath @Arguments }
}

function Get-SccacheS3Level {
    <#
    .SYNOPSIS
        sccache's S3 level as the SCCACHE_* settings it needs, or the reason it is left out; the key itself is never returned.
    .DESCRIPTION
        The level joins only with its endpoint, bucket and both key halves, which -Lookup reads by variable name (the process
        environment by default). docs/windows-build-resources.md § Two cache levels
    .OUTPUTS
        @{ Settings; Note } - both empty when no S3 level is configured, Settings empty and Note set when one is incomplete.
    #>
    param(
        [string]$WebdavEndpoint = '',
        [string]$S3Endpoint = '',
        [string]$S3Bucket = '',
        [string]$S3Region = '',
        [string]$KeyIdVariable = 'KATAGLYPHIS_SCCACHE_S3_ACCESS_KEY_ID',
        [string]$SecretVariable = 'KATAGLYPHIS_SCCACHE_S3_SECRET_ACCESS_KEY',
        [scriptblock]$Lookup = { param($name) [Environment]::GetEnvironmentVariable($name) }
    )
    $level = @{ Settings = [ordered]@{}; Note = '' }
    if (-not ($S3Endpoint -or $S3Bucket)) { return $level }
    $missing = @(
        if (-not $S3Endpoint) { 'the endpoint' }
        if (-not $S3Bucket) { 'the bucket' }
        foreach ($variable in $KeyIdVariable, $SecretVariable) {
            if ([string]::IsNullOrEmpty((& $Lookup $variable))) { $variable }
        }
    )
    $uri = $null
    if ($S3Endpoint -and -not [Uri]::TryCreate($S3Endpoint, [UriKind]::Absolute, [ref]$uri)) { $missing += "an absolute endpoint URL (got '$S3Endpoint')" }
    if ($missing.Count -gt 0) {
        $level.Note = "the S3 level is left out: it needs $($missing -join ', ')"
        return $level
    }
    $level.Settings['SCCACHE_ENDPOINT'] = $S3Endpoint
    $level.Settings['SCCACHE_BUCKET'] = $S3Bucket
    if ($S3Region) { $level.Settings['SCCACHE_REGION'] = $S3Region }
    $level.Settings['SCCACHE_S3_USE_SSL'] = if ($uri.Scheme -eq 'https') { 'true' } else { 'false' }
    # Without a WebDAV level the bucket is sccache's only backend, which needs no chain.
    if ($WebdavEndpoint) { $level.Settings['SCCACHE_MULTILEVEL_CHAIN'] = 'webdav,s3' }
    return $level
}

function Set-SccacheChainWithout {
    # Takes -Level out of SCCACHE_MULTILEVEL_CHAIN and returns the chain left: one level needs none, and a chain naming a missing level fails the server.
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Level)
    $chain = "$env:SCCACHE_MULTILEVEL_CHAIN"
    $levels = @($chain.Split(',').Trim() -ne '')
    $kept = @($levels | Where-Object { $Level -notcontains $_ })
    if ($kept.Count -eq $levels.Count) { return $chain }
    if ($kept.Count -le 1) { Remove-Item Env:\SCCACHE_MULTILEVEL_CHAIN -ErrorAction SilentlyContinue } else { $env:SCCACHE_MULTILEVEL_CHAIN = $kept -join ',' }
    return "$env:SCCACHE_MULTILEVEL_CHAIN"
}

function Remove-SccacheS3Level {
    # Drops the S3 level from this process and its chain, warning with -Reason; $false when there was none to drop.
    param([Parameter(Mandatory)][string]$Reason)
    $bucket = "$env:SCCACHE_BUCKET"
    if (-not $bucket) { return $false }
    foreach ($name in 'SCCACHE_BUCKET', 'SCCACHE_ENDPOINT', 'SCCACHE_REGION', 'SCCACHE_S3_USE_SSL') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    $chain = Set-SccacheChainWithout -Level 's3'
    Write-Warning "sccache: the S3 level (bucket $bucket) is dropped for this process: $Reason; the build runs on '$(if ($chain) { $chain } else { 'its other level' })'."
    return $true
}

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
    $dir = Join-Path $RepoRoot 'logs\build-logs'
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

function Get-VsFilesystemFallback {
    # A dead vswhere should glob and warn once per process, never once per caller.
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
        # The pin wins so a VS major promotion never floats in through the fallback.
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
    return $script:VsFilesystemFallbackCache
}

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
    $selector = @(if (-not $All) { '-latest' })
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
        $vsPaths = @(Get-VsFilesystemFallback)
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

function Get-DriveFreeSpaceGb {
    param([Parameter(Mandatory)][string]$Drive)
    $disk = Get-PSDrive -Name $Drive -ErrorAction SilentlyContinue
    if (-not $disk -or $null -eq $disk.Free) { return $null }
    return [math]::Round($disk.Free / 1GB, 1)
}
Export-ModuleMember -Function Get-DriveFreeSpaceGb

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
        For callers that branch on the answer instead of throwing.
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
    'Get-HostSettingValue',
    'Test-UrlPortOpen',
    'Get-TcpEndpointUri',
    'Invoke-S5cmdWithKey',
    'Invoke-WithProcessEnvironment',
    'Get-SccacheS3Level',
    'Set-SccacheChainWithout',
    'Remove-SccacheS3Level',
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

# Candidate order belongs to the caller; app bundles and test build trees differ.
function Resolve-BuildExecutable {
    param(
        [Parameter(Mandatory)][string]$BuildRoot,
        [Parameter(Mandatory)][string]$ExecutableName,
        [string[]]$RelativeDirectory = @(''),
        [switch]$ResolveCandidatePath
    )

    foreach ($relative in $RelativeDirectory) {
        $candidate = if ([string]::IsNullOrEmpty($relative)) {
            Join-Path $BuildRoot $ExecutableName
        } else {
            Join-Path $BuildRoot (Join-Path $relative $ExecutableName)
        }
        if (Test-Path $candidate) {
            if ($ResolveCandidatePath) { return (Resolve-Path $candidate).Path }
            return $candidate
        }
    }

    $found = Get-ChildItem -Path $BuildRoot -Filter $ExecutableName -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

Export-ModuleMember -Function Resolve-BuildExecutable

function ConvertTo-MsixSigningPassword {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Caller-supplied passwords protect throwaway development signing certificates.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Development certificate scripts receive the password through their public CLI.')]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Password)
    return ConvertTo-SecureString -String $Password -AsPlainText -Force
}

Export-ModuleMember -Function ConvertTo-MsixSigningPassword

function Resolve-PathFromRoot {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $Root $Path
}

Export-ModuleMember -Function Resolve-PathFromRoot

function Find-ChildDirectoryFile {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [string]$DirectoryFilter = '*',
        [Parameter(Mandatory)][string]$RelativePath
    )
    Get-ChildItem -Path $Parent -Directory -Filter $DirectoryFilter -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName $RelativePath } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

Export-ModuleMember -Function Find-ChildDirectoryFile

function Get-CompilerWrapperVariableName {
    param([switch]$IncludeCuda)
    $names = @('CMAKE_C_COMPILER_LAUNCHER', 'CMAKE_CXX_COMPILER_LAUNCHER', 'RUSTC_WRAPPER', 'CC_WRAPPER', 'CXX_WRAPPER')
    if ($IncludeCuda) { $names += 'CMAKE_CUDA_COMPILER_LAUNCHER' }
    return $names
}

function Set-CompilerWrapperEnvironment {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value, [switch]$IncludeCuda)
    foreach ($name in Get-CompilerWrapperVariableName -IncludeCuda:$IncludeCuda) {
        Set-Item -LiteralPath "Env:$name" -Value $Value
    }
}

function Remove-CompilerWrapperEnvironment {
    param([switch]$IncludeCuda)
    foreach ($name in Get-CompilerWrapperVariableName -IncludeCuda:$IncludeCuda) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Set-CompilerWrapperEnvironment, Remove-CompilerWrapperEnvironment

function Write-RedFindingList {
    param([Parameter(Mandatory)][string]$Header, [object[]]$Item = @())
    Write-Host $Header -ForegroundColor Red
    foreach ($finding in $Item) { Write-Host "  $finding" -ForegroundColor Red }
}

Export-ModuleMember -Function Write-RedFindingList

function New-TemporaryDirectory {
    param([Parameter(Mandatory)][string]$Prefix)
    $path = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Force -Path $path -ErrorAction Stop
    return $path
}

Export-ModuleMember -Function New-TemporaryDirectory
