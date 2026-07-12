# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, ConvertTo-ParameterList, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

# -- Logging primitives (module-internal; formerly WindowsLogging.Common.psm1, whose
# only consumer was this module). Scripts use the Write-BuildLog* wrappers below. --

function New-LogContext {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$LogDir,
        [string]$LogFilePrefix = 'session'
    )

    $effectiveLogDir = if ([System.IO.Path]::IsPathRooted($LogDir)) { $LogDir } else { Join-Path $Workspace $LogDir }
    $logDirPath = Resolve-DirectoryPath -Path $effectiveLogDir
    $timestamp = New-Timestamp -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $logDirPath "$LogFilePrefix-$timestamp.log"

    [pscustomobject]@{
        Workspace = $Workspace
        LogPath   = $logPath
        StartedAt = (Get-Date).ToString('o')
        LogWriter = $null
    }
}

function Open-LogWriter {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    $parentDir = Split-Path -Parent $Context.LogPath
    if ($parentDir) {
        Resolve-DirectoryPath -Path $parentDir | Out-Null
    }

    $fileStream = New-Object System.IO.FileStream(
        $Context.LogPath,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
    )

    $writer = New-Object System.IO.StreamWriter($fileStream, [System.Text.Encoding]::UTF8)
    $writer.AutoFlush = $true
    $Context.LogWriter = $writer
}

function Close-LogWriter {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    if ($Context.LogWriter) {
        try {
            $Context.LogWriter.Flush()
            $Context.LogWriter.Dispose()
        } catch {
        } finally {
            $Context.LogWriter = $null
        }
    }
}

function Write-ContextLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $suppressConsoleOutput = $false
    if ($null -ne $Context.PSObject.Properties['SuppressConsoleOutput']) {
        $suppressConsoleOutput = [bool]$Context.SuppressConsoleOutput
    }

    if (-not $Message) {
        if (-not $suppressConsoleOutput) {
            Write-Host ''
        }
        if ($Context.LogWriter) {
            $Context.LogWriter.WriteLine('')
        }
        return
    }

    if (-not $suppressConsoleOutput) {
        switch ($Level) {
            'Warning' {
                Write-Warning $Message
            }
            'Error' {
                Write-Host $Message -ForegroundColor Red
            }
            'Success' {
                Write-Host $Message -ForegroundColor Green
            }
            default {
                Write-Host $Message
            }
        }
    }

    if ($Context.LogWriter) {
        $timestamp = Get-Date -Format 'HH:mm:ss'
        $prefix = switch ($Level) {
            'Warning' { 'WARNING: ' }
            'Error' { 'ERROR: ' }
            'Success' { 'SUCCESS: ' }
            default { '' }
        }

        $Context.LogWriter.WriteLine("[$timestamp] $prefix$Message")
    }
}

function New-BuildContext {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$LogDir,
        [switch]$StopOnError
    )

    $baseContext = New-LogContext -Workspace $Workspace -LogDir $LogDir -LogFilePrefix 'build-windows'
    $summaryPath = $baseContext.LogPath -replace 'build-windows-', 'build-summary-' -replace '\.log$', '.json'

    [pscustomobject]@{
        Workspace   = $baseContext.Workspace
        LogPath     = $baseContext.LogPath
        SummaryPath = $summaryPath
        StartedAt   = $baseContext.StartedAt
        LogWriter   = $baseContext.LogWriter
        SuppressConsoleOutput = $false
        StopOnError = [bool]$StopOnError
        Results     = @{
            Succeeded       = New-Object System.Collections.Generic.List[string]
            Failed          = New-Object System.Collections.Generic.List[string]
            # Steps that failed but were declared non-gating (Invoke-BuildStep -AllowFailure),
            # e.g. experimental toolchains. Reported in the summary but do NOT set exit 1.
            AllowedFailures = New-Object System.Collections.Generic.List[string]
            Errors          = @{}
            Durations       = [ordered]@{}
        }
    }
}

function Open-BuildLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    Open-LogWriter -Context $Context
}

function Close-BuildLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    Close-LogWriter -Context $Context
}

function Write-BuildLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Info
}

function Write-BuildLogWarning {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Warning
}

function Write-BuildLogError {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Error
}

function Write-BuildLogSuccess {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-ContextLog -Context $Context -Message $Message -Level Success
}

