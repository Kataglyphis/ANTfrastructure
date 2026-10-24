#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Mutations prove the gate fails for structural metrics; they do not prove runtime behavior or duplication detection.

$complexityScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-CodeComplexity.ps1'

function Invoke-ComplexityCase {
    param([string]$Prefix, [Collections.IDictionary]$Files, [scriptblock]$Assert)
    Invoke-InTestDir -DirectoryPrefix $Prefix -Files $Files -Body {
        param($directory)
        $report = & $complexityScript -Path $directory -PassThru
        & $Assert $report $directory
    }
}

function Invoke-ValidComplexityCase {
    param([string]$Prefix, [switch]$MalformedArchive, [scriptblock]$Assert)
    $files = @{ 'valid.ps1' = "function Test-Good { 'ok' }" }
    if ($MalformedArchive) { $files['archive/broken.ps1'] = 'function Bad { if ( }' }
    Invoke-ComplexityCase -Prefix $Prefix -Files $files -Assert $Assert
}

function Assert-UnitCyclomatic {
    param($Report, [string]$Name, [int]$Expected)
    $found = @($Report.Units | Where-Object Name -eq $Name)
    Assert-Equal 1 $found.Count "expected one unit named $Name"
    Assert-Equal $Expected $found[0].Cyclomatic
    return $found[0]
}

function Assert-ComplexityMutation {
    param([string]$Prefix, [string]$FileName, [string]$Control, [string]$Mutation, [string]$Metric)
    Invoke-InTestDir -DirectoryPrefix $Prefix -Body {
        param($directory)
        $file = Join-Path $directory $FileName
        [IO.File]::WriteAllText($file, $Control)
        $report = & $complexityScript -Path $file -PassThru
        Assert-Equal 0 $report.FindingCount
        [IO.File]::WriteAllText($file, $Mutation)
        $mutated = & $complexityScript -Path $file -PassThru
        Assert-Equal 1 @($mutated.Findings | Where-Object Metric -eq $Metric).Count
        Assert-Throws { & $complexityScript -Path $file -Strict -PassThru | Out-Null } -MessagePattern 'complexity gate failed'
    }
}

function New-NestingFixture {
    param([int]$Depth)
    return "function Test-Nesting {`n" + ('if ($true) {' * $Depth) + "'leaf'" + ('}' * $Depth) + "`n}"
}

function New-SizeFixture {
    param([int]$Count)
    return "function Test-Size {`n# comment only`n`n" + ((1..$Count | ForEach-Object { "`$x = $_" }) -join "`n") + "`n}"
}

Describe 'PowerShell complexity analysis' {
    It 'counts each named scope and the script body without charging nested functions twice' {
        Invoke-ComplexityCase -Prefix 'complexity-scope-' -Files @{ 'sample.ps1' = @'
if ($true) { $script:ran = $true }
function Outer {
    if ($true) { 'outer' }
    function Inner {
        if ($true) { 'inner' }
    }
}
class Sample {
    [int] Evaluate([int] $value) {
        if ($value -gt 0) { return 1 }
        return 0
    }
}
'@ } -Assert {
            param($report)
            Assert-Equal 1 $report.FileCount
            Assert-Equal 4 $report.UnitCount
            [void](Assert-UnitCyclomatic -Report $report -Name '<script>' -Expected 2)
            [void](Assert-UnitCyclomatic -Report $report -Name 'Outer' -Expected 2)
            [void](Assert-UnitCyclomatic -Report $report -Name 'Outer.Inner' -Expected 2)
            $method = Assert-UnitCyclomatic -Report $report -Name 'Sample.Evaluate' -Expected 2
            Assert-Equal 'Method' $method.Kind
        }
    }

    It 'counts Boolean, pipeline-chain, ternary and null-coalescing branches' {
        Invoke-ComplexityCase -Prefix 'complexity-operators-' -Files @{ 'operators.ps1' = @'
if ($a -and $b -or $c) { 'yes' }
Write-Output first && Write-Output second
$value = $a ?? 5
$value ??= 6
$result = $a ? 1 : 0
'@ } -Assert {
            param($report)
            Assert-Equal 8 $report.Units[0].Cyclomatic
            Assert-Equal 0 $report.FindingCount
        }
    }

    It 'counts elseif, loops, switch cases, catch and trap branches' {
        Invoke-ComplexityCase -Prefix 'complexity-flow-' -Files @{ 'flow.ps1' = @'
function Test-Flow {
    if ($a) {} elseif ($b) {}
    for ($i = 0; $i -lt 1; $i++) {}
    foreach ($item in @()) {}
    while ($false) {}
    do {} while ($false)
    do {} until ($true)
    switch ($a) { 1 {}; 2 {} }
    try {} catch {}
    trap { continue }
}
'@ } -Assert {
            param($report)
            [void](Assert-UnitCyclomatic -Report $report -Name 'Test-Flow' -Expected 12)
            Assert-Equal 0 $report.FindingCount
        }
    }

    It 'turns a clean complexity control red when branches cross the fixed limit' {
        $control = "function Test-Branches {`n" + ((1..14 | ForEach-Object { "if (`$a -eq $_) { 'yes' }" }) -join "`n") + "`n}"
        $mutation = $control.Replace("`n}", "`nif (`$a -eq 15) { 'yes' }`n}")
        Assert-ComplexityMutation -Prefix 'complexity-branch-' -FileName 'branch.ps1' -Control $control -Mutation $mutation -Metric 'Cyclomatic'
    }

    It 'turns a clean nesting control red with one deeper branch' {
        Assert-ComplexityMutation -Prefix 'complexity-nesting-' -FileName 'nesting.ps1' -Control (New-NestingFixture 5) -Mutation (New-NestingFixture 6) -Metric 'Nesting'
    }

    It 'turns a clean size control red while ignoring blank and comment-only lines' {
        Assert-ComplexityMutation -Prefix 'complexity-size-' -FileName 'size.ps1' -Control (New-SizeFixture 78) -Mutation (New-SizeFixture 80) -Metric 'CodeLines'
    }

    It 'ignores archive files and fails on an empty selection' {
        Invoke-ValidComplexityCase -Prefix 'complexity-input-' -MalformedArchive -Assert {
            param($report, $directory)
            Assert-Equal 1 $report.FileCount
            Assert-Throws { & $complexityScript -Path (Join-Path $directory 'archive') -PassThru | Out-Null } -MessagePattern 'No PowerShell files selected'
        }
    }

    It 'fails before reporting metrics for malformed source' {
        Invoke-ValidComplexityCase -Prefix 'complexity-parse-' -Assert {
            param($report, $directory)
            Assert-Equal 0 $report.FindingCount
            [IO.File]::WriteAllText((Join-Path $directory 'broken.ps1'), 'function Bad { if ( }')
            Assert-Throws { & $complexityScript -Path $directory -PassThru | Out-Null } -MessagePattern 'parse error'
        }
    }

    It 'writes the complete report as JSON' {
        Invoke-ValidComplexityCase -Prefix 'complexity-json-' -Assert {
            param($report, $directory)
            $json = Join-Path $directory 'report.json'
            $savedReport = & $complexityScript -Path (Join-Path $directory 'valid.ps1') -JsonPath $json -PassThru
            $saved = Get-TestJsonFile -Path $json
            Assert-Equal $report.UnitCount $savedReport.UnitCount
            Assert-Equal $savedReport.UnitCount $saved.UnitCount
            Assert-Equal 15 $saved.Limits.Cyclomatic
            Assert-Equal 5 $saved.Limits.Nesting
            Assert-Equal 80 $saved.Limits.CodeLines
        }
    }
}
