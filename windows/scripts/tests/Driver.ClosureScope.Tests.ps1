#requires -Version 7.0
# Backlog #40: the scripted resume (-ResumeStage) NEVER worked. Its retry
# blocks use .GetNewClosure(), which snapshots the LOCAL scope only — but
# $Docker / $MediaCoreCpus / $MediaMemoryGb / $ResumeStage are script-level
# param() variables, so inside the blocks they resolved to EMPTY and the run
# degraded to `[] run --isolation hyperv --cpu-count  --memory "g" ...`, dying
# with a PowerShell PARSER error that pointed nowhere.
#
# The identical fix ($dockerExe = $Docker, etc.) had been on the sibling
# Invoke-RunCommitStage since 2026-07 and carried an explanatory comment — the
# resume path simply never got it, and NOTHING tested this file's closures.
#
# So this suite does not test the one bug; it tests the CLASS. Any
# .GetNewClosure() block anywhere in either driver that reads a top-level
# param() variable is a latent copy of the same defect, and fails here.


Describe 'driver .GetNewClosure() blocks never read script-scope param() vars' {

    $windowsDir = Split-Path $PSScriptRoot -Parent | Split-Path -Parent

    function Get-ScriptParamNames {
        param([System.Management.Automation.Language.ScriptBlockAst]$Ast)
        # The top-level param() block only — NOT function parameters, which are
        # locals of their function and therefore captured correctly.
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
            # The defect only exists INSIDE a function. At script top level the
            # param() variables ARE locals of the script scope, so a closure
            # there captures them correctly — flagging those would be a false
            # positive, and a test that cries wolf gets muted.
            $fn = $call.Parent
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
            if (-not $fn) { continue }

            # Locals of the enclosing function: its parameters, plus everything
            # assigned anywhere in its body. An assignment like
            # `$isolation = $script:BuildIsolation` SHADOWS a same-named script
            # param (PowerShell names are case-insensitive) and is captured fine.
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
        # Comma-wrap: an empty array unrolls to $null on return, and the callers
        # need .Count.
        return , $violations
    }

    It 'build.ps1 has no closure reading a script param (the #40 defect)' {
        $bad = Get-ClosureViolation -Path (Join-Path $windowsDir 'build.ps1')
        $detail = ($bad | ForEach-Object { "`$$($_.Variable) at line $($_.Line)" }) -join '; '
        Assert-Equal 0 $bad.Count "build.ps1: .GetNewClosure() blocks must copy script params into LOCALS first (see `$dockerExe). Offenders: $detail"
    }

    It 'build-buildkit.ps1 has no closure reading a script param' {
        $bad = Get-ClosureViolation -Path (Join-Path $windowsDir 'build-buildkit.ps1')
        $detail = ($bad | ForEach-Object { "`$$($_.Variable) at line $($_.Line)" }) -join '; '
        Assert-Equal 0 $bad.Count "build-buildkit.ps1: closures must not read script params. Offenders: $detail"
    }

    It 'still detects the defect when it is reintroduced (the test is not vacuous)' {
        # A tautological guard would pass on a file with no closures at all.
        # Prove the detector fires on the exact shape backlog #40 described.
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
