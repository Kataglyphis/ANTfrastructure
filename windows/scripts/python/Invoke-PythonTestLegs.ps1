#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Runs a Python project's pytest suite once per Python leg on the runner itself, for python-ci-windows.yml's arm64 job.

<#
.SYNOPSIS
    Syncs and tests each -PythonVersions leg with uv, and fails naming every leg that failed.
.DESCRIPTION
    The runner-native twin of linux/scripts/02-toolchain/python/ci_tests.sh: the project's own testpaths unless
    -TestPaths names others, -Extras for every leg (empty: all extras), and a free-threaded leg (3.14t) that syncs only
    -FreeThreadedExtras when set. Every leg gates, and a failed leg does not stop the next one. -InstallUv first puts
    the uv that versions.env pins (UV_VERSION, UV_WINDOWS_<ARCH>_SHA256) on PATH.
#>
[CmdletBinding()]
param(
    [string]$PythonVersions = '3.14',
    [string]$Extras = '',
    [string]$FreeThreadedExtras = '',
    [string]$TestPaths = '',
    [switch]$InstallUv,
    [ValidateSet('arm64', 'amd64')][string]$UvArch = $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }),
    # For tests: another versions.env, and a release base the uv zip is fetched from (file:// works).
    [string]$VersionsEnvPath = (Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env'),
    [string]$UvReleaseBase = 'https://github.com/astral-sh/uv/releases/download'
)

$ErrorActionPreference = 'Stop'
# A failing leg is counted below, not raised by the first native command that exits non-zero.
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsScripts.Shared.psm1')
Import-Module (Join-Path $PSScriptRoot '..\modules\WindowsUv.Common.psm1')

# Comma or space separated, as the workflow inputs are.
function Split-List([string]$Value) { return @($Value -split '[,\s]+' | Where-Object { $_ }) }

if ($InstallUv) {
    $versions = ConvertFrom-VersionsEnv -Path $VersionsEnvPath
    $shaKey = "UV_WINDOWS_$($UvArch.ToUpperInvariant())_SHA256"
    foreach ($key in 'UV_VERSION', $shaKey) {
        if (-not $versions.Contains($key) -or -not $versions[$key]) { throw "$key is not set in $VersionsEnvPath; this ANTfrastructure pin cannot install uv" }
    }
    $triple = if ($UvArch -eq 'arm64') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
    $tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
    $zip = Join-Path $tmp "uv-$triple.zip"
    Invoke-DownloadWithRetry -Url "$UvReleaseBase/$($versions['UV_VERSION'])/uv-$triple.zip" -DestinationPath $zip -ExpectSignature PK
    Assert-FileSha256 -Path $zip -Expected $versions[$shaKey] -Label "uv $($versions['UV_VERSION']) ($triple)" -PinName $shaKey
    $uvDir = Join-Path $tmp 'uv-pinned'
    Expand-Archive -LiteralPath $zip -DestinationPath $uvDir -Force
    $env:PATH = "$uvDir;$env:PATH"
}

$legs = @(Split-List $PythonVersions)
if ($legs.Count -eq 0) { throw '-PythonVersions names no leg' }
$paths = @(Split-List $TestPaths)
$failed = [System.Collections.Generic.List[string]]::new()
foreach ($leg in $legs) {
    $legExtras = if ($leg -match 't$' -and $FreeThreadedExtras) { $FreeThreadedExtras } else { $Extras }
    $syncArgs = @('sync', '--dev')
    $syncArgs += if ($legExtras) { Split-List $legExtras | ForEach-Object { '--extra', $_ } } else { '--all-extras' }
    if (Test-Path -LiteralPath 'uv.lock') { $syncArgs += '--locked' }
    Write-Host "=== Python ${leg}: uv $($syncArgs -join ' ')"
    # A venv per leg, and 3.14 as 3.14+gil: uv would otherwise hand a bare 3.14 the free-threaded build a 3.14t leg fetched.
    try { $null = New-UvProjectEnvironment -Workspace (Get-Location).Path -EnvName ".venv-ci-$leg" -PythonVersion $leg }
    catch { $failed.Add("$leg (venv: $($_.Exception.Message))"); continue }
    & uv @syncArgs
    if ($LASTEXITCODE -ne 0) { $failed.Add("$leg (sync exited $LASTEXITCODE)"); continue }
    & uv run --no-sync python -m pytest @paths
    if ($LASTEXITCODE -ne 0) { $failed.Add("$leg (pytest exited $LASTEXITCODE)") }
}
Remove-Item Env:UV_PROJECT_ENVIRONMENT -ErrorAction SilentlyContinue
if ($failed.Count -gt 0) { throw "Python legs failed: $($failed -join ', ')" }
Write-Host "All $($legs.Count) Python leg(s) passed: $($legs -join ', ')"
