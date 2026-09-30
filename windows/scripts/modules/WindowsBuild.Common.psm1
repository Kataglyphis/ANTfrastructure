# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
# Guarded, no -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedPath }

# -- Logging primitives (module-internal; scripts use the Write-BuildLog* wrappers) --

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
            # Best-effort: the writer may already be disposed on double-close.
            Write-Verbose "log writer dispose: $($_.Exception.Message)"
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
            # Non-gating failures (Invoke-BuildStep -AllowFailure): in the summary, never exit 1.
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
        [switch]$IgnoreExitCode,
        # Secret values logged as '<redacted>' when a parameter matches exactly; the process still gets them.
        [string[]]$RedactParameterValues
    )

    $parameterList = ConvertTo-ParameterList -Value $Parameters

    # @(): a scalar result has no .Count under StrictMode.
    $parameterList = @($parameterList)

    $logParameterList = $parameterList
    $secretValues = @($RedactParameterValues | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($secretValues.Count -gt 0) {
        $logParameterList = @($parameterList | ForEach-Object {
                if ($secretValues -ccontains $_) { '<redacted>' } else { $_ }
            })
    }

    $cmdLine = if ($logParameterList -and $logParameterList.Count) { "$File $($logParameterList -join ' ')" } else { $File }
    Write-BuildLog -Context $Context -Message "CMD: $cmdLine"

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    # LASTEXITCODE does not exist before a session's first native call, and StrictMode throws on it.
    $previousLastExitCode = if (Test-Path variable:global:LASTEXITCODE) { $global:LASTEXITCODE } else { 0 }
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

    # Mirrors Invoke-BuildStep -AllowFailure rather than calling it, whose boolean would pollute the passed-through output.
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Script
        $stopwatch.Stop()
        $Context.Results.Succeeded.Add($Name) | Out-Null
    } catch {
        $stopwatch.Stop()
        $Context.Results.Errors[$Name] = $_.Exception.Message
        $Context.Results.AllowedFailures.Add($Name) | Out-Null
        Write-BuildLogWarning -Context $Context -Message "$Name failed, continuing. Details: $($_.Exception.Message)"
    }

    if ($null -eq $Context.Results.Durations) {
        $Context.Results.Durations = [ordered]@{}
    }
    $Context.Results.Durations[$Name] = $stopwatch.Elapsed.TotalSeconds
}

# All three buckets at once, so an all-skip batch reaches the no-gate-ran arm instead of a null reference.
function Initialize-BuildGateBuckets {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    if (-not $Context.Results.ContainsKey('Gates')) {
        $Context.Results['Gates'] = New-Object System.Collections.Generic.List[string]
        $Context.Results['GateFailures'] = New-Object System.Collections.Generic.List[string]
        $Context.Results['GateSkips'] = New-Object System.Collections.Generic.List[string]
    }
}

<#
.SYNOPSIS
    Runs one GATING step: a failure is recorded and the run continues; Assert-BuildGates raises the verdict.
.DESCRIPTION
    PowerShell twin of linux/scripts/01-core/gates.sh; without a closing Assert-BuildGates it is advisory lint.
.PARAMETER Context
    Build context from New-BuildContext / New-CiSession.
.PARAMETER Name
    Gate name, as it will appear in the summary and in the final failure message.
.PARAMETER Script
    The gate; a terminating error or a propagated non-zero exit is a failure.
#>
function Invoke-BuildGate {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [scriptblock]$Script
    )

    Initialize-BuildGateBuckets -Context $Context
    $Context.Results['Gates'].Add($Name) | Out-Null

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-BuildLog -Context $Context -Message "== $Name =="
    try {
        & $Script
        $stopwatch.Stop()
        $Context.Results.Succeeded.Add($Name) | Out-Null
        Write-BuildLog -Context $Context -Message "== ${Name}: ok =="
    } catch {
        $stopwatch.Stop()
        $Context.Results.Errors[$Name] = $_.Exception.Message
        $Context.Results.Failed.Add($Name) | Out-Null
        $Context.Results['GateFailures'].Add($Name) | Out-Null
        Write-BuildLogError -Context $Context -Message "== ${Name}: FAILED == $($_.Exception.Message)"
    }
    $Context.Results.Durations[$Name] = $stopwatch.Elapsed.TotalSeconds
}

<#
.SYNOPSIS
    Records a gate that could not run (its tool is absent) and why: neither a pass nor a failure.
.DESCRIPTION
    Red by default and never counted as a gate that ran: docs/shared-script-libraries.md#gate-aggregation-01-coregatessh
.PARAMETER Context
    Build context from New-BuildContext / New-CiSession.
