#requires -Version 7.0
# Fakes cover copy verdicts and process environment scope; real bind-mount I/O and native runtime loading remain build coverage.

Import-Module (Join-Path $PSScriptRoot 'WindowsConsumer.ArtifactFixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsConsumer.ExecutionFixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsScripts.Shared.psm1') -ErrorAction Stop

function Assert-CmakeRuntimeEnvironment {
    param($State)
    foreach ($debug in @($false, $true)) {
        Invoke-TestEnvironmentCases -Name PATH -Value @($null, '', 'parent path') -With @{ SCCACHE_MAX_JOBS = '1' } -AssertRestored -Body {
                param($parent)
                $State.Runtime = if ($debug) { [IO.FileInfo]::new((Join-Path ([IO.Path]::GetTempPath()) 'clang_rt.fixture.dll')) } else { $null }
                $configuration = if ($debug) { 'Debug' } else { 'Release' }
                $expected = if ($debug) { $State.Runtime.DirectoryName + ';' + $parent } else { $parent }
                foreach ($mode in @('success', 'nonzero', 'throw')) {
                    $State.Throw = $mode -eq 'throw'; $State.Code = if ($mode -eq 'nonzero') { 9 } else { 0 }
                    $runtimeDirs = if ($debug) { @($State.Runtime.DirectoryName) } else { @() }
                    $invoke = { Invoke-MutCmakeBuildCommand -Context ([pscustomobject]@{}) -BuildArgs @('--build', 'fixture build', '--config', $configuration, '--parallel', '2', '--verbose') -SanitizerRuntimeDirs $runtimeDirs }.GetNewClosure()
                    if ($mode -eq 'success') { Assert-Equal 0 @(& $invoke).Count 'the build adds no result objects to its output' }
                    else { Assert-Throws $invoke -MessagePattern ('CMake build failed with exit code ' + $(if ($mode -eq 'throw') { 1 } else { 9 })) }
                    Assert-Equal $expected $State.Paths[-1] 'CMake runtime PATH preserves directory precedence'
                    Assert-Equal "--build|fixture build|--config|$configuration|--parallel|2|--verbose" ($State.Calls[-1] -join '|')
                }
                Assert-True (@($State.Logs | Where-Object { $_ -like 'ERROR: Build exception:*|PATH=dirty build path' }).Count -gt 0) 'exception diagnostics precede environment restoration'
        }.GetNewClosure()
    }
}

function Assert-EnvironmentCaseExecution {
    $seen = [Collections.Generic.List[object]]::new()
    Invoke-WithEnv @{ ANT_EXECUTION_CASE = 'outside' } {
        $caseRecords = $seen
        Invoke-MutTestEnvironmentCases -Name ANT_EXECUTION_CASE -Value @($null, '', 'configured') -Body {
            param($value)
            $caseRecords.Add($value)
            Assert-Equal $value ([Environment]::GetEnvironmentVariable('ANT_EXECUTION_CASE'))
            Assert-Equal ($null -ne $value) (Test-Path Env:ANT_EXECUTION_CASE)
            $env:ANT_EXECUTION_CASE = 'changed in case'
        }.GetNewClosure()
        Assert-Equal 3 $seen.Count 'environment case iteration must include every caller value'
        Assert-Equal outside $env:ANT_EXECUTION_CASE
        Assert-Throws {
            Invoke-MutTestEnvironmentCases -Name ANT_EXECUTION_CASE -Value @('failing') -Body { throw 'case callback failed' }
        } -MessagePattern 'case callback failed'
        Assert-Equal outside $env:ANT_EXECUTION_CASE 'failed case cleanup restores the parent'
        Assert-Throws {
            Invoke-MutTestEnvironmentCases -Name ANT_EXECUTION_CASE -Value @('expected') -AssertRestored -Body { $env:ANT_EXECUTION_CASE = 'unexpected' }
        } -MessagePattern 'operation restores the environment value'
        Assert-Throws {
            Invoke-MutTestEnvironmentCases -Name ANT_EXECUTION_CASE -Value @() -Body { throw 'must not run' }
        } -MessagePattern 'Value'
        Assert-Throws {
            Invoke-MutTestEnvironmentCases -Name ANT_EXECUTION_CASE -Value $null -Body { throw 'must not run' }
        } -MessagePattern 'Value'
    }.GetNewClosure()
}

