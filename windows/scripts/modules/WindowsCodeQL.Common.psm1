#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Consumed by OmniAccelerANT's Build-Windows.ps1 with no in-repo caller: see docs/consumer-inventory.md § Why a grep was not enough

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
Import-Module $sharedPath

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
    Remove-CompilerWrapperEnvironment
}

function Get-CodeQLTimeoutMinutes {
    # A hung extractor once burned a whole night, so database creation and analysis have watchdogs.
    $timeoutMinutes = 180
    if ($env:CODEQL_TIMEOUT_MINUTES) {
        $parsed = 0
        if ([int]::TryParse($env:CODEQL_TIMEOUT_MINUTES, [ref]$parsed) -and $parsed -gt 0) { $timeoutMinutes = $parsed }
    }
    return $timeoutMinutes
}

function Resolve-CodeQLExecutable {
    param([pscustomobject]$Context, [string]$Workspace)

    $codeQLDir = Join-Path $Workspace 'codeql-cli'
    $codeQLExe = Join-Path $codeQLDir 'codeql\codeql.exe'
    if (Test-Path $codeQLExe) { return $codeQLExe }

    # $env:CODEQL_VERSION pins a release tag, deliberately not a versions.env key; else latest.
    $codeQLUrl = if (-not [string]::IsNullOrWhiteSpace($env:CODEQL_VERSION)) {
        "https://github.com/github/codeql-cli-binaries/releases/download/$($env:CODEQL_VERSION)/codeql-win64.zip"
    } else {
        'https://github.com/github/codeql-cli-binaries/releases/latest/download/codeql-win64.zip'
    }
    Write-BuildLog -Context $Context -Message "Downloading CodeQL CLI from $codeQLUrl ..."
    New-Item -ItemType Directory -Force -Path $codeQLDir | Out-Null
    $zipPath = Join-Path $codeQLDir 'codeql.zip'
    # The PK guard rejects an HTML error page served as the asset.
    Invoke-DownloadWithRetry -Url $codeQLUrl -DestinationPath $zipPath -ExpectSignature 'PK' -Description 'CodeQL CLI (codeql-win64.zip)'
    Expand-Archive -Path $zipPath -DestinationPath $codeQLDir -Force
    return $codeQLExe
}

function Invoke-CodeQLPackDownload {
    param([string]$CodeQLExe, [string]$QueryPack)
    & $CodeQLExe pack download $QueryPack | Out-Host
    return $LASTEXITCODE
}

function Invoke-CodeQLPackDownloads {
    param([pscustomobject]$Context, [string]$CodeQLExe, [string[]]$Languages, [bool]$Download)

    if (-not $Download) {
        Write-BuildLog -Context $Context -Message 'Skipping query pack download (CodeQLDownload not set).'
        return
    }
    Write-BuildLog -Context $Context -Message 'Downloading query packs for all languages...'
    foreach ($lang in $Languages) {
        $queryPack = "codeql/$lang-queries"
        Write-BuildLog -Context $Context -Message "Downloading Query Pack: $queryPack..."
        $downloadExit = Invoke-CodeQLPackDownload -CodeQLExe $CodeQLExe -QueryPack $queryPack
        if ($downloadExit -ne 0) {
            Write-BuildLogWarning -Context $Context -Message "Failed to download $queryPack, continuing..."
        }
    }
}

function Get-CodeQLInnerCommand {
    param([hashtable]$ForwardParameters, [string]$BuildScriptPath)

    $innerArgs = @{}
    foreach ($pair in $ForwardParameters.GetEnumerator()) {
        if ($pair.Key -eq 'CodeQL') { continue }
        $innerArgs[$pair.Key] = $pair.Value
    }
    $innerParamList = @()
    foreach ($pair in $innerArgs.GetEnumerator()) {
        if ($pair.Value -is [switch] -and $pair.Value.IsPresent) { $innerParamList += "-$($pair.Key)" }
        elseif ($pair.Value -is [bool] -and $pair.Value) { $innerParamList += "-$($pair.Key)" }
        elseif ($pair.Value -isnot [switch] -and $pair.Value -isnot [bool]) { $innerParamList += "-$($pair.Key)", "$($pair.Value)" }
    }
    # CodeQL tokenizes --command as one string, so an interpolated array loses quoting.
    $innerCommandParts = @('cmd', '/c', 'pwsh', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BuildScriptPath) + $innerParamList
    return ($innerCommandParts | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { "$_" }
    }) -join ' '
}