.PARAMETER Name
    Gate name, as it will appear in the skip list and in the verdict.
.PARAMETER Reason
    Why it could not run; optional only to match gate_skip's signature.
#>
function Add-BuildGateSkip {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Reason = ''
    )

    Initialize-BuildGateBuckets -Context $Context
    $Context.Results['GateSkips'].Add($Name) | Out-Null
    if ($Reason) {
        $Context.Results.Errors[$Name] = "skipped: $Reason"
        Write-BuildLogWarning -Context $Context -Message "== ${Name}: SKIPPED ($Reason) =="
    } else {
        Write-BuildLogWarning -Context $Context -Message "== ${Name}: SKIPPED =="
    }
}

<#
.SYNOPSIS
    Raises the verdict for every Invoke-BuildGate in this context: throws on a failure, an untolerated skip, or no gate run.
.DESCRIPTION
    An empty gate list reporting success is the failure this exists to prevent, so no-gate-ran outranks -TolerateSkips.
.PARAMETER Context
    The same context the gates ran against.
.PARAMETER Label
    Name for the batch in the failure message (default 'gates').
.PARAMETER TolerateSkips
    Let an Add-BuildGateSkip record pass; off by default so tolerance is visible at the call site.
#>
function Assert-BuildGates {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context,
        [string]$Label = 'gates',
        [switch]$TolerateSkips
    )

    # Not an if-expression: it unrolls a 1-element list to a string and an empty one to $null.
    $skips = @()
    if ($Context.Results.ContainsKey('GateSkips')) {
        $skips = @($Context.Results['GateSkips'])
    }
    if ($skips.Count -gt 0) {
        Write-BuildLogWarning -Context $Context -Message (
            "${Label}: {0} gate(s) SKIPPED, and graded nothing: {1}" -f $skips.Count, ($skips -join ', '))
    }

    if (-not $Context.Results.ContainsKey('Gates') -or $Context.Results['Gates'].Count -eq 0) {
        if ($skips.Count -gt 0) {
            throw ("${Label}: no gate ran - all {0} were skipped, so there is no result to report." -f $skips.Count)
        }
        throw "${Label}: no gate ran - refusing to report green over nothing."
    }

    $failures = $Context.Results['GateFailures']
    if ($failures.Count -gt 0) {
        throw ("$Label FAILED ({0} of {1}): {2}" -f $failures.Count,
            $Context.Results['Gates'].Count, ($failures -join ', '))
    }

    if ($skips.Count -gt 0 -and -not $TolerateSkips) {
        $ask = 'Pass -TolerateSkips to Assert-BuildGates if a skip is acceptable, and say why.'
        throw ('{0} FAILED: {1} gate(s) skipped and a skip is not tolerated here: {2}. {3}' -f
            $Label, $skips.Count, ($skips -join ', '), $ask)
    }

    if ($skips.Count -gt 0) {
        Write-BuildLog -Context $Context -Message (
            "$Label OK ({0} gate(s), {1} skipped)" -f $Context.Results['Gates'].Count, $skips.Count)
    } else {
        Write-BuildLog -Context $Context -Message ("$Label OK ({0} gate(s))" -f $Context.Results['Gates'].Count)
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
        # Record a failure as a non-gating AllowedFailure instead of throwing.
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
    # Allowed failures count toward the total, or the headline reads 100% over failed steps.
    $allowedCount = if ($null -ne $Context.Results.AllowedFailures) { $Context.Results.AllowedFailures.Count } else { 0 }
    $total = $Context.Results.Succeeded.Count + $Context.Results.Failed.Count + $allowedCount
    $successRate = if ($total -gt 0) { [math]::Round(($Context.Results.Succeeded.Count / $total) * 100, 1) } else { 0 }
    $summaryLine = "Total: $total steps, $($Context.Results.Succeeded.Count) succeeded, $($Context.Results.Failed.Count) failed"
    if ($allowedCount -gt 0) {
        $summaryLine += ", $allowedCount failed but allowed"
    }
    $summaryLine += " ($($successRate)% success rate)"
    Write-BuildLog -Context $Context -Message $summaryLine

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

function Get-PyprojectPackageName {
    # pyproject.toml [project] name, else the repo-root leaf directory.
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [string]$Default = ''
    )

    if (-not [string]::IsNullOrEmpty($Default)) { return $Default }
    $pyproject = Join-Path $RepoRoot 'pyproject.toml'
    if (Test-Path $pyproject) {
        $content = Get-Content $pyproject -Raw
        if ($content -match 'name\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    return (Split-Path $RepoRoot -Leaf)
}

function New-UvBuildDelegates {
    # Defined here, not in WindowsUv.Common, so the closures resolve Invoke-BuildExternal and Write-BuildLog*.
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Context
    )

    return @{
        CommandRunner = {
            param([string]$File, [string[]]$CommandArgs)
            Invoke-BuildExternal -Context $Context -File $File -Parameters $CommandArgs | Out-Null
        }.GetNewClosure()
        LogInfo    = { param([string]$Message); Write-BuildLog -Context $Context -Message $Message }.GetNewClosure()
        LogWarning = { param([string]$Message); Write-BuildLogWarning -Context $Context -Message $Message }.GetNewClosure()
    }
}

Export-ModuleMember -Function @(
    'Get-PyprojectPackageName',
    'New-UvBuildDelegates',
    'New-BuildContext',
    'Open-BuildLog',
    'Close-BuildLog',
    'Write-BuildLog',
    'Write-BuildLogWarning',
    'Write-BuildLogError',
    'Write-BuildLogSuccess',
    'Invoke-BuildExternal',
    'Invoke-BuildOptional',
    'Invoke-BuildGate',
    'Add-BuildGateSkip',
    'Assert-BuildGates',
    'Invoke-BuildStep',
    'Write-BuildSummary',
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'ConvertTo-ParameterList'
)

# All addresses at once: Windows takes ~2 s to report a refused ::1 before trying 127.0.0.1.
function Test-TcpEndpointReachable {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 2000
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $clients = [System.Collections.Generic.List[System.Net.Sockets.TcpClient]]::new()
    try {
        $resolve = [System.Net.Dns]::GetHostAddressesAsync($HostName)
        if (-not $resolve.Wait($TimeoutMs)) { return $false }
        $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        foreach ($address in $resolve.Result) {
            $client = [System.Net.Sockets.TcpClient]::new($address.AddressFamily)
            $clients.Add($client)
            $pending.Add($client.ConnectAsync($address, $Port))
        }
        while ($pending.Count -gt 0) {
            $left = $TimeoutMs - [int]$clock.ElapsedMilliseconds
            if ($left -le 0) { return $false }
            $done = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), $left)
            if ($done -lt 0) { return $false }
            if ($pending[$done].IsCompletedSuccessfully) { return $true }
            $pending.RemoveAt($done)
        }
        return $false
    } catch {
        return $false
    } finally {
        foreach ($c in $clients) { $c.Dispose() }
    }
}

