#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

# The arm64 bundle's two target CPython trees: one staging function for the GIL and the free-threaded build, over synthetic PCbuild outputs.

BeforeAll {
    $script:repo = Get-RepoRoot
    Import-Module (Join-Path $script:repo 'windows\scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
    # A PCbuild output, source tree and VS redist as Build-TargetCpython.ps1 meets them; -HostCrt plants MSBuild's host-arch CRT copies.
    function script:New-TargetBuild {
        param([Parameter(Mandatory)][string]$Dir, [switch]$FreeThreaded, [switch]$HostCrt, [uint16]$ExeMachine = 0xAA64)
        $src = Join-Path $Dir 'src'
        foreach ($f in 'Include\Python.h', 'Include\cpython\object.h', 'PC\pyconfig.h', 'Lib\os.py', 'Lib\site-packages\host_pkg\__init__.py') {
            New-Item -ItemType File -Force (Join-Path $src $f) | Out-Null
        }
        New-Item -ItemType File -Force (Join-Path $src 'Lib\ensurepip\_bundled\pip-25.3-py3-none-any.whl') | Out-Null
        $build = Join-Path $Dir 'build'
        $t = if ($FreeThreaded) { 't' } else { '' }
        $names = if ($FreeThreaded) { 'python3.14t.exe', 'pythonw3.14t.exe' } else { 'python.exe', 'pythonw.exe' }
        New-TestPeFile -Path (Join-Path $build $names[0]) -Machine $ExeMachine -Tag 'exe'
        New-TestPeFile -Path (Join-Path $build $names[1]) -Machine 0xAA64 -Tag 'wexe'
        foreach ($n in "python314$t.dll", "python3$t.dll", "_ssl$(if ($FreeThreaded) { '.cp314t-win_arm64' }).pyd", 'libcrypto-3-arm64.dll', "venvlauncher$t.exe", "venvwlauncher$t.exe") {
            New-TestPeFile -Path (Join-Path $build $n) -Machine 0xAA64 -Tag $n
        }
        foreach ($n in 'python3.lib', 'python3t.lib', 'python314.lib', 'python314t.lib') { Set-Content (Join-Path $build $n) 'lib' }
        New-TestPeFile -Path (Join-Path $build 'vcruntime140.dll') -Machine 0xAA64 -Tag 'vcrt'
        if ($HostCrt) {
            # As the real ARM64 output has them (2026-10-07): an x64 vcruntime140_1.dll, which has no ARM64 edition, and here one more.
            New-TestPeFile -Path (Join-Path $build 'vcruntime140_1.dll') -Machine 0x8664 -Tag 'host-vcrt1'
            New-TestPeFile -Path (Join-Path $build 'msvcp140.dll') -Machine 0x8664 -Tag 'host-msvcp'
        }
        $redist = Join-Path $Dir 'redist'
        foreach ($n in 'vcruntime140.dll', 'msvcp140.dll') { New-TestPeFile -Path (Join-Path $redist $n) -Machine 0xAA64 -Tag "redist-$n" }
        return @{ Src = $src; Build = $build; Redist = $redist }
    }
    # Both sides sorted the same way, so the expectation never depends on how a culture orders '_' and case.
    function script:Join-Sorted { param([string[]]$Name) return (@($Name) | Sort-Object) -join ',' }
    function script:Get-TreeFiles {
        param([string]$Root)
        return Join-Sorted @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($Root.Length + 1) })
    }
}