function Invoke-CodeQLRunPhase {
    param([pscustomobject]$Run, [string[]]$Arguments, [string]$Phase, [string]$FailureMessage = '')
    $succeeded = 0 -eq (Invoke-CodeQLProcess -CodeQLExe $Run.CodeQLExe -Arguments $Arguments -Phase $Phase -TimeoutMinutes $Run.TimeoutMinutes)
    if (-not $succeeded -and $FailureMessage) { throw $FailureMessage }
    return $succeeded
}

function Write-CodeQLMessages {
    param([pscustomobject]$Context, [string[]]$Messages)
    foreach ($message in $Messages) { Write-BuildLog -Context $Context -Message $message }
}

function Initialize-CodeQLDatabaseCluster {
    param([pscustomobject]$Run, [string]$InnerCommand, [bool]$CleanCodeQLDb)

    $dbClusterDir = Join-Path $Run.Workspace 'codeql-db-cluster'
    if (Test-Path $dbClusterDir) {
        if ($CleanCodeQLDb) {
            Write-BuildLog -Context $Run.Context -Message "Cleaning existing CodeQL DB cluster: $dbClusterDir"
            Remove-Item -Recurse -Force $dbClusterDir
        } else {
            # A reused cluster keeps its original config because only database create reads it.
            Write-CodeQLMessages -Context $Run.Context -Messages @(
                "Keeping existing CodeQL DB cluster (CleanCodeQLDb not set): $dbClusterDir",
                'Skipping database creation and reusing existing CodeQL DB cluster (a code-scanning config applies only to a new one: -CleanCodeQLDb).'
            )
            return $dbClusterDir
        }
    }

    # A cache hit would also hide the compile from the extractor.
    Disable-SccacheForTrace
    Write-BuildLog -Context $Run.Context -Message 'sccache is off for the traced build (KATAGLYPHIS_NO_SCCACHE=1, wrappers and launchers cleared).'
    $createArgs = Get-CodeQLDatabaseCreateArgs -DbClusterDir $dbClusterDir -Languages $Run.Languages -InnerCommand $InnerCommand -SourceRoot $Run.Workspace -CodeScanningConfig $Run.CodeScanningConfig -Overwrite:$CleanCodeQLDb
    $scope = if ($Run.CodeScanningConfig) { $Run.CodeScanningConfig } else { 'none, the analysis is unscoped' }
    Write-BuildLog -Context $Run.Context -Message "Creating database cluster with languages: $($Run.Languages -join ', '); code-scanning config: $scope"
    $null = Invoke-CodeQLRunPhase -Run $Run -Arguments $createArgs -Phase 'database create' -FailureMessage 'CodeQL Database Cluster creation failed'
    return $dbClusterDir
}

function Get-CodeQLAnalyzeArgs {
    param([string]$LangDbDir, [string]$Query, [string]$SarifOutput, [bool]$Download)
    $analyzeArgs = @('database', 'analyze', $LangDbDir, $Query, '--format=sarif-latest', "--output=$SarifOutput")
    if ($Download) { $analyzeArgs += '--download' }
    return $analyzeArgs
}

