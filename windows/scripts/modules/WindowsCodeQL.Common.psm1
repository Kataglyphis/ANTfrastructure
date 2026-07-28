# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NOTE (downstream consumers -- do NOT remove as "dead code"): this module has no
# callers inside THIS repo, but Kataglyphis-Inference-Engine's
# scripts/windows/Build-Windows.ps1 imports it from its ContainerHub submodule at
# ExternalLib/Kataglyphis-ContainerHub/windows/scripts/modules/. It was deleted
# once in 5be9b1e and restored (2026-07-15) -- grep known consumers before any
# future sweep of windows/scripts/modules/.

Set-StrictMode -Version Latest
#requires -Version 7.0


# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

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
        [string[]]$Languages = @('cpp', 'rust')
    )

    Write-BuildLog -Context $Context -Message "=== CodeQL Mode Active ==="

    $cleanCodeQLDb = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CleanCodeQLDb'
    $codeQLDownload = Get-ForwardSwitchValue -ForwardParameters $ForwardParameters -Name 'CodeQLDownload'

    Write-BuildLog -Context $Context -Message "CodeQL cleanup enabled: $cleanCodeQLDb"
    Write-BuildLog -Context $Context -Message "CodeQL download enabled: $codeQLDownload"

    $codeQLUrl = 'https://github.com/github/codeql-cli-binaries/releases/latest/download/codeql-win64.zip'
    $codeQLDir = Join-Path $Workspace 'codeql-cli'
    $codeQLExe = Join-Path $codeQLDir 'codeql\codeql.exe'

    if (-not (Test-Path $codeQLExe)) {
        Write-BuildLog -Context $Context -Message 'Downloading CodeQL CLI...'
        New-Item -ItemType Directory -Force -Path $codeQLDir | Out-Null
        $zipPath = Join-Path $codeQLDir 'codeql.zip'
        Invoke-WebRequest -Uri $codeQLUrl -OutFile $zipPath
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
    $innerCommand = @('cmd', '/c', 'powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BuildScriptPath) + $innerParamList

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

    $languageArgs = @()
    foreach ($lang in $Languages) {
        $languageArgs += "--language=$lang"
    }

    if ($shouldCreateDbCluster) {
        $createArgs = @(
            'database', 'create', $dbClusterDir,
            '--db-cluster'
        ) + $languageArgs + @(
            "--command=$innerCommand",
            '--no-run-unnecessary-builds',
            "--source-root=$Workspace"
        )

        if ($cleanCodeQLDb) {
            $createArgs += '--overwrite'
        }

        Write-BuildLog -Context $Context -Message "Creating database cluster with languages: $($Languages -join ', ')"
        & $codeQLExe @createArgs

        if ($LASTEXITCODE -ne 0) {
            throw 'CodeQL Database Cluster creation failed'
        }
    } else {
        Write-BuildLog -Context $Context -Message 'Skipping database creation and reusing existing CodeQL DB cluster.'
    }

    $resultsDir = Join-Path $Workspace 'codeql-results'
    New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

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
                continue
            }
        }

        Write-BuildLogSuccess -Context $Context -Message "Analysis completed for $lang. Results saved to: $sarifOutput"
    }

    Write-BuildLog -Context $Context -Message ''
    Write-BuildLogSuccess -Context $Context -Message '=== CodeQL Analysis Complete ==='
    Write-BuildLog -Context $Context -Message "All results available in: $resultsDir"
}

Export-ModuleMember -Function @(
    'Invoke-BuildCodeQL'
)