Describe 'Install-CpythonTargetTree' {

    It 'stages the GIL tree as the bundle always had it: CRT replaced from the redist, beside the exe and in bin, the shim its only package' {
        Invoke-InTestDir { param($d)
            $b = New-TargetBuild -Dir $d -HostCrt
            $root = Join-Path $d 'runtime\python'
            $r = Install-CpythonTargetTree -BuildDir $b.Build -SourceDir $b.Src -Destination $root -Arch arm64 -RedistDir $b.Redist `
                -BundleBin (Join-Path $d 'runtime\bin') -ShimWrittenBy 'test (TARGET)'
            $want = Join-Sorted @('DLLs\_ssl.pyd', 'DLLs\libcrypto-3-arm64.dll', 'DLLs\msvcp140.dll', 'DLLs\vcruntime140.dll', 'include\cpython\object.h',
                'include\Python.h', 'include\pyconfig.h', 'Lib\ensurepip\_bundled\pip-25.3-py3-none-any.whl', 'Lib\os.py',
                'Lib\site-packages\sitecustomize.py', 'libs\python314.lib', 'msvcp140.dll', 'python.exe', 'python3.dll', 'python314.dll', 'pythonw.exe',
                'vcruntime140.dll')
            Assert-Equal $want (Get-TreeFiles $root) 'the GIL layout, without vcruntime140_1.dll and the host package'
            Assert-Equal 'msvcp140.dll,vcruntime140.dll' (Get-TreeFiles (Join-Path $d 'runtime\bin')) 'the CRT in the bundle bin'
            $redistHash = (Get-FileHash (Join-Path $b.Redist 'msvcp140.dll')).Hash
            foreach ($f in 'msvcp140.dll', 'DLLs\msvcp140.dll', '..\bin\msvcp140.dll') {
                Assert-Equal $redistHash (Get-FileHash (Join-Path $root $f)).Hash "$f is the redist's ARM64 copy, not MSBuild's x64 one"
            }
            Assert-Match 'test \(TARGET\)' (Get-Content -Raw (Join-Path $root 'Lib\site-packages\sitecustomize.py')) 'the shim credits its writer'
            Assert-Equal "$root\python.exe|$root\libs\python314.lib|17" "$($r.Exe)|$($r.Lib)|$($r.Files)" 'the returned facts'
        }
    }

    It 'stages the free-threaded tree with its own exe, python314t.lib and venv launchers, an empty site-packages and no bundle bin' {
        Invoke-InTestDir { param($d)
            $b = New-TargetBuild -Dir $d -FreeThreaded
            $root = Join-Path $d 'runtime\python-freethreaded'
            $r = Invoke-WithEnv @{ PYTHON_VERSION = '3.14.8' } {
                Install-CpythonTargetTree -BuildDir $b.Build -SourceDir $b.Src -Destination $root -Arch arm64 -FreeThreaded -RedistDir $b.Redist
            }
            $want = Join-Sorted @('DLLs\_ssl.cp314t-win_arm64.pyd', 'DLLs\libcrypto-3-arm64.dll', 'DLLs\vcruntime140.dll', 'include\cpython\object.h',
                'include\Python.h', 'include\pyconfig.h', 'Lib\ensurepip\_bundled\pip-25.3-py3-none-any.whl', 'Lib\os.py',
                'Lib\venv\scripts\nt\venvlaunchert.exe', 'Lib\venv\scripts\nt\venvwlaunchert.exe', 'libs\python314t.lib', 'msvcp140.dll',
                'python3.14t.exe', 'python314t.dll', 'python3t.dll', 'pythonw3.14t.exe', 'vcruntime140.dll')
            Assert-Equal $want (Get-TreeFiles $root) 'no python.exe, no GIL import lib, no shim; the launchers where uv venv looks'
            Assert-True (Test-Path (Join-Path $root 'Lib\site-packages') -PathType Container) 'site-packages exists, empty'
            Assert-False (Test-Path (Join-Path $d 'runtime\bin')) 'the GIL tree owns the bundle bin'
            Assert-Equal "$root\python3.14t.exe|$root\libs\python314t.lib" "$($r.Exe)|$($r.Lib)" 'the returned facts'
        }
    }

    It 'refuses <Why>' -ForEach @(
        @{ Why = 'a host-arch interpreter'; Exe = 0x8664; Pattern = 'python\.exe machine is 0x8664, expected 0xAA64' }
        @{ Why = 'a free-threaded build of another minor version'; Ft = $true; Version = '3.15.0'; Pattern = 'python3\.15t\.exe was not produced' }
        @{ Why = 'a free-threaded build without python314t.lib'; Ft = $true; Drop = 'build\python314t.lib'; Pattern = 'no python3XYt\.lib import library' }
        @{ Why = 'a host-arch DLL the redist cannot replace'; HostCrt = $true; Drop = 'redist\msvcp140.dll'; Pattern = 'msvcp140\.dll is machine 0x8664, expected 0xAA64, and no arm64 redist replacement' }
        @{ Why = 'a free-threaded build with a python.exe'; Ft = $true; Add = 'build\python.exe'; Pattern = 'GIL request could resolve to the free-threaded build' }
        @{ Why = 'a free-threaded build without its venv launcher'; Ft = $true; Drop = 'build\venvwlaunchert.exe'; Pattern = 'venvwlaunchert\.exe was not produced' }
        @{ Why = 'a vcruntime140.dll neither the build nor the redist has'; Drop = 'build\vcruntime140.dll', 'redist\vcruntime140.dll'; Pattern = 'vcruntime140\.dll \(target-arch\) could not be staged beside python\.exe' }
        @{ Why = 'a source tree without the ensurepip wheel'; Drop = 'src\Lib\ensurepip'; Pattern = 'pip-\*\.whl missing' }
    ) {
        # Every row names only what it changes; strict mode refuses a key a row leaves out.
        $c = @{ Exe = 0xAA64; Ft = $false; HostCrt = $false; Version = '3.14.8'; Drop = @(); Add = '' }
        foreach ($k in $_.Keys) { $c[$k] = $_[$k] }
        Invoke-InTestDir { param($d)
            $b = New-TargetBuild -Dir $d -FreeThreaded:$c.Ft -HostCrt:$c.HostCrt -ExeMachine $c.Exe
            foreach ($x in @($c.Drop)) { Remove-Item (Join-Path $d $x) -Recurse }
            if ($c.Add) { New-TestPeFile -Path (Join-Path $d $c.Add) -Machine 0xAA64 -Tag 'added' }
            $out = Join-Path $d 'out'
            Invoke-WithEnv @{ PYTHON_VERSION = $c.Version } {
                Assert-Throws { Install-CpythonTargetTree -BuildDir $b.Build -SourceDir $b.Src -Destination $out -Arch arm64 -FreeThreaded:$c.Ft -RedistDir $b.Redist } `
                    -MessagePattern $c.Pattern
            }
            if ($c.Exe -ne 0xAA64) { Assert-False (Test-Path $out) 'nothing was staged' }
        }
    }
}

