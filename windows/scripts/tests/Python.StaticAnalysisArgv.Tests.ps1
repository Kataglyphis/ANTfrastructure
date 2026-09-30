#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

# A second bandit -r is exit 2 and easy to miss, so the argv is built from the driver's AST and its flags counted.

Describe 'Invoke-CiStaticAnalysis: bandit argv' {

    $repoRoot = Get-RepoRoot
    $driver = Join-Path $repoRoot 'windows\scripts\python\Invoke-CiStaticAnalysis.ps1'
    $linuxTwin = Join-Path $repoRoot 'linux/scripts/02-toolchain/python/ci_static_analysis.sh'

    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens, [ref]$parseErrors)

    # Found by its second element, the gate name, so the assertions are about the argv, not the text around it.
    $banditCall = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.CommandElements.Count -ge 3 -and
                $n.CommandElements[1].Extent.Text -eq '"bandit"' }, $true)) | Select-Object -First 1

    $targetsAssign = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$banditTargets' }, $true)) | Select-Object -First 1

    # Build the real argv with known inputs.
    $argv = @()
    if ($null -ne $banditCall -and $null -ne $targetsAssign) {
        $body = '{0}{1}{2}' -f $targetsAssign.Extent.Text, [Environment]::NewLine, $banditCall.CommandElements[2].Extent.Text
        $sb = [scriptblock]::Create('param($PackageName, $ExtraPaths, $BanditExcludes)' + [Environment]::NewLine + $body)
        $argv = @(& $sb 'orchestrant' @('benchmarks', 'frontend', 'bench') 'tests,vendor')
    }

    It 'has a parseable driver and a bandit gate to grade' {
        Assert-Equal 0 @($parseErrors).Count
        Assert-NotNull $banditCall
        Assert-NotNull $targetsAssign
    }

    It 'passes exactly ONE -r, no matter how many extra paths there are' {
        Assert-Equal 1 @($argv | Where-Object { $_ -ceq '-r' }).Count
    }

    It 'puts the package and every extra path after that single -r, in order' {
        Assert-Equal 'bandit -r orchestrant benchmarks frontend bench -x tests,vendor' ($argv -join ' ')
    }

    It 'still names only the package when there are no extra paths' {
        $sb = [scriptblock]::Create('param($PackageName, $ExtraPaths, $BanditExcludes)' + [Environment]::NewLine +
            ('{0}{1}{2}' -f $targetsAssign.Extent.Text, [Environment]::NewLine, $banditCall.CommandElements[2].Extent.Text))
        $bare = @(& $sb 'orchestrant' @() 'tests,vendor')
        Assert-Equal 'bandit -r orchestrant -x tests,vendor' ($bare -join ' ')
        Assert-Equal 1 @($bare | Where-Object { $_ -ceq '-r' }).Count
    }

    It 'takes the exclude list from -BanditExcludes rather than a literal' {
        # One -x carrying whatever the caller passed, so a consumer never hard-codes the whole list.
        Assert-Equal 1 @($argv | Where-Object { $_ -ceq '-x' }).Count
        Assert-Equal 'tests,vendor' $argv[$argv.Count - 1]
    }

    It 'defaults -BanditExcludes to exactly the Linux twin BANDIT_EXCLUDES default' {
        # Two lanes grading one tree with different exclude sets would report findings on one lane only.
        $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'BanditExcludes' }) |
            Select-Object -First 1
        Assert-NotNull $param
        $windowsDefault = $param.DefaultValue.Extent.Text.Trim("'")

        $shell = Get-Content -LiteralPath $linuxTwin -Raw
        $m = [regex]::Match($shell, 'BANDIT_EXCLUDES="\$\{BANDIT_EXCLUDES:-(?<v>[^}]*)\}"')
        Assert-True $m.Success
        Assert-Equal $m.Groups['v'].Value $windowsDefault
    }
}
