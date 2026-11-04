#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# MatMul of a matrix by a 1-D vector, DirectML against the CPU: see docs/windows-builds.md § DirectML's wrong MatMul

Set-StrictMode -Version Latest

# MatMul(A[4,3], v[3]) at opset 13 with A as an initializer, encoded so no onnx package or model file is needed.
$script:MatMulModelHex = '08083a6f0a110a01610a017612017922064d61744d756c12016d2a3b0804080310014201614a300000803f0000004000004040000080400000a0400000c0400000e04000000041000010410000204100003041000040415a0f0a0176120a0a08080112040a02080362090a017912040a02080142040a00100d'

<#
.SYNOPSIS
    The Python that runs the model on both providers and prints one JSON line.
.NOTES
    An unexpected exception exits non-zero on purpose, so a broken probe cannot read as a missing adapter.
#>
function Get-OrtDmlMatMulProbeSource {
    [OutputType([string])]
    param()
    return @"
import json
import numpy as np
import onnxruntime as ort
model = bytes.fromhex('$script:MatMulModelHex')
feed = {'v': np.array([1, 10, 100], dtype=np.float32)}
cpu = ort.InferenceSession(model, providers=['CPUExecutionProvider']).run(None, feed)[0].tolist()
session = ort.InferenceSession(model, providers=['DmlExecutionProvider', 'CPUExecutionProvider'])
active = 'DmlExecutionProvider' in session.get_providers()
print(json.dumps({'adapter': active, 'cpu': cpu, 'dml': session.run(None, feed)[0].tolist() if active else None}))
"@
}

<#
.SYNOPSIS
    Grades the probe's output: Pass, NoAdapter, Wrong or ProbeFailed, with a one-line Detail.
#>
function ConvertFrom-OrtDmlMatMulProbe {
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][string]$Text, [int]$ExitCode = 0)
    $verdict = { param($status, $detail) [pscustomobject]@{ Status = $status; Detail = $detail } }
    if ($ExitCode -ne 0) { return & $verdict 'ProbeFailed' "the probe exited $ExitCode`: $Text" }
    $line = @($Text -split "`r?`n" | Where-Object { $_ -match '^\{.*\}\s*$' }) | Select-Object -Last 1
    if (-not $line) { return & $verdict 'ProbeFailed' "the probe printed no JSON line: $Text" }
    $report = $line | ConvertFrom-Json
    $want = @(321, 654, 987, 1320)
    $cpu = @($report.cpu)
    if ($cpu.Count -ne 4 -or (@(0..3 | Where-Object { [math]::Abs($cpu[$_] - $want[$_]) -gt 1e-3 })).Count -gt 0) {
        return & $verdict 'ProbeFailed' "the CPU control returned [$($cpu -join ', ')], expected [$($want -join ', ')]"
    }
    if (-not $report.adapter) { return & $verdict 'NoAdapter' 'no DirectML adapter is visible here, so the shape was not checked' }
    $dml = @($report.dml)
    if ($dml.Count -ne 4 -or (@(0..3 | Where-Object { [math]::Abs($dml[$_] - $want[$_]) -gt 1e-3 })).Count -gt 0) {
        return & $verdict 'Wrong' "DirectML returned [$($dml -join ', ')] where the CPU returned [$($cpu -join ', ')]"
    }
    return & $verdict 'Pass' "DirectML matches the CPU: [$($dml -join ', ')]"
}

<#
.SYNOPSIS
    Runs the probe under a Python that has onnxruntime and returns its verdict.
#>
function Invoke-OrtDmlMatMulProbe {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Python)
    $global:LASTEXITCODE = 0
    $output = & $Python -c (Get-OrtDmlMatMulProbeSource) 2>&1 | Out-String
    return ConvertFrom-OrtDmlMatMulProbe -Text $output -ExitCode $LASTEXITCODE
}

Export-ModuleMember -Function Get-OrtDmlMatMulProbeSource, ConvertFrom-OrtDmlMatMulProbe, Invoke-OrtDmlMatMulProbe
