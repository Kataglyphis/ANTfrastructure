#requires -Version 7.0
# Fixtures cover shared source metadata and patch policy; they do not run Meson, download SDKs or build upstream projects.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsContainerImage.Common.psm1') -DisableNameChecking


function Assert-NinjaArmFeatureFixture {
    param([string]$Command = 'Add-NinjaArmFeatureFlags')
    Invoke-InTestDir -Files @{ 'build.ninja' = "build selected/kernel-fp16.c.obj: CC x.c`n  FLAGS = /O2`nbuild excluded/kernel-fp16.c.obj: CC x.c`n  FLAGS = /O2`nbuild selected/kernel-sme.c.obj: CC x.c`n  FLAGS = /O2`n" } -Body { param($dir)
        $options = @{ NinjaFile = (Join-Path $dir build.ninja); Label = 'fixture'; FeatureMap = ([ordered]@{ fp16 = 'fp16'; sme = '' }); TokenPattern = '-{0}\.c\.obj'; Include = { param($line) $line -match '^build selected/' } }
        Assert-Equal 1 (& $Command @options -Floor 1)
        $lines = [IO.File]::ReadAllLines($options.NinjaFile)
        Assert-Equal '  FLAGS = /O2 /clang:-march=armv8.2-a+fp16' $lines[1]
        Assert-Equal '  FLAGS = /O2' $lines[3]
        Assert-Equal '  FLAGS = /O2' $lines[5]
        Assert-Throws { & $Command @options -Floor 2 } -MessagePattern 'tagged only 1 fixture'
    }.GetNewClosure()
}

