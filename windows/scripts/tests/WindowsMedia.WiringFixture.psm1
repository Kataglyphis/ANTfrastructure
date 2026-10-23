#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# AST and listing fixtures do not configure, compile or execute media runtimes.

function New-MediaTestAstView {
    param([Parameter(Mandatory)][string]$ScriptPath)
    $tree = Get-TestScriptAst -ScriptPath $ScriptPath
    [pscustomobject]@{ Ast = $tree; Nodes = @($tree.FindAll({ $true }, $true)) }
}

function Get-MediaTestAstNode {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast, [Parameter(Mandatory)][scriptblock]$Predicate, [switch]$ScriptLevel, [switch]$DirectChildren)
    $Ast.FindAll({ param($node)
        if ($DirectChildren -and -not [object]::ReferenceEquals($node.Parent, $Ast)) { return $false }
        if (-not (& $Predicate $node)) { return $false }
        if ($ScriptLevel) {
            for ($parent = $node.Parent; $parent; $parent = $parent.Parent) {
                if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { return $false }
            }
        }
        return $true
    }, $true)
}

function Get-MediaTestEnclosingIf {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Node, [string]$ConditionPattern = '')
    for ($parent = $Node.Parent; $parent; $parent = $parent.Parent) {
        if ($parent -is [Management.Automation.Language.IfStatementAst] -and
            (-not $ConditionPattern -or $parent.Clauses.Item1.Extent.Text -match $ConditionPattern)) { return $parent }
    }
}

function Get-MediaTestAssignment {
    param([Parameter(Mandatory)][Management.Automation.Language.Ast]$Ast, [Parameter(Mandatory)][string]$Variable,
        [string]$Operator = '', [string]$Value = '', [Management.Automation.Language.Ast]$Contains, [switch]$Single)
    $assignments = @(Get-MediaTestAstNode -Ast $Ast -Predicate { param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $Variable -and
        (-not $Operator -or $node.Operator -eq $Operator) -and (-not $Value -or $node.Right.Extent.Text -eq $Value)
    })
    if ($Single -or $Contains) {
        Assert-Equal 1 $assignments.Count "one $Variable assignment"
        if ($Contains) {
            $right = $assignments[0].Right.Extent
            Assert-True ($Contains.Extent.StartOffset -ge $right.StartOffset -and $Contains.Extent.EndOffset -le $right.EndOffset) "$Variable holds $($Contains.Extent.Text)"
        }
        return $assignments[0]
    }
    return $assignments
}

function Assert-MediaTestFindingGuard {
    param([Parameter(Mandatory)][Management.Automation.Language.CommandAst[]]$Command,
        [Parameter(Mandatory)][string]$Variable, [switch]$Unconditional, [string]$ParentCondition = '')
    Assert-Equal 1 $Command.Count 'one finding-gate call site'
    $root = $Command[0]
    while ($root.Parent) { $root = $root.Parent }
    $null = Get-MediaTestAssignment -Ast $root -Variable $Variable -Contains $Command[0] -Single
    $condition = "$Variable.Count -gt 0"
    $checks = @(Get-MediaTestAstNode -Ast $root -Predicate { param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq $condition
    })
    Assert-Equal 1 $checks.Count "one if ($condition)"
    Assert-Equal 1 $checks[0].Clauses.Count 'no elseif arm'
    Assert-Null $checks[0].ElseClause 'no else arm'
    $throws = @(Get-MediaTestAstNode -Ast $checks[0].Clauses[0].Item2 -DirectChildren -Predicate { param($node) $node -is [Management.Automation.Language.ThrowStatementAst] })
    Assert-Equal 1 $throws.Count 'a direct throw'
    if ($Unconditional) { Assert-Null (Get-MediaTestEnclosingIf -Node $checks[0]) 'the check is not nested in a lane condition' }
    if ($ParentCondition) {
        $parent = Get-MediaTestEnclosingIf -Node $Command[0] -ConditionPattern $ParentCondition
        Assert-NotNull $parent "the enclosing $ParentCondition"
        Assert-True ([object]::ReferenceEquals($checks[0].Parent, $parent.Clauses[0].Item2)) 'the check sits directly in the lane block'
    }
}

