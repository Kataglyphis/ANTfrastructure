#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Starts an app bundle's self-test through its launcher and returns the JSON report; self-contained, for runners without a checkout.

<#
.SYNOPSIS
    Runs -Command (launcher name, then its arguments) in -Bundle and refuses anything but exit 0 with a JSON report saying ok.
.DESCRIPTION
    WindowsPythonApp.Common's Invoke-PythonAppSelfTest calls this, and a cross lane copies it beside the bundle, because the
    windows-11-arm run job has neither a checkout nor the module. With -Root, the report's onnxruntime_module must lie under it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string[]]$Command,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
# A pwsh -File call hands a comma list over as one string.
$Command = @($Command | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$exe = Join-Path $Bundle "$($Command[0]).exe"
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "No launcher $exe for the self-test" }
$rest = @($Command | Select-Object -Skip 1)
# stderr is shown, never parsed: ORT prints EP errors there (DirectML on a host without a GPU).
$PSNativeCommandUseErrorActionPreference = $false
$stdout = @(& $exe @rest 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  stderr: $_" } else { "$_" }
    })
$code = $LASTEXITCODE
$text = $stdout -join [Environment]::NewLine
Write-Host $text
if ($code -ne 0) { throw "self-test '$($Command -join ' ')' exited $code" }
# The report is the last block from a bare '{' line to a bare '}' line; ORT's fallback notice has braces of its own.
$lines = @($text -split "`r?`n")
$end = -1
for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -ceq '}') { $end = $i; break } }
$start = -1
for ($i = $end; $i -ge 0; $i--) { if ($lines[$i] -ceq '{') { $start = $i; break } }
if ($start -lt 0 -or $end -lt $start) { throw "self-test '$($Command -join ' ')' printed no JSON report" }
$report = ($lines[$start..$end] -join "`n") | ConvertFrom-Json -AsHashtable
if (-not $report['ok']) { throw "self-test '$($Command -join ' ')' did not report ok" }
$module = [string]$report['onnxruntime_module']
if ($Root) {
    $rootFull = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\') + '\'
    if ($module -and -not $module.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The self-test loaded ONNX Runtime from $module, outside $Root"
    }
}
return $report