function Invoke-CodeQLLanguageAnalysis {
    param([pscustomobject]$Run, [string]$DbClusterDir, [string]$ResultsDir, [string]$Language)

    Write-CodeQLMessages -Context $Run.Context -Messages @('', '------------------------------------------------', ">>> Analyzing Language: $Language", '------------------------------------------------')

    $langDbDir = Join-Path $DbClusterDir $Language
    $sarifOutput = Join-Path $ResultsDir "$Language.sarif"
    $querySuite = "codeql/$Language-queries:codeql-suites/$Language-security-and-quality.qls"
    $analyzeArgs = Get-CodeQLAnalyzeArgs -LangDbDir $langDbDir -Query $querySuite -SarifOutput $sarifOutput -Download $Run.Download

    if (-not (Invoke-CodeQLRunPhase -Run $Run -Arguments $analyzeArgs -Phase "analyze $Language")) {
        Write-BuildLogWarning -Context $Run.Context -Message "Analysis with query suite failed for $Language, trying with query pack..."
        $fallbackQueryPack = "codeql/$Language-queries"
        $fallbackArgs = Get-CodeQLAnalyzeArgs -LangDbDir $langDbDir -Query $fallbackQueryPack -SarifOutput $sarifOutput -Download $Run.Download
        if (-not (Invoke-CodeQLRunPhase -Run $Run -Arguments $fallbackArgs -Phase "analyze $Language (pack)")) {
            Write-BuildLogError -Context $Run.Context -Message "Analysis failed for $Language even with basic query pack"
            return $false
        }
    }

    Write-BuildLogSuccess -Context $Run.Context -Message "Analysis completed for $Language. Results saved to: $sarifOutput"
    if ($Run.CodeScanningConfig) {
        $dropped = Remove-SarifIgnoredResult -SarifPath $sarifOutput -IgnoredPaths (Get-CodeScanningPathsIgnore -ConfigPath $Run.CodeScanningConfig)
        Write-BuildLog -Context $Run.Context -Message ("{0}: dropped {1} result(s) under the config's paths-ignore." -f $Language, $dropped)
    }
    return $true
}

function Invoke-CodeQLAnalyses {
    param([pscustomobject]$Run, [string]$DbClusterDir, [string]$ResultsDir)

    # Other languages still run, but each failure reaches the final verdict.
    $failedLanguages = @()
    foreach ($lang in $Run.Languages) {
        $succeeded = Invoke-CodeQLLanguageAnalysis -Run $Run -DbClusterDir $DbClusterDir -ResultsDir $ResultsDir -Language $lang
        if (-not $succeeded) { $failedLanguages += $lang }
    }
    if (@($failedLanguages).Count -gt 0) {
        throw "CodeQL analysis failed for language(s): $($failedLanguages -join ', '). See log above; partial results in: $ResultsDir"
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
        # Optional config scopes analysis; an empty value scans unscoped.
        [string]$CodeScanningConfig = ''
    )

    Write-BuildLog -Context $Context -Message "=== CodeQL Mode Active ==="
    $cleanCodeQLDb = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CleanCodeQLDb'
    $codeQLDownload = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CodeQLDownload'
    $timeoutMinutes = Get-CodeQLTimeoutMinutes
    Write-BuildLog -Context $Context -Message "CodeQL cleanup enabled: $cleanCodeQLDb"
    Write-BuildLog -Context $Context -Message "CodeQL download enabled: $codeQLDownload"

    $codeQLExe = Resolve-CodeQLExecutable -Context $Context -Workspace $Workspace
    Invoke-CodeQLPackDownloads -Context $Context -CodeQLExe $codeQLExe -Languages $Languages -Download $codeQLDownload
    $innerCommand = Get-CodeQLInnerCommand -ForwardParameters $ForwardParameters -BuildScriptPath $BuildScriptPath
    $run = [pscustomobject]@{
        Context = $Context; Workspace = $Workspace; CodeQLExe = $codeQLExe
        Languages = $Languages; CodeScanningConfig = $CodeScanningConfig
        Download = $codeQLDownload; TimeoutMinutes = $timeoutMinutes
    }
    $dbClusterDir = Initialize-CodeQLDatabaseCluster -Run $run -InnerCommand $innerCommand -CleanCodeQLDb $cleanCodeQLDb
    $resultsDir = Join-Path $Workspace 'codeql-results'
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null
    Invoke-CodeQLAnalyses -Run $run -DbClusterDir $dbClusterDir -ResultsDir $resultsDir
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