Describe 'Shared source-build operations' {
    It 'resolves raw values by explicit, ordered environment and default precedence while callers retain prefix policies' {
        Invoke-WithEnv @{ ANT_VALUE_FIRST = '  '; ANT_VALUE_SECOND = ' vv2 '; ANT_VALUE_THIRD = 'third' } {
            Assert-Equal ' explicit ' (Resolve-BuildValue -Value ' explicit ' -EnvironmentVariables ANT_VALUE_SECOND -DefaultValue default)
            Assert-Equal ' vv2 ' (Resolve-BuildValue -Value ' ' -EnvironmentVariables @('', 'ANT_VALUE_FIRST', 'ANT_VALUE_SECOND', 'ANT_VALUE_THIRD') -DefaultValue default)
            Assert-Equal default (Resolve-BuildValue -EnvironmentVariables @('ANT_VALUE_FIRST', 'ANT_VALUE_MISSING') -DefaultValue default)
            Assert-Equal 'v2' (Get-SourceBuildVersion -Value vv2 -StripVPrefix)
            Assert-Equal '2' (Get-SourceBuildVersion -Value V2 -StripVPrefix)
            Assert-Equal '2' (Resolve-ContainerImageValue -Value vv2 -TrimVPrefix)
            Assert-Equal 'V2' (Resolve-ContainerImageValue -Value V2 -TrimVPrefix)
            Assert-Equal ' vv2 ' (Resolve-ContainerImageValue -EnvironmentVariable ANT_VALUE_SECOND -TrimVPrefix)
        }
    }

    It 'keeps the exact Windows Meson tool section and appends caller compiler/rust policy verbatim' {
        $expected = @('[binaries]', "c = ['clang-cl', '--target=aarch64-pc-windows-msvc']", "cpp = ['clang-cl', '--target=aarch64-pc-windows-msvc']",
            "ar = 'llvm-lib'", "strip = 'llvm-strip'", "windres = 'llvm-rc'", "pkg-config = 'pkg-config'", "cmake = 'cmake'", "rust = ['rustc', '--target=aarch64-pc-windows-msvc']") -join "`n"
        $actual = Format-MesonWindowsBinaries -C "'clang-cl', '--target=aarch64-pc-windows-msvc'" -Cpp "'clang-cl', '--target=aarch64-pc-windows-msvc'" -ExtraLine "rust = ['rustc', '--target=aarch64-pc-windows-msvc']"
        Assert-Equal $expected $actual
        $native = Format-MesonWindowsBinaries -C "'clang-cl'" -Cpp "'clang-cl'" -ExtraLine @("cl = 'C:/VS/cl.exe'", "ml64 = 'C:/VS/ml64.exe'", '')
        Assert-Match "c = \['clang-cl'\]" $native
        Assert-Match "cl = 'C:/VS/cl.exe'\nml64 = 'C:/VS/ml64.exe'\n$" $native
        Assert-False ($native -match '\-\-target=') 'native compiler policy must not inherit the cross target'
    }

    It 'skips only absent optional patch inputs and keeps required inputs and present-file postconditions strict' {
        Invoke-InTestDir -Files @{ 'source.txt' = 'anchor old' } -Body { param($dir)
            $missing = Join-Path $dir missing.txt
            Assert-False (Invoke-InlineRegexPatch -IfPresent -Path $missing -Pattern old -Replacement new -AssertGone old)
            Assert-Throws { Invoke-InlineRegexPatch -Path $missing -Pattern old -Replacement new -AssertGone old } -MessagePattern 'file not found'
            $source = Join-Path $dir source.txt
            Assert-True (Invoke-InlineRegexPatch -IfPresent -Path $source -Pattern old -Replacement new -AssertGone old -Quiet)
            Assert-Equal 'anchor new' ([IO.File]::ReadAllText($source))
            Assert-Throws { Invoke-InlineRegexPatch -IfPresent -Path $source -Pattern absent -Replacement ignored -AssertGone new } -MessagePattern 'still present'
        }
    }

    It 'keeps named PE machine facts separate from unrecognized values' {
        Assert-Equal AMD64 (Get-PeMachineName -Value 0x8664)
        Assert-Equal ARM64X (Get-PeMachineName -Value 0xA64E)
        Assert-Equal UNKNOWN (Get-PeMachineName -Value 0)
        Assert-Null (Get-PeMachineName -Value 0x1234)
    }

    It 'selects the first matching literal feature token and keeps empty features blocked' {
        $features = [ordered]@{ neondotfp16arith = 'dotprod+fp16'; neondot = 'dotprod'; neonsme2 = ''; neonsme = '' }
        Assert-Equal '/clang:-march=armv8.2-a+dotprod+fp16' (Get-NinjaFeatureFlag -Line 'kernel-neondotfp16arith.c.obj' -FeatureMap $features -TokenPattern '-{0}[.-]')
        Assert-Equal '' (Get-NinjaFeatureFlag -Line 'kernel-neonsme2.c.obj' -FeatureMap $features -TokenPattern '-{0}[.-]')
        Assert-Equal '' (Get-NinjaFeatureFlag -Line 'plain.c.obj' -FeatureMap $features -TokenPattern '-{0}[.-]')
        Assert-Equal '/clang:-march=armv8.2-a+i8mm' (Get-NinjaFeatureFlag -Line 'mmt4d_arm_64_i8mm.c.obj' -FeatureMap @{ mmt4d_arm_64_i8mm = 'i8mm' } -TokenPattern '{0}\.c\.obj')
        Assert-Equal '' (Get-NinjaFeatureFlag -Line 'kernelXfp16.c.obj' -FeatureMap @{ 'kernel.fp16' = 'fp16' } -TokenPattern '{0}\.c\.obj') 'feature keys are literal tokens'
        Invoke-TestFunctionMutations -Find "            return ''" -Replace '' -Expected 'a blocked first match cannot fall through' -Body {
            Assert-Equal '' (Get-MutNinjaFeatureFlag -Line kernel_bf16 -FeatureMap ([ordered]@{ kernel = ''; kernel_bf16 = 'bf16' }) -TokenPattern '{0}') 'a blocked first match cannot fall through'
            } -FunctionName @('Get-NinjaFeatureFlag') -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1'
    }

    It 'applies ARM features only to included translation units and keeps the floor armed' {
        Assert-NinjaArmFeatureFixture
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsSourceBuild.Common.psm1' `
            -FunctionName Add-NinjaArmFeatureFlags, Add-NinjaPerTuFlags, Get-NinjaFeatureFlag `
            -Find '-Floor $Floor -AlreadyTaggedPattern' -Replace '-Floor 0 -AlreadyTaggedPattern' `
            -Expected 'expected an exception but none was thrown' -Body { Assert-NinjaArmFeatureFixture -Command Add-MutNinjaArmFeatureFlags }
    }

    It 'detects missing Meson tools and inverted explicit-value precedence' {
        Invoke-TestFunctionMutations -Find '"strip = ''llvm-strip''",' -Replace '' -Expected 'strip tool must be rendered' -Body {
            Assert-Match "strip = 'llvm-strip'" (Format-MutMesonWindowsBinaries -C "'cc'" -Cpp "'cxx'") 'strip tool must be rendered'
            } -FunctionName @('Format-MesonWindowsBinaries') -ScriptPath 'windows\scripts\modules\WindowsMeson.Common.psm1'
        Invoke-TestFunctionMutations -Find 'if (-not [string]::IsNullOrWhiteSpace($Value))' -Replace 'if ([string]::IsNullOrWhiteSpace($Value))' -Expected 'explicit value wins' -Body {
            Assert-Equal explicit (Resolve-MutBuildValue -Value explicit -DefaultValue fallback) 'explicit value wins'
            } -FunctionName @('Resolve-BuildValue') -ScriptPath 'windows\scripts\modules\WindowsScripts.Shared.psm1'
    }

    It 'detects an optional-file no-op reported as a patch and corrupted machine-name metadata' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Patches.psm1' -FunctionName Invoke-InlineRegexPatch -Find 'if ($IfPresent -and -not (Test-Path $Path)) { return $false }' -Replace 'if ($IfPresent -and -not (Test-Path $Path)) { return $true }' -Body {
            Invoke-InTestDir { param($dir)
                Assert-Throws { Assert-False (Invoke-MutInlineRegexPatch -IfPresent -Path (Join-Path $dir missing.txt) -Pattern old -Replacement new) 'missing optional source was not patched' } -MessagePattern 'missing optional source was not patched'
            }
        }
        Invoke-TestFunctionMutations -Find "0x8664 = 'AMD64'" -Replace "0x8664 = 'BROKEN'" -Expected 'AMD64 diagnostic name' -Body {
            Assert-Equal AMD64 (Get-MutPeMachineName -Value 0x8664) 'AMD64 diagnostic name'
            } -ScriptPath 'windows\scripts\modules\WindowsTargetArch.Common.psm1'
    }

    It 'detects bypassing the shared marker verdict during one-time block insertion' {
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Patches.psm1' -FunctionName Read-SourcePatchInput, Add-FileBlockOnce -Find '($Marker -and ($text -match $Marker))' -Replace '$false' -Body {
            Invoke-InTestDir -Files @{ 'source.txt' = 'marker already exists' } -Body { param($dir)
                Assert-Throws { Assert-False (Add-MutFileBlockOnce -Path (Join-Path $dir source.txt) -Marker marker -Content inserted) 'a matching marker must keep the block unchanged' } -MessagePattern 'a matching marker must keep the block unchanged'
            }
        }
    }

    It 'resolves an optional sccache executable without probing explicit overrides or dereferencing a missing command' {
        $state = New-TestCallState @{ Command = $null }
        Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1' -FunctionName Resolve-SccacheServerPath -FixtureState $state -Prelude @'
Set-StrictMode -Version Latest
function Get-Command { param($Name, $ErrorAction) $State.Calls.Add($Name); $State.Command }
'@ -Body { param($state)
            Assert-Equal 'C:\explicit\sccache.exe' (Resolve-MutSccacheServerPath -SccachePath 'C:\explicit\sccache.exe')
            Assert-Equal 0 $state.Calls.Count
            Assert-Equal '' (Resolve-MutSccacheServerPath)
            Assert-Equal sccache.exe $state.Calls[0]
            $state.Command = [pscustomobject]@{ Source = 'C:\found\sccache.exe' }
            Assert-Equal 'C:\found\sccache.exe' (Resolve-MutSccacheServerPath)
        }
    }

    It 'preserves sccache output, log prefixes and nonzero exit codes in the shared native command' {
        $state = New-TestCallState @{ Code = 23 }
        Invoke-WithTestNativeCommand -Name Invoke-SccacheFixture -FixtureState $state -Implementation { 'first'; 'second' } -Body { param($state)
            Invoke-WithFunctionModule -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1' -FunctionName Invoke-SccacheServerCommand -BodyArgumentList $state -Body { param($state)
                $result = Invoke-MutSccacheServerCommand -SccachePath Invoke-SccacheFixture -ArgumentList '--start-server' -LogPrefix test-prefix -InformationVariable information 6>$null
                Assert-Equal 23 $result.ExitCode
                Assert-Equal 'first|second' ($result.Output -join '|')
                Assert-Equal '--start-server' $state.Calls[0][0]
                Assert-Match 'test-prefix\| first.*test-prefix\| second' ($information -join '|')
            }
            Invoke-TestFunctionMutations -Find '$code = $LASTEXITCODE' -Replace '$code = 0' -Expected 'sccache command exit status must survive capture' -Body {
            Assert-Equal 23 (Invoke-MutSccacheServerCommand -SccachePath Invoke-SccacheFixture -ArgumentList '--start-server' -LogPrefix mutant 6>$null).ExitCode 'sccache command exit status must survive capture'
            } -FunctionName @('Invoke-SccacheServerCommand') -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1'
        }
    }

    It 'logs optional, idempotent and verified patch outcomes without running skipped patch or message callbacks' {
        Invoke-InTestDir -Files @{ 'source.txt' = 'old' } -Body { param($dir)
            $state = New-TestCallState @{ MessageCount = 0 }
            $patch = { param($path) $state.Calls.Add($path); [IO.File]::WriteAllText($path, 'marker new') }.GetNewClosure()
            $message = @{ Missing = 'missing'; Already = 'already'; Patched = { $state.MessageCount++; 'patched' }.GetNewClosure() }
            $log = { param($text) $state.Calls.Add($text) }.GetNewClosure()
            $options = @{ Marker = 'marker'; Patch = $patch; Condition = { param($text) $text -match 'marker new' }; FailureMessage = 'postcondition failed'; Message = $message; Log = $log }
            Assert-Equal Missing (Invoke-VerifiedSourceFilePatch @options -Path (Join-Path $dir missing.txt))
            Assert-Equal 'missing' $state.Calls[0]
            Assert-Equal 0 $state.MessageCount
            $source = Join-Path $dir source.txt
            Assert-Equal Patched (Invoke-VerifiedSourceFilePatch @options -Path $source)
            Assert-Equal $source $state.Calls[1]
            Assert-Equal patched $state.Calls[2]
            Assert-Equal 1 $state.MessageCount
            Assert-Equal Already (Invoke-VerifiedSourceFilePatch @options -Path $source)
            Assert-Equal already $state.Calls[3]
            Assert-Equal 1 $state.MessageCount
            [IO.File]::WriteAllText($source, 'old')
            Assert-Throws { Invoke-VerifiedSourceFilePatch -Path $source -Marker marker -Patch {} -Condition { $false } -FailureMessage 'postcondition failed' } -MessagePattern 'postcondition failed'
            Invoke-TestFunctionMutations -Find 'Assert-SourceFileContent -Path $Path -Condition $Condition -FailureMessage $FailureMessage' -Replace '' -Throws 'postcondition failed' -Body {
                param($source)
                Invoke-MutVerifiedSourceFilePatch -Path $source -Marker marker -Patch {} -Condition { $false } -FailureMessage 'postcondition failed'
            } -FunctionName @('Invoke-VerifiedSourceFilePatch', 'Assert-SourceFileContent') -BodyArgumentList $source -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Patches.psm1'
        }
    }
}
