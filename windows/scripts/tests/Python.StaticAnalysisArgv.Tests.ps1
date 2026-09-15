#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The bandit command line of windows/scripts/python/Invoke-CiStaticAnalysis.ps1,
# and its parity with the Linux twin's.
#
# THE DEFECT THIS PINS. Both drivers spelled the -ExtraPaths / extra-path knob as
# one `-r` PER path. bandit's `-r` is store_true against a SINGLE nargs='*'
# positional, so `bandit -r a -r b` is "unrecognized arguments" and exit 2
# (measured with bandit 1.9.4): the knob took the whole gate down on every lane
# that used it, which is why the OrchestrANT consumer could not adopt it. The
# assertions below COUNT the flags rather than eyeballing the string, because a
# second `-r` is exactly what a reader does not see.
#
# It is asserted by BUILDING the argv the driver builds -- the argument
# expression is lifted out of the script's AST and evaluated with the variables
# set -- not by grepping the file, so a rename or a reflow cannot make it pass
# while the command changes.

Describe 'Invoke-CiStaticAnalysis: bandit argv' {

    $repoRoot = Get-RepoRoot
    $driver = Join-Path $repoRoot 'windows\scripts\python\Invoke-CiStaticAnalysis.ps1'
    $linuxTwin = Join-Path $repoRoot 'linux/scripts/02-toolchain/python/ci_static_analysis.sh'

    $tokens = $null; $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($driver, [ref]$tokens, [ref]$parseErrors)

    # The `& $runAnalyser "bandit" ( <argv> ) @()` call, by its SECOND element,
    # which is the gate name. Finding it by position is what lets the assertions
    # below be about the argv rather than about the text around it.
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
        # One -x, and its value is whatever the caller passed. A literal here is
        # the state OrchestrANT audit item A107 named: a consumer with one more
        # directory to skip had to hard-code the whole string in its own driver.
        Assert-Equal 1 @($argv | Where-Object { $_ -ceq '-x' }).Count
        Assert-Equal 'tests,vendor' $argv[$argv.Count - 1]
    }

    It 'defaults -BanditExcludes to exactly the Linux twin BANDIT_EXCLUDES default' {
        # Cross-lane parity is the point of the pair: two lanes grading one tree
        # with different exclude sets is a finding that exists on one lane only.
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