<#
.SYNOPSIS
    Removes an SCCACHE_WEBDAV_ENDPOINT this process cannot reach, so sccache falls back to its disk cache.
.DESCRIPTION
    sccache exits at server start on an unreachable store, killing every compile: docs/windows-build-resources.md#the-consumer-side-probe
.OUTPUTS
    [bool] - $true when the endpoint was removed.
#>
function Clear-UnreachableSccacheEndpoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param([ValidateRange(100, 60000)][int]$TimeoutMs = 2000)

    $endpoint = [Environment]::GetEnvironmentVariable('SCCACHE_WEBDAV_ENDPOINT')
    # sccache ignores an empty value, so there is nothing to probe.
    if ([string]::IsNullOrEmpty($endpoint)) { return $false }

    $uri = $null
    $why = ''
    if (-not [Uri]::TryCreate($endpoint.Trim(), [UriKind]::Absolute, [ref]$uri) -or -not $uri.DnsSafeHost) {
        $why = 'is not an absolute URL with a host'
    } elseif (-not (Test-TcpEndpointReachable -HostName $uri.DnsSafeHost -Port $uri.Port -TimeoutMs $TimeoutMs)) {
        $why = "is unreachable (TCP $($uri.DnsSafeHost):$($uri.Port), no connection within $TimeoutMs ms)"
    }
    if (-not $why) { return $false }

    Remove-Item Env:\SCCACHE_WEBDAV_ENDPOINT -ErrorAction SilentlyContinue
    $chainNote = ''
    if ("$env:SCCACHE_MULTILEVEL_CHAIN" -match 'webdav') {
        Remove-Item Env:\SCCACHE_MULTILEVEL_CHAIN -ErrorAction SilentlyContinue
        $chainNote = ' SCCACHE_MULTILEVEL_CHAIN named webdav and was removed too.'
    }
    $cacheDir = if ($env:SCCACHE_DIR) { $env:SCCACHE_DIR } else { "sccache's default directory" }
    Write-Warning ("sccache: SCCACHE_WEBDAV_ENDPOINT=$endpoint $why - removed for this process, so sccache " +
        "caches on local disk ($cacheDir) instead of failing every compile.$chainNote An image that " +
        "publishes its build host's endpoint is the usual cause: docs/windows-build-resources.md#the-consumer-side-probe")
    return $true
}

