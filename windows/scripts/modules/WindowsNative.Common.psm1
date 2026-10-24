#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Not in WindowsScripts.Shared, which is copied before the VS layer, so every edit there re-pays the VS install.

Set-StrictMode -Version Latest

function Invoke-ShieldedNative {
    <#
    .SYNOPSIS
        Stderr-shielded native call through `cmd.exe /c "<line> 2>&1"`; throws on non-zero exit unless -Optional.
    .DESCRIPTION
        cmd merges stderr before PS 5.1 can make it a terminating error; $LASTEXITCODE is always normalized afterwards.
    .PARAMETER CommandLine
        The literal cmd.exe command line; the caller quotes paths by cmd's rules, not PowerShell's.
    #>
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [string]$Label = '',
        [switch]$Optional,
        [switch]$Quiet
    )
    if (-not $Label) { $Label = ($CommandLine -split '\s+')[0] }
    # /s plus a leading space: deterministic quote stripping even when the line starts with a quoted exe path.
    $out = & cmd.exe /s /c " $CommandLine 2>&1"
    $code = $LASTEXITCODE
    if (-not $Quiet) { $out | ForEach-Object { Write-Host $_ } }
    if ($code -ne 0) {
        if ($Optional) {
            Write-Warning "[$Label] exited $code (optional step; continuing)"
        } else {
            $global:LASTEXITCODE = $code
            throw "[$Label] failed (exit $code)"
        }
    }
    $global:LASTEXITCODE = 0
    return $out
}

Export-ModuleMember -Function Invoke-ShieldedNative

function Invoke-NativeProbeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 120,
        [switch]$InheritStandardError,
        [switch]$PreserveOutput
    )
    $start = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($argument in $ArgumentList) { $start.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = $Environment[$key] }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = -not $InheritStandardError
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = if ($start.RedirectStandardError) { $process.StandardError.ReadToEndAsync() } else { $null }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            return [pscustomobject]@{ ExitCode = $null; Text = '' }
        }
        $process.WaitForExit()
        $text = $stdout.Result
        if ($stderr) { $text += $stderr.Result }
        if (-not $PreserveOutput) { $text = $text.Trim() }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Text = $text }
    } finally { $process.Dispose() }
}

Export-ModuleMember -Function Invoke-NativeProbeProcess

function ConvertFrom-PythonJsonProbeOutput {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Lines,
        [Parameter(Mandatory)][int]$ExitCode, [switch]$DiagnosticTail)
    $json = $Lines | Where-Object { "$_".StartsWith('{') } | Select-Object -Last 1
    if ($ExitCode -ne 0 -or -not $json) {
        $detail = if ($DiagnosticTail) { ': ' + (($Lines | Select-Object -Last 3) -join ' | ') } else { '' }
        return [pscustomobject]@{ Report = $null; Failure = "$ExitCode without a report$detail" }
    }
    return [pscustomobject]@{ Report = ($json | ConvertFrom-Json -AsHashtable); Failure = $null }
}

Export-ModuleMember -Function ConvertFrom-PythonJsonProbeOutput

# Marker and probe target strings share one empty-token policy; see docs/windows-builds.md under Shared Windows behavior.
function ConvertFrom-DelimitedTargetList {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$SeparatorPattern
    )
    return @($Text -split $SeparatorPattern | Where-Object { $_ })
}

Export-ModuleMember -Function ConvertFrom-DelimitedTargetList

function Invoke-PythonJsonProbe {
    param(
        [Parameter(Mandatory)][string]$Python,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Prefix,
        [string[]]$InterpreterArgument = @(),
        [string[]]$ArgumentList = @(),
        [switch]$DiscardStandardError,
        [switch]$DiagnosticTail,
        [string]$FailurePrefix = 'exit'
    )
    $probe = Join-Path ([IO.Path]::GetTempPath()) "$Prefix-$([guid]::NewGuid().ToString('N')).py"
    try {
        [IO.File]::WriteAllText($probe, $Source)
        $probeArgs = @($InterpreterArgument) + @($probe) + @($ArgumentList)
        $lines = if ($DiscardStandardError) { @(& $Python @probeArgs 2>$null) } else { @(& $Python @probeArgs 2>&1 | ForEach-Object { "$_" }) }
        $code = $LASTEXITCODE
    } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    $parsed = ConvertFrom-PythonJsonProbeOutput -Lines $lines -ExitCode $code -DiagnosticTail:$DiagnosticTail
    if ($parsed.Failure) { throw "$FailurePrefix $($parsed.Failure)" }
    return $parsed.Report
}

Export-ModuleMember -Function Invoke-PythonJsonProbe

function Invoke-PwshProbeProcess {
    param([Parameter(Mandatory)][string]$Source, [hashtable]$ProcessOptions = @{})
    $argument = @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Source)))
    Invoke-NativeProbeProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList $argument @ProcessOptions
}

Export-ModuleMember -Function Invoke-PwshProbeProcess