function New-FfmpegTestListing {
    param([Parameter(Mandatory)][ValidateSet('amf', 'vulkan')][string]$Backend,
        [Parameter(Mandatory)][Collections.IDictionary]$Expectation, [string[]]$Drop = @(), [string[]]$NoDevice = @(),
        [switch]$NoHwaccel, [switch]$NoEnable)
    $eol = if ($Backend -eq 'amf') { "`n" } else { "`r`n" }
    $description = if ($Backend -eq 'amf') { 'AMD AMF thing' } else { 'Vulkan thing' }
    $listing = @{}
    foreach ($kind in 'encoders', 'decoders', 'filters') {
        if (-not $Expectation.Contains($kind)) { continue }
        $flags = if ($kind -eq 'filters') { 'TC' } else { 'V....D' }
        $header = switch ($kind) {
            encoders { "Encoders:${eol} V....D mpeg4                MPEG-4 part 2$eol" }
            decoders { "Decoders:$eol" }
            filters { "Filters:${eol}  T.. = Timeline support$eol" }
        }
        $rows = @($Expectation[$kind] | Where-Object { $_ -notin $Drop } | ForEach-Object { " $flags $($_.PadRight(20)) $description" })
        $listing[$kind] = $header + ($rows -join $eol)
    }
    $listing.hwaccels = "Hardware acceleration methods:${eol}dxva2${eol}d3d11va$eol" + $(if ($NoHwaccel) { '' } else { "$Backend$eol" })
    $listing.version = 'configuration: --enable-shared ' + $(if ($NoEnable) { '' } else { "--enable-$Backend " }) + '--enable-gpl'
    foreach ($decoder in $Expectation['hwdecoders']) {
        $devices = 'dxva2 d3d11va d3d11va d3d12va amf' + $(if ($decoder -in $NoDevice) { '' } else { ' vulkan' })
        $listing["decoder=$decoder"] = "Decoder $decoder [$decoder]:${eol}    General capabilities: dr1 delay threads ${eol}    Supported hardware devices: $devices $eol"
    }
    return $listing
}

function Assert-FfmpegTestConfigSymbols {
    param([Parameter(Mandatory)][Collections.IDictionary]$Expectation,
        [Parameter(Mandatory)][string[]]$Actual, [Parameter(Mandatory)][ValidateSet('amf', 'vulkan')][string]$Backend)
    $prefix = if ($Backend -eq 'vulkan') { 'CONFIG_' } else { '' }
    $expected = @(
        foreach ($kind in 'encoders', 'decoders', 'filters') {
            $suffix = switch ($kind) { encoders { 'ENCODER' }; decoders { 'DECODER' }; filters { 'FILTER' } }
            foreach ($name in $Expectation[$kind]) {
                if ($Backend -eq 'amf' -and $kind -eq 'filters' -and $name -eq 'vsrc_amf') { 'AMF_CAPTURE_FILTER' }
                else { "$prefix${name}_$suffix".ToUpperInvariant() }
            }
        }
        foreach ($name in $Expectation['hwaccels']) { "$prefix$name".ToUpperInvariant() }
        if ($Backend -eq 'vulkan') {
            foreach ($name in $Expectation['hwdecoders']) { "CONFIG_${name}_VULKAN_HWACCEL".ToUpperInvariant() }
            'CONFIG_VULKAN_1_4'
            'HAVE_SPIRV_HEADERS_SPIRV_H'
        }
    )
    $differences = @(Compare-Object -ReferenceObject $expected -DifferenceObject $Actual)
    Assert-Equal 0 $differences.Count "build gate and smoke agree: $($differences | Out-String)"
}

function Get-OpenCvTestDownloadedOrtSummary {
    param([switch]$ConfigureLog)
    $lines = @(
        '  ONNX Runtime:                  YES (ver 1.25.1)'
        '    Include path:                C:/temp/opencv-src/build/3rdparty/onnxruntime/onnxruntime-win-x64-1.25.1/include'
        '    Link libraries:              C:/temp/opencv-src/build/3rdparty/onnxruntime/onnxruntime-win-x64-1.25.1/lib/onnxruntime.lib'
    )
    if ($ConfigureLog) { $lines = @($lines | ForEach-Object { "-- $_" }) }
    $lines -join "`n"
}

Export-ModuleMember -Function New-MediaTestAstView, Get-MediaTestAstNode, Get-MediaTestEnclosingIf, Assert-MediaTestFindingGuard, New-FfmpegTestListing, Assert-FfmpegTestConfigSymbols, Get-OpenCvTestDownloadedOrtSummary

Export-ModuleMember -Function Get-MediaTestAssignment