function Assert-TestFunctionSourceRoundTrip {
    $value = "source 'quotes' λ`nsecond line"
    $probe = @'
if ($FixtureSource -cne "source 'quotes' λ`nsecond line") { throw 'fixture source roundtrip failed' }
'@
    $result = Invoke-MutTestFunctionSourceProbe -FixtureSource $value -ProbeSource $probe
    Assert-Equal 0 $result.ExitCode 'child source transport must preserve Unicode, newlines and quotes'
    $failure = Invoke-MutTestFunctionSourceProbe -FixtureSource $value -ProbeSource "Write-Error 'source probe failed'; 'continued after error'"
    Assert-TestPwshFailure -Probe $failure -Pattern 'source probe failed' -Reason 'child source transport must fail on a nonterminating error'
}

function Assert-TestRuntimeEnvironmentScope {
    foreach ($prior in @(
            @{ Value = $null; Present = $false; Expected = 'child=1' }
            @{ Value = ''; Present = $true; Expected = 'child=1' }
            @{ Value = 'parent=1'; Present = $true; Expected = 'child=1:parent=1' })) {
        Invoke-WithProcessEnvironment -Environment @{ ASAN_OPTIONS = $prior.Value; PATH = 'C:\base' } -ScriptBlock {
            $expectedOptions = $prior.Expected
            foreach ($fail in @($false, $true)) {
                $body = {
                    Assert-Equal $expectedOptions $env:ASAN_OPTIONS 'ASAN_OPTIONS child scope must prepend caller options'
                    Assert-Equal 'C:\first;C:\second;C:\base' $env:PATH 'runtime PATH scope must preserve directory order and filter empty entries'
                    $env:ASAN_OPTIONS = 'body changed options'
                    $env:PATH = 'body changed path'
                    if ($fail) { throw 'fixture runtime failed' }
                    'body output'
                    23
                }.GetNewClosure()
                $invoke = { Invoke-MutWithRuntimePath -RuntimeDirs @('C:\first', $null, ' ', 'C:\second') -AsanOptions 'child=1' -Script $body }.GetNewClosure()
                if ($fail) { Assert-Throws $invoke -MessagePattern 'fixture runtime failed' }
                else { Assert-Equal 'body output|23' ((& $invoke) -join '|') 'scope transport preserves body output' }
                Assert-Equal 'C:\base' $env:PATH 'runtime PATH must restore after success and failure'
                Assert-Equal $prior.Present (Test-Path Env:ASAN_OPTIONS) 'ASAN_OPTIONS restores unset versus defined empty'
                Assert-Equal $prior.Value ([Environment]::GetEnvironmentVariable('ASAN_OPTIONS'))
            }
            Invoke-MutWithRuntimePath -RuntimeDirs @($null, '', ' ') -AsanOptions '' -Script {
                $env:PATH = 'unscoped body path'
                $env:ASAN_OPTIONS = 'unscoped body options'
            }
            Assert-Equal 'unscoped body path' $env:PATH 'without runtime directories the caller owns PATH changes'
            Assert-Equal 'unscoped body options' $env:ASAN_OPTIONS 'without options the caller owns ASAN_OPTIONS changes'
        }.GetNewClosure()
    }
}

