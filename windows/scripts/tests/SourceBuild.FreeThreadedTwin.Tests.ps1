#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The cp3XYt twins' plan, gates, store and wiring; NOT covered: the builds and the venv proof, which need the images (:winamd64, :winarm64 + a device).

# A stand-in file at -Path, its directory created: the plan and the link lookups test presence only.
function script:New-StandInFile([string]$Path) {
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
    Set-Content -LiteralPath $Path -Value 'x'
}

# A free-threaded install stand-in: the two files Get-FreeThreadedTwinPlan requires, nothing that runs.
function script:New-FakeFreeThreadedInstall {
    param([Parameter(Mandatory)][string]$Dir)
    New-StandInFile "$Dir\python3.14t.exe"
    New-StandInFile "$Dir\libs\python314t.lib"
    return $Dir
}

function script:Get-TwinWiringText([string]$Rel) { return [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $Rel)) }

# A wheel at -Path whose members are -Machine PEs: -Member maps a member path to the DLLs it imports.
function script:New-PeTestWheel {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Member = @{}, [uint16]$Machine = 0xAA64)
    $pe = @{}
    foreach ($m in $Member.GetEnumerator()) { $pe[$m.Key] = @{ Machine = $Machine; Import = $m.Value } }
    return New-TestWheel -Path $Path -Member $pe
}

Describe 'Free-threaded twin store and ABI tag' {

    It 'stores apart from PYTHON_WHEELS: PYTHON_WHEELS_CP314T, else C:\runtime\wheels-cp314t' {
        Invoke-WithEnv @{ PYTHON_WHEELS_CP314T = 'X:\ft' } { Assert-Equal 'X:\ft' (Get-FreeThreadedWheelStore) 'the image ENV' }
        Invoke-WithEnv @{ PYTHON_WHEELS_CP314T = $null } { Assert-Equal 'C:\runtime\wheels-cp314t' (Get-FreeThreadedWheelStore) 'the default' }
    }

    It 'derives the cp3XYt tag from PYTHON_VERSION, 3.14 when unset' {
        Assert-Equal 'cp314t' (Get-FreeThreadedAbiTag -Version '3.14.8')
        Assert-Equal 'cp315t' (Get-FreeThreadedAbiTag -Version '3.15.0')
        Invoke-WithEnv @{ PYTHON_VERSION = $null } { Assert-Equal 'cp314t' (Get-FreeThreadedAbiTag) 'unset' }
    }

    It 'never stages a cp3XYt wheel into the GIL store, which still takes its own wheels (mutation)' {
        Invoke-InTestDir { param($d)
            $null = New-Item -ItemType Directory -Force -Path "$d\dist"
            Set-Content -LiteralPath "$d\dist\pkg-1.0-cp314-cp314t-win_amd64.whl" -Value 'w'
            Assert-Throws { Save-PythonWheel -SourceDir "$d\dist" -WheelDir "$d\store" } -MessagePattern 'is free-threaded and never goes into'
            Assert-False (Test-Path "$d\store\pkg-1.0-cp314-cp314t-win_amd64.whl") 'nothing copied'
            Remove-Item "$d\dist\*.whl"
            Set-Content -LiteralPath "$d\dist\pkg-1.0-cp314-cp314-win_amd64.whl" -Value 'w'
            Assert-Equal "$d\store\pkg-1.0-cp314-cp314-win_amd64.whl" "$(Save-PythonWheel -SourceDir "$d\dist" -WheelDir "$d\store")" 'a GIL wheel still stages'
        }
    }
}