function Invoke-BuildExternal {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$File,
        [object]$Parameters,
        [switch]$IgnoreExitCode
    )

    $parameterList = ConvertTo-ParameterList -Value $Parameters

    # Coerce to an array to ensure .Count property exists even when ConvertTo-ParameterList
    # returns a scalar or unexpected type. This prevents errors like "The property
    # 'Count' cannot be found on this object." when callers pass strings.
    $parameterList = @($parameterList)

    $cmdLine = if ($parameterList -and $parameterList.Count) { "$File $($parameterList -join ' ')" } else { $File }
    Write-BuildLog -Context $Context -Message "CMD: $cmdLine"

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $previousLastExitCode = $global:LASTEXITCODE
    $global:LASTEXITCODE = 0

    try {
        $capturedOutput = @()
        if ($parameterList -and $parameterList.Count -gt 0) {
            & $File @parameterList 2>&1 | ForEach-Object {
                $line = $_.ToString()
                $capturedOutput += $line
                if (-not [String]::IsNullOrWhiteSpace($line)) { Write-BuildLog -Context $Context -Message $line }
            }
        } else {
            & $File 2>&1 | ForEach-Object {
                $line = $_.ToString()
                $capturedOutput += $line
                if (-not [String]::IsNullOrWhiteSpace($line)) { Write-BuildLog -Context $Context -Message $line }
            }
        }

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
            $outputText = if ($capturedOutput) { ($capturedOutput -join "`n") } else { '<no output>' }
            throw "Command failed with exit code $($exitCode): $cmdLine`n--- OUTPUT ---`n$outputText"
        }

        return $exitCode
    } finally {
        $global:LASTEXITCODE = $previousLastExitCode
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-BuildOptional {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [scriptblock]$Script,
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        & $Script
    } catch {
        Write-BuildLogWarning -Context $Context -Message "$Name failed, continuing. Details: $($_.Exception.Message)"
    }
}

function Invoke-BuildStep {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$StepName,
        [Parameter(Mandatory)]
        [scriptblock]$Script,
        [switch]$Critical,
        # When set, a failure is recorded as a non-gating AllowedFailure (warning, not error) and
        # never throws -- for steps that are permitted to fail (e.g. experimental Python builds).
        [switch]$AllowFailure
    )

    Write-BuildLog -Context $Context -Message ""
    Write-BuildLog -Context $Context -Message ">>> Starting: $StepName"
    Write-BuildLog -Context $Context -Message ("=" * 60)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        & $Script
        $stopwatch.Stop()
        $Context.Results.Succeeded.Add($StepName) | Out-Null
        Write-BuildLogSuccess -Context $Context -Message "<<< Completed: $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
        
        # Add a diagnostic entry to the JSON summary tracking the duration of this step
        if ($null -eq $Context.Results.Durations) {
            $Context.Results.Durations = [ordered]@{}
        }
        $Context.Results.Durations[$StepName] = $stopwatch.Elapsed.TotalSeconds
        
        return $true
    } catch {
        $stopwatch.Stop()
        $errorMessage = $_.Exception.Message
        if ($null -eq $Context.Results.Durations) {
            $Context.Results.Durations = [ordered]@{}
        }
        $Context.Results.Durations[$StepName] = $stopwatch.Elapsed.TotalSeconds
        $Context.Results.Errors[$StepName] = $errorMessage

        if ($AllowFailure) {
            $Context.Results.AllowedFailures.Add($StepName) | Out-Null
            Write-BuildLogWarning -Context $Context -Message "<<< FAILED (allowed, non-gating): $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
            Write-BuildLogWarning -Context $Context -Message "    Error: $errorMessage"
            return $false
        }

        $Context.Results.Failed.Add($StepName) | Out-Null
        Write-BuildLogError -Context $Context -Message "<<< FAILED: $StepName (Duration: $($stopwatch.Elapsed.ToString('mm\:ss\.fff')))"
        Write-BuildLogError -Context $Context -Message "    Error: $errorMessage"


        if ($_.ScriptStackTrace) {
            Write-BuildLog -Context $Context -Message "    Stack: $($_.ScriptStackTrace)"
        }

        if ($Context.StopOnError -and $Critical) {
            throw "Critical step '$StepName' failed: $errorMessage"
        }

        return $false
    }
}

