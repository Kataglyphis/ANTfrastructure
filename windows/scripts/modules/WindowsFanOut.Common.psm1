#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# One child pwsh per piece of work, N at a time: Invoke-Tests.ps1 and Invoke-Lint.ps1 fan out through it (CON126).

Set-StrictMode -Version Latest

function Invoke-PwshFanOut {
    <#
    .SYNOPSIS
        Runs -Script once per argument set, -Jobs at a time; returns each child's output lines and its -ResultFile text ($null when it wrote none), in order.
    .PARAMETER ArgumentSets
        One array of arguments per child; each child also gets -ResultFile <path>, where it writes what the caller reads back.
    .PARAMETER InputSets
        Optional, one array of lines per child, handed over as -InputFile <path>: a file list too long for a command line.
    #>
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][object[]]$ArgumentSets,
        [object[]]$InputSets = @(),
        [ValidateRange(1, 1024)][int]$Jobs = [Environment]::ProcessorCount
    )
    $work = Join-Path ([IO.Path]::GetTempPath()) ('pwsh-fanout-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $sets = @(for ($i = 0; $i -lt $ArgumentSets.Count; $i++) {
                $childArgs = @($ArgumentSets[$i]) + @('-ResultFile', (Join-Path $work "$i.json"))
                if ($i -lt $InputSets.Count) {
                    $inputFile = Join-Path $work "$i.in"
                    Set-Content -LiteralPath $inputFile -Value @($InputSets[$i])
                    $childArgs += @('-InputFile', $inputFile)
                }
                , $childArgs
            })
        0..($sets.Count - 1) | ForEach-Object -ThrottleLimit $Jobs -Parallel {
            $childArgs = @(($using:sets)[$_])
            & pwsh -NoProfile -NonInteractive -File $using:Script @childArgs *> (Join-Path $using:work "$_.out")
        }
        for ($i = 0; $i -lt $sets.Count; $i++) {
            $result = Join-Path $work "$i.json"
            [pscustomobject]@{
                Index  = $i
                Output = @(Get-Content -LiteralPath (Join-Path $work "$i.out") -ErrorAction SilentlyContinue)
                Result = if (Test-Path -LiteralPath $result) { Get-Content -LiteralPath $result -Raw } else { $null }
            }
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @('Invoke-PwshFanOut')
