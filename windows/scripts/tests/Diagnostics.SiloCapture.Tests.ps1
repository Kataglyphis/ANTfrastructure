#requires -Version 7.0
# NOT covered: live container behavior, host CIM state or debugger attaches; fixtures pin query logic, transport and manual discovery.

Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop

function Assert-SiloDebuggerCapture {
    Invoke-InTestDir -Prefix 'silo-capture-' -Body { param($dir)
        $state = New-TestCallState @{ Code = 7 }
        Invoke-WithTestNativeCommand -Name Invoke-CdbFixture -FixtureState $state -Implementation {
            'debugger stdout'
            Write-Error 'debugger stderr' -ErrorAction Continue
        } -Body { param($state)
            foreach ($invasive in @($false, $true)) {
                $log = Join-Path $dir "capture-$invasive.log"
                $command = '.reload /f; !handle 0 f Event; qd'
                $output = @(Invoke-MutSiloDebugger -CdbPath Invoke-CdbFixture -ProcessId 314 -OutDir 'C:\logs with spaces' -Command $command -LogPath $log -Invasive:$invasive)
                Assert-Equal 0 $output.Count 'debugger streams must reach only the capture log'
                Assert-True (Test-Path -LiteralPath $log) 'debugger capture must write its log'
                $text = [IO.File]::ReadAllText($log)
                Assert-Match 'debugger stdout' $text
                Assert-Match 'debugger stderr' $text 'stderr must stay in the saved log'
                Assert-Equal 7 $global:LASTEXITCODE 'caller verdicts retain the raw debugger status'
                $prefix = if ($invasive) { '-p' } else { '-pv|-p' }
                Assert-Equal "$prefix|314|-y|srv*C:\logs with spaces\sym*https://msdl.microsoft.com/download/symbols|-c|$command" ($state.Calls[-1] -join '|') 'attach policy and command boundaries must remain exact'
            }
        }
    }
}

function Assert-SiloManualHandlePlan {
    param([string]$ScriptPath)
    $ast = Get-TestScriptAst -ScriptPath $ScriptPath
    $initializers = @($ast.EndBlock.Statements | Where-Object {
        $_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$cdb'
    })
    Assert-Equal 1 $initializers.Count 'manual discovery must initialize debugger state before the optional branch'
    $discover = Get-TestAstAncestor -Node (Get-TestAstCommands -Ast $ast -Name Get-CdbPath) -Type ([Management.Automation.Language.IfStatementAst]) -First
    $detail = Get-TestAstAncestor -Node (Get-TestAstCommands -Ast $ast -Name Get-Process) -Type ([Management.Automation.Language.IfStatementAst]) -First
    Assert-NotNull $discover
    Assert-NotNull $detail
    Set-StrictMode -Version Latest
    $LsmPid = 314; $Handle = 0x338
    . ([scriptblock]::Create($initializers[0].Extent.Text))
    & ([scriptblock]::Create($discover.Extent.Text))
    & ([scriptblock]::Create($detail.Extent.Text))
    Assert-Null $cdb 'manual handles do not require a debugger'
    Assert-Equal 314 $LsmPid 'manual discovery retains the supplied process'
    Assert-Equal 0x338 $Handle 'manual discovery retains the supplied handle'
}

function Get-SiloWininitPrelude {
    @'
function Get-CimInstance { param($ClassName, $Filter) $State.Calls.Add(@($ClassName, $Filter)); $State.Rows }
function Get-Date { $State.Now }
function Start-Sleep { param([int]$Seconds) $State.Now = $State.Now.AddSeconds($Seconds) }
'@
}

function Assert-SiloWininitQueries {
    param($State)
    Assert-Equal 0 @(Get-MutSiloWininitId).Count
    $State.Rows = @([pscustomobject]@{ ProcessId = 13 })
    Assert-Equal 13 (Get-MutSiloWininitId)
    $State.Rows += [pscustomobject]@{ ProcessId = 29 }
    Assert-Equal '13|29' ((Get-MutSiloWininitId) -join '|')

    $State.Now = [datetime]'2026-01-01T00:00:00Z'
    $newWininit = Wait-MutForNewSilo -BaselinePid @(13) -TimeoutSec 1 -PollSec 1
    Assert-Equal 29 $newWininit.ProcessId 'polling must exclude existing silo ids'

    $State.Rows = @([pscustomobject]@{ ProcessId = 13 })
    $State.Now = [datetime]'2026-01-01T00:00:00Z'
    Assert-Null (Wait-MutForNewSilo -BaselinePid @(13) -TimeoutSec 1 -PollSec 1) 'a missed silo remains a timeout result'
    Assert-Equal 5 $State.Calls.Count 'baseline and polling both use the shared query'
    foreach ($call in $State.Calls) {
        Assert-Equal "Win32_Process|Name='wininit.exe'" ($call -join '|') 'all discovery paths must use the exact wininit query'
    }
}

