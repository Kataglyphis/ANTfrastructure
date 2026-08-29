#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# The #131 cross-lane helpers that replaced three-to-six hand-rolled copies
# each: Add-NinjaPerTuFlags (fake build.ninja), Write-AbsentOnCrossMarker,
# Get-PythonCMakeHintArgs, Get-TargetBuildPython (fixture CPython tree),
# Invoke-InlineRegexPatch -SkipIfMatch/-AssertGone, and the PE asserts over a
# real system DLL. Pure fixtures -- nothing here needs a toolchain.

Describe 'Add-NinjaPerTuFlags' {

    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-ninja-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
        $script:ninja = Join-Path $script:tmp 'build.ninja'
        @(
            'build a/kernel_avx512.cpp.obj: CXX_COMPILER a/kernel_avx512.cpp',
            '  FLAGS = /O2 /MD',
            '  INCLUDES = -Ia',
            'build a/plain.cpp.obj: CXX_COMPILER a/plain.cpp',
            '  FLAGS = /O2 /MD',
            'build b/kernel_avx512_2.cpp.obj: CXX_COMPILER b/kernel_avx512_2.cpp',
            '  FLAGS = /O2 /MD',
            'build c/link.dll: CXX_SHARED_LIBRARY_LINKER a/kernel_avx512.cpp.obj',
            '  LINK_FLAGS = /DLL'
        ) | Set-Content -Path $script:ninja -Encoding ASCII
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'tags exactly the FLAGS lines of the selected build statements and returns the count' {
        $n = Add-NinjaPerTuFlags -NinjaFile $script:ninja -Label 'fixture' -Floor 2 -AlreadyTaggedPattern 'mavx512' -Select { param($l) if ($l -match 'kernel_avx512') { '/clang:-mavx512f' } }
        Assert-Equal 2 $n 'two kernel TUs selected'
        $lines = Get-Content $script:ninja
        Assert-True ($lines[1] -eq '  FLAGS = /O2 /MD /clang:-mavx512f') 'first kernel tagged'
        Assert-True ($lines[4] -eq '  FLAGS = /O2 /MD') 'plain TU untouched'
        Assert-True ($lines[6] -eq '  FLAGS = /O2 /MD /clang:-mavx512f') 'second kernel tagged'
        Assert-True ($lines[8] -eq '  LINK_FLAGS = /DLL') 'link statement untouched (no FLAGS line)'
    }

    It 'is idempotent: a second run counts the already-tagged lines but does not re-append' {
        $n = Add-NinjaPerTuFlags -NinjaFile $script:ninja -Label 'fixture' -Floor 2 -AlreadyTaggedPattern 'mavx512' -Select { param($l) if ($l -match 'kernel_avx512') { '/clang:-mavx512f' } }
        Assert-Equal 2 $n 'still counts two'
        Assert-True ((Get-Content $script:ninja)[1] -eq '  FLAGS = /O2 /MD /clang:-mavx512f') 'no double tag'
    }

    It 'throws below the floor and leaves the file untouched' {
        $before = Get-Content $script:ninja -Raw
        $threw = $false
        try { Add-NinjaPerTuFlags -NinjaFile $script:ninja -Label 'fixture' -Floor 5 -Select { param($l) if ($l -match 'nomatch_zzz') { '/x' } } | Out-Null } catch { $threw = $true; Assert-True ($_.Exception.Message -match 'tagged only 0 fixture') 'message names the count and label' }
        Assert-True $threw 'a selector that matches nothing must throw'
        Assert-Equal $before (Get-Content $script:ninja -Raw) 'file untouched on a floor failure'
    }
}

Describe 'Write-AbsentOnCrossMarker' {
    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
        $script:savedArch = $env:WINDOWS_TARGET_ARCH
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-absent-' + [guid]::NewGuid().ToString('N'))
    }
    AfterAll { $env:WINDOWS_TARGET_ARCH = $script:savedArch; Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'creates the root + ensured dirs and writes the arch-named marker with the reason lines' {
        $env:WINDOWS_TARGET_ARCH = 'arm64'
        $m = Write-AbsentOnCrossMarker -Root (Join-Path $script:tmp 'litert-lm') -Component 'LiteRT-LM' -Reason @('bazel has no windows-arm64 config') -EnsureDirs @('include', 'bin')
        Assert-True (Test-Path (Join-Path $script:tmp 'litert-lm\include')) 'include dir ensured'
        Assert-True (Test-Path (Join-Path $script:tmp 'litert-lm\bin')) 'bin dir ensured'
        Assert-Equal 'ABSENT-ON-ARM64.txt' (Split-Path $m -Leaf) 'default file name follows the target arch'
        $body = Get-Content $m
        Assert-True ($body[0] -match 'LiteRT-LM is intentionally ABSENT from the Windows arm64 bundle') 'first line names component + arch'
        Assert-True ($body -contains 'bazel has no windows-arm64 config') 'reason line present'
        Assert-True ($body[-1] -eq 'See docs/windows-cross-builds.md.') 'docs pointer last'
    }

    It 'honours an explicit file name (the TVM/IREE COMPILER marker)' {
        $env:WINDOWS_TARGET_ARCH = 'arm64'
        $m = Write-AbsentOnCrossMarker -Root (Join-Path $script:tmp 'tvm') -Component 'tvm_compiler.dll' -Reason @('needs target LLVM') -FileName 'COMPILER-ABSENT-ON-ARM64.txt'
        Assert-Equal 'COMPILER-ABSENT-ON-ARM64.txt' (Split-Path $m -Leaf)
    }
}

