#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    A Python repo's Windows CI build: pytest on each Python leg, the gating static analysis, then the packaging driver.
.DESCRIPTION
    python-ci-windows.yml's build script for a repo that ships none of its own; the twin of the Linux lane's ci_tests.sh,
    ci_static_analysis.sh and ci_packaging.sh. -SettingsFile sets any parameter below except the four paths, by name, and
    one passed on the command line wins. See docs/python-ci.md § The Windows build driver.
.PARAMETER RepoRoot
    The checkout to build; empty is the current directory.
.PARAMETER SettingsFile
    A .psd1 of parameter values; empty takes <RepoRoot>\scripts\windows\python-ci.psd1 when it exists.
.PARAMETER PackageName
    The importable package pytest covers; empty reads pyproject.toml's name.
.PARAMETER PythonVersions
    Comma or space separated legs; empty is the pinned X.Y, plus X.Yt when pyproject.toml declares free-threading.
    `pinned` stands for that X.Y, `pinnedt` for its twin.
.PARAMETER TestExtras
    Extras every leg syncs instead of all of them (the Linux lane's SYNC_EXTRAS).
.PARAMETER FreeThreadedExtras
    Extras an X.Yt leg syncs instead; set, that leg gates (FREE_THREADED_SYNC_EXTRAS).
.PARAMETER TestPaths
    Comma or space separated pytest paths; empty runs the project's testpaths.
.PARAMETER ExtraPaths
    Invoke-CiStaticAnalysis.ps1's -ExtraPaths (STATIC_ANALYSIS_EXTRA_PATHS).
.PARAMETER BanditExcludes
    Invoke-CiStaticAnalysis.ps1's -BanditExcludes; empty keeps its default.
.PARAMETER DataLocks
    Repo-relative data locks (a models.lock) the hub's fetch-data-lock.py fetches beside themselves before packaging.
.PARAMETER StaticAnalysisScript
    Test seam: the static-analysis driver, run as a child process.
.PARAMETER PackagingScript
    Test seam: the packaging driver, run as a child process.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$SettingsFile = '',
    [string]$PackageName = '',
    [string]$PythonVersions = '',
    [string]$TestExtras = '',
    [string]$FreeThreadedExtras = '',
    [string]$TestPaths = '',
    [string]$StaticAnalysisPythonVersion = '',
    [string[]]$ExtraPaths = @(),
    [string]$BanditExcludes = '',
    [string]$PackagingPythonVersion = '',
    [string[]]$DataLocks = @(),
    [string]$LogDir = 'logs',
    [switch]$EnablePySpy,
    [switch]$StopOnError,
    [string]$StaticAnalysisScript = (Join-Path $PSScriptRoot 'Invoke-CiStaticAnalysis.ps1'),
    [string]$PackagingScript = (Join-Path $PSScriptRoot 'Invoke-CiPackaging.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = (Get-Location).Path }
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'pyproject.toml') -PathType Leaf)) {
    throw "$RepoRoot has no pyproject.toml: pass -RepoRoot, or run from the repo root"
}
. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
$repoRoot = Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsScripts.Shared', 'WindowsBuild.Common', 'WindowsUv.Common', 'WindowsPythonWheel.Common') -EnterRepoRoot -RepoRoot $RepoRoot

if (-not $SettingsFile) {
    $candidate = Join-Path $repoRoot 'scripts\windows\python-ci.psd1'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $SettingsFile = $candidate }
}
if ($SettingsFile) {
    $settings = Import-PowerShellDataFile -LiteralPath $SettingsFile
    $fixed = @('RepoRoot', 'SettingsFile', 'StaticAnalysisScript', 'PackagingScript')
    foreach ($key in @($settings.Keys)) {
        if ($key -in $fixed -or -not $MyInvocation.MyCommand.Parameters.ContainsKey($key)) {
            throw "$SettingsFile sets '$key', which is not a setting of $($MyInvocation.MyCommand.Name)"
        }
        # The parameter's type converts the value, so a list given for PythonVersions joins with spaces.
        if (-not $PSBoundParameters.ContainsKey($key)) { Set-Variable -Name $key -Value $settings[$key] }
    }
}

$context = New-CiSession -RepoRoot $repoRoot -LogDir $LogDir -StopOnError:$StopOnError -WithUvDelegates
$uv = @{ CommandRunner = $script:UvCommandRunner; LogInfo = $script:UvLogInfo; LogWarning = $script:UvLogWarning }
$tracker = [System.Collections.Generic.List[string]]::new()
$PackageName = Get-PyprojectPackageName -RepoRoot $repoRoot -Default $PackageName

# A demo is a profiling showcase, not a gate: it logs "skipped", as on the Linux lane.
function Invoke-BenchDemo([string]$Label, [string[]]$Arguments) {
    $code = Invoke-BuildExternal -Context $context -File 'uv' -Parameters (@('run') + $Arguments) -IgnoreExitCode
    if ($code -ne 0) { Write-BuildLogWarning -Context $context -Message "$Label skipped (exit $code)" }
}