function Enable-SccacheCompilerWrapper {
    param(
        [Parameter(Mandatory)]
        [string]$SccacheExe
    )

    # Before any launcher is wired: an endpoint this host cannot reach kills sccache's server.
    $null = Clear-UnreachableSccacheEndpoint
    $env:CMAKE_C_COMPILER_LAUNCHER = $SccacheExe
    $env:CMAKE_CXX_COMPILER_LAUNCHER = $SccacheExe
    # No CUDA launcher: sccache-wrapped nvcc loses the per-arch .cubin files before fatbinary combines them.
    $env:RUSTC_WRAPPER = $SccacheExe
    $env:CC_WRAPPER = $SccacheExe
    $env:CXX_WRAPPER = $SccacheExe
}

# Consumer API with no in-repo caller: see docs/consumer-inventory.md § Why a grep was not enough
function Initialize-BuildCacheEnvironment {
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context,
        [string]$FastBuildDir = ""
    )

    $fastLocalCache = if (-not [string]::IsNullOrWhiteSpace($FastBuildDir)) {
        $FastBuildDir
    } elseif ($env:KATAGLYPHIS_FAST_BUILD_DIR) {
        $env:KATAGLYPHIS_FAST_BUILD_DIR
    } else {
        "C:\kataglyphis_fast_build"
    }

    $env:GLOBAL_CACHE_DIR = Join-Path $fastLocalCache ".cache"
    $env:SCCACHE_DIR      = Join-Path $env:GLOBAL_CACHE_DIR "sccache"
    $env:CARGO_HOME       = Join-Path $env:GLOBAL_CACHE_DIR "cargo"
    $env:PUB_CACHE        = Join-Path $env:GLOBAL_CACHE_DIR "pub-cache"

    foreach ($cachePath in @($env:SCCACHE_DIR, $env:CARGO_HOME, $env:PUB_CACHE)) {
        if (-not (Test-Path -LiteralPath $cachePath -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $cachePath | Out-Null
        }
    }

    $cargoBin = Join-Path $env:CARGO_HOME "bin"
    if ($env:PATH -notlike "*$cargoBin*") {
        $env:PATH = "$cargoBin;$env:PATH"
    }

    Write-BuildLog -Context $Context -Message "Initialized Fast Local Cache at: $fastLocalCache"
    
    # Process-wide, so later CMake/configure steps pick sccache up without caller wiring.
    $sccacheCmd = Get-Command 'sccache' -ErrorAction SilentlyContinue
    if ($sccacheCmd) {
        $sccacheExe = $sccacheCmd.Source
        Write-BuildLog -Context $Context -Message "DEBUG: sccache found at: $sccacheExe. Enabling compiler cache."
        Enable-SccacheCompilerWrapper -SccacheExe $sccacheExe

        if (-not $env:SCCACHE_MAX_JOBS) {
            $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString()
            Write-BuildLog -Context $Context -Message "DEBUG: AUTO-SET SCCACHE_MAX_JOBS=$($env:SCCACHE_MAX_JOBS) (from Initialize-BuildCacheEnvironment)"
        }
    }
    return $fastLocalCache
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

function Show-SccacheStats {
    # Stats are diagnostics, not a gate: a non-zero sccache exit does not fail the step.
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context
    )

    if (Get-Command "sccache" -ErrorAction SilentlyContinue) {
        Invoke-BuildStep -Context $Context -StepName "Sccache Statistics" -Script {
            $statsLines = Get-SccacheStatsText
            if ($null -ne $statsLines) {
                foreach ($line in $statsLines) {
                    Write-BuildLog -Context $Context -Message $line
                }
            }
        }
    }
}