function Write-BuildSummary {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    Write-BuildLog -Context $Context -Message ""
    Write-BuildLog -Context $Context -Message ("=" * 60)
    Write-BuildLog -Context $Context -Message "=== BUILD PIPELINE SUMMARY ==="
    Write-BuildLog -Context $Context -Message ("=" * 60)
    Write-BuildLog -Context $Context -Message ""

    if ($Context.Results.Succeeded.Count -gt 0) {
        Write-BuildLogSuccess -Context $Context -Message "SUCCEEDED ($($Context.Results.Succeeded.Count)):"
        foreach ($step in $Context.Results.Succeeded) {
            Write-BuildLogSuccess -Context $Context -Message "  [OK] $step"
        }
    }

    Write-BuildLog -Context $Context -Message ""

    if ($Context.Results.Failed.Count -gt 0) {
        Write-BuildLogError -Context $Context -Message "FAILED ($($Context.Results.Failed.Count)):"
        foreach ($step in $Context.Results.Failed) {
            Write-BuildLogError -Context $Context -Message "  [X] $step"
            Write-BuildLogError -Context $Context -Message "      Error: $($Context.Results.Errors[$step])"
        }
    }

    if ($null -ne $Context.Results.AllowedFailures -and $Context.Results.AllowedFailures.Count -gt 0) {
        Write-BuildLog -Context $Context -Message ""
        Write-BuildLogWarning -Context $Context -Message "ALLOWED FAILURES ($($Context.Results.AllowedFailures.Count)) -- non-gating (did not fail the run):"
        foreach ($step in $Context.Results.AllowedFailures) {
            Write-BuildLogWarning -Context $Context -Message "  [!] $step"
            Write-BuildLogWarning -Context $Context -Message "      Error: $($Context.Results.Errors[$step])"
        }
    }

    Write-BuildLog -Context $Context -Message ""
    $total = $Context.Results.Succeeded.Count + $Context.Results.Failed.Count
    $successRate = if ($total -gt 0) { [math]::Round(($Context.Results.Succeeded.Count / $total) * 100, 1) } else { 0 }
    Write-BuildLog -Context $Context -Message "Total: $total steps, $($Context.Results.Succeeded.Count) succeeded, $($Context.Results.Failed.Count) failed ($($successRate)% success rate)"

    if ($null -ne $Context.Results.Durations -and $Context.Results.Durations.Count -gt 0) {
        Write-BuildLog -Context $Context -Message ""
        Write-BuildLog -Context $Context -Message "=== STEP DURATIONS ==="
        $Context.Results.Durations.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
            Write-BuildLog -Context $Context -Message ("  {0,-50} : {1:N2}s" -f $_.Key, $_.Value)
        }
    }

    if ($Context.Results.Failed.Count -gt 0) {
        Write-BuildLog -Context $Context -Message ""
        Write-BuildLog -Context $Context -Message ("=" * 60)
        Write-BuildLogError -Context $Context -Message "=== ERROR DETAILS ==="
        Write-BuildLog -Context $Context -Message ("=" * 60)
        $errorIndex = 1
        foreach ($step in $Context.Results.Failed) {
            Write-BuildLogError -Context $Context -Message ""
            Write-BuildLogError -Context $Context -Message "[$errorIndex/$($Context.Results.Failed.Count)] $step"
            Write-BuildLogError -Context $Context -Message "    $($Context.Results.Errors[$step])"
            $errorIndex++
        }
        Write-BuildLog -Context $Context -Message ""
    }

    if ($Context.LogPath) {
        Write-BuildLog -Context $Context -Message "Full log available at: $($Context.LogPath)"
    }

    if ($Context.Results.Failed.Count -gt 0) {
        Write-BuildLogWarning -Context $Context -Message "Pipeline completed with errors!"
    } else {
        Write-BuildLogSuccess -Context $Context -Message "Pipeline completed successfully!"
    }

    try {
        $summary = [ordered]@{
            startedAt = $Context.StartedAt
            finishedAt = (Get-Date).ToString('o')
            workspace = $Context.Workspace
            logPath = $Context.LogPath
            summaryPath = $Context.SummaryPath
            totals = [ordered]@{
                total = $total
                succeeded = $Context.Results.Succeeded.Count
                failed = $Context.Results.Failed.Count
                successRate = $successRate
            }
            succeededSteps = @($Context.Results.Succeeded)
            failedSteps = @($Context.Results.Failed)
            errors = $Context.Results.Errors
            durations = $Context.Results.Durations
        }

        $summaryJson = $summary | ConvertTo-Json -Depth 8
        Set-Content -Path $Context.SummaryPath -Value $summaryJson -Encoding UTF8
        Write-BuildLog -Context $Context -Message "Machine-readable summary available at: $($Context.SummaryPath)"
    } catch {
        Write-BuildLogWarning -Context $Context -Message "Failed to write JSON summary: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @(
    'New-BuildContext',
    'Open-BuildLog',
    'Close-BuildLog',
    'Write-BuildLog',
    'Write-BuildLogWarning',
    'Write-BuildLogError',
    'Write-BuildLogSuccess',
    'Invoke-BuildExternal',
    'Invoke-BuildOptional',
    'Invoke-BuildStep',
    'Write-BuildSummary',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList'
)
