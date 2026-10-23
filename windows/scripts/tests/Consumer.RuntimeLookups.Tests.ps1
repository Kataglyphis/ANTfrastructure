#requires -Version 7.0
# Fixture files and runners cover lookup precedence and ABI failure policy; real interpreters and UV remain image coverage.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsUv.Common.psm1')
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsPythonWheel.Common.psm1')
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsScripts.Shared.psm1')

function Assert-LinuxScriptLookupPolicy {
    param([scriptblock]$Resolve)
    Invoke-InTestDir { param($dir)
        $modules = Join-Path $dir 'windows\scripts\modules'
        $checkout = Join-Path $dir 'linux\scripts\03-media\runtime\ort-venv-census.py'
        $image = Join-Path $dir 'windows\scripts\ort-venv-census.py'
        [void][IO.Directory]::CreateDirectory($modules)
        Assert-Equal $checkout (& $Resolve $modules) 'missing copies must name the expected checkout path'
        [void][IO.Directory]::CreateDirectory($image)
        Assert-Equal $checkout (& $Resolve $modules) 'a directory named like the helper is not a script'
        Remove-Item -LiteralPath $image
        [IO.File]::WriteAllText($image, 'image helper')
        Assert-Equal $image (& $Resolve $modules) 'a flat image uses the helper above modules'
        [void][IO.Directory]::CreateDirectory((Split-Path $checkout))
        [IO.File]::WriteAllText($checkout, 'checkout helper')
        Assert-Equal $checkout (& $Resolve $modules) 'the checkout copy takes precedence over a flat image copy'
    }.GetNewClosure()
}