Describe 'Get-PythonCMakeHintArgs' {
    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
        $script:py = @{ Exe = 'C:\temp\cpython\PCbuild\amd64\python.exe'; Include = 'C:\temp\cpython\Include'; Lib = 'C:\temp\cpython\PCbuild\arm64\python314.lib'; LibDir = 'C:\temp\cpython\PCbuild\arm64' }
    }

    It 'emits the trio per prefix, case-exact, host exe + target lib' {
        $a = Get-PythonCMakeHintArgs -Python $script:py -Prefix @('Python', 'PYTHON')
        Assert-Equal 6 $a.Count 'three hints per prefix'
        Assert-True ($a -ccontains '-DPython_EXECUTABLE=C:\temp\cpython\PCbuild\amd64\python.exe') 'Python_EXECUTABLE is the host exe'
        Assert-True ($a -ccontains '-DPython_LIBRARY=C:\temp\cpython\PCbuild\arm64\python314.lib') 'Python_LIBRARY is the target lib'
        Assert-True ($a -ccontains '-DPYTHON_LIBRARY=C:\temp\cpython\PCbuild\arm64\python314.lib') 'legacy prefix gets the same target lib'
        Assert-True (@($a | Where-Object { $_ -cmatch '^-DPython3_' }).Count -eq 0) 'never the ignored Python3_ spelling unless asked'
    }

    It 'adds the NumPy include hint on the first prefix and forward-slashes on request' {
        $a = Get-PythonCMakeHintArgs -Python $script:py -Prefix @('PYTHON3') -ForwardSlash -NumPyIncludeDir 'C:\np\include'
        Assert-True ($a -ccontains '-DPYTHON3_EXECUTABLE=C:/temp/cpython/PCbuild/amd64/python.exe') 'forward slashes applied'
        Assert-True ($a -ccontains '-DPYTHON3_NumPy_INCLUDE_DIR=C:/np/include') 'NumPy hint carried the first prefix'
    }
}

Describe 'Get-TargetBuildPython (fixture CPython tree)' {
    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
        $script:savedArch = $env:WINDOWS_TARGET_ARCH
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-tpy-' + [guid]::NewGuid().ToString('N'))
        foreach ($d in 'PCbuild\amd64', 'PCbuild\arm64', 'Include') { New-Item -Path (Join-Path $script:tmp $d) -ItemType Directory -Force | Out-Null }
        Set-Content (Join-Path $script:tmp 'PCbuild\amd64\python.exe') 'x'
        Set-Content (Join-Path $script:tmp 'PCbuild\amd64\python314.lib') 'x'
        Set-Content (Join-Path $script:tmp 'PCbuild\arm64\python314.lib') 'x'
    }
    AfterAll { $env:WINDOWS_TARGET_ARCH = $script:savedArch; Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'on a cross lane: host .Exe, target .Lib/.LibDir, Available when the target lib exists' {
        $env:WINDOWS_TARGET_ARCH = 'arm64'
        $t = Get-TargetBuildPython -CpythonDir $script:tmp
        Assert-True ($t.Exe -like '*\PCbuild\amd64\python.exe') 'host interpreter runs'
        Assert-True ($t.Lib -like '*\PCbuild\arm64\python314.lib') 'target import lib links'
        Assert-True ($t.LibDir -like '*\PCbuild\arm64') 'target lib dir'
        Assert-True $t.Available 'available while the target lib exists'
        Remove-Item (Join-Path $script:tmp 'PCbuild\arm64\python314.lib') -Force
        Assert-True (-not (Get-TargetBuildPython -CpythonDir $script:tmp).Available) 'not available once the target lib is gone'
        Set-Content (Join-Path $script:tmp 'PCbuild\arm64\python314.lib') 'x'
    }

    It 'on the native lane collapses to the host values' {
        $env:WINDOWS_TARGET_ARCH = 'amd64'
        $t = Get-TargetBuildPython -CpythonDir $script:tmp
        Assert-True ($t.Lib -like '*\PCbuild\amd64\python314.lib') 'host == target'
        Assert-True $t.Available
    }
}

