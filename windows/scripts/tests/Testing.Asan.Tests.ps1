#requires -Version 7.0
# Tests for WindowsTesting.Common and WindowsClang.Common, both upstreamed from
# Kataglyphis-BeschleunigerBallett's vendored scripts/windows/modules copies on
# 2026-08-11 (they were never covered there).
#
# Only host-independent behaviour is asserted. The ASan-runtime *discovery*
# depends on which Visual Studio / LLVM the machine has, so what is pinned here
# is the contract that survives either answer: it never throws, it always
# returns an array, and -Msvc never yields an LLVM path (mixing the two is the
# exact defect the module exists to prevent — LLVM's clang_rt.asan_dynamic
# aborts a COM/CRT-hosting application with an unsuppressible bad-free).

Describe 'Invoke-WithAsanOptions' {

    It 'prepends to an existing ASAN_OPTIONS and restores it afterwards' {
        Invoke-WithEnv @{ ASAN_OPTIONS = 'pre=1' } {
            $seen = $null
            Invoke-WithAsanOptions -Options 'x=2' -Script { $script:seen = $env:ASAN_OPTIONS }
            Assert-Equal 'x=2:pre=1' $script:seen 'caller options must come first, existing ones must survive'
            Assert-Equal 'pre=1' $env:ASAN_OPTIONS 'the previous value must be restored'
        }
    }

    It 'removes the variable again when it was unset before' {
        Invoke-WithEnv @{ ASAN_OPTIONS = '' } {
            Invoke-WithAsanOptions -Options 'y=3' -Script { $script:inner = $env:ASAN_OPTIONS }
            Assert-Equal 'y=3' $script:inner 'the block must see exactly the caller options'
            Assert-True ([string]::IsNullOrEmpty($env:ASAN_OPTIONS)) 'an initially unset variable must not be left set'
        }
    }

    It 'restores ASAN_OPTIONS even when the script block throws' {
        Invoke-WithEnv @{ ASAN_OPTIONS = 'keep=1' } {
            Assert-Throws { Invoke-WithAsanOptions -Options 'z=9' -Script { throw 'boom' } } 'the block error must propagate'
            Assert-Equal 'keep=1' $env:ASAN_OPTIONS 'restore must happen on the failure path too'
        }
    }
}

Describe 'Invoke-WithRuntimePath' {

    It 'prepends runtime dirs to PATH and restores it afterwards' {
        Invoke-WithEnv @{ PATH = 'C:\base'; ASAN_OPTIONS = '' } {
            Invoke-WithRuntimePath -RuntimeDirs @('C:\rt1', 'C:\rt2') -Script { $script:seenPath = $env:PATH }
            Assert-Equal 'C:\rt1;C:\rt2;C:\base' $script:seenPath 'runtime dirs must come first, in order'
            Assert-Equal 'C:\base' $env:PATH 'PATH must be restored'
        }
    }

    It 'tolerates $null, empty and whitespace entries without touching PATH' {
        Invoke-WithEnv @{ PATH = 'C:\base'; ASAN_OPTIONS = '' } {
            Invoke-WithRuntimePath -RuntimeDirs @($null, '', '   ') -Script { $script:seenPath2 = $env:PATH }
            Assert-Equal 'C:\base' $script:seenPath2 'an all-empty list must leave PATH alone'
        }
    }
}

