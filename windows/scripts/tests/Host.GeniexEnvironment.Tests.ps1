#requires -Version 7.0
# Lifted launcher functions use fake process and HTTP operations; no GenieX server or live port is started.

function Invoke-GeniexEnvironmentFixture {
    param([scriptblock]$Body, [scriptblock]$BeforeDirectory = {}, [scriptblock]$BeforeProcess = {}, [string]$Find = '', [string]$Replace = '')
    $source = (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/host/Start-GeniexServers.ps1' -FunctionName Start-Lane).ToString()
    $source += "`n" + (Get-ScriptFunctionDefinition -ScriptPath 'windows/scripts/modules/WindowsScripts.Shared.psm1' -FunctionName Invoke-WithProcessEnvironment).ToString()
    $exercise = $Body
    Invoke-WithEnv -Vars @{ ANT_GENIEX_UNSET = $null; ANT_GENIEX_EMPTY = ''; ANT_GENIEX_VALUE = 'parent' } -Body {
        Invoke-InTestDir { param($dir)
            $state = New-TestCallState @{ Root = $dir; BeforeDirectory = $BeforeDirectory; BeforeProcess = $BeforeProcess
                Environment = @{ ANT_GENIEX_UNSET = 'server'; ANT_GENIEX_EMPTY = 'child'; ANT_GENIEX_VALUE = $null } }
            $prelude = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ServerEnv = $State.Environment
$LaneLogDir = Join-Path $State.Root 'lane logs'
$exe = 'C:\GenieX CLI\geniex.exe'
$ProbeHost = '127.0.0.1'
$BindAddress = '127.0.0.1'; $Nctx = 16384; $Keepalive = 86400; $MaxTokens = 4096; $LogLevel = 'info'; $Ngl = 3
function Get-LaneModel { 'fixture model' }
function Get-NetTCPConnection { param($State, $LocalPort, $ErrorAction) }
function Invoke-PullIfMissing {}
function Test-ServeFlag { $true }
function Get-Date { param($Format) '20300101-123456' }
function New-Item { param($ItemType, [switch]$Force, $Path) & $State.BeforeDirectory; Microsoft.PowerShell.Management\New-Item -ItemType $ItemType -Force -Path $Path }
function Start-Process {
    param($WindowStyle, $FilePath, $ArgumentList, $RedirectStandardOutput, $RedirectStandardError)
    $State.Calls.Add(@($WindowStyle, $FilePath, ($ArgumentList -join '|'), $RedirectStandardOutput, $RedirectStandardError,
        $env:ANT_GENIEX_UNSET, $env:ANT_GENIEX_EMPTY, $env:ANT_GENIEX_VALUE, (Test-Path Env:ANT_GENIEX_VALUE)))
    & $State.BeforeProcess
    'ignored process output'
}
function Start-Sleep {}
function Invoke-RestMethod { if (Test-Path Env:ANT_GENIEX_UNSET) { throw 'environment leaked into readiness probe' }; $State.Calls.Add('probe') }
function Invoke-Warmup { $State.Calls.Add('warmup') }
'@
            Invoke-WithFunctionModule -Text $source -Prelude $prelude -FixtureState $state -Find $Find -Replace $Replace -Body $exercise
        }
    }
}

function Assert-GeniexParentEnvironment {
    Assert-False (Test-Path Env:ANT_GENIEX_UNSET) 'unset variables must remain absent'
    Assert-True (Test-Path Env:ANT_GENIEX_EMPTY) 'empty variables must remain defined'
    Assert-Equal '' $env:ANT_GENIEX_EMPTY
    Assert-Equal parent $env:ANT_GENIEX_VALUE 'existing values must be restored'
}

Describe 'GenieX lane environment scope' {
    It 'starts hidden with the same arguments and paired logs while restoring absent, empty and existing parent variables' {
        Invoke-GeniexEnvironmentFixture { param($state)
            $output = @(Start-MutLane -Compute gpu -Port 18182 6>$null)
            Assert-Equal 0 $output.Count
            Assert-Equal 3 $state.Calls.Count
            Assert-Equal 'probe|warmup' ($state.Calls[1..2] -join '|')
            $call = $state.Calls[0]
            Assert-Equal 'Hidden|C:\GenieX CLI\geniex.exe|serve|--compute|gpu|--host|127.0.0.1:18182|--nctx|16384|--keepalive|86400|--max-tokens|4096|--log|info|--ngl|3' ($call[0..2] -join '|')
            Assert-Equal (Join-Path $state.Root 'lane logs/gpu-18182-20300101-123456.out.log') $call[3]
            Assert-Equal (Join-Path $state.Root 'lane logs/gpu-18182-20300101-123456.err.log') $call[4]
            Assert-Equal 'server|child||True' ($call[5..8] -join '|')
            Assert-GeniexParentEnvironment
        }
    }

    It 'restores parent variables when log setup or process startup throws' {
        foreach ($setup in @(@{ BeforeDirectory = { throw 'fixture directory failed' } }, @{ BeforeProcess = { throw 'fixture process failed' } })) {
            Invoke-GeniexEnvironmentFixture @setup -Body {
                Assert-Throws { Start-MutLane -Compute gpu -Port 18182 6>$null } -MessagePattern 'fixture (directory|process) failed'
                Assert-GeniexParentEnvironment
            }
        }
    }

    It 'detects omitted environment cleanup' {
        Invoke-GeniexEnvironmentFixture -Find 'Remove-Item -LiteralPath "Env:$environmentName" -ErrorAction SilentlyContinue' -Replace '' -Body {
            Start-MutLane -Compute gpu -Port 18182 6>$null
            Assert-Throws { Assert-GeniexParentEnvironment } -MessagePattern 'unset variables must remain absent'
        }
    }

    It 'requires the shared companion without forced module reloads' {
        $calls = @(Get-TestScriptCommands -ScriptPath 'windows/scripts/host/Start-GeniexServers.ps1' -Name Import-Module)
        Assert-Equal 1 $calls.Count
        $arguments = Get-TestCommandArguments $calls[0]
        Assert-Equal Stop $arguments.ErrorAction
        Assert-False $arguments.Contains('Force')
    }
}

Describe 'Partial process-environment setup failure' {
    It 'restores earlier writes and preserves the original setup exception' {
        Invoke-WithEnv -Vars @{ ANT_ENV_FIRST = 'original'; ANT_ENV_SECOND = $null } -Body {
            $prelude = @'
function Set-Item {
    param($LiteralPath, $Value)
    if ($LiteralPath -eq 'Env:ANT_ENV_SECOND' -and $Value -eq 'fail') { throw 'fixture environment write failed' }
    Microsoft.PowerShell.Management\Set-Item -LiteralPath $LiteralPath -Value $Value
}
'@
            $module = @{ ScriptPath = 'windows/scripts/modules/WindowsScripts.Shared.psm1'; FunctionName = 'Invoke-WithProcessEnvironment'; Prelude = $prelude }
            $setup = 'foreach ($environmentName in @($Environment.Keys)) { Set-Item -LiteralPath "Env:$environmentName" -Value $Environment[$environmentName] }'
            Invoke-TestFunctionMutations -ModuleArguments $module -IncludeControl -Find ("try {`n        " + $setup) -Replace ($setup + "`n    try {") -Expected 'partial setup must restore earlier writes' -Body {
                Assert-Throws { Invoke-MutWithProcessEnvironment -Environment ([ordered]@{ ANT_ENV_FIRST = 'changed'; ANT_ENV_SECOND = 'fail' }) -ScriptBlock { throw 'callback must not run' } } -MessagePattern 'fixture environment write failed'
                Assert-Equal original $env:ANT_ENV_FIRST 'partial setup must restore earlier writes'
                Assert-False (Test-Path Env:ANT_ENV_SECOND)
            }
        }
    }
}
