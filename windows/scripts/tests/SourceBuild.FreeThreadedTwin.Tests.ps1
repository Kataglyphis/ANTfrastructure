#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The cp3XYt twins' plan, store and wiring; NOT covered: the builds and the venv proof, which need the image (proved in :winamd64).

# A free-threaded install stand-in: the two files Get-FreeThreadedTwinPlan requires, nothing that runs.
function script:New-FakeFreeThreadedInstall {
    param([Parameter(Mandatory)][string]$Dir)
    $null = New-Item -ItemType Directory -Force -Path "$Dir\libs"
    Set-Content -LiteralPath "$Dir\python3.14t.exe" -Value 'x'
    Set-Content -LiteralPath "$Dir\libs\python314t.lib" -Value 'x'
    return $Dir
}

function script:Get-TwinWiringText([string]$Rel) { return [System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $Rel)) }

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

    It 'skips GIL-only and twin-less distributions and the cross lanes; throws for an unknown one or a missing interpreter (mutation)' {
        Invoke-InTestDir { param($d)
            Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = "$d\absent"; PYTHON_VERSION = '3.14.8'; WINDOWS_TARGET_ARCH = 'amd64' } {
                $gil = Get-FreeThreadedTwinPlan -Distribution 'onnxruntime_genai_directml'
                Assert-False $gil.Build
                Assert-Match '^free-threaded: no cp314t twin of onnxruntime_genai_directml: gil, pybind11 2\.13\.6' $gil.Reason
                Assert-Match 'none, pyproject\.toml: wheel\.py-api = "py3"' (Get-FreeThreadedTwinPlan -Distribution 'apache-tvm').Reason
                Assert-Throws { Get-FreeThreadedTwinPlan -Distribution 'onnxruntime' } -MessagePattern 'needs a cp314t twin, and this image has no .*python3\.14t\.exe to build it with'
                Assert-Throws { Get-FreeThreadedTwinPlan -Distribution 'numpy' } -MessagePattern 'numpy is not in Get-FreeThreadedTwinTable'
            }
            Invoke-WithEnv @{ PYTHON_FREETHREADED_BIN = (New-FakeFreeThreadedInstall "$d\ft"); PYTHON_VERSION = '3.14.8'; WINDOWS_TARGET_ARCH = 'arm64' } {
                $cross = Get-FreeThreadedTwinPlan -Distribution 'onnxruntime'
                Assert-False $cross.Build 'no twin on a cross lane yet'
                Assert-Match 'the arm64 cross build makes none yet' $cross.Reason
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
                $null = New-Item -ItemType Directory -Force -Path "$d\tgt\libs"
                Set-Content -LiteralPath "$d\tgt\libs\python314t.lib" -Value 'x'
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
        $a = @(Get-IreeFreeThreadedCmakeArgs -CmakeExtra @('-DIREE_BUILD_COMPILER=ON', '-DPython3_EXECUTABLE=C:/gil/python.exe') -Python $ft -NumPyIncludeDir 'C:\v\np')
        Assert-False ($a -contains '-DPython3_EXECUTABLE=C:/gil/python.exe') 'the GIL interpreter is gone'
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
