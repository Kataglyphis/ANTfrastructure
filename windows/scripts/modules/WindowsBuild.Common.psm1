Set-StrictMode -Version Latest

$sharedModulePath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required shared module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$loggingModulePath = Join-Path $PSScriptRoot 'WindowsLogging.Common.psm1'
if (-not (Test-Path $loggingModulePath)) {
    throw "Required logging module not found: $loggingModulePath"
}

Import-Module $loggingModulePath -Force

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
            Succeeded = New-Object System.Collections.Generic.List[string]
            Failed    = New-Object System.Collections.Generic.List[string]
            Errors    = @{}
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
    $global:LASTEXITCODE = 0

    try {
        # Create temp files for capturing output
        $stdOutFile = [System.IO.Path]::GetTempFileName()
        $stdErrFile = [System.IO.Path]::GetTempFileName()

        try {
            # Use Start-Process for reliable execution of paths containing spaces
            # This avoids issues with the & operator and cmd.exe path parsing
            $startProcessArgs = @{
                FilePath = $File
                Wait = $true
                NoNewWindow = $true
                PassThru = $true
                RedirectStandardOutput = $stdOutFile
                RedirectStandardError = $stdErrFile
            }

            if ($parameterList -and $parameterList.Count -gt 0) {
                $startProcessArgs.ArgumentList = $parameterList
            }

            $process = Start-Process @startProcessArgs

            # Read captured output into variables for logging and diagnostics
            $capturedStdOut = @()
            $capturedStdErr = @()
            if (Test-Path $stdOutFile) {
                $capturedStdOut = Get-Content $stdOutFile
            }
            if (Test-Path $stdErrFile) {
                $capturedStdErr = Get-Content $stdErrFile
            }

            # Log captured output (preserve order: stdout then stderr)
            foreach ($line in $capturedStdOut) {
                if (-not [String]::IsNullOrWhiteSpace($line)) { Write-BuildLog -Context $Context -Message $line }
            }
            foreach ($line in $capturedStdErr) {
                if (-not [String]::IsNullOrWhiteSpace($line)) { Write-BuildLog -Context $Context -Message $line }
            }

            $exitCode = $process.ExitCode
            if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
                # Include captured output in the thrown error to make logs self-contained
                $stdOutText = if ($capturedStdOut) { ($capturedStdOut -join "`n") } else { '<no stdout>' }
                $stdErrText = if ($capturedStdErr) { ($capturedStdErr -join "`n") } else { '<no stderr>' }
                throw "Command failed with exit code ${exitCode}: $cmdLine`n--- STDOUT ---`n$stdOutText`n--- STDERR ---`n$stdErrText"
            }

            return $exitCode
        } finally {
            # Clean up temp files
            if (Test-Path $stdOutFile) { Remove-Item $stdOutFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $stdErrFile) { Remove-Item $stdErrFile -Force -ErrorAction SilentlyContinue }
        }
    } finally {
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
        [switch]$Critical
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
        return $true
    } catch {
        $stopwatch.Stop()
        $errorMessage = $_.Exception.Message
        $Context.Results.Failed.Add($StepName) | Out-Null
        $Context.Results.Errors[$StepName] = $errorMessage
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

    Write-BuildLog -Context $Context -Message ""
    $total = $Context.Results.Succeeded.Count + $Context.Results.Failed.Count
    $successRate = if ($total -gt 0) { [math]::Round(($Context.Results.Succeeded.Count / $total) * 100, 1) } else { 0 }
    Write-BuildLog -Context $Context -Message "Total: $total steps, $($Context.Results.Succeeded.Count) succeeded, $($Context.Results.Failed.Count) failed ($($successRate)% success rate)"

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
        }

        $summaryJson = $summary | ConvertTo-Json -Depth 8
        Set-Content -Path $Context.SummaryPath -Value $summaryJson -Encoding UTF8
        Write-BuildLog -Context $Context -Message "Machine-readable summary available at: $($Context.SummaryPath)"
    } catch {
        Write-BuildLogWarning -Context $Context -Message "Failed to write JSON summary: $($_.Exception.Message)"
    }
}

function Remove-BuildRoot {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        Write-BuildLog -Context $Context -Message "Build root does not exist: $Path"
        return $true
    }

    Write-BuildLog -Context $Context -Message "Terminating potentially locking processes..."
    $processNames = @(
        "flutter", "dart",
        "msbuild", "devenv",
        "ninja", "cmake", "ctest",
        "cl", "link",
        "clang", "clang-cl", "lld-link",
        "vstest.console", "testhost",
        "cargo", "rustc"
    )

    foreach ($name in $processNames) {
        Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 3

    for ($i = 1; $i -le 8; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-BuildLog -Context $Context -Message "Build directory removed: $Path"
            return $true
        } catch {
            Write-BuildLogWarning -Context $Context -Message "Attempt $i/8 failed: $($_.Exception.Message)"

            foreach ($name in $processNames) {
                Get-Process $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }

            if ($i -lt 8) { Start-Sleep -Seconds 2 }
        }
    }

    return $false
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
    'Remove-BuildRoot',
    'Resolve-WorkspacePath',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'New-TimestampedFilePath',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList'
)
