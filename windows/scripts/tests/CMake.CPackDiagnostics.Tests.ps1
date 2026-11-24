#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local files and the lifted canonical logger cover diagnostics; no package generator, installer or compiler executes.

Import-TestRepoModule -Name 'WindowsCMake.Common'

function Get-CPackFixtureLog {
    param([hashtable]$Files)
    $state = New-TestCallState -Properties @{ Root = '' }
    Invoke-InTestDir {
        param($dir)
        $state.Root = $dir
        Write-TestFileTree -Root $dir -Files $Files
        $logger = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsBuild.Common.psm1' -FunctionName Write-BuildLogMessages).ToString()
        $prelude = $logger + "`n" + @'
function Write-BuildLog {
    param($Context, [string]$Message)
    $State.Calls.Add([pscustomobject]@{ LogContext = $Context; Message = $Message })
}
'@
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsCMake.Common.psm1' -FunctionName Get-CPackGeneratorLogMessages, Write-CPackGeneratorLog `
            -Prelude $prelude -Prefix Probe -FixtureState $state -Body {
                param($fixture)
                Write-ProbeCPackGeneratorLog -Context ([pscustomobject]@{}) -BuildPath $fixture.Root -TailLines 2
            }
        $state.Calls | ForEach-Object Message
    }
}

Describe 'Portable CPack generator diagnostics' {
    It 'exports the real diagnostic entry from its module' {
        Assert-Equal 'WindowsCMake.Common' (Get-Command Write-CPackGeneratorLog -Module WindowsCMake.Common -ErrorAction Stop).ModuleName
    }

    It 'prints the requested tail and path of a nested generator log' {
        $lines = @(Get-CPackFixtureLog -Files @{ '_CPack_Packages/win64/NSIS/NSISOutput.log' = "line 1`nError: path too long`nline 3`n" })
        Assert-Match 'NSISOutput\.log' ($lines -join "`n")
        Assert-True ($lines -contains 'Error: path too long')
        Assert-True ($lines -contains 'line 3')
        Assert-False ($lines -contains 'line 1')
    }

    foreach ($case in @(
            @{ Name = 'reports a missing generator directory'; Files = @{ 'unrelated.txt' = 'outside the generator directory' }; Pattern = 'does not exist' },
            @{ Name = 'reports an existing directory without generator logs'; Files = @{ '_CPack_Packages/unrelated.txt' = 'not a generator log' }; Pattern = 'No CPack generator logs under ' }
        )) {
        It $case.Name {
            Assert-Match $case.Pattern ((@(Get-CPackFixtureLog -Files $case.Files)) -join "`n")
        }
    }

    It 'keeps sorted generator paths and each separate tail without unrelated files' {
        $lines = @(Get-CPackFixtureLog -Files @{
                '_CPack_Packages/b.log' = "old-b`ntail-b1`ntail-b2`n"
                '_CPack_Packages/a.log' = "old-a`ntail-a1`ntail-a2`n"
                '_CPack_Packages/unrelated.txt' = 'not a generator log'
            })
        Assert-Equal 6 $lines.Count
        Assert-Match 'a\.log' $lines[0]
        Assert-Equal 'tail-a1' $lines[1]
        Assert-Equal 'tail-a2' $lines[2]
        Assert-Match 'b\.log' $lines[3]
        Assert-Equal 'tail-b1' $lines[4]
        Assert-Equal 'tail-b2' $lines[5]
    }
}