function Invoke-UvAbiPolicyFixture {
    param([scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $state = New-TestCallState @{ Root = [IO.Path]::GetTempPath(); Missing = [guid]::NewGuid().ToString(); Runner = $null; Probe = [pscustomobject]@{ ExitCode = 0; Output = @('noise', ' cp314t ') } }
    $prelude = @'
$script:ChainOrtAbiCode = 'fixture ABI code'
$State.Runner = {
    param($Python, $Arguments)
    $State.Calls.Add("$Python/$($Arguments -join '|')")
    $State.Probe
}.GetNewClosure()
'@
    Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsUv.Common.psm1' `
        -FunctionName Get-UvChainOrtPythonAbi, Assert-UvChainOrtAbiFit, Select-UvChainOrtWheelStore `
        -FixtureState $state -Prelude $prelude -Find $Find -Replace $Replace -Body $Body
}

function Assert-UvAbiProbeFailure {
    param($State)
    $State.Probe.ExitCode = 9
    $State.Probe.Output = @('first failure', 'last failure')
    $probe = Get-MutUvChainOrtPythonAbi -Python 'fixture python' -Runner $State.Runner
    Assert-Equal 9 $probe.ExitCode 'probe failure status must reach the caller'
    Assert-Equal 'first failure|last failure' ($probe.Result.Output -join '|') 'all probe diagnostics must survive'
    Assert-Throws { Assert-MutUvChainOrtAbiFit -Python 'fixture python' -Runner $State.Runner } -MessagePattern 'cannot read the ABI tag.*first failure \| last failure'
    Assert-Equal 'original store' (Select-MutUvChainOrtWheelStore -Python 'fixture python' -Runner $State.Runner -WheelStore 'original store') 'store selection remains best effort on probe failure'
    $State.Probe = [pscustomobject]@{ ExitCode = 9 }
    Assert-Equal 'original store' (Select-MutUvChainOrtWheelStore -Python 'fixture python' -Runner $State.Runner -WheelStore 'original store') 'a failed optional probe need not expose output'
}

function Assert-WheelSuiteEnvironmentScope {
    param($State)
    $suite = [pscustomobject]@{ Isolated = $true; PytestArgs = @('-W', 'error', 'tests/test wheel.py'); Env = @{ WHEEL_SCOPE_UNSET = 'child'; WHEEL_SCOPE_EMPTY = 'child'; WHEEL_SCOPE_VALUE = $null } }
    Invoke-WithProcessEnvironment -Environment @{ WHEEL_SCOPE_UNSET = $null; WHEEL_SCOPE_EMPTY = ''; WHEEL_SCOPE_VALUE = 'parent' } -ScriptBlock {
        foreach ($failure in @($false, $true)) {
            $State.Failure = $failure
            $before = (Get-Location).Path
            if ($failure) {
                Assert-Throws { Invoke-MutWheelTestsRun -Python 'fixture python' -RunDir $State.Root -Suite $suite } -MessagePattern 'fixture wheel runner failed'
            } else {
                Assert-Equal 19 (Invoke-MutWheelTestsRun -Python 'fixture python' -RunDir $State.Root -Suite $suite) 'the wheel driver returns the external exit status'
            }
            Assert-Equal $State.Root $State.Calls[-1].Location 'wheel tests run outside the checkout'
            Assert-Equal 'child|child|False' $State.Calls[-1].Environment 'the wheel command must get its scoped variables'
            Assert-Equal 'fixture python/-I|fixture helper.py|run|--|-W|error|tests/test wheel.py/True' $State.Calls[-1].Invocation 'interpreter arguments and IgnoreExitCode remain unchanged'
            Assert-Equal $before (Get-Location).Path 'wheel failures must restore the caller location'
            Assert-False (Test-Path Env:WHEEL_SCOPE_UNSET) 'wheel failures must restore an absent variable'
            Assert-True (Test-Path Env:WHEEL_SCOPE_EMPTY) 'wheel failures must retain a defined empty variable'
            Assert-Equal '' $env:WHEEL_SCOPE_EMPTY
            Assert-Equal 'parent' $env:WHEEL_SCOPE_VALUE
        }
    }
}

function Assert-PythonAppWheelEnumeration {
    param($Root)
    $store = Join-Path $Root 'wheel[store]'
    Write-TestFileTree -Root $store -Files @{ 'one-1-cp315-cp315-win_arm64.whl' = 'first'; 'two-1-py3-none-any.whl' = 'second'; 'nested\other-1-py3-none-any.whl' = 'nested'; 'readme.txt' = 'text' }
    [void][IO.Directory]::CreateDirectory((Join-Path $store 'directory-1-py3-none-any.whl'))
    $wheels = @(Get-MutPythonAppWheelFile -Directory $store)
    Assert-Equal 2 $wheels.Count 'wheel enumeration returns all direct file candidates, without matching directories or nested wheels'
    Assert-True ($wheels[0] -is [IO.FileInfo]) 'callers retain file metadata'
    Assert-Equal 'two-1-py3-none-any.whl' (Get-MutPythonAppWheelFile -Directory $store -Filter '*-none-any.whl').Name 'callers retain their filename filter'
    Assert-Throws { Get-MutPythonAppWheelFile -Directory (Join-Path $store absent) } -MessagePattern 'absent'
}

function Invoke-PythonAppFileMutation {
    param([string]$FunctionName, [string]$Find, [string]$Replace, [string]$Expected, [scriptblock]$Body)
    $factory = { param($dir)
        @{ ScriptPath = 'windows\scripts\modules\WindowsPythonApp.Common.psm1'; FunctionName = $FunctionName; BodyArgumentList = @($dir) }
    }.GetNewClosure()
    Invoke-TestFunctionMutations -ModuleArgumentsFactory $factory -IncludeControl -Find $Find -Replace $Replace -Expected $Expected -Body $Body
}

Describe 'Consumer runtime file and interpreter lookups' {
    It 'shares checkout and image lookup while keeping the existing UV entry point' {
        Assert-LinuxScriptLookupPolicy -Resolve { param($modules) Resolve-SharedLinuxScriptFile -RepoPath 'linux\scripts\03-media\runtime\ort-venv-census.py' -ModuleDir $modules }
        Assert-LinuxScriptLookupPolicy -Resolve { param($modules) Get-UvOrtCensusPath -ModuleDir $modules }
    }

    It 'detects preferring the image helper over an existing checkout helper' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsPythonWheel.Common.psm1' -FunctionName Resolve-SharedLinuxScriptFile `
            -Find 'foreach ($candidate in @($repo,' -Replace 'foreach ($candidate in @(' `
            -Body {
                Assert-Throws { Assert-LinuxScriptLookupPolicy -Resolve { param($modules) Resolve-MutSharedLinuxScriptFile -RepoPath 'linux\scripts\03-media\runtime\ort-venv-census.py' -ModuleDir $modules } } -MessagePattern 'checkout copy takes precedence'
            }
    }

    It 'uses isolated Python arguments and the trimmed final output line for both ABI callers' {
        Invoke-UvAbiPolicyFixture -Body { param($state)
            Invoke-WithEnv @{ PYTHON_WHEELS_FREE_THREADED = $state.Root; PYTHON_WHEELS_CP314T = $null } {
                Assert-Equal $state.Root (Select-MutUvChainOrtWheelStore -Python 'fixture python' -Runner $state.Runner -WheelStore 'original store')
                Assert-MutUvChainOrtAbiFit -Python 'fixture python' -Runner $state.Runner -Wheels @('onnxruntime-1-cp314-cp314t-win_amd64.whl', 'ext-1-cp39-abi3-win_amd64.whl', 'pure-1-py3-none-any.whl')
                Assert-Equal 2 $state.Calls.Count
                foreach ($call in $state.Calls) { Assert-Equal 'fixture python/-I|-c|fixture ABI code' $call }
                Assert-Throws { Assert-MutUvChainOrtAbiFit -VenvPath fixture -Python 'fixture python' -Runner $state.Runner -Wheels @('onnxruntime-1-cp314-cp314-win_amd64.whl') } -MessagePattern 'fixture is a cp314t venv'
            }
        }
    }

    It 'does not probe without a twin directory and keeps ABI assertion failures fatal' {
        Invoke-UvAbiPolicyFixture -Body { param($state)
            Invoke-WithEnv @{ PYTHON_WHEELS_FREE_THREADED = (Join-Path $state.Root $state.Missing); PYTHON_WHEELS_CP314T = $state.Root } {
                Assert-Equal 'original store' (Select-MutUvChainOrtWheelStore -Python 'fixture python' -Runner $state.Runner -WheelStore 'original store')
                Assert-Equal 0 $state.Calls.Count 'an explicitly selected missing twin directory does not probe or fall through'
            }
            Invoke-WithEnv @{ PYTHON_WHEELS_FREE_THREADED = $state.Root } { Assert-UvAbiProbeFailure $state }
        }
    }

    It 'detects swallowing the ABI interpreter exit status' {
        Invoke-UvAbiPolicyFixture -Find 'ExitCode = $probe.ExitCode' -Replace 'ExitCode = 0' -Body { param($state)
            Invoke-WithEnv @{ PYTHON_WHEELS_FREE_THREADED = $state.Root } {
                Assert-Throws { Assert-UvAbiProbeFailure $state } -MessagePattern 'probe failure status must reach the caller'
            }
        }
    }

    It 'scopes wheel-suite environment overrides and restores absent and empty variables after success or failure' {
        $state = New-TestCallState @{ Root = [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar); Failure = $false }
        $module = @{
            ScriptPath = 'windows\scripts\python\Invoke-FreeThreadedWheelTests.ps1'; FunctionName = 'Invoke-WheelTestsRun'; FixtureState = $state
            Prelude = @'
$context = [pscustomobject]@{ Fixture = $true }
function Get-FreeThreadedWheelSuiteHelper { 'fixture helper.py' }
function Invoke-BuildExternal {
    param($Context, $File, $Parameters, [switch]$IgnoreExitCode)
    $State.Calls.Add([pscustomobject]@{ Location = (Get-Location).Path; Environment = "$env:WHEEL_SCOPE_UNSET|$env:WHEEL_SCOPE_EMPTY|$(Test-Path Env:WHEEL_SCOPE_VALUE)"; Invocation = "$File/$($Parameters -join '|')/$IgnoreExitCode" })
    if ($State.Failure) { throw 'fixture wheel runner failed' }
    19
}
'@
        }
        Invoke-TestFunctionMutations -ModuleArguments $module -IncludeControl `
            -Find 'Invoke-WithProcessEnvironment -Environment $Suite.Env -ScriptBlock {' -Replace '& {' -Expected 'wheel command must get its scoped variables' `
            -Body { param($fixture) Assert-WheelSuiteEnvironmentScope $fixture }
    }

    It 'creates Python app work directories in caller order while preserving explicit paths and detects dropping additional output directories' {
        $state = New-TestCallState
        $prelude = @'
function New-Item { param($ItemType, $Path, [switch]$Force, $ErrorAction) $State.Calls.Add(@($Path)) }
'@
        $prelude += (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsScripts.Shared.psm1' -FunctionName Initialize-BuildDirectory).ToString()
        $module = @{ ScriptPath = 'windows\scripts\modules\WindowsPythonApp.Common.psm1'; FunctionName = @('Initialize-PythonAppDirectory', 'New-PythonAppWorkDirectory'); FixtureState = $state; Prelude = $prelude }
        Invoke-TestFunctionMutations -ModuleArguments $module -IncludeControl `
            -Find '(@($AdditionalPath) + @($Path))' -Replace '@($Path)' -Expected 'output directories must be created before the work directory' -Body {
                param($fixture)
                $work = New-MutPythonAppWorkDirectory -DefaultName 'fixture app work' -AdditionalPath @('package output')
                Assert-Equal (Join-Path ([IO.Path]::GetTempPath()) 'fixture app work') $work
                Assert-Equal "package output|$work" ($fixture.Calls[-1] -join '|') 'output directories must be created before the work directory'
                foreach ($path in 'relative work', ' ') {
                    Assert-Equal $path (New-MutPythonAppWorkDirectory -Path $path -DefaultName unused) 'explicit paths retain their existing interpretation'
                    Assert-Equal $path ($fixture.Calls[-1] -join '|')
                }
            }
    }

    It 'reuses app staging directories while removing stale contents only when requested and detects skipped cleanup' {
        Invoke-PythonAppFileMutation -FunctionName Initialize-PythonAppDirectory `
            -Find 'Initialize-BuildDirectory -Path $Path -Empty:$Empty' -Replace 'Initialize-BuildDirectory -Path $Path' -Expected 'empty staging must remove old contents' -Body {
                    param($root)
                    Write-TestFileTree -Root $root -Files @{ 'nested\stale.txt' = 'old' }
                    Initialize-MutPythonAppDirectory -Path $root
                    Assert-True (Test-Path -LiteralPath (Join-Path $root 'nested\stale.txt')) 'ordinary allocation preserves existing contents'
                    Initialize-MutPythonAppDirectory -Path $root -Empty
                    Assert-True (Test-Path -LiteralPath $root -PathType Container)
                    Assert-Equal 0 @(Get-ChildItem -LiteralPath $root -Force).Count 'empty staging must remove old contents'
            }
    }

    It 'enumerates literal wheel stores without choosing an ABI or descending into nested stores and detects directory candidates' {
        Invoke-PythonAppFileMutation -FunctionName Get-PythonAppWheelFile `
            -Find '-File -Filter' -Replace '-Filter' -Expected 'wheel enumeration returns all direct file candidates' `
            -Body { param($root) Assert-PythonAppWheelEnumeration $root }
    }
}
