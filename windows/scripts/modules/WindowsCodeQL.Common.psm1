#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Consumed by OmniAccelerANT's Build-Windows.ps1 with no in-repo caller: see docs/consumer-inventory.md § Why a grep was not enough

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# Guarded, no -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

if (-not (Get-Module -Name 'WindowsBuild.Common')) {
    Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

function Get-ForwardSwitchValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$ForwardParameters,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $ForwardParameters.ContainsKey($Name)) {
        return $false
    }

    $value = $ForwardParameters[$Name]
    if ($value -is [System.Management.Automation.SwitchParameter]) {
        return $value.IsPresent
    }

    return [bool]$value
}

# Pure, so tests need no CLI; -CodeScanningConfig scopes the analysis, not what the extractor reads.
function Get-CodeQLDatabaseCreateArgs {
    param(
        [Parameter(Mandatory)]
        [string]$DbClusterDir,
        [Parameter(Mandatory)]
        [string[]]$Languages,
        [Parameter(Mandatory)]
        [string]$InnerCommand,
        [Parameter(Mandatory)]
        [string]$SourceRoot,
        [string]$CodeScanningConfig = '',
        [switch]$Overwrite
    )

    $createArgs = @('database', 'create', $DbClusterDir, '--db-cluster')
    foreach ($lang in $Languages) {
        $createArgs += "--language=$lang"
    }
    $createArgs += @(
        "--command=$InnerCommand",
        '--no-run-unnecessary-builds',
        "--source-root=$SourceRoot"
    )
    if (-not [string]::IsNullOrWhiteSpace($CodeScanningConfig)) {
        # A missing named config must fail rather than scan unscoped, vendored trees included.
        if (-not (Test-Path -LiteralPath $CodeScanningConfig -PathType Leaf)) {
            throw "CodeQL code-scanning config not found: $CodeScanningConfig"
        }
        $createArgs += "--codescanning-config=$((Resolve-Path -LiteralPath $CodeScanningConfig).Path)"
    }
    if ($Overwrite) {
        $createArgs += '--overwrite'
    }
    return $createArgs
}

function Invoke-CodeQLProcess {
    param(
        [Parameter(Mandatory)][string]$CodeQLExe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][int]$TimeoutMinutes
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $CodeQLExe
    foreach ($argument in $Arguments) { $psi.ArgumentList.Add($argument) }
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        # The extractor leaves children behind; kill the tree, not just the parent.
        & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        throw "CodeQL $Phase did not finish within $TimeoutMinutes min and was killed; raise CODEQL_TIMEOUT_MINUTES and watch the log."
    }
    return $proc.ExitCode
}

# The block-list `paths-ignore:` entries of a code-scanning config; comments and quotes stripped.
function Get-CodeScanningPathsIgnore {
    param([Parameter(Mandatory)][string]$ConfigPath)

    # The list ends at the next column-0 key; a column-0 comment does not end it.
    if ((Get-Content -LiteralPath $ConfigPath -Raw) -notmatch '(?ms)^paths-ignore:[^\n]*\n(.*?)(?=^[^\s#]|\z)') {
        return , [string[]]@()
    }
    $entries = foreach ($m in [regex]::Matches($Matches[1], '(?m)^[ \t]+-[ \t]+(.+?)[ \t]*(?:#.*)?\r?$')) {
        $m.Groups[1].Value.Trim('"', "'")
    }
    return , [string[]]@($entries)
}

# CodeQL's path semantics: a plain path covers itself and everything below it, * one segment, ** any depth.
function Test-CodeScanningPathIgnored {
    param([Parameter(Mandatory)][string]$Uri, [string[]]$Patterns = @())

    foreach ($pattern in $Patterns) {
        $p = $pattern.TrimEnd('/')
        if ($p -notmatch '[*?]') {
            if ($Uri -eq $p -or $Uri.StartsWith("$p/")) { return $true }
            continue
        }
        $rx = '^' + (([regex]::Escape($p) -replace '\\\*\\\*', '.*') -replace '\\\*', '[^/]*' -replace '\\\?', '[^/]') + '(/.*)?$'
        if ($Uri -match $rx) { return $true }
    }
    return $false
}