Describe 'Invoke-InlineRegexPatch guards (-SkipIfMatch / -AssertGone)' {
    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsSourceBuild.Patches.psm1') -Force -DisableNameChecking
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-patch-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:tmp -ItemType Directory -Force | Out-Null
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'applies, then reports already-applied via -SkipIfMatch on the second call' {
        $f = Join-Path $script:tmp 'a.cmake'
        Set-Content $f 'if(MSVC_C_ARCHITECTURE_ID MATCHES 64)'
        $r1 = Invoke-InlineRegexPatch -Path $f -Pattern 'MATCHES 64\)' -Replacement 'MATCHES "^(x64)$")' -SkipIfMatch '\^\(x64\)' -AssertGone 'MATCHES 64\)' -Description 'fixture'
        $r2 = Invoke-InlineRegexPatch -Path $f -Pattern 'MATCHES 64\)' -Replacement 'MATCHES "^(x64)$")' -SkipIfMatch '\^\(x64\)' -AssertGone 'MATCHES 64\)' -Description 'fixture'
        Assert-True $r1 'first call patched'
        Assert-True $r2 'second call reports applied'
        Assert-True ((Get-Content $f -Raw) -notmatch 'MATCHES 64\)') 'old pattern gone'
    }

    It 'throws when the pattern is absent but -AssertGone still matches (layout drift)' {
        $f = Join-Path $script:tmp 'b.cmake'
        Set-Content $f 'if(MSVC_C_ARCHITECTURE_ID   MATCHES 64)'   # double space defeats the exact pattern
        $threw = $false
        try { Invoke-InlineRegexPatch -Path $f -Pattern 'ID MATCHES 64\)' -Replacement 'x' -AssertGone 'MATCHES 64\)' -Description 'fixture' -WarnMessage 'quiet' | Out-Null } catch { $threw = $true }
        Assert-True $threw 'drift must throw, not warn'
    }
}

Describe 'PE asserts over a real system DLL' {
    BeforeAll {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Import-Module (Join-Path $root 'scripts\modules\WindowsTargetArch.Common.psm1') -Force -DisableNameChecking
        $script:hostArch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq 'Arm64') { 'arm64' } else { 'amd64' }
        $script:otherArch = if ($script:hostArch -eq 'amd64') { 'arm64' } else { 'amd64' }
        $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('wbt-pe-' + [guid]::NewGuid().ToString('N'))
        New-Item -Path (Join-Path $script:tmp 'sub') -ItemType Directory -Force | Out-Null
        Copy-Item (Join-Path $env:SystemRoot 'System32\kernel32.dll') (Join-Path $script:tmp 'sub\k.dll')
        Set-Content (Join-Path $script:tmp 'sub\readme.txt') 'not a pe'
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'Assert-DirectoryTargetArch passes for the runner arch and counts only native files' {
        Assert-Equal 1 (Assert-DirectoryTargetArch -Path $script:tmp -Arch $script:hostArch -Context 'fixture') 'one DLL, the txt is ignored'
    }

    It 'Assert-DirectoryTargetArch throws for the other arch, naming the file, and on an empty tree' {
        $threw = $false
        try { Assert-DirectoryTargetArch -Path $script:tmp -Arch $script:otherArch -Context 'fixture' | Out-Null } catch { $threw = $true; Assert-True ($_.Exception.Message -match 'k\.dll') 'offender named' }
        Assert-True $threw 'wrong machine must throw'
        $empty = Join-Path $script:tmp 'empty'; New-Item $empty -ItemType Directory -Force | Out-Null
        $threw = $false
        try { Assert-DirectoryTargetArch -Path $empty -Arch $script:hostArch | Out-Null } catch { $threw = $true }
        Assert-True $threw 'an empty tree is a failure, never a pass'
    }

    It 'Assert-PythonExtensionTag accepts bare and target-tagged names and rejects host-tagged ones' {
        Assert-True (Assert-PythonExtensionTag -Name 'cv2.pyd' -Arch 'arm64') 'bare .pyd passes'
        Assert-True (Assert-PythonExtensionTag -Name 'C:\x\cv2.cp314-win_arm64.pyd' -Arch 'arm64') 'target tag passes'
        $threw = $false
        try { Assert-PythonExtensionTag -Name 'cv2.cp314-win_amd64.pyd' -Arch 'arm64' | Out-Null } catch { $threw = $true }
        Assert-True $threw 'host tag on a target module must throw'
    }
}
