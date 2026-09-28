#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# NOTE (downstream consumers -- do NOT remove as "dead code"): this module has no
# callers inside THIS repo, but OmniAccelerANT's
# scripts/windows/Build-Windows.ps1 imports it from its ANTfrastructure submodule at
# third_party/ANTfrastructure/windows/scripts/modules/. It was deleted
# once in 5be9b1e and restored (2026-07-15) -- grep known consumers before any
# future sweep of windows/scripts/modules/.

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, Invoke-DownloadWithRetry, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# Guarded, WITHOUT -Force (repo-wide nested-import rule, 2026-08-04): a forced
# nested re-import rebinds the dependency into THIS module's private scope and
# unloads the caller's top-level import — the PS module-scoping trap that broke
# the BuildDriver test suite and forced build-gstreamer's import-Shared-twice
# workaround. Trade-off (accepted): a long-lived dev session that edits Shared
# must Remove-Module/reimport manually; containers always start fresh.
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# Logging/build primitives (Write-BuildLog*, Write-BuildLogWarning/Error/Success)
# come from the sibling WindowsBuild.Common module; without this import a
# standalone consumer of this module hits CommandNotFound at runtime. Guarded,
# WITHOUT -Force, for the same nested-import rule as above.
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

# The `codeql database create` argv, apart from the executable. Pure, so a suite can
# hold it without the CLI (Invoke-BuildCodeQL downloads and runs a real codeql.exe).
# -CodeScanningConfig is the scoping seam: a code-scanning config file (paths-ignore,
# query filters) that travels inside the database to `database analyze`. It scopes
# the ANALYSIS, not extraction -- a built language's extractor still reads whatever
# the build compiles.
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
        # A named config that is not there must fail, not scan unscoped: the whole
        # point of passing one is to keep vendored trees out of the results.
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
        # Optional code-scanning config (see Get-CodeQLDatabaseCreateArgs). Empty keeps
        # the previous, unscoped behaviour.
        [string]$CodeScanningConfig = ''
    )

    Write-BuildLog -Context $Context -Message "=== CodeQL Mode Active ==="

    $cleanCodeQLDb = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CleanCodeQLDb'
    $codeQLDownload = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CodeQLDownload'

    Write-BuildLog -Context $Context -Message "CodeQL cleanup enabled: $cleanCodeQLDb"
    Write-BuildLog -Context $Context -Message "CodeQL download enabled: $codeQLDownload"

    # Optional version pin via $env:CODEQL_VERSION (a codeql-cli-binaries
    # release tag, e.g. 'v2.18.4'); default keeps the previous latest-release
    # behavior. Deliberately NOT a versions.env key - that file has its own
    # process - just an overridable seam.
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
        # Retry-safe download (Shared helper) instead of raw Invoke-WebRequest;
        # the PK signature guard rejects HTML error pages served as the asset.
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
    # --command takes ONE string that CodeQL tokenizes itself. Interpolating a
    # PowerShell array would space-join the elements and lose all quoting, so
    # build the command line explicitly, quoting every element that contains
    # whitespace or quotes (embedded quotes are backslash-escaped).
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
        $createArgs = Get-CodeQLDatabaseCreateArgs -DbClusterDir $dbClusterDir -Languages $Languages `
            -InnerCommand $innerCommand -SourceRoot $Workspace `
            -CodeScanningConfig $CodeScanningConfig -Overwrite:$cleanCodeQLDb

        $scope = if ($CodeScanningConfig) { $CodeScanningConfig } else { 'none, the analysis is unscoped' }
        Write-BuildLog -Context $Context -Message "Creating database cluster with languages: $($Languages -join ', '); code-scanning config: $scope"
        & $codeQLExe @createArgs

        if ($LASTEXITCODE -ne 0) {
            throw 'CodeQL Database Cluster creation failed'
        }
    } else {
        # The config is read at `database create` only: a reused cluster keeps its scope.
        Write-BuildLog -Context $Context -Message 'Skipping database creation and reusing existing CodeQL DB cluster (a code-scanning config applies only to a new one: -CleanCodeQLDb).'
    }

    $resultsDir = Join-Path $Workspace 'codeql-results'
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

    # Languages whose analysis failed even on the fallback query pack. Collected
    # so the loop still analyzes the remaining languages, but the function no
    # longer reports success when any of them failed.
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

        & $codeQLExe @analyzeArgs

        if ($LASTEXITCODE -ne 0) {
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

            & $codeQLExe @fallbackArgs
            if ($LASTEXITCODE -ne 0) {
                Write-BuildLogError -Context $Context -Message "Analysis failed for $lang even with basic query pack"
                $failedLanguages += $lang
                continue
            }
        }

        Write-BuildLogSuccess -Context $Context -Message "Analysis completed for $lang. Results saved to: $sarifOutput"
    }

    if (@($failedLanguages).Count -gt 0) {
        throw "CodeQL analysis failed for language(s): $($failedLanguages -join ', '). See log above; partial results in: $resultsDir"
    }

    Write-BuildLog -Context $Context -Message ''
    Write-BuildLogSuccess -Context $Context -Message '=== CodeQL Analysis Complete ==='
    Write-BuildLog -Context $Context -Message "All results available in: $resultsDir"
}

Export-ModuleMember -Function @(
    'Get-CodeQLDatabaseCreateArgs',
    'Invoke-BuildCodeQL'
)


