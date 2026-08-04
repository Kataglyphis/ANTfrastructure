# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

#requires -Version 7.0

# WindowsVulkanValidation.Common - generic driver for "run a Vulkan executable
# with the Khronos validation layer's synchronization validation turned on and
# fail if the log contains a SYNC-HAZARD".
#
# This module is project-agnostic: nothing project-specific is hard-coded here.
# A thin wrapper script imports it, supplies its own executable / working
# directory / log directory defaults, and turns the result into an exit code.
#
# Why the module exists at all: synchronization validation is not part of core
# validation and is off by default (it is expensive - it tracks every command's
# resource accesses), so it can only be enabled through a vk_layer_settings.txt.
# The loader reads that file from the CURRENT WORKING DIRECTORY or from the
# directory containing the running executable - there is no environment
# variable pointing at an arbitrary path - so the file has to be staged next to
# the binary for the duration of one run and removed again afterwards. Checking
# a permanent copy in next to the binary would silently enable sync validation,
# with its overhead, on every later unrelated run. That staging dance, the
# VK_LAYER_PATH save/restore, and the log scan are identical for every Vulkan
# project; only the executable and its arguments differ.
#
# Function contract:
#   Get-VulkanLayerSettingsDefaultPath - packaged vk_layer_settings.txt default
#   Copy-VulkanLayerSettings           - stage a settings file next to a binary
#   Restore-VulkanLayerSettings        - undo the staging (incl. any backup)
#   Get-VulkanValidationHazard         - scan a log for hazard/validation lines
#   Write-VulkanValidationReport       - print the per-hazard summary + count
#   Test-VulkanValidationLog           - scan + report, $true when the log is clean
#   Invoke-VulkanValidationRun         - stage, set env, run, restore, write log
#
# Invoke-VulkanValidationRun deliberately does NOT return the exit code on the
# pipeline: the executable under test writes to stdout, so a captured return
# value would collect its output. The exit code is left in $LASTEXITCODE, which
# is what the wrapper scripts inspect (same contract as
# WindowsAppRunner.Common's Invoke-AppRun).

Set-StrictMode -Version Latest

# Packaged, deliberately minimal vk_layer_settings.txt. Staged by
# Invoke-VulkanValidationRun when the caller passes no -SettingsPath, so a
# project with no checked-in settings file still gets a working sync-validation
# run. Projects that want to document or extend the settings keep their own
# copy and pass -SettingsPath explicitly.
function Get-VulkanLayerSettingsDefaultPath {
    return (Join-Path $PSScriptRoot 'vk_layer_settings.default.txt')
}

# Copies $SettingsPath into $TargetDirectory as vk_layer_settings.txt and
# returns a staging handle for Restore-VulkanLayerSettings.
#
# If the target directory already contains a vk_layer_settings.txt (a project
# that ships one next to its binaries), it is moved aside first and restored on
# cleanup - staging must never destroy a file the caller did not create.
function Copy-VulkanLayerSettings {
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath,
        [Parameter(Mandatory)]
        [string]$TargetDirectory
    )

    if (-not (Test-Path $SettingsPath)) {
        throw "Vulkan layer settings file not found at '$SettingsPath'."
    }
    if (-not (Test-Path $TargetDirectory)) {
        throw "Target directory for vk_layer_settings.txt not found at '$TargetDirectory'."
    }

    $stagedPath = Join-Path $TargetDirectory 'vk_layer_settings.txt'
    $backupPath = $null
    if (Test-Path $stagedPath) {
        $backupPath = "$stagedPath.pre-sync-validation.bak"
        Move-Item -LiteralPath $stagedPath -Destination $backupPath -Force
    }

    Copy-Item -LiteralPath (Resolve-Path $SettingsPath).Path -Destination $stagedPath -Force

    return [pscustomobject]@{
        StagedPath = $stagedPath
        BackupPath = $backupPath
        SourcePath = (Resolve-Path $SettingsPath).Path
    }
}

# Removes the staged vk_layer_settings.txt and puts back whatever was there
# before. Safe to call from a finally block: a $null handle is ignored and
# missing files are not an error, so a failure mid-run still cleans up.
function Restore-VulkanLayerSettings {
    param(
        [Parameter(ValueFromPipeline)]
        [psobject]$Staging
    )

    process {
        if ($null -eq $Staging) { return }

        # Never leave a copy lying around next to the binary - it would silently
        # enable (expensive) sync validation on every later, unrelated run.
        Remove-Item -LiteralPath $Staging.StagedPath -Force -ErrorAction SilentlyContinue

        if ($Staging.BackupPath -and (Test-Path $Staging.BackupPath)) {
            Move-Item -LiteralPath $Staging.BackupPath -Destination $Staging.StagedPath -Force
        }
    }
}

