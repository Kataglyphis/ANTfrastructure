# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
  Rust CI in the Windows container: security checks, fmt, clippy, tests, benches and the release build.
#>

param(
    [string]$Workspace = $env:WORKSPACE,
    [string]$Binary    = $env:BINARY,
    [string]$Version   = $env:VERSION
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    $Workspace = (Get-Location).Path
}

. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsScripts.Shared')

# The image env, else the checkout's versions.env, never a literal: unpinned, crates.io picks the verdict's version.
function Get-ANTfrastructurePin {
    param([Parameter(Mandatory)][string]$Name)

    $fromEnv = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv }

    # windows\scripts\rust -> windows\scripts -> windows -> the ANTfrastructure root.
    $versionsEnv = Join-Path $PSScriptRoot '..\..\..\linux\scripts\01-core\versions.env'
    if (Test-Path $versionsEnv) {
        $pins = ConvertFrom-VersionsEnv -Path $versionsEnv
        if ($pins.Contains($Name) -and -not [string]::IsNullOrWhiteSpace($pins[$Name])) {
            return $pins[$Name]
        }
    }
    throw ("$Name is not set and could not be read from $versionsEnv. " +
           'It pins a cargo tool whose verdict decides this lane; running the ' +
           'install unpinned would let crates.io choose the version instead.')
}

$CargoAuditVersion = Get-ANTfrastructurePin -Name 'CARGO_AUDIT_VERSION'
$CargoDenyVersion  = Get-ANTfrastructurePin -Name 'CARGO_DENY_VERSION'

$logDir = Join-Path $Workspace "logs"
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$Context = New-BuildContext -Workspace $Workspace -LogDir $logDir -StopOnError
Open-BuildLog -Context $Context

try {
    Write-BuildLog -Context $Context -Message "=== Build Environment ==="
    Write-BuildLog -Context $Context -Message "Workspace: $Workspace"
    Write-BuildLog -Context $Context -Message "BINARY:    $Binary"
    Write-BuildLog -Context $Context -Message "VERSION:   $Version"

    Set-Location -Path $Workspace

    Invoke-BuildStep -Context $Context -StepName "Setup Environment" -Critical -Script {
        $scoopShims = "C:\Users\ContainerAdministrator\scoop\shims"
        if (-not ($env:PATH -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ieq $scoopShims })) {
            Write-BuildLog -Context $Context -Message "Prepending scoop shims to PATH: $scoopShims"
            $env:PATH = "$scoopShims;$env:PATH"
        } else {
            Write-BuildLog -Context $Context -Message "Scoop shims already in PATH"
        }
    }

    Invoke-BuildStep -Context $Context -StepName "Verify Toolchain" -Critical -Script {
        Invoke-BuildExternal -Context $Context -File "rustup" -Parameters "--version"
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters "--version"
    }

    # EXTRA_CARGO_ARGS, e.g. "--features <feature>".
    $ExtraCargoArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($env:EXTRA_CARGO_ARGS)) {
        $ExtraCargoArgs = $env:EXTRA_CARGO_ARGS -split ' '
        Write-BuildLog -Context $Context -Message "Extra cargo args: $($ExtraCargoArgs -join ' ')"
    } else {
        $ExtraCargoArgs = @()
        Write-BuildLog -Context $Context -Message "No EXTRA_CARGO_ARGS specified; proceeding without extra cargo args."
    }

    function Join-ParameterSet {
        param(
            [array]$Base,
            [array]$Extra
        )
        if ($Extra.Length -eq 0) { return $Base }
        $sepIndex = [array]::IndexOf($Base, '--')
        if ($sepIndex -ge 0) {
            if ($sepIndex -gt 0) {
                $head = $Base[0..($sepIndex - 1)]
            } else {
                $head = @()
            }
            $tail = $Base[$sepIndex..($Base.Length - 1)]
            return ,($head + $Extra + $tail)
        } else {
            return ,($Base + $Extra)
        }
    }

    # The image's rustup has no dist server left, so a component is checked for, never installed.
    function Assert-CargoSubcommand {
        param([Parameter(Mandatory)][string]$Name)
        $out = @(& cargo $Name --version 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "cargo $Name is not installed for the active toolchain: $(($out | Out-String).Trim())"
        }
        Write-BuildLog -Context $Context -Message "cargo $Name`: $($out[0])"
    }

    Invoke-BuildStep -Context $Context -StepName "Security Checks (audit & deny)" -Script {
        # One crate per `cargo install`: --version applies to every crate on the line.
        Write-BuildLog -Context $Context -Message "cargo-audit $CargoAuditVersion / cargo-deny $CargoDenyVersion (versions.env)"
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("install", "--locked", "--version", $CargoAuditVersion, "cargo-audit")
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("install", "--locked", "--version", $CargoDenyVersion, "cargo-deny")
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters "audit"
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("deny", "check", "advisories", "licenses", "bans", "sources")
    }

    Invoke-BuildStep -Context $Context -StepName "Format Check (cargo fmt)" -Critical -Script {
        Assert-CargoSubcommand -Name 'fmt'
        $fmtParams = @("fmt", "--all", "--", "--check")
        $fmtParams = Join-ParameterSet -Base $fmtParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $fmtParams
    }

    Invoke-BuildStep -Context $Context -StepName "Linting (cargo clippy)" -Critical -Script {
        Assert-CargoSubcommand -Name 'clippy'
        $clippyParams = @("clippy", "--all-targets", "--all-features", "--", "-D", "warnings")
        $clippyParams = Join-ParameterSet -Base $clippyParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $clippyParams
    }

    Invoke-BuildStep -Context $Context -StepName "Unit Tests" -Critical -Script {
        $testParams = @("test", "--all", "--verbose")
        $testParams = Join-ParameterSet -Base $testParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $testParams
    }

    Invoke-BuildStep -Context $Context -StepName "Benchmarks" -Script {
        # Benchmarks might fail if not configured, leaving as non-critical
        $benchParams = @("bench")
        $benchParams = Join-ParameterSet -Base $benchParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $benchParams
    }

    Invoke-BuildStep -Context $Context -StepName "Release Build" -Critical -Script {
        $buildParams = @("build", "--release")
        $buildParams = Join-ParameterSet -Base $buildParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $buildParams
    }

    Write-BuildSummary -Context $Context
    Write-BuildLogSuccess -Context $Context -Message "Pipeline completed successfully."
    exit 0
} catch {
    Write-BuildLogError -Context $Context -Message "Pipeline failed: $($_.Exception.Message)"
    Write-BuildSummary -Context $Context
    exit 1
} finally {
    Close-BuildLog -Context $Context
}

