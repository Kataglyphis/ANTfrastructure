#requires -Version 7.0
# Real child pwsh covers environment isolation, arguments and streams; sanitizer runtime behavior remains compiler coverage.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsScripts.Shared.psm1')

function New-AgenticChildEnvironmentModule {
    param([string]$Root)
    $state = [pscustomobject]@{ Root = $Root; Log = (Join-Path $Root 'child.log'); ParentValue = $null; ParentPresent = $false; Messages = [Collections.Generic.List[string]]::new() }
    return @{
        ScriptPath = 'windows\scripts\modules\WindowsAgenticLoop.Common.psm1'
        FunctionName = @('Invoke-LoggedAgenticCommand', 'Invoke-TestCommand', 'Get-SanitizerEnvVars', 'Invoke-SanitizerTestCommand')
        FixtureState = $state
        Prelude = @'
$script:AgenticDryRun = $false
function Write-AgenticSection {}
function Write-AgenticLog { param($Message, $Level) $State.Messages.Add($Message) }
function Get-AgenticLogFile {
    $State.ParentValue = [Environment]::GetEnvironmentVariable('ASAN_OPTIONS')
    $State.ParentPresent = Test-Path Env:ASAN_OPTIONS
    $State.Log
}
'@
    }
}

function Assert-AgenticSanitizerChildIsolation {
    param($State)
    foreach ($original in @($null, '', 'original parent options')) {
        Invoke-WithProcessEnvironment -Environment @{ ASAN_OPTIONS = $original } -ScriptBlock {
            $present = Test-Path Env:ASAN_OPTIONS
            $report = (Join-Path $State.Root 'sanitizer.json').Replace("'", "''")
            $command = "param([string]`$marker = 'param works'); @{ Marker = `$marker; Options = `$env:ASAN_OPTIONS; Cwd = (Get-Location).Path } | ConvertTo-Json | Set-Content -LiteralPath '$report'; 'child stdout'; [Console]::Error.WriteLine('child stderr'); exit 0"
            Assert-True (Invoke-MutSanitizerTestCommand -Command $command -Sanitizer asan -RepoRoot $State.Root 6>$null) 'a successful sanitizer child must pass its test phase'
            $actual = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
            Assert-Equal 'detect_leaks=1:halt_on_error=1:abort_on_error=1:allocator_may_return_null=1' $actual.Options 'the sanitizer child must receive its configured options'
            Assert-Equal 'param works' $actual.Marker 'the original command retains its leading param block'
            Assert-Equal $State.Root $actual.Cwd 'test commands still run in RepoRoot'
            Assert-Equal $present $State.ParentPresent 'the parent must retain its unset versus defined state while the child starts'
            Assert-Equal $original $State.ParentValue 'the parent must retain its environment while the child starts'
            Assert-Equal $original ([Environment]::GetEnvironmentVariable('ASAN_OPTIONS')) 'child completion must leave the parent untouched'
            $log = Get-Content -LiteralPath $State.Log -Raw
            Assert-Match 'child stdout' $log 'stdout remains in the durable phase log'
            Assert-Match 'child stderr' $log 'stderr remains in the durable phase log'
            Assert-True ($State.Messages.Contains("Command: $command")) 'command logging retains the original command without environment setup text'
        }
    }
}

function Invoke-AgenticChildEnvironmentMutation {
    param([string]$Find, [string]$Replace, [string]$Expected, [scriptblock]$Body)
    Invoke-TestFunctionMutations -ModuleArgumentsFactory { param($dir) New-AgenticChildEnvironmentModule -Root $dir } `
        -IncludeControl -Find $Find -Replace $Replace -Expected $Expected -Body $Body
}

Describe 'Agentic child environment isolation' {
    It 'keeps sanitizer options out of the parent and detects missing child overrides' {
        Invoke-AgenticChildEnvironmentMutation -Find '-Environment $envVars' -Replace '-Environment @{}' -Expected 'sanitizer child must receive its configured options' `
            -Body { param($state) Assert-AgenticSanitizerChildIsolation $state }
    }

    It 'fails the test phase on a failed child exit and detects swallowing its status' {
        Invoke-AgenticChildEnvironmentMutation -Find 'return $LASTEXITCODE' -Replace 'return 0' -Expected 'failing sanitizer child must fail its test phase' `
            -Body { param($state)
                Assert-False (Invoke-MutSanitizerTestCommand -Command 'exit 7' -Sanitizer asan -RepoRoot $state.Root 6>$null) 'a failing sanitizer child must fail its test phase'
            }
    }

    It 'preserves apostrophes, newlines, empty values and removals in the child environment' {
        Invoke-InTestDir { param($dir)
            $arguments = New-AgenticChildEnvironmentModule -Root $dir
            Invoke-WithFunctionModule @arguments -Body { param($state)
                $report = (Join-Path $state.Root 'quoted.json').Replace("'", "''")
                $value = "a'b`nsecond line"
                $environment = @{ AGENTIC_ENV_QUOTED = $value; AGENTIC_ENV_EMPTY = ''; AGENTIC_ENV_REMOVED = $null }
                Invoke-WithProcessEnvironment -Environment @{ AGENTIC_ENV_QUOTED = 'parent'; AGENTIC_ENV_EMPTY = 'parent'; AGENTIC_ENV_REMOVED = 'parent' } -ScriptBlock {
                    $command = "@{ Value = `$env:AGENTIC_ENV_QUOTED; Empty = `$env:AGENTIC_ENV_EMPTY; EmptyPresent = (Test-Path Env:AGENTIC_ENV_EMPTY); Removed = (Test-Path Env:AGENTIC_ENV_REMOVED) } | ConvertTo-Json | Set-Content -LiteralPath '$report'"
                    Assert-True (Invoke-MutTestCommand -Command $command -RepoRoot $state.Root -Environment $environment 6>$null)
                    $actual = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
                    Assert-Equal $value $actual.Value
                    Assert-Equal '' $actual.Empty
                    Assert-True $actual.EmptyPresent 'empty remains defined in the child'
                    Assert-False $actual.Removed 'null explicitly removes the inherited child variable'
                    foreach ($name in $environment.Keys) { Assert-Equal 'parent' ([Environment]::GetEnvironmentVariable($name)) 'environment overrides cannot mutate the parent' }
                }
                Assert-True (Invoke-MutTestCommand -Command 'exit 0' -RepoRoot $state.Root -Environment $null 6>$null) 'a null override map retains the normal command transport'
            }
        }
    }
}