function Assert-BuildArtifactCopyPolicy {
    param($State)
    foreach ($code in 0, 7, 8, 15, 16, 24) {
        $State.Code = $code
        $State.Warnings.Clear()
        $destination = Join-Path $State.Root "build $code"
        $parameters = @{ Context = [pscustomobject]@{}; Source = 'build source'; Destination = $destination; ExcludeCommonRustAndCppCache = $true; ExcludeFiles = @('*.tmp'); ExcludeDirs = @('extra cache') }
        if ($code -ge 16) {
            Assert-Throws { Sync-MutBuildArtifacts @parameters } -MessagePattern "serious error.*build source.*build $code"
            Assert-Equal $code $global:LASTEXITCODE 'fatal copy status remains visible to the caller'
        } else {
            Assert-Equal 0 @(Sync-MutBuildArtifacts @parameters).Count 'build sync emits no native output or verdict object'
            Assert-Equal 0 $global:LASTEXITCODE 'accepted copy status is cleared'
        }
        $expectedWarnings = if ($code -lt 16 -and ($code -band 8)) { 1 } else { 0 }
        Assert-Equal $expectedWarnings $State.Warnings.Count 'build sync retains its transient-lock warning policy'
        Assert-True (Test-Path -LiteralPath $destination -PathType Container) 'copy destination is allocated'
        $expected = "build source|$destination|/E|/MT:16|/R:1|/W:1|/FFT|/NOOFFLOAD|/NFL|/NDL|/NJH|/NJS|/nc|/ns|/np|/XD|extra cache|target|.git|node_modules|build-clangcl-debug|build-clangcl-release|build-clangcl-profile|/XF|*.tmp"
        Assert-Equal $expected ($State.Calls[-1] -join '|') 'build copy argument order and bounded retries remain intact'
    }
}

