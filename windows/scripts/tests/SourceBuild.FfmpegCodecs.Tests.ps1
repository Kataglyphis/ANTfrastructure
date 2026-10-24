#requires -Version 7.0
# NOT covered: real codec build or Meson; both Meson commands are stubbed here.

. (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1' -FunctionName 'Find-TextLineIndexes')

Describe 'Find-TextLineIndexes' {
    It 'returns matching zero-based indexes in source order and accepts empty input' {
        $indexes = @(Find-TextLineIndexes -Lines @('Name: codec', 'Libs: -lx265', 'Libs.private: -lc++', 'Libs: -lfoo') -Pattern '^Libs:')
        Assert-Equal '1,3' ($indexes -join ',') 'both matching rows, in file order'
        Assert-Equal 0 @(Find-TextLineIndexes -Lines @() -Pattern '^Libs:').Count 'an empty file has no matches'
    }
}

Describe 'Add-CodecPcSystemLib (x265 4.2 static lib needs advapi32)' {
    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-FfmpegCodecs.ps1' -FunctionName 'Add-CodecPcSystemLib')
        function Invoke-OnPc([string]$Text, [int]$Times = 1) {
            Invoke-InTestDir { param($root)
                $pc = Join-Path $root 'x265.pc'
                [System.IO.File]::WriteAllText($pc, $Text)
                for ($n = 0; $n -lt $Times; $n++) { Add-CodecPcSystemLib -Pc $pc -Name 'advapi32' | Out-Null }
                [System.IO.File]::ReadAllText($pc) -replace "`r`n", "`n"
            }
        }
    }

    It 'appends the missing system lib to Libs: once, and leaves every other line alone' {
        # x265 4.2's generated x265.pc, trimmed to the lines that matter here.
        $pc = "prefix=C:/runtime/ffmpeg-codecs`nName: x265`nLibs: -L`${libdir} -lx265`nLibs.private: -lc++`n"
        $want = $pc.Replace('-lx265', '-lx265 -ladvapi32')
        Assert-Equal $want (Invoke-OnPc $pc -Times 2) 'appended exactly once across two runs; Libs.private untouched'
    }

    It 'treats only the whole -l`<name> as present (a longer name is not it)' {
        Assert-Equal "Libs: -lx265 -ladvapi32x -ladvapi32`n" (Invoke-OnPc "Libs: -lx265 -ladvapi32x`n") 'a prefix match does not count'
    }

    It 'refuses a .pc without exactly one Libs: line' {
        Assert-Throws { Invoke-OnPc "Name: x265`n" } -MessagePattern 'has 0 Libs: line'
        Assert-Throws { Invoke-OnPc "Libs: -lx265`nLibs: -lx265`n" } -MessagePattern 'has 2 Libs: line'
    }
}

Describe 'FFmpeg codec Meson compiler environment' {
    BeforeAll {
        $sharedEnvironment = (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsScripts.Shared.psm1' -FunctionName 'Invoke-WithProcessEnvironment').ToString()
        $script:MesonEnvironmentPrelude = @"
`$script:WorkDir = 'C:\codec-test'
`$script:Prefix = 'C:\codec-prefix'
$sharedEnvironment
function Test-SccacheRemoteConfigured { return `$false }
function meson {
    `$State.Calls.Add(@(`$args))
    `$State.CompilerStates.Add([pscustomobject]@{
        CCSet = Test-Path Env:CC
        CC = [Environment]::GetEnvironmentVariable('CC')
        CXXSet = Test-Path Env:CXX
        CXX = [Environment]::GetEnvironmentVariable('CXX')
    })
    `$global:LASTEXITCODE = `$State.Code
}
"@
    }

    It 'uses clang-cl and restores compiler variables after success and failure' {
        $cases = @(
            @{ Code = 0; CC = $null; CXX = ''; ExpectedCalls = 2; FailurePattern = '' }
            @{ Code = 23; CC = 'caller-cc'; CXX = 'caller-cxx'; ExpectedCalls = 1; FailurePattern = 'fixture meson setup failed \(23\)' }
        )
        $exercise = { param($fixture)
            $fixture.Calls.Clear()
            $fixture.CompilerStates.Clear()
            if ($fixture.FailurePattern) {
                Assert-Throws { Invoke-MutCodecMeson -Name 'fixture' -SourceDir 'C:\codec-source' -Options @() } -MessagePattern $fixture.FailurePattern
            } else {
                Invoke-MutCodecMeson -Name 'fixture' -SourceDir 'C:\codec-source' -Options @('-Dfixture=true')
            }
            Assert-Equal $fixture.ExpectedCalls $fixture.Calls.Count 'setup failure prevents install'
            Assert-Equal $fixture.ExpectedCalls $fixture.CompilerStates.Count
            foreach ($during in $fixture.CompilerStates) {
                Assert-Equal 'clang-cl' $during.CC
                Assert-True $during.CCSet
                Assert-Equal 'clang-cl' $during.CXX
                Assert-True $during.CXXSet
            }
        }
        Invoke-InTestDir {
            foreach ($case in $cases) {
                $state = New-TestCallState @{ Code = $case.Code; ExpectedCalls = $case.ExpectedCalls; FailurePattern = $case.FailurePattern; CompilerStates = [Collections.Generic.List[object]]::new() }
                $module = @{ ScriptPath = 'windows\scripts\build\Build-FfmpegCodecs.ps1'; FunctionName = @('Invoke-CodecMeson'); FixtureState = $state; Prelude = $script:MesonEnvironmentPrelude }
                Invoke-WithEnv @{ CC = $case.CC; CXX = $case.CXX } {
                    Invoke-WithFunctionModule @module -Body $exercise
                    if ($null -eq $case.CC) { Assert-False (Test-Path Env:CC) 'unset CC remains unset' }
                    else { Assert-Equal $case.CC $env:CC 'CC returns to the caller value' }
                    if ($case.CXX -eq '') {
                        Assert-True (Test-Path Env:CXX) 'empty CXX remains defined'
                        Assert-Equal '' (Get-Item Env:CXX).Value
                    } else { Assert-Equal $case.CXX $env:CXX 'CXX returns to the caller value' }
                }
            }
            $mutationState = New-TestCallState @{ Code = 0; ExpectedCalls = 2; FailurePattern = ''; CompilerStates = [Collections.Generic.List[object]]::new() }
            $mutationModule = @{ ScriptPath = 'windows\scripts\build\Build-FfmpegCodecs.ps1'; FunctionName = @('Invoke-CodecMeson'); FixtureState = $mutationState; Prelude = $script:MesonEnvironmentPrelude }
            Invoke-WithEnv @{ CC = $null; CXX = '' } {
                Invoke-TestFunctionMutations -ModuleArguments $mutationModule `
                    -Find 'Invoke-WithProcessEnvironment -Environment @{ CC = $cc; CXX = $cc } -ScriptBlock {' -Replace '& {' `
                    -Expected 'expected \[clang-cl\] but got' -Body $exercise
            }
        }
    }
}