# Returns the log lines matching any hazard pattern (Select-String MatchInfo
# objects, so callers keep line numbers and text).
#
# The default pattern is the synchronization validation marker SYNC-HAZARD;
# pass -Pattern to widen the scan to other validation output, e.g.
# @('SYNC-HAZARD', 'VUID-', 'Validation Error') for a general validation gate.
# Matching is literal (-SimpleMatch), so a pattern is a substring, not a regex.
function Get-VulkanValidationHazard {
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,
        [string[]]$Pattern = @('SYNC-HAZARD')
    )

    if (-not (Test-Path $LogPath)) {
        throw "Log file not found at '$LogPath'."
    }

    return @(Select-String -Path $LogPath -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue)
}

# Prints the per-hazard summary the caller sees on failure, with the count in
# the header and the full log path so the run can be inspected afterwards.
function Write-VulkanValidationReport {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$Hazard,
        [Parameter(Mandatory)]
        [string]$LogPath,
        [string]$Label = 'SYNCHRONIZATION HAZARDS'
    )

    Write-Host ''
    Write-Host "=== $Label DETECTED ($($Hazard.Count)) ===" -ForegroundColor Red
    foreach ($line in $Hazard) {
        Write-Host "  $($line.Line.Trim())" -ForegroundColor Red
    }
    Write-Host "Full log: $LogPath" -ForegroundColor Red
}

# Scan + report in one call: returns $true when the log is clean, $false (after
# printing the hazard report) when it is not. Wrappers map that straight onto
# their exit code.
function Test-VulkanValidationLog {
    param(
        [Parameter(Mandatory)]
        [string]$LogPath,
        [string[]]$Pattern = @('SYNC-HAZARD'),
        [string]$Label = 'SYNCHRONIZATION HAZARDS',
        # Suppresses the "=== NO ... DETECTED ===" success line for callers that
        # print their own.
        [switch]$Quiet
    )

    $hazards = @(Get-VulkanValidationHazard -LogPath $LogPath -Pattern $Pattern)
    if ($hazards.Count -gt 0) {
        Write-VulkanValidationReport -Hazard $hazards -LogPath $LogPath -Label $Label
        return $false
    }

    if (-not $Quiet) {
        Write-Host "=== NO $Label DETECTED ===" -ForegroundColor Green
    }
    return $true
}

