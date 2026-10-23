#requires -Version 7.0

Import-Module (Join-Path $PSScriptRoot 'WindowsConsumer.ExecutionFixtures.psm1') -ErrorAction Stop
# Fake build tools cover dispatch, diagnostics and cleanup; real compiler, junction and packaging compatibility remains build coverage.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsScripts.Shared.psm1')
$script:ConsumerNativeWrappers = @('CMAKE_C_COMPILER_LAUNCHER', 'CMAKE_CXX_COMPILER_LAUNCHER', 'RUSTC_WRAPPER', 'CC_WRAPPER', 'CXX_WRAPPER')

function Invoke-PackagingLifecycleFixture {
    param([scriptblock]$Body, [string]$Failure = '', [string]$Find = '', [string]$Replace = '')
    $exercise = $Body
    Invoke-InTestDir { param($dir)
        $state = New-TestCallState @{ Root = $dir; Failure = $Failure }
        $prelude = @'
$repoRoot = $State.Root
$PythonVersion = 'fixture-python'
$buildArgs = @('build', '--python', 'cpython-fixture')
$script:BuildContext = [pscustomobject]@{ Fixture = $true }
$script:UvCommandRunner = {}; $script:UvLogInfo = {}; $script:UvLogWarning = {}
function New-UvProjectEnvironment {
    param($Workspace, $PythonVersion, $EnvName, $CommandRunner, $LogInfo, $LogWarning)
    $State.Calls.Add("create:$EnvName/$PythonVersion")
    $environment = Join-Path $Workspace $EnvName
    [void][IO.Directory]::CreateDirectory($environment)
    [IO.File]::WriteAllText((Join-Path $environment 'pyvenv.cfg'), 'home = C:\fixture python')
    'ignored environment output'
}
function Add-PythonLibPath { param($PythonDir) $State.Calls.Add("native:$PythonDir") }
function Sync-UvProjectDependencies {
    $State.Calls.Add('sync')
    if ($State.Failure -eq 'sync') { throw 'fixture sync failure' }
}
function Invoke-BuildExternal {
    param($Context, $File, $Parameters)
    $State.Calls.Add("build:$File/$($Parameters -join '|')")
    if ($State.Failure -eq 'build') { throw 'fixture build failure' }
    'ignored build output'
}
function Remove-UvProjectEnvironment { param($EnvPath, $LogInfo, $LogWarning) $State.Calls.Add("remove:$(Split-Path $EnvPath -Leaf)") }
'@
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\python\Invoke-CiPackaging.ps1' -FunctionName Invoke-PackagingEnvironmentBuild `
            -FixtureState $state -Prelude $prelude -Find $Find -Replace $Replace -Body $exercise
    }.GetNewClosure()
}

function Assert-PackagingFailureCleanup {
    param($State)
    Assert-Throws { Invoke-MutPackagingEnvironmentBuild -EnvName 'environment' } -MessagePattern 'fixture (sync|build) failure'
    Assert-Equal 'remove:environment' $State.Calls[$State.Calls.Count - 1] 'packaging failures must still remove their environment'
}

