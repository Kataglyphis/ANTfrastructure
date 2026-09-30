#requires -Version 7.0
# .GetNewClosure() snapshots only the local scope, so a closure in a function sees script-level param() variables empty.


Describe 'driver .GetNewClosure() blocks never read script-scope param() vars' {

    $windowsDir = Split-Path $PSScriptRoot -Parent | Split-Path -Parent

    function Get-ScriptParamNames {
        param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
        # Top-level param() only: function parameters are locals and captured correctly.
        if (-not $Ast.ParamBlock) { return @() }
        return @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    function Get-ClosureViolation {
        param([string]$Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $scriptParams = Get-ScriptParamNames -Ast $ast
        $violations = @()
        # Every `{ ... }.GetNewClosure()` in the file.
        $closureCalls = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                $n.Member.Value -eq 'GetNewClosure' -and
                $n.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
            }, $true)
        foreach ($call in $closureCalls) {
            # At script top level param() variables are locals, so flagging them would be a false positive.
            $fn = $call.Parent
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
            if (-not $fn) { continue }

            # A same-named local assignment (names are case-insensitive) shadows the script param and is captured fine.
            $locals = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            if ($fn.Body.ParamBlock) {
                foreach ($p in $fn.Body.ParamBlock.Parameters) { [void]$locals.Add($p.Name.VariablePath.UserPath) }
            }
            foreach ($a in $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                if ($a.Left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    [void]$locals.Add($a.Left.VariablePath.UserPath)
                }
            }

            $block = $call.Expression.ScriptBlock
            if ($block.ParamBlock) {
                foreach ($p in $block.ParamBlock.Parameters) { [void]$locals.Add($p.Name.VariablePath.UserPath) }
            }
            $vars = $block.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst]
                }, $true)
            foreach ($v in $vars) {
                # Explicitly scoped reads ($script:X, $global:X) are deliberate.
                if (-not $v.VariablePath.IsUnqualified) { continue }
                $name = $v.VariablePath.UserPath
                if ($locals.Contains($name)) { continue }
                if ($scriptParams -contains $name) {
                    $violations += [pscustomobject]@{
                        Variable = $name
                        Line     = $v.Extent.StartLineNumber
                        Function = $fn.Name
                    }
                }
            }
        }
        # Comma-wrap: an empty array unrolls to $null on return, and callers need .Count.
        return , $violations
    }

    It 'Build-Buildkit.ps1 has no closure reading a script param (the #40 defect)' {
        $bad = Get-ClosureViolation -Path (Join-Path $windowsDir 'Build-Buildkit.ps1')
        $detail = ($bad | ForEach-Object { "`$$($_.Variable) at line $($_.Line)" }) -join '; '
        Assert-Equal 0 $bad.Count "Build-Buildkit.ps1: closures must not read script params. Offenders: $detail"
    }

    It 'still detects the defect when it is reintroduced (the test is not vacuous)' {
        # Prove the detector fires, or a file with no closures would pass tautologically.
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("closure-probe-" + [guid]::NewGuid().ToString('N') + '.ps1')
        @'
param([string]$Docker, [int]$MediaCoreCpus)
function Invoke-Thing {
    $container = 'c1'
    $action = { & $Docker run --cpu-count $MediaCoreCpus --name $container }.GetNewClosure()
    & $action
}
'@ | Set-Content -Path $tmp -Encoding utf8
        try {
            $bad = Get-ClosureViolation -Path $tmp
            $names = @($bad.Variable | Sort-Object -Unique)
            Assert-Equal 2 $names.Count "the detector must flag both script params, got: $($names -join ',')"
            Assert-True ($names -contains 'Docker') 'must flag $Docker'
            Assert-True ($names -contains 'MediaCoreCpus') 'must flag $MediaCoreCpus'
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does NOT flag function parameters or block params (no false positives)' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("closure-ok-" + [guid]::NewGuid().ToString('N') + '.ps1')
        @'
param([string]$Docker)
function Invoke-Thing {
    param([string]$ContainerName, [int]$Cpus)
    $dockerExe = $Docker
    $action = {
        param($attempt)
        & $dockerExe run --cpu-count $Cpus --name $ContainerName --attempt $attempt
    }.GetNewClosure()
    & $action 1
}
'@ | Set-Content -Path $tmp -Encoding utf8
        try {
            $bad = Get-ClosureViolation -Path $tmp
            $got = @($bad | ForEach-Object { $_.Variable }) -join ','
            Assert-Equal 0 $bad.Count "the sibling's correct pattern must not be flagged, got: $got"
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}