Describe 'Shared silo debugger transport' {
    Invoke-TestMutationChecks -Check @(
        @{ Name = 'keeps non-invasive defaults and detects controlling attaches'; Kind = 'debugger'; Find = "'-pv', '-p'"; Replace = "'-p'" },
        @{ Name = 'retains a single native argument for an invasive attach'; Kind = 'debugger'; Find = '[string[]]$attach'; Replace = '$attach' },
        @{ Name = 'saves both debugger streams and detects uncaptured output'; Kind = 'debugger'; Find = ' > $LogPath 2>&1'; Replace = '' },
        @{ Name = 'keeps the shared CIM query scoped to wininit'; Kind = 'wininit'; Find = "Name='wininit.exe'"; Replace = "Name='services.exe'" },
        @{ Name = 'excludes existing process ids while waiting'; Kind = 'wininit'; Find = '$_.ProcessId -notin $BaselinePid'; Replace = '$_.ProcessId -in $BaselinePid' }
    ) -ArgumentsFactory {
        param($check)
        if ($check.Kind -eq 'debugger') {
            $expected = if ($check.Replace) { 'attach policy and command boundaries must remain exact' } else { 'debugger streams must reach only the capture log' }
            @{ ScriptPath = 'windows/scripts/modules/WindowsSiloProbe.Common.psm1'; FunctionName = 'Invoke-SiloDebugger';
                Find = $check.Find; Replace = $check.Replace; Expected = $expected; Body = { Assert-SiloDebuggerCapture } }
        } else {
            $expected = if ($check.Find -eq "Name='wininit.exe'") { 'all discovery paths must use the exact wininit query' } else { 'polling must exclude existing silo ids' }
            @{ ScriptPath = 'windows/scripts/modules/WindowsSiloProbe.Common.psm1';
                FunctionName = @('Get-SiloWininit', 'Get-SiloWininitId', 'Wait-ForNewSilo');
                Find = $check.Find; Replace = $check.Replace; Expected = $expected; IncludeControl = $true;
                Prelude = Get-SiloWininitPrelude; Body = { param($state) Assert-SiloWininitQueries $state } }
        }
    }

    It 'propagates a missing debugger command' {
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsSiloProbe.Common.psm1' -FunctionName Invoke-SiloDebugger -Body {
            Invoke-InTestDir { param($dir)
                Assert-Throws { Invoke-MutSiloDebugger -CdbPath Invoke-AbsentCdbFixture -ProcessId 314 -OutDir $dir -Command qd -LogPath (Join-Path $dir missing.log) } -MessagePattern 'Invoke-AbsentCdbFixture'
            }
        }
    }

    It 'shares the exact wininit query while preserving zero, one and several identifiers' {
        $state = New-TestCallState @{ Rows = @(); Now = [datetime]'2026-01-01T00:00:00Z' }
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsSiloProbe.Common.psm1' `
            -FunctionName @('Get-SiloWininit', 'Get-SiloWininitId', 'Wait-ForNewSilo') -FixtureState $state `
            -Prelude (Get-SiloWininitPrelude) -Body { param($state) Assert-SiloWininitQueries $state }
        $moduleAst = Get-TestScriptAst -ScriptPath 'windows/scripts/modules/WindowsSiloProbe.Common.psm1'
        foreach ($name in 'Get-SiloWininitId', 'Wait-ForNewSilo') {
            $functionAst = @($moduleAst.FindAll({ param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
            }, $true)) | Select-Object -First 1
            Assert-Equal 1 @(Get-TestAstCommands -Ast $functionAst -Name Get-SiloWininit).Count "$name must use the shared query helper"
        }
    }

    It 'wires every existing caller to the shared operations and preserves the only controlling-attach opt-in' {
        $names = @('Find-LsmEventHolder', 'Get-HostLsm', 'Get-LsmWaitObject', 'Get-SiloProcesses', 'Get-LsmWaitstack')
        foreach ($name in $names) {
            $ast = Get-TestScriptAst -ScriptPath "windows/scripts/diagnostics/$name.ps1"
            Assert-Equal 1 @(Get-TestAstCommands -Ast $ast -Name Get-SiloWininitId).Count
            $calls = @(Get-TestAstCommands -Ast $ast -Name Invoke-SiloDebugger)
            $count = if ($name -eq 'Find-LsmEventHolder') { 3 } elseif ($name -eq 'Get-LsmWaitstack') { 0 } else { 1 }
            Assert-Equal $count $calls.Count
            foreach ($call in $calls) {
                $bound = Get-TestCommandArguments $call
                Assert-Equal '$OutDir' $bound.OutDir
                Assert-Equal ($name -eq 'Get-LsmWaitObject') $bound.Contains('Invasive') 'only the existing opt-in caller forwards Invasive'
            }
        }
        $module = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsSiloProbe.Common.psm1'
        $probe = Test-ColdModuleCommands -ModulePath $module -CommandName Get-SiloWininitId, Invoke-SiloDebugger
        Assert-Equal 0 $probe.ExitCode $probe.Output
    }

    It 'keeps the documented manual handle mode independent of debugger discovery and rejects lost initialization' {
        $path = Join-Path (Get-RepoRoot) 'windows/scripts/diagnostics/Find-LsmEventHolder.ps1'
        Assert-SiloManualHandlePlan -ScriptPath $path
        Assert-TestScriptContains -ScriptPath $path -Literal '$cdb = $null'
        Invoke-InTestDir -Files @{ 'manual.ps1' = ([IO.File]::ReadAllText($path).Replace('$cdb = $null', '')) } -Body { param($dir)
            Assert-Throws { Assert-SiloManualHandlePlan -ScriptPath (Join-Path $dir manual.ps1) } -MessagePattern 'manual discovery must initialize debugger state'
        }
    }
}
