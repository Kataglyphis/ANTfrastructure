<#
.SYNOPSIS
  Build script for running inside the Windows container, using the Kataglyphis-ContainerHub build framework.

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
$modulesPath = Join-Path $PSScriptRoot "..\modules"
$buildModule = Join-Path $modulesPath "WindowsBuild.Common.psm1"

if (-not (Test-Path $buildModule)) {
    Write-Error "Required module not found: $buildModule."
    exit 1
}

Import-Module $buildModule -Force

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

    # Read extra cargo args from environment (e.g. "--features with_cxxbridge")
    $ExtraCargoArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($env:EXTRA_CARGO_ARGS)) {
        $ExtraCargoArgs = $env:EXTRA_CARGO_ARGS -split ' '
        Write-BuildLog -Context $Context -Message "Extra cargo args: $($ExtraCargoArgs -join ' ')"
    }

    function Combine-Params {
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
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("install", "--locked", "cargo-audit", "cargo-deny")
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters "audit"
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters @("deny", "check", "advisories", "licenses", "bans", "sources")
    }

    Invoke-BuildStep -Context $Context -StepName "Format Check (cargo fmt)" -Critical -Script {
        Invoke-BuildExternal -Context $Context -File "rustup" -Parameters @("component", "add", "rustfmt")
        $fmtParams = @("fmt", "--all", "--", "--check")
        $fmtParams = Combine-Params -Base $fmtParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $fmtParams
    }

    Invoke-BuildStep -Context $Context -StepName "Linting (cargo clippy)" -Critical -Script {
        Invoke-BuildExternal -Context $Context -File "rustup" -Parameters @("component", "add", "clippy")
        $clippyParams = @("clippy", "--all-targets", "--all-features", "--", "-D", "warnings")
        $clippyParams = Combine-Params -Base $clippyParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $clippyParams
    }

    Invoke-BuildStep -Context $Context -StepName "Unit Tests" -Critical -Script {
        $testParams = @("test", "--all", "--verbose")
        $testParams = Combine-Params -Base $testParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $testParams
    }

    Invoke-BuildStep -Context $Context -StepName "Benchmarks" -Script {
        # Benchmarks might fail if not configured, leaving as non-critical
        $benchParams = @("bench")
        $benchParams = Combine-Params -Base $benchParams -Extra $ExtraCargoArgs
        Invoke-BuildExternal -Context $Context -File "cargo" -Parameters $benchParams
    }

    Invoke-BuildStep -Context $Context -StepName "Release Build" -Critical -Script {
        $buildParams = @("build", "--release")
        $buildParams = Combine-Params -Base $buildParams -Extra $ExtraCargoArgs
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