# Full pipeline: stage the layer settings next to the executable, point
# VK_LAYER_PATH at the SDK's layer directory, run the executable from
# $WorkingDirectory and tee its output into $LogPath.
#
# The environment and the staged settings file are restored in a finally block,
# so a crashing or interrupted run leaves neither behind. The process exit code
# is left in $LASTEXITCODE (1 when the process could not be started at all);
# the log is always written, so the caller can scan it either way.
function Invoke-VulkanValidationRun {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,
        [string[]]$Arguments = @(),
        # The application usually resolves shaders/models/textures relative to
        # the CWD, which is rarely the directory the binary lives in.
        [string]$WorkingDirectory = (Get-Location).Path,
        [Parameter(Mandatory)]
        [string]$LogPath,
        # Directory containing the Khronos validation layer (the Vulkan SDK's
        # Bin on Windows). Left untouched when empty, so a system-installed
        # layer is used as-is.
        [string]$LayerPath,
        # Source of the vk_layer_settings.txt staged next to the executable.
        # Defaults to the module's packaged minimal settings file.
        [string]$SettingsPath,
        # Hard cap on the run in seconds. 0 (the default) waits forever and
        # streams the output live; a positive value redirects the output to
        # files, waits with a timeout and kills the process if it overruns
        # (the log is still written, so the scan below stays meaningful).
        [int]$TimeoutSeconds = 0
    )

    if (-not (Test-Path $ExecutablePath)) {
        throw "Executable not found at '$ExecutablePath'."
    }
    $ExecutablePath = (Resolve-Path $ExecutablePath).Path

    if ($LayerPath -and -not (Test-Path $LayerPath)) {
        throw "Vulkan layer directory not found at '$LayerPath'."
    }
    if (-not (Test-Path $WorkingDirectory)) {
        throw "Working directory not found at '$WorkingDirectory'."
    }

    if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
        $SettingsPath = Get-VulkanLayerSettingsDefaultPath
    }

    $logDirectory = Split-Path $LogPath -Parent
    if ($logDirectory -and -not (Test-Path $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    # The loader reads vk_layer_settings.txt from the CWD or from the directory
    # containing the executable - copy next to the executable so this works
    # regardless of where the caller runs the exe from.
    $staging = Copy-VulkanLayerSettings -SettingsPath $SettingsPath -TargetDirectory (Split-Path $ExecutablePath -Parent)

    $layerPathWasSet = Test-Path Env:\VK_LAYER_PATH
    $originalLayerPath = if ($layerPathWasSet) { $env:VK_LAYER_PATH } else { $null }
    $exitCode = 0
    try {
        if ($LayerPath) {
            $env:VK_LAYER_PATH = (Resolve-Path $LayerPath).Path
        }

        Push-Location $WorkingDirectory
        try {
            $argumentText = if ($Arguments.Count -gt 0) { ' ' + ($Arguments -join ' ') } else { '' }
            Write-Host "Running $ExecutablePath$argumentText with khronos_validation.validate_sync=true" -ForegroundColor Cyan

            if ($TimeoutSeconds -gt 0) {
                $exitCode = Invoke-VulkanValidationTimedProcess -ExecutablePath $ExecutablePath -Arguments $Arguments `
                    -WorkingDirectory (Get-Location).Path -LogPath $LogPath -TimeoutSeconds $TimeoutSeconds
            } else {
                & $ExecutablePath @Arguments 2>&1 | Tee-Object -FilePath $LogPath
                # $LASTEXITCODE is undefined until the first native command of
                # the session has run, hence the Test-Path guard under StrictMode.
                $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
                if ($null -eq $exitCode) { $exitCode = 0 }
            }
        } finally {
            Pop-Location
        }
    } catch {
        Write-Warning "Failed to run $ExecutablePath : $_"
        $exitCode = 1
        if (-not (Test-Path $LogPath)) { New-Item -ItemType File -Path $LogPath -Force | Out-Null }
    } finally {
        if ($layerPathWasSet) {
            $env:VK_LAYER_PATH = $originalLayerPath
        } else {
            Remove-Item Env:\VK_LAYER_PATH -ErrorAction SilentlyContinue
        }
        Restore-VulkanLayerSettings -Staging $staging
    }

    $global:LASTEXITCODE = $exitCode
}

# Timeout branch of Invoke-VulkanValidationRun: Start-Process is the only way
# to get a killable handle, and it cannot stream through Tee-Object, so stdout
# and stderr are redirected to temp files, concatenated into the run log and
# echoed once the process is done. Returns the exit code (124 on timeout, the
# convention `timeout(1)` uses). Module-internal: not exported, because the
# name is generic and the semantics are specific to this driver.
function Invoke-VulkanValidationTimedProcess {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory)]
        [string]$LogPath,
        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $stdoutPath = "$LogPath.stdout.tmp"
    $stderrPath = "$LogPath.stderr.tmp"
    try {
        $startArgs = @{
            FilePath               = $ExecutablePath
            WorkingDirectory       = $WorkingDirectory
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
            NoNewWindow            = $true
            PassThru               = $true
        }
        # Start-Process rejects an empty -ArgumentList, so only pass it when
        # the caller actually supplied arguments.
        if ($Arguments.Count -gt 0) { $startArgs['ArgumentList'] = $Arguments }

        $process = Start-Process @startArgs
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Write-Warning "Timeout after $TimeoutSeconds s - killing $ExecutablePath."
            try { $process.Kill($true) } catch { Write-Verbose "process kill race (already exited): $($_.Exception.Message)" }
            $process.WaitForExit()
            $exitCode = 124
        } else {
            $exitCode = $process.ExitCode
        }

        $output = @()
        foreach ($stream in @($stdoutPath, $stderrPath)) {
            if (Test-Path $stream) { $output += @(Get-Content -LiteralPath $stream) }
        }
        Set-Content -LiteralPath $LogPath -Value $output
        $output | ForEach-Object { Write-Host $_ }

        return $exitCode
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-VulkanLayerSettingsDefaultPath, Copy-VulkanLayerSettings,
    Restore-VulkanLayerSettings, Get-VulkanValidationHazard, Write-VulkanValidationReport,
    Test-VulkanValidationLog, Invoke-VulkanValidationRun
