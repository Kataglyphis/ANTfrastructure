#requires -Version 7.0
# Host-independent only: -Msvc must never yield LLVM's ASan runtime, which aborts COM/CRT hosts with a bad-free.

foreach ($module in 'WindowsTesting.Common', 'WindowsClang.Common') {
    Import-Module (Join-Path (Get-RepoRoot) "windows/scripts/modules/$module.psm1") -ErrorAction Stop
}

function Assert-TestExecutableLayout {
    param([Collections.IDictionary]$Files, [string]$ExecutableName, [string]$ExpectedRelativePath,
        [string[]]$AdditionalDirectory = @(), [string]$Reason)
    Invoke-InTestDir -Files $Files -Body { param($dir)
        $actual = Resolve-TestExecutable -BuildRoot $dir -ExecutableName $ExecutableName -AdditionalRelativeDirectory $AdditionalDirectory
        Assert-Equal (Join-Path $dir $ExpectedRelativePath) $actual $Reason
    }.GetNewClosure()
}

function Get-TestEnvSeen {
    param([hashtable]$Vars, [string]$Command, [hashtable]$Arguments)
    # The After values are read before Invoke-WithEnv restores the caller's environment.
    Invoke-WithEnv $Vars {
        $seen = @{}
        & $Command @Arguments -Script { $seen.Path = $env:PATH; $seen.Asan = $env:ASAN_OPTIONS }
        [pscustomobject]@{ Path = $seen.Path; Asan = $seen.Asan; PathAfter = $env:PATH; AsanAfter = $env:ASAN_OPTIONS }
    }
}

Describe 'Invoke-WithAsanOptions' {
    # Each wrapped run happens once; the tests below only read what it saw.
    $asan = @{
        prepended = Get-TestEnvSeen @{ ASAN_OPTIONS = 'pre=1' } Invoke-WithAsanOptions @{ Options = 'x=2' }
        unset = Get-TestEnvSeen @{ ASAN_OPTIONS = '' } Invoke-WithAsanOptions @{ Options = 'y=3' }
        emptyKept = Get-TestEnvSeen @{ ASAN_OPTIONS = 'pre=1' } Invoke-WithAsanOptions @{ Options = '' }
        emptyUnset = Get-TestEnvSeen @{ ASAN_OPTIONS = '' } Invoke-WithAsanOptions @{ Options = '' }
    }

    It 'prepends to an existing ASAN_OPTIONS and restores it afterwards' {
        Assert-Equal 'x=2:pre=1' $asan.prepended.Asan 'caller options must come first, existing ones must survive'
        Assert-Equal 'pre=1' $asan.prepended.AsanAfter 'the previous value must be restored'
    }

    It 'removes the variable again when it was unset before' {
        Assert-Equal 'y=3' $asan.unset.Asan 'the block must see exactly the caller options'
        Assert-True ([string]::IsNullOrEmpty($asan.unset.AsanAfter)) 'an initially unset variable must not be left set'
    }

    It 'restores ASAN_OPTIONS even when the script block throws' {
        Invoke-WithEnv @{ ASAN_OPTIONS = 'keep=1' } {
            Assert-Throws { Invoke-WithAsanOptions -Options 'z=9' -Script { throw 'boom' } } 'the block error must propagate'
            Assert-Equal 'keep=1' $env:ASAN_OPTIONS 'restore must happen on the failure path too'
        }
    }

    It 'runs the block with ASAN_OPTIONS untouched for an empty -Options' {
        # Consumers pass -AsanOptions '' for full-application runs; a mandatory [string] would refuse it.
        Assert-Equal 'pre=1' $asan.emptyKept.Asan 'nothing may be prepended, not even a separator'
        Assert-Equal 'pre=1' $asan.emptyKept.AsanAfter 'the caller value must survive'
        Assert-True ([string]::IsNullOrEmpty($asan.emptyUnset.Asan)) 'an unset variable stays unset inside the block'
    }
}

Describe 'Invoke-WithRuntimePath' {
    # Each wrapped run happens once; the tests below only read what it saw.
    $runtime = @{
        ordered = Get-TestEnvSeen @{ PATH = 'C:\base'; ASAN_OPTIONS = '' } Invoke-WithRuntimePath @{ RuntimeDirs = @('C:\rt1', 'C:\rt2') }
        blank = Get-TestEnvSeen @{ PATH = 'C:\base'; ASAN_OPTIONS = '' } Invoke-WithRuntimePath @{ RuntimeDirs = @($null, '', '   ') }
        optedOut = Get-TestEnvSeen @{ PATH = 'C:\base'; ASAN_OPTIONS = 'pre=1' } Invoke-WithRuntimePath @{ RuntimeDirs = @('C:\rt1'); AsanOptions = '' }
    }

    It 'prepends runtime dirs to PATH and restores it afterwards' {
        Assert-Equal 'C:\rt1;C:\rt2;C:\base' $runtime.ordered.Path 'runtime dirs must come first, in order'
        Assert-Equal 'C:\base' $runtime.ordered.PathAfter 'PATH must be restored'
    }

    It 'tolerates $null, empty and whitespace entries without touching PATH' {
        Assert-Equal 'C:\base' $runtime.blank.Path 'an all-empty list must leave PATH alone'
    }

    It "accepts -AsanOptions '' and still prepends the runtime dirs" {
        Assert-Equal 'C:\rt1;C:\base' $runtime.optedOut.Path 'the runtime dirs still come first'
        Assert-Equal 'pre=1' $runtime.optedOut.Asan 'an opted-out run keeps the caller ASAN_OPTIONS as they were'
        Assert-Equal 'C:\base' $runtime.optedOut.PathAfter 'PATH must be restored'
    }
}

Describe 'Get-AsanRuntimeDirs' {

    It 'never throws on a host with no Visual Studio and no LLVM' {
        # An explicit flag: the no-hit answer is legitimately empty, so no return value tells it from a throw.
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
        # PowerShell unrolls a returned empty array to $null, so every caller wraps the call in @().
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
        Assert-TestExecutableLayout -Files @{ 'unit.exe' = 'x'; 'Release/unit.exe' = 'x' } -ExecutableName unit.exe `
            -ExpectedRelativePath unit.exe -Reason 'the flat build root wins over a multi-config subdir'
    }

    It 'finds a binary in a caller-supplied extra directory' {
        Assert-TestExecutableLayout -Files @{ 'Test/perf/bench.exe' = 'x'; 'aaa/bench.exe' = 'recursive decoy' } -ExecutableName bench.exe `
            -ExpectedRelativePath 'Test/perf/bench.exe' -AdditionalDirectory 'Test/perf' `
            -Reason '-AdditionalRelativeDirectory replaced the hard-coded Test\* probes'
    }

    It 'falls back to a recursive search' {
        Assert-TestExecutableLayout -Files @{ 'deep/nested/hidden.exe' = 'x' } -ExecutableName hidden.exe `
            -ExpectedRelativePath 'deep/nested/hidden.exe' -Reason 'an unlisted layout must still be found'
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
