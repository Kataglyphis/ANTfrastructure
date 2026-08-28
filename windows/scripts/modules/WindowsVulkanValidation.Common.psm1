# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Project-agnostic driver: run a Vulkan executable with the Khronos layer's
# synchronization validation on and fail if the log holds a SYNC-HAZARD.
#
# Sync validation turns on only through a vk_layer_settings.txt that the loader reads
# from the CWD or the executable's directory - hence the stage/restore dance below.
#
# Invoke-VulkanValidationRun leaves the exit code in $LASTEXITCODE instead of
# returning it (a returned value would collect the executable's stdout), same
# contract as WindowsAppRunner.Common's Invoke-AppRun.

Set-StrictMode -Version Latest

# Packaged minimal settings, staged when the caller passes no -SettingsPath, so a
# project with no checked-in settings file still gets a sync-validation run.
function Get-VulkanLayerSettingsDefaultPath {
    return (Join-Path $PSScriptRoot 'vk_layer_settings.default.txt')
}

# Returns a staging handle for Restore-VulkanLayerSettings. An existing
# vk_layer_settings.txt is moved aside, never destroyed.
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

# Safe to call from a finally block: a $null handle is ignored and missing files are
# not an error, so a failure mid-run still cleans up.
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

# Returns MatchInfo objects, so callers keep line numbers and text. Matching is
# literal (-SimpleMatch): a -Pattern entry is a substring, not a regex.
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

# $true when the log is clean, $false after printing the hazard report.
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

# Environment and staged settings are restored in a finally block, so a crashing run
# leaves neither behind; the log is always written and $LASTEXITCODE is 1 when the
# process could not start at all.
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
        # Khronos validation layer directory (the Vulkan SDK's Bin). Empty leaves
        # VK_LAYER_PATH alone, so a system-installed layer is used as-is.
        [string]$LayerPath,
        # Source of the vk_layer_settings.txt staged next to the executable.
        # Defaults to the module's packaged minimal settings file.
        [string]$SettingsPath,
        # 0 (the default) waits forever and streams the output live; a positive value
        # redirects to files, waits with a timeout and kills the process on overrun.
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

    # Next to the executable, not the CWD: the caller may run it from anywhere.
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

# Timeout branch: Start-Process is the only killable handle but cannot stream through
# Tee-Object, hence the temp files. Returns 124 on timeout, as `timeout(1)` does.
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
            # WaitForExit(ms) can return before .ExitCode is settled; the parameterless
            # overload blocks until it is.
            $process.WaitForExit()
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