Describe 'the arm64 media chains stage the free-threaded tree once' {

    BeforeAll {
        $script:target, $script:core, $script:tvm = foreach ($rel in 'Build-TargetCpython.ps1', 'Build-MediaCoreAll.ps1', 'Build-MediaTvmAll.ps1') {
            [IO.File]::ReadAllText((Join-Path $script:repo "windows\scripts\build\$rel"))
        }
    }

    It 'builds and stages the GIL tree before the free-threaded build, both with the x64-hosted toolset, and scrubs its output' {
        $order = '(?s)Invoke-CpythonPcbuild -SourceDir \$SourceDir -Platform \$cpyBuildPlatform -ExtraArguments \$hostToolArgs' +
            '.*Install-CpythonTargetTree -BuildDir \$cpyOutDir .*-ShimWrittenBy ' +
            '.*Invoke-CpythonPcbuild -SourceDir \$SourceDir -Platform \$cpyBuildPlatform -FreeThreaded -ExtraArguments \$hostToolArgs' +
            '.*Install-CpythonTargetTree -BuildDir \(Get-CpythonFreeThreadedBuildDir -SourceDir \$SourceDir -Arch \$tgtArch\)' +
            ".*-Destination \(Join-Path \`$InstallDir 'python-freethreaded'\) -Arch \`$tgtArch -FreeThreaded" +
            '.*Remove-Item \(Get-CpythonFreeThreadedBuildDir -SourceDir \$SourceDir\) -Recurse'
        Assert-Match $order $script:target
        Assert-Match ([regex]::Escape("`$hostToolArgs = @('`"/p:PreferredToolArchitecture=x64`"')")) $script:target 'the GIL build''s old argument, for both builds'
    }

    It 'media-core stages both trees for the merge, and media-tvm, whose trees the merge drops, the GIL one only' {
        Assert-Match "Script = 'Build-TargetCpython\.ps1';\s+SourceDir = 'C:\\temp\\cpython' \}" $script:core 'media-core runs the script plainly'
        Assert-Match "Build-TargetCpython\.ps1'\) -SourceDir 'C:\\temp\\cpython' -InstallDir \`$id -SkipFreeThreaded" $script:tvm
    }
}