Describe 'Get-FreeThreadedTwinPlan' {

    It 'builds a twin when the image has the free-threaded install, and says why' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = (New-FakeFreeThreadedInstall "$d\ft"); PYTHON_VERSION = '3.14.8'; WINDOWS_TARGET_ARCH = 'amd64' } {
                $plan = Get-FreeThreadedTwinPlan -Distribution 'av'
                Assert-True $plan.Build
                Assert-Match '^free-threaded: building the cp314t twin of av \(setup\.py: compiler directive' $plan.Reason
            }
        }
    }

    It 'skips GIL-only and twin-less distributions; throws for an unknown one or a missing interpreter (mutation)' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = "$d\absent"; PYTHON_VERSION = '3.14.8'; WINDOWS_TARGET_ARCH = 'amd64' } {
                $gil = Get-FreeThreadedTwinPlan -Distribution 'onnxruntime_genai_directml'
                Assert-False $gil.Build
                Assert-Match '^free-threaded: no cp314t twin of onnxruntime_genai_directml: gil, pybind11 2\.13\.6' $gil.Reason
                Assert-Match 'none, pyproject\.toml: wheel\.py-api = "py3"' (Get-FreeThreadedTwinPlan -Distribution 'apache-tvm').Reason
                Assert-Throws { Get-FreeThreadedTwinPlan -Distribution 'onnxruntime' } -MessagePattern 'needs a cp314t twin, and this image has no .*python3\.14t\.exe to build it with'
                Assert-Throws { Get-FreeThreadedTwinPlan -Distribution 'numpy' } -MessagePattern 'numpy is not in Get-FreeThreadedTwinTable'
            }
        }
    }

    It 'a cross lane builds the twin with the host interpreter and the target''s python3XYt.lib; no target CPython skips it (mutation)' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = (New-FakeFreeThreadedInstall "$d\ft"); PYTHON_VERSION = '3.14.8'; WINDOWS_TARGET_ARCH = 'arm64'; TEMP_DIR = $d } {
                $none = Get-FreeThreadedTwinPlan -Distribution 'onnxruntime' -TargetFreeThreadedRoot "$d\tgt"
                Assert-False $none.Build 'no target CPython, no GIL wheel, no twin'
                Assert-Match 'the arm64 cross build has no target CPython, so it builds no GIL wheel either' $none.Reason
                New-StandInFile "$d\cpython\PCbuild\arm64\python314.lib"
                Assert-Throws { Get-FreeThreadedTwinPlan -Distribution 'av' -TargetFreeThreadedRoot "$d\tgt" } `
                    -MessagePattern 'av needs a cp314t twin, and this image has no .*tgt\\libs\\python3t\.lib to build it with'
                New-StandInFile "$d\tgt\libs\python314t.lib"
                $plan = Get-FreeThreadedTwinPlan -Distribution 'av' -TargetFreeThreadedRoot "$d\tgt"
                Assert-True $plan.Build
                Assert-Match '^free-threaded: building the cp314t twin of av for win_arm64 \(setup\.py' $plan.Reason
                Remove-Item -LiteralPath "$d\ft\python3.14t.exe"
                Assert-Throws { Get-FreeThreadedTwinPlan -Distribution 'av' -TargetFreeThreadedRoot "$d\tgt" } -MessagePattern 'no .*ft\\python3\.14t\.exe to build it with'
            }
        }
    }
}

Describe 'Free-threaded build interpreters' {

    It 'Get-TargetBuildPython -FreeThreaded: the host install natively, the target tree''s python3XYt.lib on cross' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = (New-FakeFreeThreadedInstall "$d\ft"); PYTHON_VERSION = '3.14.8'; WINDOWS_TARGET_ARCH = 'amd64' } {
                $native = Get-TargetBuildPython -FreeThreaded
                Assert-Equal "$d\ft\python3.14t.exe|$d\ft\libs\python314t.lib|True" "$($native.Exe)|$($native.Lib)|$($native.Available)"
            }
            Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = "$d\ft"; PYTHON_VERSION = '3.14.8'; WINDOWS_TARGET_ARCH = 'arm64' } {
                $missing = Get-TargetBuildPython -FreeThreaded -TargetFreeThreadedRoot "$d\tgt"
                Assert-False $missing.Available 'no target tree staged'
                New-StandInFile "$d\tgt\libs\python314t.lib"
                $cross = Get-TargetBuildPython -FreeThreaded -TargetFreeThreadedRoot "$d\tgt"
                Assert-Equal "$d\ft\python3.14t.exe|$d\tgt\libs\python314t.lib|True" "$($cross.Exe)|$($cross.Lib)|$($cross.Available)" 'host runs, target links'
            }
        }
    }

    It 'Invoke-PythonWheelBuild -FreeThreaded refuses a GIL interpreter and a missing -Distribution before building (mutation)' {
        Assert-Throws { Invoke-PythonWheelBuild -Python @{ Exe = 'C:\x\python.exe' } -WorkingDir 'C:\x' -Arguments 'setup.py bdist_wheel' -ModuleName 'av' -FreeThreaded -Distribution 'av' } `
            -MessagePattern 'needs New-FreeThreadedBuildPython''s interpreter'
        Assert-Throws { Invoke-PythonWheelBuild -Python @{ Exe = 'C:\x\python.exe'; FreeThreaded = $true } -WorkingDir 'C:\x' -Arguments 'setup.py bdist_wheel' -ModuleName 'av' -FreeThreaded } `
            -MessagePattern 'needs -Distribution'
    }

    It 'Save-FreeThreadedWheel stops a GIL-tagged wheel at the tag gate, before any venv or store (mutation)' {
        Invoke-InTestDir { param($d)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $w = "$d\av-19.0.1-cp314-cp314-win_amd64.whl"
            [System.IO.Compression.ZipFile]::Open($w, 'Create').Dispose()
            Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = 'amd64' } {
                Assert-Throws { Save-FreeThreadedWheel -Wheel $w -Distribution 'av' -Store "$d\store" } -MessagePattern 'fails the cp3XYt tag gate:\s+.*tagged cp314-cp314'
            }
            Assert-False (Test-Path "$d\store") 'nothing stored'
        }
    }

    It 'Assert-NinjaFreeThreadedDefine counts Py_GIL_DISABLED=1 compile lines and throws on none (mutation)' {
        Invoke-InTestDir { param($d)
            Set-Content -LiteralPath "$d\build.ninja" -Value @('build a.obj: CXX a.cc', '  DEFINES = -DNDEBUG -DPy_GIL_DISABLED=1 -DX', '  DEFINES = /DPy_GIL_DISABLED=1')
            Assert-Equal 2 (Assert-NinjaFreeThreadedDefine -BuildDir $d -Label 'test')
            Set-Content -LiteralPath "$d\build.ninja" -Value @('  DEFINES = -DNDEBUG -DPy_GIL_DISABLED=10', '  # Py_GIL_DISABLED=1')
            Assert-Throws { Assert-NinjaFreeThreadedDefine -BuildDir $d -Label 'test' } -MessagePattern 'no line of .* defines Py_GIL_DISABLED=1'
        }
    }

    It 'Invoke-CmakeConfigure -Settle configures twice, and never after a failed first configure (mutation)' {
        Invoke-InTestDir { param($d)
            $bin = New-Item -ItemType Directory -Force -Path "$d\bin"
            @('@echo off', 'echo %*>> "%WBT_CMAKE_LOG%"', 'exit /b %WBT_CMAKE_RC%') -join "`r`n" | Set-Content -LiteralPath "$bin\cmake.bat" -Encoding ASCII
            Invoke-WithEnv @{ PATH = "$bin;$env:PATH"; WBT_CMAKE_LOG = "$d\cmake.log"; WBT_CMAKE_RC = '0'; WINDOWS_TARGET_ARCH = 'amd64' } {
                $null = Invoke-CmakeConfigure -SourceDir $d -BuildDir "$d\b" -InstallPrefix "$d\p" -Settle
                Assert-Equal 2 @(Get-Content "$d\cmake.log").Count 'the settling second run'
                Remove-Item "$d\cmake.log"
                $null = Invoke-CmakeConfigure -SourceDir $d -BuildDir "$d\b" -InstallPrefix "$d\p"
                Assert-Equal 1 @(Get-Content "$d\cmake.log").Count 'without -Settle, one run'
                Remove-Item "$d\cmake.log"
                $env:WBT_CMAKE_RC = '1'
                Assert-Throws { Invoke-CmakeConfigure -SourceDir $d -BuildDir "$d\b" -InstallPrefix "$d\p" -Settle } -MessagePattern 'CMake configuration failed'
                Assert-Equal 1 @(Get-Content "$d\cmake.log").Count 'a failed configure is not repeated'
            }
        }
    }

    It 'ORT''s twin keeps the GIL interpreter in custom commands only, so no DLL relinks (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-OnnxFromSource.ps1' -FunctionName 'Set-OrtNinjaCommandPython')
        Invoke-InTestDir { param($d)
            $ninja = "$d\build.ninja"
            Set-Content -LiteralPath $ninja -Value @(
                'build onnxruntime_dll.def: CUSTOM_COMMAND x', '  COMMAND = cmd.exe /C "cd /D C:\b && C:\ft\Scripts\python.exe C:/s/gen_def.py"',
                'build a.obj: CXX a.cc', '  INCLUDES = -IC:\ft\Scripts\python.exe-is-not-a-command -IC:/python-freethreaded/include')
            Assert-Equal 1 (Set-OrtNinjaCommandPython -NinjaFile $ninja -From 'C:\ft\Scripts\python.exe' -To 'C:\gil\python.exe')
            $text = Get-Content -Raw $ninja
            Assert-Match ([regex]::Escape('&& C:\gil\python.exe C:/s/gen_def.py')) $text 'the custom command'
            Assert-Match ([regex]::Escape('-IC:\ft\Scripts\python.exe-is-not-a-command')) $text 'compile lines untouched'
        }
    }

    It 'the DLL homes the twins'' proof registers are the shim''s, one list (mutation)' {
        $homes = @(Get-PythonDllHome -OpenCvArchDir 'x64')
        Assert-Equal 7 $homes.Count ($homes -join ', ')
        Assert-Equal 'C:\runtime\lib\opencv5\x64\vc18\bin' $homes[0] 'the OpenCV arch dir is substituted'
        Invoke-InTestDir { param($d)
            $shim = [System.IO.File]::ReadAllText((Write-PythonDllDirectoryShim -SitePackages $d -OpenCvArchDir 'x64'))
            foreach ($h in $homes) { Assert-Match ([regex]::Escape("r'$h',")) $shim $h }
            Assert-Match '_dirs \+= \[\s+r''C:\\runtime\\lib\\opencv5' $shim 'inside the list'
        }
    }
}

Describe 'Free-threaded cross twins (arm64): static gates, the venv pin and the store' {

    It 'Get-FreeThreadedWheelImportFinding passes python3XYt.dll modules only, beside a .pyd that imports no runtime (mutation)' {
        Invoke-InTestDir { param($d)
            $good = New-PeTestWheel -Path "$d\good\av-1.0-cp314-cp314t-win_arm64.whl" -Member @{
                'av\_core.cp314t-win_arm64.pyd' = @('python314t.dll', 'kernel32.dll'); 'av\helper.pyd' = @('kernel32.dll'); 'av\avcodec.dll' = @('python314.dll') }
            Assert-Equal '' "$(Get-FreeThreadedWheelImportFinding -Path $good -AbiTag 'cp314t')" 'a DLL is no module; only .pyd imports count'
            $gil = New-PeTestWheel -Path "$d\gil\onnxruntime-1.0-cp314-cp314t-win_arm64.whl" -Member @{
                'onnxruntime\capi\onnxruntime_pybind11_state.pyd' = @('python314.dll'); 'onnxruntime\capi\stable.pyd' = @('python3.dll') }
            $f = @(Get-FreeThreadedWheelImportFinding -Path $gil -AbiTag 'cp314t')
            Assert-Equal 3 $f.Count ($f -join ' | ')
            Assert-Match 'onnxruntime_pybind11_state\.pyd imports python314\.dll, not python314t\.dll' ($f -join "`n") 'the GIL runtime'
            Assert-Match 'stable\.pyd imports python3\.dll, not python314t\.dll' ($f -join "`n") 'the stable-ABI stub'
            Assert-Match 'no module of onnxruntime-1\.0-cp314-cp314t-win_arm64\.whl imports python314t\.dll' ($f -join "`n") 'none imports the free-threaded one'
        }
    }

    It 'Save-FreeThreadedWheel stores a cross twin on tags, imports and PE machine, with no proof here; any one of them stops it (mutation)' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = 'arm64'; PYTHON_VERSION = '3.14.8'; PYTHON_FREETHREADED_BIN = "$d\absent" } {
                $ok = New-PeTestWheel -Path "$d\a\av-1.0-cp314-cp314t-win_arm64.whl" -Member @{ 'av\_core.cp314t-win_arm64.pyd' = @('python314t.dll') }
                Assert-Equal "$d\store\av-1.0-cp314-cp314t-win_arm64.whl" (Save-FreeThreadedWheel -Wheel $ok -Distribution 'av' -Store "$d\store") 'stored without an interpreter'
                $x64 = New-PeTestWheel -Path "$d\b\av-1.0-cp314-cp314t-win_arm64.whl" -Member @{ 'av\_core.cp314t-win_arm64.pyd' = @('python314t.dll') } -Machine 0x8664
                Assert-Throws { Save-FreeThreadedWheel -Wheel $x64 -Distribution 'av' -Store "$d\store2" } -MessagePattern 'machine 0x8664, expected 0xAA64'
                $gil = New-PeTestWheel -Path "$d\c\av-1.0-cp314-cp314t-win_arm64.whl" -Member @{ 'av\_core.pyd' = @('python314.dll') }
                Assert-Throws { Save-FreeThreadedWheel -Wheel $gil -Distribution 'av' -Store "$d\store2" } -MessagePattern 'fails the cp3XYt import gate:\s+av[/\\]_core\.pyd imports python314\.dll'
                $hostTagged = New-PeTestWheel -Path "$d\e\av-1.0-cp314-cp314t-win_amd64.whl" -Member @{ 'av\_core.cp314t-win_amd64.pyd' = @('python314t.dll') }
                Assert-Throws { Save-FreeThreadedWheel -Wheel $hostTagged -Distribution 'av' -Store "$d\store2" } -MessagePattern 'is a win_amd64 wheel, not win_arm64'
                Assert-False (Test-Path "$d\store2") 'nothing refused reached a store'
            }
        }
    }

    It 'Invoke-PythonWheelBuild -FreeThreaded names bdist_wheel''s platform on a cross lane (mutation)' {
        Invoke-InTestDir { param($d)
            # A build interpreter stand-in: records its arguments and leaves the one twin a build would.
            $twin = New-PeTestWheel -Path "$d\made\m-1.0-cp314-cp314t-win_arm64.whl" -Member @{ 'm.cp314t-win_arm64.pyd' = @('python314t.dll') }
            Set-Content -LiteralPath "$d\py.cmd" -Encoding ascii -Value @('@echo %*> "%~dp0args.txt"', "@copy /y ""$twin"" ""%~dp0dist\"" >nul")
            $null = New-Item -ItemType Directory -Force -Path "$d\dist"
            Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = 'arm64'; PYTHON_VERSION = '3.14.8'; PYTHON_WHEELS_CP314T = "$d\store" } {
                $stored = Invoke-PythonWheelBuild -Python @{ Exe = "$d\py.cmd"; FreeThreaded = $true } -WorkingDir $d -Arguments 'setup.py bdist_wheel' `
                    -ModuleName 'm' -FreeThreaded -Distribution 'm' -DistDir "$d\dist"
                Assert-Equal 'setup.py bdist_wheel --plat-name win_arm64' "$(Get-Content "$d\args.txt")".Trim() 'the target tag, added once'
                Assert-Equal "$d\store\m-1.0-cp314-cp314t-win_arm64.whl" "$stored" 'gated and stored apart'
            }
        }
    }

    It 'the cross build venv''s shim names a free-threaded module .cp3XYt-<tag>.pyd and a GIL one .cp3XY-<tag>.pyd (mutation)' {
        Invoke-InTestDir { param($d)
            $shim = [System.IO.File]::ReadAllText((Write-PythonDllDirectoryShim -SitePackages $d -OpenCvArchDir 'arm64' -CrossExtTag 'win_arm64'))
            Assert-Match ([regex]::Escape("_abi = 't' if sysconfig.get_config_var('Py_GIL_DISABLED') else ''")) $shim 'the free-threaded build keeps its t'
            Assert-Match ([regex]::Escape("_ext = '.cp%d%d%s-%s.pyd' % (sys.version_info[0], sys.version_info[1], _abi, _target_tag)")) $shim 'one formula for both'
            Assert-Match "_target_tag = 'win_arm64'" $shim 'the target tag'
        }
    }

    It 'Get-FreeThreadedStoreFinding: every twin-verdict GIL wheel has one tag-clean twin of its version, and nothing else is there (mutation)' {
        Invoke-InTestDir { param($d)
            $gil = "$d\wheels"; $ft = "$d\wheels-cp314t"
            foreach ($n in 'onnxruntime-1.30.0-cp314-cp314-win_arm64', 'av-19.0.1-cp314-cp314-win_arm64', 'apache_tvm_ffi-0.1.13-cp314-cp314-win_arm64',
                'iree_base_runtime-3.12.0-cp312-abi3-win_arm64', 'apache_tvm-0.27.0-py3-none-win_arm64', 'onnxruntime_genai_directml-0.17.0-cp314-cp314-win_arm64', 'numpy-2.5.3-cp314-cp314-win_arm64') {
                [void](New-PeTestWheel -Path "$gil\$n.whl")
            }
            foreach ($n in 'onnxruntime-1.30.0', 'av-19.0.1', 'apache_tvm_ffi-0.1.13', 'iree_base_runtime-3.12.0') { [void](New-PeTestWheel -Path "$ft\$n-cp314-cp314t-win_arm64.whl") }
            Assert-Equal '' "$(Get-FreeThreadedStoreFinding -Store $ft -GilStore $gil -PlatformTag 'win_arm64')" 'the cross store mirrors the GIL store'
            Remove-Item "$ft\av-19.0.1-cp314-cp314t-win_arm64.whl"
            [void](New-PeTestWheel -Path "$ft\av-19.0.0-cp314-cp314t-win_arm64.whl")
            [void](New-PeTestWheel -Path "$ft\numpy-2.5.3-cp314-cp314t-win_arm64.whl")
            [void](New-PeTestWheel -Path "$gil\pkg-1.0-cp314-cp314t-win_arm64.whl")
            Remove-Item "$ft\iree_base_runtime-3.12.0-cp314-cp314t-win_arm64.whl"
            [void](New-PeTestWheel -Path "$ft\iree_base_compiler-3.12.0-cp314-cp314t-win_arm64.whl")
            [void](New-PeTestWheel -Path "$ft\onnxruntime-1.30.0-cp314-cp314t-win_amd64.whl")
            $f = @(Get-FreeThreadedStoreFinding -Store $ft -GilStore $gil -PlatformTag 'win_arm64') -join "`n"
            foreach ($want in 'av-19\.0\.0-cp314-cp314t-win_arm64\.whl is version 19\.0\.0, its GIL wheel av-19\.0\.1-cp314-cp314-win_arm64\.whl 19\.0\.1',
                'numpy-2\.5\.3-cp314-cp314t-win_arm64\.whl is in .*, but Get-FreeThreadedTwinTable gives numpy no twin',
                'pkg-1\.0-cp314-cp314t-win_arm64\.whl is free-threaded and sits in the GIL store',
                'iree_base_runtime-3\.12\.0-cp312-abi3-win_arm64\.whl has no cp3XYt twin',
                'iree_base_compiler-3\.12\.0-cp314-cp314t-win_arm64\.whl has no GIL wheel in .* to pair with',
                'onnxruntime has 2 twins in', 'onnxruntime-1\.30\.0-cp314-cp314t-win_amd64\.whl is a win_amd64 wheel, not win_arm64') {
                Assert-Match $want $f $want
            }
        }
    }
}

