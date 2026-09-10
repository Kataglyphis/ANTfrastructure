# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

<#
.SYNOPSIS
  Build script for running inside the Windows container, using the ContainerHub build framework.

.DESCRIPTION
  - Uses WindowsBuild.Common.psm1 for structured logging and step management.
  - Ensures Scoop shims are in PATH.
  - Verifies rustup/cargo install.
  - Runs security checks, linting, tests, benches, and release build.
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

# Import ContainerHub build framework (relative to this script's location in ContainerHub)
. (Join-Path $PSScriptRoot '..\modules\Initialize-CiEnvironment.ps1')
Initialize-CiEnvironment -ScriptRoot $PSScriptRoot -Modules @('WindowsBuild.Common', 'WindowsScripts.Shared')

# Resolve a versions.env pin at RUN time. Two channels, both real:
#   1. the process environment -- Dockerfile.base bakes every versions.env key
#      into the Machine environment (Import-Versions.ps1), and a Windows
#      container inherits that into every process, so inside the image the pin
#      is simply $env:<KEY>;
#   2. the checkout beside this script, for a host run where nothing is baked.
# NEITHER is allowed to fall back to a literal. `cargo install` with no
# --version resolves to whatever crates.io serves that minute, which is the
# hazard the versions.env note for these two keys describes: a new advisory-db
# schema or a new default lint turns this lane red with no commit behind it and
# nothing to bisect. An unresolvable pin THROWS instead.
function Get-ContainerHubPin {
    param([Parameter(Mandatory)][string]$Name)

    $fromEnv = [Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) { return $fromEnv }

    # windows\scripts\rust -> windows\scripts -> windows -> the ContainerHub root.
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

$CargoAuditVersion = Get-ContainerHubPin -Name 'CARGO_AUDIT_VERSION'
$CargoDenyVersion  = Get-ContainerHubPin -Name 'CARGO_DENY_VERSION'

# Initialize Build Context
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

    # Read extra cargo args from environment (e.g. "--features <feature>").
    # If none provided, no extra cargo args will be passed to cargo.
    $ExtraCargoArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($env:EXTRA_CARGO_ARGS)) {
        $ExtraCargoArgs = $env:EXTRA_CARGO_ARGS -split ' '
        Write-BuildLog -Context $Context -Message "Extra cargo args: $($ExtraCargoArgs -join ' ')"
    } else {
        # Default: no extra cargo args.
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

    Invoke-BuildStep -Context $Context -StepName "Security Checks (audit & deny)" -Script {
        # ONE crate per `cargo install`: `--version X a b` applies the SAME
        # version to every crate on the line, so the two pins cannot share an
        # invocation. Same split, same reason, as the Linux half in
        # linux/scripts/02-toolchain/rust/cargo_security_checks.sh.
        Write-BuildLog -Context $Context -Message "cargo-audit $CargoAuditVersion / cargo-deny $CargoDenyVersion (versions.env)"
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("install", "--locked", "--version", $CargoAuditVersion, "cargo-audit")
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("install", "--locked", "--version", $CargoDenyVersion, "cargo-deny")
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters "audit"
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("deny", "check", "advisories", "licenses", "bans", "sources")
    }

    Invoke-BuildStep -Context $Context -StepName "Format Check (cargo fmt)" -Critical -Script {
        Invoke-BuildExternal -Context $Context -File "rustup" -Parameters @("component", "add", "rustfmt")
        $fmtParams = @("fmt", "--all", "--", "--check")
        $fmtParams = Join-ParameterSet -Base $fmtParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $fmtParams
    }

    Invoke-BuildStep -Context $Context -StepName "Linting (cargo clippy)" -Critical -Script {
        Invoke-BuildExternal -Context $Context -File "rustup" -Parameters @("component", "add", "clippy")
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

