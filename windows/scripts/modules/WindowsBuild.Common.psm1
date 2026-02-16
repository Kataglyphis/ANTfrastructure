Set-StrictMode -Version Latest

$sharedModulePath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required shared module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

function New-BuildContext {
    param(
        [Parameter(Mandatory)]
        [string]$Workspace,
        [Parameter(Mandatory)]
        [string]$LogDir,
        [switch]$StopOnError
    )

    $logDirPath = Resolve-DirectoryPath -Path (Join-Path $Workspace $LogDir)
    $timestamp = New-Timestamp -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $logDirPath "build-windows-$timestamp.log"
    $summaryPath = Join-Path $logDirPath "build-summary-$timestamp.json"

    [pscustomobject]@{
        Workspace  = $Workspace
        LogPath    = $logPath
        SummaryPath = $summaryPath
        StartedAt  = (Get-Date).ToString('o')
        LogWriter  = $null
        StopOnError = [bool]$StopOnError
        Results    = @{
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

function Close-BuildLog {
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

function Write-BuildLog {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-Host $Message
    if ($Context.LogWriter) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $Context.LogWriter.WriteLine("[$timestamp] $Message")
    }
}

function Write-BuildLogWarning {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($Message) {
        Write-Warning $Message
        if ($Context.LogWriter) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $Context.LogWriter.WriteLine("[$timestamp] WARNING: $Message")
        }
    } else {
        Write-Host ""
        if ($Context.LogWriter) {
            $Context.LogWriter.WriteLine("")
        }
    }
}

function Write-BuildLogError {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($Message) {
        Write-Host $Message -ForegroundColor Red
        if ($Context.LogWriter) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $Context.LogWriter.WriteLine("[$timestamp] ERROR: $Message")
        }
    } else {
        Write-Host ""
        if ($Context.LogWriter) {
            $Context.LogWriter.WriteLine("")
        }
    }
}

function Write-BuildLogSuccess {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    if ($Message) {
        Write-Host $Message -ForegroundColor Green
        if ($Context.LogWriter) {
            $timestamp = Get-Date -Format "HH:mm:ss"
            $Context.LogWriter.WriteLine("[$timestamp] SUCCESS: $Message")
        }
    } else {
        Write-Host ""
        if ($Context.LogWriter) {
            $Context.LogWriter.WriteLine("")
        }
    }
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

    $cmdLine = if ($parameterList -and $parameterList.Count) { "$File $($parameterList -join ' ')" } else { $File }
    Write-BuildLog -Context $Context -Message "CMD: $cmdLine"

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $global:LASTEXITCODE = 0

    try {
        & $File @parameterList 2>&1 | ForEach-Object {
            if ($null -eq $_) { return }
            Write-BuildLog -Context $Context -Message ([string]$_)
        }

        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
            throw "Command failed with exit code ${exitCode}: $cmdLine"
        }

        return $exitCode
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
    Write-BuildLog -Context $Context -Message ""

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
    @("flutter", "dart", "msbuild", "devenv", "ninja", "cmake") | ForEach-Object {
        Get-Process $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 3

    for ($i = 1; $i -le 3; $i++) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-BuildLog -Context $Context -Message "Build directory removed: $Path"
            return $true
        } catch {
            Write-BuildLogWarning -Context $Context -Message "Attempt $i/3 failed: $($_.Exception.Message)"
            if ($i -lt 3) { Start-Sleep -Seconds 2 }
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
    'Remove-BuildRoot'
)