Describe 'Free-threaded twin wiring' {

    It 'each twin build asks the plan for its distribution and stores through Invoke-PythonWheelBuild -FreeThreaded (mutation)' {
        $twinCall = @{
            'Build-OnnxFromSource.ps1' = "Get-FreeThreadedTwinPlan -Distribution 'onnxruntime'"
            'Build-FfmpegFromSource.ps1' = "Invoke-FreeThreadedTwinWheel -GilPython \`$py -Distribution 'av'"
            'Build-TvmFromSource.ps1' = "Invoke-FreeThreadedTwinWheel -GilPython \`$py -Distribution 'apache-tvm-ffi'"
            'Build-IreeFromSource.ps1' = "Dist = 'iree-base-compiler'.*Dist = 'iree-base-runtime'"
        }
        foreach ($script in $twinCall.Keys) {
            Assert-Match $twinCall[$script] (Get-TwinWiringText "windows\scripts\build\$script") "$script builds its twin"
        }
        foreach ($script in 'Build-OnnxFromSource.ps1', 'Build-IreeFromSource.ps1') {
            Assert-Match '-FreeThreaded -Distribution' (Get-TwinWiringText "windows\scripts\build\$script") "$script stores through the twin path"
        }
        Assert-Match "-notin \`$pythonArgs" (Get-TwinWiringText 'windows\scripts\build\Build-OnnxFromSource.ps1') 'ORT reconfigures with its GIL args minus the GIL interpreter'
        Assert-Match 'Get-WheelMemberDifference -Reference \$GilWheel' (Get-TwinWiringText 'windows\scripts\build\Build-OnnxFromSource.ps1') 'ORT proves one build'
        Assert-Match 'IREE_ENABLE_PYTHON_STABLE_ABI=OFF' (Get-TwinWiringText 'windows\scripts\build\Build-IreeFromSource.ps1') 'IREE turns abi3 off'
    }

    It 'the arm64 cross paths build their twins too: the target lib, the lane''s ninja edits, --plat-name (mutation)' {
        $ffmpeg = Get-TwinWiringText 'windows\scripts\build\Build-FfmpegFromSource.ps1'
        Assert-Match 'build_ext --plat-name \$distutilsPlat -L ""\$\(\(Get-TargetBuildPython -FreeThreaded\)\.LibDir\)"" bdist_wheel --plat-name' $ffmpeg 'PyAV links the target python3XYt.lib first'
        Assert-Match '-Arguments \$pyavTwinCmd' $ffmpeg 'and builds with that command'
        $ort = Get-TwinWiringText 'windows\scripts\build\Build-OnnxFromSource.ps1'
        Assert-Match 'Update-OrtNinjaFile -BuildDir \$BuildDir -SourceDir \$SourceDir -Cross \$Cross' $ort 'the twin re-applies the lane''s MLAS flags'
        Assert-Match '-InstallPrefix \$ortInstallDir -Cross \$onnxCross\)' $ort 'and is told the lane'
        $tvm = Get-TwinWiringText 'windows\scripts\build\Build-TvmFromSource.ps1'
        Assert-Match "Get-FreeThreadedTwinPlan -Distribution 'apache-tvm-ffi'" $tvm 'the cross tvm-ffi twin asks the plan'
        Assert-Match '(?s)New-TvmFfiCrossWheel -Python \$ftPy .*?-AbiTag \$ftAbi' $tvm 'one assembly for both wheels, the twin tagged cp3XYt'
        Assert-Match "Save-FreeThreadedWheel -Wheel \`$twin -Distribution 'apache-tvm-ffi'" $tvm 'gated and stored apart'
        Assert-Match "Name 'apache-tvm' .*-PythonTag 'py3' -AbiTag 'none'" $tvm 'apache-tvm is py3-none, which a 3.14t venv installs'
        Assert-Match "if \(\`$Python\['FreeThreaded'\]\) \{ \[void\]\(Assert-NinjaFreeThreadedDefine" $tvm 'the twin core compiles with Py_GIL_DISABLED'
        $iree = Get-TwinWiringText 'windows\scripts\build\Build-IreeFromSource.ps1'
        Assert-Match "if \(\`$ireeCross -and \`$pkg\.Dir -eq 'compiler'\) \{ continue \}" $iree 'cross twins the runtime only'
        Assert-Equal 2 ([regex]::Matches($iree, 'Update-IreeCrossNinjaFile -BuildDir \$(build|Build)Dir')).Count 'the GIL configure and the twin''s both get the ukernel flags'
        Assert-Match "packArgs = if \(\`$Cross\) \{ `"setup\.py bdist_wheel -d" $iree 'setup.py packs for --plat-name, as the GIL cross wheel does'
        Assert-Match '-InstallDir \$ireeInstallDir -Cross:\$ireeCross' $iree 'the twin is told the lane'
        $manifestRun = 'source=windows/scripts/build/Write-BundleManifest\.ps1,target=C:\\bkmnt\\Write-BundleManifest\.ps1 `\s+--mount=type=bind,source=linux/scripts/03-media/free-threaded-twins\.txt,target=C:\\bkmnt\\free-threaded-twins\.txt'
        Assert-Match $manifestRun (Get-TwinWiringText 'windows\Dockerfile.media-merge-builder') 'the cross manifest reads the twin table'
    }

    It 'the media stages mount the module, the helper and the twin table, the merge names and COPYs the store, the image bakes both files (mutation)' {
        $media = Get-TwinWiringText 'windows\Dockerfile.media-builder'
        $mount = 'source=linux/scripts/02-toolchain/python/free-threaded-wheel.py,target=C:\bkmnt\free-threaded-wheel.py'
        Assert-Equal 3 ([regex]::Matches($media, [regex]::Escape($mount))).Count 'ONNX, FFmpeg and media-tvm RUNs'
        $table = 'source=linux/scripts/03-media/free-threaded-twins.txt,target=C:\bkmnt\free-threaded-twins.txt'
        Assert-Equal 3 ([regex]::Matches($media, [regex]::Escape($table))).Count 'the twin table in the same three RUNs, one level above modules\'
        Assert-Match 'WindowsPythonWheel\.Common\.psm1 `\s+C:\\bkmods\\' $media 'media buildmods carries the module'
        $merge = Get-TwinWiringText 'windows\Dockerfile.media-merge-builder'
        Assert-Match 'PYTHON_WHEELS_CP314T="C:\\runtime\\wheels-cp314t"' $merge 'the image ENV'
        Assert-Match 'COPY --from=media-tvm C:\\runtime\\wheels-cp314t C:\\runtime\\wheels-cp314t' $merge 'the media-tvm fan-in'
        Assert-Match 'New-Item -Path \(Get-FreeThreadedWheelStore\)' (Get-TwinWiringText 'windows\scripts\build\Build-MediaTvmAll.ps1') 'media-tvm creates it on every lane'
        Assert-Match 'free-threaded-wheel\.py linux\\scripts\\03-media\\free-threaded-twins\.txt C:\\temp\\scripts\\' (Get-TwinWiringText 'windows\Dockerfile') 'the final image bakes the helper and the table'
        $smoke = Get-TwinWiringText 'windows\scripts\build\Test-Container.ps1'
        Assert-Match 'Get-FreeThreadedTwinTable -Path \$ftTable' $smoke 'section 20 reads the image''s own table, as the gate mounts windows/scripts alone'
        Assert-Match "'PYTHON_WHEELS', 'PYTHON_WHEELS_CP314T'" $smoke 'section 19 checks the pointer'
        Assert-Match 'Invoke-FreeThreadedWheelVenvProof' $smoke 'section 20 proves every twin again'
    }
}