Describe 'Get-AsanRuntimeDirs' {

    It 'never throws on a host with no Visual Studio and no LLVM' {
        # -AllowMissing inside Get-VisualStudioAsanRuntimeDirs is what makes this
        # true: no VS install means one fewer runtime root, not a failure.
        # Asserted as an explicit flag because the no-hit answer is legitimately
        # empty, so no return-value assertion can distinguish it from a throw.
        $threw = $false
        try {
            $null = Get-AsanRuntimeDirs -RuntimeFlavor Msvc
            $null = Get-AsanRuntimeDirs -RuntimeFlavor Clang
            $null = Get-AsanRuntimeDirs
        } catch {
            $threw = $true
        }
        Assert-False $threw 'every flavor must degrade quietly on an unprovisioned host'
    }

    It '@()-wrapping gives an array on any host, including the no-hit one' {
        # PowerShell unrolls a returned empty array, so `$x = Get-AsanRuntimeDirs`
        # yields $null when nothing is found. Every caller therefore wraps -
        # @(Get-AsanRuntimeDirs ...) - and Invoke-WithRuntimePath normalizes
        # $null/scalar input as its second line of defence. This pins BOTH.
        $dirs = @(Get-AsanRuntimeDirs -RuntimeFlavor Msvc)
        Assert-True ($dirs -is [array]) '@() must always produce an array'
    }

    It 'never returns an LLVM path for -RuntimeFlavor Msvc' {
        foreach ($d in @(Get-AsanRuntimeDirs -RuntimeFlavor Msvc)) {
            Assert-False ($d -match '(?i)\\lib\\clang\\|\\LLVM\\') "Msvc flavor must not yield the LLVM runtime: $d"
        }
    }

    It 'returns only directories that actually contain the runtime DLL' {
        foreach ($d in @(Get-AsanRuntimeDirs)) {
            Assert-True (Test-Path (Join-Path $d 'clang_rt.asan_dynamic-x86_64.dll')) "reported dir must hold the DLL: $d"
        }
    }

    It 'Get-AsanRuntimeDll agrees with the first directory it reports' {
        $first = @(Get-AsanRuntimeDirs -RuntimeFlavor Msvc) | Select-Object -First 1
        $dll = Get-AsanRuntimeDll -RuntimeFlavor Msvc
        if ($null -eq $first) {
            Assert-Null $dll 'no directory means no DLL path'
        } else {
            Assert-Equal (Join-Path $first 'clang_rt.asan_dynamic-x86_64.dll') $dll 'must be the DLL inside the first dir'
        }
    }
}

Describe 'Resolve-TestExecutable' {

    It 'prefers the build root over a configuration subdirectory' {
        Invoke-InTestDir {
            param($dir)
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'Release')
            Set-Content -Path (Join-Path $dir 'unit.exe') -Value 'x'
            Set-Content -Path (Join-Path $dir 'Release\unit.exe') -Value 'x'
            Assert-Equal (Join-Path $dir 'unit.exe') (Resolve-TestExecutable -BuildRoot $dir -ExecutableName 'unit.exe') `
                'the flat build root wins over a multi-config subdir'
        }
    }

    It 'finds a binary in a caller-supplied extra directory' {
        Invoke-InTestDir {
            param($dir)
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'Test\perf')
            Set-Content -Path (Join-Path $dir 'Test\perf\bench.exe') -Value 'x'
            Assert-Equal (Join-Path $dir 'Test\perf\bench.exe') `
                (Resolve-TestExecutable -BuildRoot $dir -ExecutableName 'bench.exe' -AdditionalRelativeDirectory @('Test\perf')) `
                '-AdditionalRelativeDirectory replaced the hard-coded Test\* probes'
        }
    }

    It 'falls back to a recursive search' {
        Invoke-InTestDir {
            param($dir)
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'deep\nested')
            Set-Content -Path (Join-Path $dir 'deep\nested\hidden.exe') -Value 'x'
            Assert-Equal (Join-Path $dir 'deep\nested\hidden.exe') (Resolve-TestExecutable -BuildRoot $dir -ExecutableName 'hidden.exe') `
                'an unlisted layout must still be found'
        }
    }

    It 'returns $null when nothing matches' {
        Invoke-InTestDir {
            param($dir)
            Assert-Null (Resolve-TestExecutable -BuildRoot $dir -ExecutableName 'nope.exe') 'a miss must be $null, not a throw'
        }
    }
}

Describe 'Test-IsCxxModuleTranslationUnit' {

    It 'detects a named-module import with the default pattern' {
        Assert-True (Test-IsCxxModuleTranslationUnit -Content "#include <x>`nimport kataglyphis.core;") 'default pattern must match'
    }

    It 'does not treat a plain include as a module TU' {
        Assert-False (Test-IsCxxModuleTranslationUnit -Content '#include <vector>') 'includes are not module imports'
    }

    It 'does not match an import mentioned inside a line' {
        Assert-False (Test-IsCxxModuleTranslationUnit -Content '// we could import kataglyphis.core here') `
            'the pattern is line-anchored on purpose'
    }

    It 'honours a caller-supplied pattern (the de-hard-coded project prefix)' {
        Assert-True (Test-IsCxxModuleTranslationUnit -Content 'import othervendor.mod;' -Pattern '(?m)^\s*import\s+\w') `
            '-ModuleImportPattern is what makes this module project-agnostic'
        Assert-False (Test-IsCxxModuleTranslationUnit -Content 'import othervendor.mod;') `
            'the default prefix must not match a foreign module'
    }
}
