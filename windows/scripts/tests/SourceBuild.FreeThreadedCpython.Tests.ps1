#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

# The image's free-threaded CPython: its build arguments, its PC\layout install and the GIL-versus-t split, over fixtures and .cmd fakes.

BeforeAll {
    $script:repo = Get-RepoRoot
    Import-Module (Join-Path $script:repo 'windows\scripts\modules\WindowsSourceBuild.Common.psm1') -Force -DisableNameChecking
    # Both builds' import libraries and their stable-ABI stubs in one directory, as a careless staging would leave them.
    function script:New-ImportLibSet {
        param([Parameter(Mandatory)][string]$Dir)
        New-Item -ItemType Directory -Force $Dir | Out-Null
        foreach ($n in 'python3.lib', 'python3t.lib', 'python314.lib', 'python314t.lib') { Set-Content (Join-Path $Dir $n) 'x' }
        return $Dir
    }
    # A .cmd standing in for python.exe: prints -Line, exits -Exit.
    function script:New-FakePython {
        param([string]$Dir, [string]$Line, [int]$Exit = 0)
        $p = Join-Path $Dir 'python.cmd'
        Set-Content -LiteralPath $p -Value @('@echo off', "echo $Line", "exit /b $Exit") -Encoding ASCII
        return $p
    }
}

Describe 'Select-CpythonImportLib' {

    It 'gives a GIL caller python314.lib and a free-threaded one python314t.lib from one directory, never a stable-ABI stub' {
        Invoke-InTestDir { param($d)
            $libs = New-ImportLibSet $d
            Assert-Equal 'python314.lib' (Select-CpythonImportLib -LibDir $libs).Name 'GIL'
            Assert-Equal 'python314t.lib' (Select-CpythonImportLib -LibDir $libs -FreeThreaded).Name 'free-threaded'
        }
    }

    It 'returns nothing rather than the other build''s lib, and nothing for a missing directory' {
        Invoke-InTestDir { param($d)
            Set-Content (Join-Path $d 'python314t.lib') 'x'
            Assert-Null (Select-CpythonImportLib -LibDir $d) 'a GIL caller must not link python314t.lib'
            Assert-Null (Select-CpythonImportLib -LibDir (Join-Path $d 'absent') -FreeThreaded) 'missing directory'
        }
    }
}

Describe 'Get-SourceBuildPython' {

    It 'keeps GIL callers on the in-tree build, and -FreeThreaded on the install root' {
        Invoke-InTestDir { param($d)
            $tree = New-ImportLibSet (Join-Path $d "PCbuild\$(Get-CpythonOutputDir -Arch (Get-WindowsHostArch))")
            $gil = Get-SourceBuildPython -CpythonDir $d
            Assert-Equal "$tree\python.exe|$tree\python314.lib" "$($gil.Exe)|$($gil.Lib)" 'GIL exe and lib'
            $root = Split-Path (New-ImportLibSet (Join-Path $d 'ft\libs')) -Parent
            Invoke-WithEnv @{ PYTHON_VERSION = '3.14.8'; PYTHON_FREETHREADED_BIN = $root } {
                $ft = Get-SourceBuildPython -FreeThreaded
                Assert-Equal "$root\python3.14t.exe|$root\include|$root\libs\python314t.lib" "$($ft.Exe)|$($ft.Include)|$($ft.Lib)" 'free-threaded exe, include and lib'
            }
        }
    }

    It 'falls back to C:\python-freethreaded and names the minor version of the pin' {
        Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = $null } {
            Assert-Equal 'C:\python-freethreaded' (Get-CpythonFreeThreadedRoot) 'the Dockerfile ENV value'
        }
        Assert-Equal 'python3.15t.exe' (Get-CpythonFreeThreadedExeName -Version '3.15.0') 'minor version only'
    }
}