Describe 'Shared consumer operation policies' {
    $copyFactory = ${function:New-TestArtifactCopyModuleArguments}
    $runtimeModule = @{ ScriptPath = 'windows/scripts/modules/WindowsTesting.Common.psm1'; FunctionName = @('Invoke-WithAsanOptions', 'Invoke-WithRuntimePath') }
    $runtimeCheck = { Assert-TestRuntimeEnvironmentScope }
    $operationChecks = @(
        @{ Name = 'keeps the build exit-bit policy, exclusions and reset timing and detects accepting a fatal exit'
           Arguments = @{ ModuleArgumentsFactory = $copyFactory
               Find = '$robocopyExit -ge 16'; Replace = '$robocopyExit -gt 16'; Expected = 'expected an exception but none was thrown'
               Body = { param($state) Assert-BuildArtifactCopyPolicy $state } } }
        @{ Name = 'shares bounded quiet copy transport without resetting raw status and detects losing timestamp tolerance'
           Arguments = @{ ModuleArgumentsFactory = $copyFactory
               Find = "'/FFT', '/NOOFFLOAD'"; Replace = "'/NOOFFLOAD'"; Expected = 'raw copy retains bounded retry and timestamp options'
               Body = {
                    param($state)
                    $state.Code = 9
                    $destination = Join-Path $state.Root 'raw destination'
                    $output = @(Invoke-MutBuildArtifactCopy -Source 'source with spaces' -Destination $destination -Arguments @('/XF', '*.obj', '/LOG:nul'))
                    Assert-Equal 1 $output.Count 'raw copy suppresses both native streams'
                    Assert-Equal 9 $output[0]
                    Assert-Equal 9 $global:LASTEXITCODE 'only the policy caller resets native status'
                    Assert-Equal "source with spaces|$destination|/E|/MT:16|/R:1|/W:1|/FFT|/NOOFFLOAD|/XF|*.obj|/LOG:nul" ($state.Calls[-1] -join '|') 'raw copy retains bounded retry and timestamp options'
               } } }
        @{ Name = 'restores scoped values and detects bypassed ASan options'
           Arguments = @{ ModuleArguments = $runtimeModule; Body = $runtimeCheck
               Find = '-Environment @{ ASAN_OPTIONS = $asanOptions }'; Replace = '-Environment @{}'; Expected = 'ASAN_OPTIONS child scope' } }
        @{ Name = 'retains empty-input short circuits and detects bypassed runtime PATH'
           Arguments = @{ ModuleArguments = $runtimeModule; Body = $runtimeCheck
               Find = "`$environment['PATH'] = ((`$normalizedRuntimeDirs -join ';') + ';' + `$env:PATH)"; Replace = '$null = $normalizedRuntimeDirs'; Expected = 'runtime PATH scope' } }
        @{ Name = 'scopes CMake runtime paths across success, failed exits and exceptions and detects bypassed restoration'
            Arguments = @{ ModuleArguments = (New-TestCmakeExecutionModuleArguments); Body = { param($state) Assert-CmakeRuntimeEnvironment $state }
                Find = 'Invoke-WithProcessEnvironment -Environment @{ PATH = $runtimePath }'; Replace = 'Invoke-WithProcessEnvironment -Environment @{}'; Expected = 'operation restores the environment value|CMake runtime PATH' } }
        @{ Name = 'runs every requested environment state, cleans failed cases and detects truncated matrices'
            Arguments = @{ ScriptPath = 'windows/scripts/tests/WindowsConsumer.ExecutionFixtures.psm1'; FunctionName = @('Invoke-TestEnvironmentCases'); Body = { Assert-EnvironmentCaseExecution }
                Find = 'foreach ($sample in $Value)'; Replace = 'foreach ($sample in @($Value[0]))'; Expected = 'environment case iteration' } }
        @{ Name = 'round-trips source text without interpolation and detects a lossy decoder'
            Arguments = @{ ScriptPath = 'windows/scripts/tests/WindowsTest.MutationCases.psm1'; FunctionName = @('Invoke-TestFunctionSourceProbe'); Body = { Assert-TestFunctionSourceRoundTrip }
                Find = 'UTF8.GetString'; Replace = 'ASCII.GetString'; Expected = 'child source transport must preserve' } }
        @{ Name = 'propagates child script errors and detects a source probe that continues after failure'
            Arguments = @{ ScriptPath = 'windows/scripts/tests/WindowsTest.MutationCases.psm1'; FunctionName = @('Invoke-TestFunctionSourceProbe'); Body = { Assert-TestFunctionSourceRoundTrip }
                Find = "ErrorActionPreference = 'Stop'"; Replace = "ErrorActionPreference = 'Continue'"; Expected = 'child source transport must fail' } }
    )
    Invoke-TestMutationChecks -Check $operationChecks

    It 'keeps Flutter advisory even for serious errors and preserves its different exclusion order and log option' {
        $module = New-TestArtifactCopyModuleArguments -Codes @(16)
        Invoke-WithFunctionModule @module -Body {
                param($state)
                Invoke-InTestDir { param($dir)
                    Assert-Equal 0 @(Sync-MutFlutterArtifactTree -Context ([pscustomobject]@{}) -Source source -Destination $dir -Kind Rust -ExcludeFiles @('*.rlib') -ExcludeDirectories @('deps')).Count
                    Assert-Equal "source|$dir|/E|/MT:16|/R:1|/W:1|/FFT|/NOOFFLOAD|/XF|*.rlib|/XD|deps|/NFL|/NDL|/NJH|/NJS|/nc|/ns|/np|/LOG:nul" ($state.Calls[0] -join '|')
                    Assert-Equal 1 $state.Warnings.Count
                    Assert-Match 'Rust artifacts.*exit code 16' $state.Warnings[0]
                    Assert-Equal 0 $global:LASTEXITCODE
                }
            }
    }

    It 'exports the raw operation from the existing Build companion in a fresh child' {
        $probe = Test-ColdModuleCommands -ModulePath @((Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsBuild.Common.psm1')) -CommandName Invoke-BuildArtifactCopy
        Assert-Equal 0 $probe.ExitCode $probe.Output
    }
}