Describe 'Consumer shared execution lifecycles' {
    It 'creates source and binary packaging environments with the native library step only before a binary build' {
        foreach ($native in @($false, $true)) {
            Invoke-PackagingLifecycleFixture -Body {
                param($state)
                $output = @(Invoke-MutPackagingEnvironmentBuild -EnvName environment -AddNativeLibraryPath:$native)
                Assert-Equal 0 $output.Count
                $expected = @('create:environment/fixture-python') + @(if ($native) { 'native:C:\fixture python' }) + @('sync', 'build:uv/build|--python|cpython-fixture', 'remove:environment')
                Assert-Equal ($expected -join ',') ($state.Calls -join ',')
            }.GetNewClosure()
        }
    }

    It 'removes the packaging environment after dependency or build failure' {
        foreach ($failure in 'sync', 'build') { Invoke-PackagingLifecycleFixture -Failure $failure -Body { param($state) Assert-PackagingFailureCleanup $state } }
    }

    It 'detects omitting packaging failure cleanup' {
        Invoke-PackagingLifecycleFixture -Failure build -Find 'Remove-UvProjectEnvironment -EnvPath $envPath -LogInfo $script:UvLogInfo -LogWarning $script:UvLogWarning' -Replace '$null = $envPath' -Body {
            param($state)
            Assert-Throws { Assert-PackagingFailureCleanup $state } -MessagePattern 'packaging failures must still remove'
        }
    }

    It 'repeats the same locking-process sweep before retrying a failed build-root removal' {
        $state = New-TestCallState @{ Attempts = 0 }
        $prelude = @'
function Test-Path { return $true }
function Get-Process { param($Name) [pscustomobject]@{ Name = $Name } }
function Stop-Process { param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Force) process { $State.Calls.Add("stop:$($InputObject.Name)") } }
function Start-Sleep { param($Seconds) $State.Calls.Add("sleep:$Seconds") }
function Remove-Item { $State.Attempts++; $State.Calls.Add('remove'); if ($State.Attempts -eq 1) { throw 'locked fixture' } }
function Write-BuildLog {}
function Write-BuildLogWarning {}
'@
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsBuild.Common.psm1' -FunctionName Stop-BuildLockingProcess, Remove-BuildRoot `
            -FixtureState $state -Prelude $prelude -Body { param($state)
                Assert-True (Remove-MutBuildRoot -Context ([pscustomobject]@{}) -Path 'fixture-root')
                $stopped = @($state.Calls | Where-Object { $_ -like 'stop:*' })
                Assert-Equal 32 $stopped.Count
                Assert-Equal (($stopped | Select-Object -First 16) -join ',') (($stopped | Select-Object -Last 16) -join ',')
                Assert-Equal 'stop:flutter,stop:dart,stop:msbuild,stop:devenv,stop:ninja,stop:cmake,stop:ctest,stop:cl,stop:link,stop:clang,stop:clang-cl,stop:lld-link,stop:vstest.console,stop:testhost,stop:cargo,stop:rustc' (($stopped | Select-Object -First 16) -join ',')
                Assert-Equal 'sleep:3,remove,sleep:2,remove' (($state.Calls | Where-Object { $_ -notlike 'stop:*' }) -join ',')
            }
    }

    It 'keeps CMake environment tables distinct from stats and forwards advanced stats without dropping blank lines' {
        $state = New-TestCallState @{ Advanced = $false }
        $prelude = @'
function Write-BuildLog { param($Context, $Message) $State.Calls.Add($Message) }
function Get-SccacheStatsText { param([switch]$Advanced) $State.Advanced = $Advanced.IsPresent; $null; ''; 'cache fixture' }
'@
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsCMake.Common.psm1' -FunctionName Write-CmakeEnvironmentDiagnostics, Write-CmakeSccacheStats `
            -FixtureState $state -Prelude $prelude -Body { param($state)
                Invoke-WithEnv @{ ANT_CMAKE_PRESENT = 'fixture'; ANT_CMAKE_ABSENT = $null } {
                    Write-MutCmakeEnvironmentDiagnostics -Context ([pscustomobject]@{}) -Name ANT_CMAKE_PRESENT, ANT_CMAKE_ABSENT
                    Write-MutCmakeEnvironmentDiagnostics -Context ([pscustomobject]@{}) -Name ANT_CMAKE_ABSENT -ShowUnset
                }
                Write-MutCmakeSccacheStats -Context ([pscustomobject]@{}) -Advanced
                Assert-True $state.Advanced
                Assert-Equal 'DEBUG:   ANT_CMAKE_PRESENT = fixture|DEBUG:   ANT_CMAKE_ABSENT = (not set)|DEBUG:   |DEBUG:   cache fixture' ($state.Calls -join '|')
            }
    }

    It 'always clears broken Flutter links with the shell and reserves stale-file deletion for repair' {
        $state = New-TestCallState @{ Exists = $false }
        $prelude = @'
function Test-Path { return $State.Exists }
function Remove-Item { $State.Calls.Add('remove-item') }
function cmd.exe { param($Mode, $Line) $State.Calls.Add($Line) }
'@
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsFlutter.Common.psm1' -FunctionName Remove-FlutterPluginLink `
            -FixtureState $state -Prelude $prelude -Body { param($state)
                Remove-MutFlutterPluginLink -Path 'C:\link tree' -RemoveStaleFile
                Assert-Equal 'rmdir /q /s "C:\link tree" 2>nul|del /q /f "C:\link tree" 2>nul' ($state.Calls -join '|')
                $state.Calls.Clear(); $state.Exists = $true
                Remove-MutFlutterPluginLink -Path 'C:\link tree'
                Assert-Equal 'remove-item|rmdir /q /s "C:\link tree" 2>nul' ($state.Calls -join '|')
            }
    }

    It 'keeps agentic environment precedence lazy and preserves whitespace values' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsAgenticLoop.Common.psm1' -FunctionName Get-AgenticEnvironmentValue -Body {
            Invoke-WithEnv @{ ANT_AGENTIC_FIXTURE = '  ' } {
                Assert-Equal '  ' (Get-MutAgenticEnvironmentValue -Name ANT_AGENTIC_FIXTURE -Fallback { throw 'fallback must stay lazy' })
            }
            Invoke-WithEnv @{ ANT_AGENTIC_FIXTURE = $null } {
                Assert-Equal fallback (Get-MutAgenticEnvironmentValue -Name ANT_AGENTIC_FIXTURE -Fallback { 'fallback' })
            }
        }
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsAgenticLoop.Common.psm1' -FunctionName Get-AgenticEnvironmentValue -Find 'if ($value)' -Replace 'if ($false)' -Body {
            Invoke-WithEnv @{ ANT_AGENTIC_FIXTURE = 'selected' } {
                Assert-Throws { Get-MutAgenticEnvironmentValue -Name ANT_AGENTIC_FIXTURE -Fallback { throw 'fallback must stay lazy' } } -MessagePattern 'fallback must stay lazy'
            }
        }
    }
}