Describe 'Get-CpythonPcbuildArguments' {

    It 'leaves the GIL build exactly as the image ran it' {
        Assert-Equal '-e -p x64 -c Release' ((Get-CpythonPcbuildArguments -SourceDir 'C:\temp\cpython') -join ' ')
    }

    It 'gives the free-threaded build --disable-gil before its own quoted output and object trees, extra properties last' {
        $a = @(Get-CpythonPcbuildArguments -SourceDir 'C:\temp\cpython' -FreeThreaded -ExtraArguments '"/p:X=1"')
        $want = '-e -p x64 -c Release --disable-gil "/p:Py_OutDir=C:\temp\cpython\PCbuild\freethreaded" ' +
            '"/p:Py_IntDir=C:\temp\cpython\PCbuild\obj\freethreaded" "/p:X=1"'
        Assert-Equal $want ($a -join ' ') 'build.bat stops parsing its own options at the first /p:'
        Assert-Equal 'C:\temp\cpython\PCbuild\freethreaded\amd64' (Get-CpythonFreeThreadedBuildDir -SourceDir 'C:\temp\cpython' -Arch amd64) 'PCbuild appends the arch'
    }
}

Describe 'Assert-CpythonInterpreter' {

    It 'accepts a free-threaded build at the pin and a GIL build when asked for one' {
        Invoke-InTestDir { param($d)
            Assert-CpythonInterpreter -Exe (New-FakePython $d '3.14.8 False 1 True') -FreeThreaded -ExpectedVersion '3.14.8' | Out-Null
            Assert-CpythonInterpreter -Exe (New-FakePython $d '3.14.8 True 0 True') -ExpectedVersion '3.14.8' | Out-Null
        }
    }

    It 'refuses the other build, another patch release, a lost AMD64 marker and a failed start' {
        Invoke-InTestDir { param($d)
            Assert-Throws { Assert-CpythonInterpreter -Exe (New-FakePython $d '3.14.8 True 0 True') -FreeThreaded } -MessagePattern 'not a free-threaded build'
            Assert-Throws { Assert-CpythonInterpreter -Exe (New-FakePython $d '3.14.8 False 1 True') } -MessagePattern 'not a GIL build'
            Assert-Throws { Assert-CpythonInterpreter -Exe (New-FakePython $d '3.14.7 False 1 True') -FreeThreaded -ExpectedVersion '3.14.8' } -MessagePattern 'not the pinned 3\.14\.8'
            Assert-Throws { Assert-CpythonInterpreter -Exe (New-FakePython $d '3.14.8 False 1 False') -FreeThreaded } -MessagePattern "lost 'AMD64'"
            Assert-Throws { Assert-CpythonInterpreter -Exe (New-FakePython $d 'ImportError' 1) -FreeThreaded } -MessagePattern 'exit 1'
            Assert-Throws { Assert-CpythonInterpreter -Exe (Join-Path $d 'absent.exe') } -MessagePattern 'missing'
        }
    }
}