function Assert-FlutterPluginsBuilt {
    param(
        [Parameter(Mandatory=$true)]
        [pscustomobject]$Context,
        [Parameter(Mandatory=$true)]
        [string]$CMakeFile,
        [Parameter(Mandatory=$true)]
        [string[]]$SearchDirectories
    )

    $expectedPlugins = @()
    if (Test-Path -LiteralPath $CMakeFile -PathType Leaf) {
        $cmakeContent = Get-Content $CMakeFile
        foreach ($line in $cmakeContent) {
            if ($line -match 'list\(APPEND FLUTTER_PLUGIN_LIST\s+"([^"]+)"\)') {
                $expectedPlugins += $matches[1]
            }
        }
        Write-BuildLog -Context $Context -Message "Expected Flutter plugins from generated CMake: $($expectedPlugins.Count)"
        foreach ($plugin in $expectedPlugins) {
            Write-BuildLog -Context $Context -Message "  - $plugin"
        }
    } else {
        Write-BuildLogWarning -Context $Context -Message "generated_plugins.cmake not found at '$CMakeFile'. Skipping expected plugin list."
    }

    $pluginArtifacts = @()
    foreach ($dir in $SearchDirectories) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $pluginArtifacts += Get-ChildItem -LiteralPath $dir -Recurse -File -Filter "*.dll"
        }
    }

    $pluginArtifacts = @($pluginArtifacts | Sort-Object -Property FullName -Unique)

    if ($pluginArtifacts.Count -eq 0) {
        Write-BuildLogWarning -Context $Context -Message "No plugin DLL artifacts found in search directories."
    } else {
        Write-BuildLog -Context $Context -Message "Built plugin DLL artifacts: $($pluginArtifacts.Count)"
        foreach ($artifact in $pluginArtifacts) {
            Write-BuildLog -Context $Context -Message "  - $($artifact.FullName)"
        }
    }

    if ($expectedPlugins.Count -gt 0 -and $pluginArtifacts.Count -gt 0) {
        foreach ($plugin in $expectedPlugins) {
            $matchedArtifact = $pluginArtifacts | Where-Object {
                $_.Name -like "$plugin*.dll" -or $_.FullName -like "*$plugin*"
            } | Select-Object -First 1

            if ($null -eq $matchedArtifact) {
                Write-BuildLogWarning -Context $Context -Message "Expected plugin '$plugin' has no matching DLL artifact name."
            } else {
                Write-BuildLog -Context $Context -Message "Plugin '$plugin' mapped to artifact: $($matchedArtifact.Name)"
            }
        }
    }
}

function Sync-BuildArtifacts {
    <#
    .SYNOPSIS
        Mirrors a directory tree with robocopy, optionally skipping build cache.
    .DESCRIPTION
        Moves a bind-mounted or network workspace onto fast local storage and back, avoiding per-object filter-driver I/O.
    .PARAMETER ExcludeCommonRustAndCppCache
        Skip regenerable dirs (Rust target, .git, node_modules, clang-cl trees); not for trees built incrementally.
    .PARAMETER ExcludeDirs
        Extra directory names to skip; robocopy /XD matches a bare name at any depth.
    .PARAMETER ExcludeFiles
        Extra file patterns to skip (robocopy /XF).
    #>
    param(
        [Parameter(Mandatory = $true)] [object] $Context,
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [string[]] $ExcludeFiles = @(),
        [string[]] $ExcludeDirs = @(),
        [switch] $ExcludeCommonRustAndCppCache
    )

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }

    if ($ExcludeCommonRustAndCppCache) {
        $ExcludeDirs += @('target', '.git', 'node_modules',
            'build-clangcl-debug', 'build-clangcl-release', 'build-clangcl-profile')
    }

    # /R:1 /W:1 avoid retry hangs on locked files, /FFT suits bind-mount timestamps, /NOOFFLOAD the VM boundary.
    $robocopyArgs = @(
        $Source, $Destination,
        '/E', '/MT:16', '/R:1', '/W:1', '/FFT', '/NOOFFLOAD',
        '/NFL', '/NDL', '/NJH', '/NJS', '/nc', '/ns', '/np'
    )
    if ($ExcludeDirs.Count -gt 0) { $robocopyArgs += @('/XD') + $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $robocopyArgs += @('/XF') + $ExcludeFiles }

    & robocopy.exe @robocopyArgs > $null 2>&1
    $robocopyExit = $LASTEXITCODE
    # robocopy exits with a bitmask: only 16 means no mirror; bit 8 is routine for a transient lock on a live tree.
    if ($robocopyExit -ge 16) {
        throw "Sync-BuildArtifacts failed (robocopy exit $robocopyExit, serious error): '$Source' -> '$Destination'"
    }
    if (($robocopyExit -band 8) -ne 0) {
        # The build log, not Write-Warning, which never reaches the log file.
        Write-BuildLogWarning -Context $Context -Message "Sync-BuildArtifacts: robocopy exit $robocopyExit - some files could not be copied (likely a transient lock); continuing."
    }
    # robocopy's nonzero success codes must not leak into callers reading $LASTEXITCODE.
    $global:LASTEXITCODE = 0
}

Export-ModuleMember -Function Initialize-BuildCacheEnvironment, Enable-SccacheCompilerWrapper, Clear-UnreachableSccacheEndpoint, Remove-BuildRoot, Show-SccacheStats, Assert-FlutterPluginsBuilt, Sync-BuildArtifacts