function Invoke-TestLeg([string]$Version, [string]$Extras) {
    Write-BuildLog -Context $context -Message "--- Python $Version ---"
    $envPath = New-TrackedUvEnvironment -Workspace $repoRoot -PythonVersion $Version -EnvName ".venv-$Version" -Tracker $tracker @uv
    try {
        $env:UV_SYNC_EXTRAS = $Extras
        try { Sync-UvProjectDependencies -NoBuildIsolationPackageWxPython -UseLocked:(Test-Path -LiteralPath 'uv.lock') @uv }
        finally { Remove-Item Env:UV_SYNC_EXTRAS -ErrorAction SilentlyContinue }
        $out = 'docs/test_results'
        Invoke-BuildExternal -Context $context -File 'uv' -Parameters (@('run', 'pytest') + @($TestPaths -split '[,\s]+' | Where-Object { $_ }) + @(
                '-v', "--cov=$PackageName", '--cov-report=term-missing', "--cov-report=html:$out/coverage-html-$Version",
                "--cov-report=xml:$out/coverage-$Version.xml", "--junitxml=$out/report-$Version.xml",
                "--html=$out/pytest-report-$Version.html", '--self-contained-html', '--md-report', '--md-report-verbose=1',
                '--md-report-output', "$out/pytest-report-$Version.md")) | Out-Null
        Invoke-BenchDemo 'demo_cprofile.py' @('python', 'bench/demo_cprofile.py')
        Invoke-BenchDemo 'demo_line_profiler.py' @('python', 'bench/demo_line_profiler.py')
        if ($EnablePySpy) {
            Invoke-BenchDemo 'py-spy profiling' @('py-spy', 'record', '--rate', '200', '--duration', '45', '-o', 'profile.svg', '--', 'python', 'bench/demo_py_spy.py')
        }
        Invoke-BenchDemo 'benchmark tests' @('pytest', 'bench/demo_pytest_benchmark.py')
    } finally {
        Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    }
}

# -Command, not -File: under -File an array parameter binds only its first element. Empty values keep the child's defaults.
function Invoke-ChildDriver([string]$Path, [System.Collections.IDictionary]$Arguments) {
    $quote = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    $text = "& $(& $quote $Path)"
    foreach ($name in $Arguments.Keys) {
        $values = @($Arguments[$name] | Where-Object { "$_" })
        if ($values.Count -gt 0) { $text += " -$name " + (@($values | ForEach-Object { & $quote $_ }) -join ',') }
    }
    Invoke-BuildExternal -Context $context -File 'pwsh' -Parameters @('-NoProfile', '-Command', $text) | Out-Null
}

try {
    try {
        Write-BuildLog -Context $context -Message "=== Windows build/test pipeline: $PackageName in $repoRoot ==="
        New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot 'docs\test_results') | Out-Null
        foreach ($leg in @(Resolve-PythonLegList -PythonVersions $PythonVersions -PyprojectPath (Join-Path $repoRoot 'pyproject.toml'))) {
            $extras = if ($TestExtras) { $TestExtras } elseif ($leg -match 't$' -and $FreeThreadedExtras) { $FreeThreadedExtras } else { '' }
            # As in ci_tests.sh: only a leg with no extras of its own may be experimental.
            $experimental = (-not $extras) -and (Test-ExperimentalPython -Version $leg)
            Invoke-BuildStep -Context $context -StepName "Python $leg - Tests" -AllowFailure:$experimental -Critical -Script {
                Invoke-TestLeg -Version $leg -Extras $extras
            } | Out-Null
        }

        Invoke-BuildStep -Context $context -StepName 'Static Analysis' -Critical -Script {
            Invoke-ChildDriver $StaticAnalysisScript ([ordered]@{
                    RepoRoot = $repoRoot; PythonVersion = $StaticAnalysisPythonVersion; PackageName = $PackageName
                    ExtraPaths = $ExtraPaths; BanditExcludes = $BanditExcludes
                })
        } | Out-Null

        Invoke-BuildStep -Context $context -StepName 'Packaging (source + Windows binaries)' -Critical -Script {
            $version = if ($PackagingPythonVersion) { $PackagingPythonVersion } else { (Get-PinnedPythonVersion).MajorMinor }
            $fetcher = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\linux\scripts\lib\fetch-data-lock.py'))
            foreach ($lock in $DataLocks) {
                $python = Find-UvPython -Request (Get-UvPythonRequest -Version $version)
                Invoke-BuildExternal -Context $context -File $python -Parameters @('-I', $fetcher, '--lock', (Join-Path $repoRoot $lock)) | Out-Null
            }
            Invoke-ChildDriver $PackagingScript ([ordered]@{ RepoRoot = $repoRoot; PythonVersion = $PackagingPythonVersion })
        } | Out-Null

        Write-BuildLog -Context $context -Message '=== Completed Windows build/test pipeline ==='
    } catch {
        Write-BuildLogError -Context $context -Message "Unhandled critical error: $($_.Exception.Message)"
        throw
    }
} finally {
    Remove-TrackedUvEnvironment -Tracker $tracker -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning
    Write-BuildSummary -Context $context
    Close-BuildLog -Context $context
    if ($context.Results.Failed.Count -gt 0) { exit 1 }
}