Describe 'Install-CpythonFreeThreadedLayout' {

    BeforeAll {
        # The fake PC\layout records its arguments and copies FAKE_LAYOUT_SRC to its --copy target, the 9th argument.
        function script:Invoke-FakeLayout {
            param([string]$Dir, [string[]]$Files, [int]$Exit = 0, [string[]]$GilSitePackages = @())
            $src = Join-Path $Dir 'src'
            foreach ($f in @('PC\layout\main.py', 'PCbuild\freethreaded\amd64\python3.14t.exe', 'Lib\site-packages\README.txt') +
                    @($GilSitePackages | ForEach-Object { "Lib\site-packages\$_" })) {
                New-Item -ItemType File -Force (Join-Path $src $f) | Out-Null
            }
            foreach ($f in $Files) { New-Item -ItemType File -Force (Join-Path $Dir "fixture\$f") | Out-Null }
            $fake = Join-Path $Dir 'python.cmd'
            Set-Content -LiteralPath $fake -Encoding ASCII -Value @('@echo off', 'echo %*> "%FAKE_LAYOUT_ARGS%"',
                "if not `"$Exit`"==`"0`" exit /b $Exit", 'xcopy /e /i /q /y "%FAKE_LAYOUT_SRC%" "%~9" >nul')
            $state = @{ Dest = Join-Path $Dir 'python-freethreaded'; Args = Join-Path $Dir 'args.txt' }
            New-Item -ItemType File -Force (Join-Path $state.Dest 'stale.txt') | Out-Null
            Invoke-WithEnv @{ FAKE_LAYOUT_ARGS = $state.Args; FAKE_LAYOUT_SRC = (Join-Path $Dir 'fixture') } {
                $state.Result = Install-CpythonFreeThreadedLayout -SourceDir $src -Destination $state.Dest -LayoutPython $fake
            }
            return $state
        }
        $script:goodLayout = @('python3.14t.exe', 'python314t.dll', 'libs\python314t.lib', 'include\pyconfig.h', 'Lib\site-packages\README.txt')
    }

    It 'asks PC\layout for the free-threaded dev and venv layout of the t build dir, replacing the old install' {
        Invoke-InTestDir { param($d)
            $s = Invoke-FakeLayout -Dir $d -Files $script:goodLayout
            Assert-Equal $s.Dest $s.Result 'returns the destination'
            $argLine = Get-Content -Raw $s.Args
            foreach ($flag in '--include-freethreaded', '--include-dev', '--include-venv', '--include-stable', 'PCbuild\freethreaded\amd64') {
                Assert-True ($argLine -match [regex]::Escape($flag)) "PC\layout called without $flag"
            }
            Assert-False (Test-Path (Join-Path $s.Dest 'stale.txt')) 'the previous install was removed first'
        }
    }

    It 'refuses a GIL tree that already has packages, a layout with a python.exe or without python3XYt.lib, and a failed PC\layout' {
        Invoke-InTestDir { param($d)
            Assert-Throws { Invoke-FakeLayout -Dir $d -Files $script:goodLayout -GilSitePackages 'pip\__init__.py' } -MessagePattern 'already holds pip'
            Assert-False (Test-Path (Join-Path $d 'args.txt')) 'PC\layout never ran'
        }
        Invoke-InTestDir { param($d)
            Assert-Throws { Invoke-FakeLayout -Dir $d -Files ($script:goodLayout + 'python.exe') } -MessagePattern 'GIL request could resolve'
        }
        Invoke-InTestDir { param($d)
            Assert-Throws { Invoke-FakeLayout -Dir $d -Files @('python3.14t.exe', 'libs\python314.lib') } -MessagePattern 'no python3XYt\.lib'
        }
        Invoke-InTestDir { param($d)
            Assert-Throws { Invoke-FakeLayout -Dir $d -Files $script:goodLayout -Exit 4 } -MessagePattern 'PC\\layout exited 4'
        }
    }

    It 'names a missing free-threaded build directory before running anything' {
        Invoke-InTestDir { param($d)
            New-Item -ItemType File -Force (Join-Path $d 'PC\layout\main.py') | Out-Null
            Assert-Throws { Install-CpythonFreeThreadedLayout -SourceDir $d -Destination (Join-Path $d 'out') -LayoutPython "$PSHOME\pwsh.exe" } `
                -MessagePattern ([regex]::Escape("$(Get-CpythonFreeThreadedBuildDir -SourceDir $d -Arch amd64) is missing"))
            Assert-False (Test-Path (Join-Path $d 'out')) 'nothing was laid out'
        }
    }
}

Describe 'the toolchain stage wires the free-threaded build in' {

    BeforeAll {
        $script:toolchain, $script:dockerfile = foreach ($rel in 'windows\scripts\build\Build-ToolchainAll.ps1', 'windows\Dockerfile.toolchain-builder') {
            [IO.File]::ReadAllText((Join-Path $script:repo $rel))
        }
    }

    It 'builds it before the scrub deletes the externals it reuses, and proves both interpreters after' {
        Assert-Match '(?s)Invoke-CpythonPcbuild -SourceDir \$src\r?\n.*Invoke-CpythonPcbuild -SourceDir \$src -FreeThreaded.*"\$src\\externals".*Assert-CpythonInterpreter -Exe \$pyExe .*Assert-CpythonInterpreter -Exe \(Join-Path \$FreeThreadedRoot \(Get-CpythonFreeThreadedExeName\)\) -FreeThreaded' $script:toolchain
    }

    It 'puts the install on PATH after the GIL tree, at the root the module defaults to' {
        Assert-Match '(?m)^ENV PATH=\$PYTHON_BUILD_BIN;\$PATH;\$PYTHON_FREETHREADED_BIN\s*$' $script:dockerfile
        $baked = [regex]::Match($script:dockerfile, '(?m)^ENV PYTHON_FREETHREADED_BIN="([^"]+)"').Groups[1].Value
        Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = $null } {
            Assert-Equal (Get-CpythonFreeThreadedRoot) $baked 'Dockerfile ENV and module default'
        }
    }
}