Describe 'Shared compiler wrapper environment policy' {
    It 'sets the five native wrappers, preserves CUDA by default and permits explicit empty CUDA values' {
        $names = $script:ConsumerNativeWrappers
        $saved = @{}; foreach ($name in $names + 'CMAKE_CUDA_COMPILER_LAUNCHER') { $saved[$name] = 'prior' }
        Invoke-WithEnv $saved {
            Set-CompilerWrapperEnvironment -Value 'C:\cache tool\sccache.exe'
            foreach ($name in $names) { Assert-Equal 'C:\cache tool\sccache.exe' (Get-Item -LiteralPath "Env:$name").Value }
            Assert-Equal prior $env:CMAKE_CUDA_COMPILER_LAUNCHER
            Set-CompilerWrapperEnvironment -Value '' -IncludeCuda
            foreach ($name in $saved.Keys) {
                Assert-True (Test-Path -LiteralPath "Env:$name") 'clearing must preserve a defined empty value'
                Assert-Equal '' (Get-Item -LiteralPath "Env:$name").Value
            }
        }
    }

    It 'detects clearing a CUDA override when enabling native compiler wrappers' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsScripts.Shared.psm1' -FunctionName Get-CompilerWrapperVariableName, Set-CompilerWrapperEnvironment `
            -Find 'if ($IncludeCuda)' -Replace 'if ($true)' -Body {
                $fixture = @{ CMAKE_CUDA_COMPILER_LAUNCHER = 'cuda override' }
                foreach ($name in $script:ConsumerNativeWrappers) { $fixture[$name] = $null }
                Invoke-WithEnv $fixture {
                    Set-MutCompilerWrapperEnvironment -Value fixture
                    Assert-Throws { Assert-Equal 'cuda override' $env:CMAKE_CUDA_COMPILER_LAUNCHER 'native wrappers must leave CUDA alone' } -MessagePattern 'native wrappers must leave CUDA alone'
                }
            }
    }

    It 'preserves the enable, CMake-disable and tracing caller policies' {
        $fixture = @{ CMAKE_CUDA_COMPILER_LAUNCHER = 'cuda override'; KATAGLYPHIS_NO_SCCACHE = $null; SCCACHE_MAX_JOBS = '1' }
        foreach ($name in $script:ConsumerNativeWrappers) { $fixture[$name] = 'prior' }
        Invoke-WithEnv $fixture {
            Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsBuild.Common.psm1' -FunctionName Enable-SccacheCompilerWrapper -Prelude 'function Clear-UnreachableSccacheEndpoint {}' -Body {
                Enable-MutSccacheCompilerWrapper -SccacheExe fixture-cache
            }
            Assert-Equal fixture-cache $env:RUSTC_WRAPPER
            Assert-Equal 'cuda override' $env:CMAKE_CUDA_COMPILER_LAUNCHER
            $fixture = New-TestCmakeExecutionModuleArguments
            Invoke-WithFunctionModule @fixture -Body {
                Invoke-MutCmakeConfigureAndBuild -Context ([pscustomobject]@{}) -BuildPath fixture-root -Preset fixture -Configuration Release -DisableSccache
            }
            foreach ($name in $script:ConsumerNativeWrappers + 'CMAKE_CUDA_COMPILER_LAUNCHER') {
                Assert-True (Test-Path -LiteralPath "Env:$name")
                Assert-Equal '' (Get-Item -LiteralPath "Env:$name").Value
            }
            Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsCodeQL.Common.psm1' -FunctionName Disable-SccacheForTrace -Body { Disable-MutSccacheForTrace }
            Assert-Equal '1' $env:KATAGLYPHIS_NO_SCCACHE
            foreach ($name in $script:ConsumerNativeWrappers) { Assert-False (Test-Path -LiteralPath "Env:$name") }
            Assert-True (Test-Path Env:CMAKE_CUDA_COMPILER_LAUNCHER)
        }
    }

    It 'resolves consumer dependencies after cold and private warm imports without replacing their module state' {
        $root = (Join-Path (Get-RepoRoot) 'windows\scripts\modules').Replace("'", "''")
        $probe = @"
`$ErrorActionPreference = 'Stop'
`$cases = @(
    @('WindowsBuild.Common', 'WindowsScripts.Shared', 'Set-CompilerWrapperEnvironment'),
    @('WindowsCMake.Common', 'WindowsScripts.Shared', 'Set-CompilerWrapperEnvironment'),
    @('WindowsCMake.Common', 'WindowsBuild.Common', 'Write-BuildCommandOutput'),
    @('WindowsCodeQL.Common', 'WindowsScripts.Shared', 'Set-CompilerWrapperEnvironment'),
    @('WindowsGstPlugins.Common', 'WindowsTargetArch.Common', 'Get-WindowsTargetArch'),
    @('WindowsSourceBuild.Common', 'WindowsTargetArch.Common', 'Get-PeMachineType'),
    @('WindowsSourceBuild.Common', 'WindowsSourceBuild.Patches', 'Invoke-InlineRegexPatch'),
    @('WindowsSourceBuild.Common', 'WindowsSourceBuild.Cuda', 'Get-GpuEnvironment'),
    @('WindowsSourceBuild.Common', 'WindowsPythonWheel.Common', 'Get-PinnedPythonVersion'),
    @('WindowsSourceBuild.Common', 'WindowsNative.Common', 'Invoke-ShieldedNative'),
    @('WindowsSourceBuild.Patches', 'WindowsScripts.Shared', 'Resolve-DirectoryPath'),
    @('WindowsSourceBuild.Cuda', 'WindowsScripts.Shared', 'Invoke-DownloadWithRetry'),
    @('WindowsSourceBuild.Cuda', 'WindowsTargetArch.Common', 'Get-WindowsTargetArch'),
    @('WindowsMigraphx.Common', 'WindowsScripts.Shared', 'Invoke-DownloadWithRetry'),
    @('WindowsMigraphx.Common', 'WindowsSourceBuild.Common', 'Get-SourceBuildPython'),
    @('WindowsTvm.Common', 'WindowsNative.Common', 'Invoke-ShieldedNative'),
    @('WindowsFlutter.Common', 'WindowsBuild.Common', 'Invoke-BuildArtifactCopy'),
    @('WindowsFormatting.Common', 'WindowsUv.Common', 'Initialize-UvVenv'),
    @('WindowsFormatting.Common', 'WindowsBuild.Common', 'New-UvBuildDelegates'),
    @('WindowsCodeQL.Common', 'WindowsBuild.Common', 'Write-BuildLog'),
    @('WindowsMsix.Signing', 'WindowsScripts.Shared', 'ConvertTo-MsixSigningPassword'),
    @('WindowsMsix.Signing', 'WindowsConfig.Common', 'Get-OrDefault'),
    @('WindowsMsix.Signing', 'WindowsBuild.Common', 'Write-BuildLog'),
    @('WindowsMsix.Common', 'WindowsScripts.Shared', 'Resolve-PathFromRoot'),
    @('WindowsUv.Common', 'WindowsScripts.Shared', 'Resolve-PathFromRoot'),
    @('WindowsUv.Common', 'WindowsPythonWheel.Common', 'Resolve-SharedLinuxScriptFile'),
    @('WindowsPythonApp.Common', 'WindowsScripts.Shared', 'Initialize-BuildDirectory'),
    @('WindowsPythonApp.Common', 'WindowsPythonWheel.Common', 'Invoke-PythonAbiProbe'),
    @('WindowsOrtPayload.Common', 'WindowsScripts.Shared', 'Initialize-BuildDirectory'),
    @('WindowsBuildDriver.Common', 'WindowsScripts.Shared', 'Get-DriveFreeSpaceGb'),
    @('WindowsTesting.Common', 'WindowsScripts.Shared', 'Invoke-WithProcessEnvironment'),
    @('WindowsSmokeTest.Common', 'WindowsScripts.Shared', 'Invoke-WithProcessEnvironment'),
    @('WindowsCrossBundle.Common', 'WindowsTargetArch.Common', 'Get-DllDependencyGraph'),
    @('WindowsRustToolchain.Common', 'WindowsScripts.Shared', 'Invoke-DownloadWithRetry'),
    @('WindowsContainerImage.Common', 'WindowsScripts.Shared', 'Resolve-BuildValue')
)
foreach (`$case in `$cases) {
    foreach (`$phase in 'cold', 'private', 'global') {
        Get-Module -All -Name Windows* | Remove-Module
        `$dependency = `$null
        `$warm = `$phase -ne 'cold'
        if (`$warm) {
            if (`$phase -eq 'global') { `$dependency = Import-Module (Join-Path '$root' "`$(`$case[1]).psm1") -PassThru }
            else {
                `$dependency = New-Module -ArgumentList '$root', `$case[1] -ScriptBlock {
                    param(`$root, `$name) Import-Module (Join-Path `$root "`$name.psm1") -PassThru
                } -ReturnResult
            }
            & `$dependency { param(`$arch) if (`$arch) { `$script:WindowsHostArch = 'retained state' } else { `$script:ConsumerBootstrapMarker = 'retained state' } } (`$case[1] -eq 'WindowsTargetArch.Common')
        }
        `$owner = New-Module -ArgumentList '$root', `$case[0] -ScriptBlock {
            param(`$root, `$name) Import-Module (Join-Path `$root "`$name.psm1") -PassThru
        } -ReturnResult
        `$command = & `$owner { param(`$name) Get-Command `$name -ErrorAction Stop } `$case[2]
        if (`$case[0] -in 'WindowsSourceBuild.Common', 'WindowsSourceBuild.Patches' -and -not `$owner.ExportedFunctions.ContainsKey(`$case[2])) { throw 'source-build architecture re-export missing' }
        if (`$phase -eq 'global' -and -not (Get-Command `$case[2] -ErrorAction SilentlyContinue)) { throw 'parent command disappeared after nested import' }
        if (`$warm) {
            `$marker = & `$command.ScriptBlock.Module { param(`$arch) Get-Variable -Name `$(if (`$arch) { 'WindowsHostArch' } else { 'ConsumerBootstrapMarker' }) -Scope Script -ValueOnly -ErrorAction SilentlyContinue } (`$case[1] -eq 'WindowsTargetArch.Common')
            if (`$marker -ne 'retained state') { throw "`$(`$case[0]) nested import replaced sibling state for `$(`$case[1]) (command module `$(`$command.Module.Name))" }
        }
    }
}
"@
        $result = Invoke-TestPwshProbe -Source $probe
        Assert-Equal 0 $result.ExitCode $result.Output
        Invoke-InTestDir { param($dir)
            $seeds = @('WindowsBuild.Common', 'WindowsCMake.Common', 'WindowsCodeQL.Common', 'WindowsGstPlugins.Common', 'WindowsSourceBuild.Common', 'WindowsRustToolchain.Common', 'WindowsContainerImage.Common', 'WindowsMigraphx.Common', 'WindowsTvm.Common', 'WindowsFlutter.Common', 'WindowsFormatting.Common', 'WindowsMsix.Signing', 'WindowsMsix.Common', 'WindowsUv.Common', 'WindowsPythonApp.Common', 'WindowsOrtPayload.Common', 'WindowsBuildDriver.Common', 'WindowsTesting.Common', 'WindowsSmokeTest.Common', 'WindowsCrossBundle.Common')
            Copy-TestModuleClosure -Seed $seeds -Destination $dir
            $mutations = @(
                @{ Module = 'WindowsSourceBuild.Common'; Find = 'Import-Module $targetArchPath -ErrorAction Stop'; Replace = 'if (-not (Get-Module -Name WindowsTargetArch.Common)) { Import-Module $targetArchPath -ErrorAction Stop }'; Message = 'source-build architecture re-export missing' },
                @{ Module = 'WindowsGstPlugins.Common'; Find = 'Import-Module $gstTargetArchPath'; Replace = 'Import-Module $gstTargetArchPath -Force'; Message = 'nested import replaced sibling state|parent command disappeared after nested import' }
            )
            foreach ($mutation in $mutations) {
                $path = Join-Path $dir "$($mutation.Module).psm1"
                $text = [IO.File]::ReadAllText($path)
                $changed = $text.Replace($mutation.Find, $mutation.Replace)
                Assert-False ($text -eq $changed) 'the bootstrap mutant must change the real import'
                [IO.File]::WriteAllText($path, $changed)
                try {
                    $mutant = Invoke-TestPwshProbe -Source ($probe.Replace($root, $dir.Replace("'", "''")))
                    Assert-TestPwshFailure -Probe $mutant -Pattern $mutation.Message -Reason 'a broken sibling import must fail the bootstrap probe'
                } finally { [IO.File]::WriteAllText($path, $text) }
            }
        }
    }

    It 'fails on missing required siblings with the owning bootstrap diagnostic' {
        Invoke-InTestDir { param($dir)
            $root = Join-Path (Get-RepoRoot) 'windows\scripts\modules'
            $cases = @(
                @{ Owner = 'WindowsGstPlugins.Common'; Copy = @(); Message = 'required sibling module not found.*WindowsTargetArch' },
                @{ Owner = 'WindowsSourceBuild.Common'; Copy = @('WindowsScripts.Shared', 'WindowsNative.Common'); Message = 'WindowsTargetArch.Common.psm1 is not next to WindowsSourceBuild.Common.psm1' },
                @{ Owner = 'WindowsRustToolchain.Common'; Copy = @(); Message = 'required sibling module not found.*WindowsScripts.Shared' },
                @{ Owner = 'WindowsContainerImage.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsBuild.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsCMake.Common'; Copy = @(); Message = 'WindowsBuild.Common.psm1' },
                @{ Owner = 'WindowsCodeQL.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsFlutter.Common'; Copy = @(); Message = 'WindowsBuild.Common.psm1' },
                @{ Owner = 'WindowsFormatting.Common'; Copy = @(); Message = 'WindowsUv.Common.psm1' },
                @{ Owner = 'WindowsMsix.Signing'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsMsix.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsUv.Common'; Copy = @(); Message = 'WindowsUvLock.Common.psm1' },
                @{ Owner = 'WindowsPythonApp.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsPythonApp.Common'; Copy = @('WindowsScripts.Shared'); Message = 'WindowsPythonWheel.Common.psm1' },
                @{ Owner = 'WindowsOrtPayload.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsBuildDriver.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsTesting.Common'; Copy = @(); Message = 'WindowsBuild.Common.psm1' },
                @{ Owner = 'WindowsSmokeTest.Common'; Copy = @(); Message = 'WindowsScripts.Shared.psm1' },
                @{ Owner = 'WindowsCrossBundle.Common'; Copy = @(); Message = 'WindowsTargetArch.Common.psm1' }
            )
            foreach ($case in $cases) {
                $destination = Join-Path $dir $case.Owner
                [void][IO.Directory]::CreateDirectory($destination)
                foreach ($name in @($case.Owner) + $case.Copy) { Copy-Item -LiteralPath (Join-Path $root "$name.psm1") -Destination $destination }
                $modulePath = (Join-Path $destination "$($case.Owner).psm1").Replace("'", "''")
                foreach ($command in @("Import-Module '$modulePath'", "New-Module -ArgumentList '$modulePath' -ScriptBlock { param(`$path) Import-Module `$path } | Out-Null")) {
                    $result = Invoke-TestPwshProbe -Source "`$ErrorActionPreference = 'Stop'; try { $command } catch { [Console]::Error.WriteLine(`$_.Exception.Message); exit 1 }; exit 0"
                    Assert-TestPwshFailure -Probe $result -Pattern $case.Message -Reason "$($case.Owner) must fail when a required companion is absent"
                }
            }
        }
    }
}