Describe 'IREE v3.12.0 on clang-cl (found proving the runtime twin)' {

    It 'links the target''s compiler-rt builtins beside clang-cl, and refuses to build without them (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-IreeFromSource.ps1' -FunctionName 'Get-IreeCompilerRtCmakeArgs')
        Invoke-InTestDir { param($d)
            $bin = New-Item -ItemType Directory -Force -Path "$d\llvm\bin"
            Set-Content -LiteralPath "$bin\clang-cl.bat" -Value '@exit /b 0'
            $rt = New-Item -ItemType Directory -Force -Path "$d\llvm\lib\clang\23\lib\windows"
            Set-Content -LiteralPath "$rt\clang_rt.builtins-x86_64.lib" -Value 'x'
            Invoke-WithEnv @{ PATH = "$bin;$env:PATH" } {
                $want = ("$rt\clang_rt.builtins-x86_64.lib" -replace '\\', '/')
                $flags = @(Get-IreeCompilerRtCmakeArgs -Arch 'amd64')
                Assert-Equal "-DCMAKE_EXE_LINKER_FLAGS=$want|-DCMAKE_SHARED_LINKER_FLAGS=$want|-DCMAKE_MODULE_LINKER_FLAGS=$want" ($flags -join '|')
                Assert-Throws { Get-IreeCompilerRtCmakeArgs -Arch 'arm64' } -MessagePattern 'no clang_rt\.builtins-aarch64\.lib beside .*__udivti3'
            }
        }
    }

    It 'the twin re-configure points both FindPythons at the venv, turns abi3 off and drops nanobind''s cached GIL suffix (mutation)' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-IreeFromSource.ps1' -FunctionName 'Get-IreeFreeThreadedCmakeArgs')
        $ft = @{ Exe = 'C:\v\Scripts\python.exe'; Include = 'C:\python-freethreaded\include'; Lib = 'C:\python-freethreaded\libs\python314t.lib' }
        # The cross GIL pass names every artifact for both prefixes; none of them may outlive the twin's own.
        $gilHints = @('-DPython3_EXECUTABLE=C:/gil/python.exe', '-DPython3_LIBRARY=C:/temp/cpython/PCbuild/arm64/python314.lib',
            '-DPython_INCLUDE_DIR=C:/temp/cpython/Include', '-DPython3_NumPy_INCLUDE_DIR=C:/gil/np')
        $a = @(Get-IreeFreeThreadedCmakeArgs -CmakeExtra (@('-DIREE_BUILD_COMPILER=ON') + $gilHints) -Python $ft -NumPyIncludeDir 'C:\v\np')
        foreach ($gone in $gilHints) { Assert-False ($a -contains $gone) "$gone is gone" }
        foreach ($want in '-DIREE_BUILD_COMPILER=ON', '-DPython3_EXECUTABLE=C:/v/Scripts/python.exe', '-DPython_LIBRARY=C:/python-freethreaded/libs/python314t.lib',
            '-DIREE_ENABLE_PYTHON_STABLE_ABI=OFF', '-DMLIR_ENABLE_PYTHON_STABLE_ABI=OFF', '-UNB_SUFFIX', '-UNB_SUFFIX_S') {
            Assert-True ($a -contains $want) "$want in [$($a -join ' ')]"
        }
    }

    It 'runs the VM ISA genrules with the configured Python, as no Windows image has python3 (mutation)' {
        $iree = Get-TwinWiringText 'windows\scripts\build\Build-IreeFromSource.ps1'
        Assert-Match ([regex]::Escape("-Pattern '`"python3 \`$\(rootpath'")) $iree 'the bare python3 genrule command'
        Assert-Match ([regex]::Escape("-Replacement '`"`$`${Python3_EXECUTABLE} `$`$(rootpath'")) $iree 'becomes the configured interpreter'
        Assert-Match 'Get-IreeCompilerRtCmakeArgs -Arch \(Get-WindowsHostArch\)' $iree 'host tools link the host builtins'
        Assert-Match 'Get-IreeCompilerRtCmakeArgs -Arch \(Get-WindowsTargetArch\)' $iree 'the target build links the target''s'
    }
}