# `database analyze` applies paths-ignore to traced C++ not at all, so the results are filtered here; returns the count dropped.
function Remove-SarifIgnoredResult {
    param(
        [Parameter(Mandatory)][string]$SarifPath,
        [string[]]$IgnoredPaths
    )

    if (-not $IgnoredPaths) { return 0 }
    $sarif = Get-Content -LiteralPath $SarifPath -Raw | ConvertFrom-Json -Depth 100
    $dropped = 0
    foreach ($run in @($sarif.runs)) {
        if ($null -eq $run.PSObject.Properties['results']) { continue }
        $kept = @($run.results | Where-Object {
                $uri = "$($_.locations[0].physicalLocation.artifactLocation.uri)"
                -not ($uri -and (Test-CodeScanningPathIgnored -Uri $uri -Patterns $IgnoredPaths))
            })
        $dropped += @($run.results).Count - $kept.Count
        $run.results = $kept
    }
    if ($dropped -gt 0) {
        $sarif | ConvertTo-Json -Depth 100 -Compress | Set-Content -LiteralPath $SarifPath -Encoding utf8NoBOM
    }
    return $dropped
}

# The image's sccache server never exits (SCCACHE_IDLE_TIMEOUT=0) and keeps its client's pipe, so a traced build never ends.
function Disable-SccacheForTrace {
    $env:KATAGLYPHIS_NO_SCCACHE = '1'
    foreach ($name in @('RUSTC_WRAPPER', 'CC_WRAPPER', 'CXX_WRAPPER', 'CMAKE_C_COMPILER_LAUNCHER', 'CMAKE_CXX_COMPILER_LAUNCHER')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

function Invoke-BuildCodeQL {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [hashtable]$ForwardParameters,
        [Parameter(Mandatory)]
        [string]$BuildScriptPath,
        [string[]]$Languages = @('cpp', 'rust'),
        # Optional code-scanning config (see Get-CodeQLDatabaseCreateArgs); empty scans unscoped.
        [string]$CodeScanningConfig = ''
    )

    Write-BuildLog -Context $Context -Message "=== CodeQL Mode Active ==="

    $cleanCodeQLDb = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CleanCodeQLDb'
    $codeQLDownload = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CodeQLDownload'
    # Every phase is bounded: a hung extractor once burned a whole night with 8 s of CPU.
    $timeoutMinutes = 180
    if ($env:CODEQL_TIMEOUT_MINUTES) {
        $parsed = 0
        if ([int]::TryParse($env:CODEQL_TIMEOUT_MINUTES, [ref]$parsed) -and $parsed -gt 0) { $timeoutMinutes = $parsed }
    }

    Write-BuildLog -Context $Context -Message "CodeQL cleanup enabled: $cleanCodeQLDb"
    Write-BuildLog -Context $Context -Message "CodeQL download enabled: $codeQLDownload"

    # $env:CODEQL_VERSION pins a release tag (e.g. 'v2.18.4'), deliberately not a versions.env key; else latest.
    $codeQLUrl = if (-not [string]::IsNullOrWhiteSpace($env:CODEQL_VERSION)) {
        "https://github.com/github/codeql-cli-binaries/releases/download/$($env:CODEQL_VERSION)/codeql-win64.zip"
    } else {
        'https://github.com/github/codeql-cli-binaries/releases/latest/download/codeql-win64.zip'
    }
    $codeQLDir = Join-Path $Workspace 'codeql-cli'
    $codeQLExe = Join-Path $codeQLDir 'codeql\codeql.exe'

    if (-not (Test-Path $codeQLExe)) {
        Write-BuildLog -Context $Context -Message "Downloading CodeQL CLI from $codeQLUrl ..."
        New-Item -ItemType Directory -Force -Path $codeQLDir | Out-Null
        $zipPath = Join-Path $codeQLDir 'codeql.zip'
        # The PK guard rejects an HTML error page served as the asset.
        Invoke-DownloadWithRetry -Url $codeQLUrl -DestinationPath $zipPath -ExpectSignature 'PK' -Description 'CodeQL CLI (codeql-win64.zip)'
        Expand-Archive -Path $zipPath -DestinationPath $codeQLDir -Force
    }

    if ($codeQLDownload) {
        Write-BuildLog -Context $Context -Message 'Downloading query packs for all languages...'
        foreach ($lang in $Languages) {
            $queryPack = "codeql/$lang-queries"
            Write-BuildLog -Context $Context -Message "Downloading Query Pack: $queryPack..."
            & $codeQLExe pack download $queryPack

            if ($LASTEXITCODE -ne 0) {
                Write-BuildLogWarning -Context $Context -Message "Failed to download $queryPack, continuing..."
            }
        }
    } else {
        Write-BuildLog -Context $Context -Message 'Skipping query pack download (CodeQLDownload not set).'
    }

    $innerArgs = @{}
    foreach ($pair in $ForwardParameters.GetEnumerator()) {
        if ($pair.Key -eq 'CodeQL') {
            continue
        }
        $innerArgs[$pair.Key] = $pair.Value
    }

    $innerParamList = @()
    foreach ($pair in $innerArgs.GetEnumerator()) {
        if ($pair.Value -is [switch] -and $pair.Value.IsPresent) { $innerParamList += "-$($pair.Key)" }
        elseif ($pair.Value -is [bool] -and $pair.Value) { $innerParamList += "-$($pair.Key)" }
        elseif ($pair.Value -isnot [switch] -and $pair.Value -isnot [bool]) { $innerParamList += "-$($pair.Key)", "$($pair.Value)" }
    }
    # --command is one string CodeQL tokenizes itself, so quote each element; an interpolated array loses quoting.
    $innerCommandParts = @('cmd', '/c', 'pwsh', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BuildScriptPath) + $innerParamList
    $innerCommand = ($innerCommandParts | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { "$_" }
    }) -join ' '

    $dbClusterDir = Join-Path $Workspace 'codeql-db-cluster'
    $shouldCreateDbCluster = $true

    if (Test-Path $dbClusterDir) {
        if ($cleanCodeQLDb) {
            Write-BuildLog -Context $Context -Message "Cleaning existing CodeQL DB cluster: $dbClusterDir"
            Remove-Item -Recurse -Force $dbClusterDir
        } else {
            Write-BuildLog -Context $Context -Message "Keeping existing CodeQL DB cluster (CleanCodeQLDb not set): $dbClusterDir"
            $shouldCreateDbCluster = $false
        }
    }

    if ($shouldCreateDbCluster) {
        # A cache hit would also hide the compile from the extractor.
        Disable-SccacheForTrace
        Write-BuildLog -Context $Context -Message 'sccache is off for the traced build (KATAGLYPHIS_NO_SCCACHE=1, wrappers and launchers cleared).'
        $createArgs = Get-CodeQLDatabaseCreateArgs -DbClusterDir $dbClusterDir -Languages $Languages `
            -InnerCommand $innerCommand -SourceRoot $Workspace `
            -CodeScanningConfig $CodeScanningConfig -Overwrite:$cleanCodeQLDb

        $scope = if ($CodeScanningConfig) { $CodeScanningConfig } else { 'none, the analysis is unscoped' }
        Write-BuildLog -Context $Context -Message "Creating database cluster with languages: $($Languages -join ', '); code-scanning config: $scope"
        $createExit = Invoke-CodeQLProcess -CodeQLExe $codeQLExe -Arguments $createArgs -Phase 'database create' -TimeoutMinutes $timeoutMinutes

        if ($createExit -ne 0) {
            throw 'CodeQL Database Cluster creation failed'
        }
    } else {
        # The config is read at `database create` only: a reused cluster keeps its scope.
        Write-BuildLog -Context $Context -Message 'Skipping database creation and reusing existing CodeQL DB cluster (a code-scanning config applies only to a new one: -CleanCodeQLDb).'
    }

    $resultsDir = Join-Path $Workspace 'codeql-results'
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

    # Collected so the other languages still run, but any failure fails the function.
    $failedLanguages = @()

    foreach ($lang in $Languages) {
        Write-BuildLog -Context $Context -Message ''
        Write-BuildLog -Context $Context -Message '------------------------------------------------'
        Write-BuildLog -Context $Context -Message ">>> Analyzing Language: $lang"
        Write-BuildLog -Context $Context -Message '------------------------------------------------'

        $langDbDir = Join-Path $dbClusterDir $lang
        $sarifOutput = Join-Path $resultsDir "$lang.sarif"
        $querySuite = "codeql/$lang-queries:codeql-suites/$lang-security-and-quality.qls"

        $analyzeArgs = @(
            'database', 'analyze', $langDbDir,
            $querySuite,
            '--format=sarif-latest',
            "--output=$sarifOutput"
        )

        if ($codeQLDownload) {
            $analyzeArgs += '--download'
        }

        $analyzeExit = Invoke-CodeQLProcess -CodeQLExe $codeQLExe -Arguments $analyzeArgs -Phase "analyze $lang" -TimeoutMinutes $timeoutMinutes

        if ($analyzeExit -ne 0) {
            Write-BuildLogWarning -Context $Context -Message "Analysis with query suite failed for $lang, trying with query pack..."
            $fallbackQueryPack = "codeql/$lang-queries"
            $fallbackArgs = @(
                'database', 'analyze', $langDbDir,
                $fallbackQueryPack,
                '--format=sarif-latest',
                "--output=$sarifOutput"
            )

            if ($codeQLDownload) {
                $fallbackArgs += '--download'
            }

            $fallbackExit = Invoke-CodeQLProcess -CodeQLExe $codeQLExe -Arguments $fallbackArgs -Phase "analyze $lang (pack)" -TimeoutMinutes $timeoutMinutes
            if ($fallbackExit -ne 0) {
                Write-BuildLogError -Context $Context -Message "Analysis failed for $lang even with basic query pack"
                $failedLanguages += $lang
                continue
            }
        }

        Write-BuildLogSuccess -Context $Context -Message "Analysis completed for $lang. Results saved to: $sarifOutput"
        if ($CodeScanningConfig) {
            $dropped = Remove-SarifIgnoredResult -SarifPath $sarifOutput -IgnoredPaths (Get-CodeScanningPathsIgnore -ConfigPath $CodeScanningConfig)
            Write-BuildLog -Context $Context -Message "$lang`: dropped $dropped result(s) under the config's paths-ignore."
        }
    }

    if (@($failedLanguages).Count -gt 0) {
        throw "CodeQL analysis failed for language(s): $($failedLanguages -join ', '). See log above; partial results in: $resultsDir"
    }

    Write-BuildLog -Context $Context -Message ''
    Write-BuildLogSuccess -Context $Context -Message '=== CodeQL Analysis Complete ==='
    Write-BuildLog -Context $Context -Message "All results available in: $resultsDir"
}

Export-ModuleMember -Function @(
    'Disable-SccacheForTrace',
    'Get-CodeScanningPathsIgnore',
    'Test-CodeScanningPathIgnored',
    'Remove-SarifIgnoredResult',
    'Get-CodeQLDatabaseCreateArgs',
    'Invoke-CodeQLProcess',
    'Invoke-BuildCodeQL'
)


