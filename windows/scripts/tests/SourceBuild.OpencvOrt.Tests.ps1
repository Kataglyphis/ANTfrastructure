#requires -Version 7.0
# OpenCV on the chain's ONNX Runtime, every lane: the -D set, the nested-header shim, the configure gate, the G-API hook.
# NOT covered: a real configure/build, the upstream FindONNX/dnn/gapi CMake itself, any DirectML or GPU run.

$script:OrtOcvScript = 'windows\scripts\build\Build-OpencvFromSource.ps1'
$script:OrtOcvHooks = 'windows\scripts\patches\opencv\cmake-hooks'
$script:OrtChain = 'C:/runtime/lib/onnxruntime-source'
$script:OrtShim = 'C:/temp/opencv-src/ort-nested'
$script:OrtVer = '1.30.0'
$script:OrtDelayLoads = @('dxcore.dll', 'd3d12.dll', 'dxgi.dll', 'DirectML.dll')

# The ORT part of a configure log after this change, in the teed opencv-configure.log shape.
$script:OrtCfgLog = @'
-- Registering hook 'POST_CREATE_MODULE_LIBRARY_opencv_gapi': C:/bkmnt/patches/opencv/cmake-hooks/POST_CREATE_MODULE_LIBRARY_opencv_gapi.cmake
-- DNN: ONNX Runtime enabled
-- antfrastructure hook: opencv_gapi delay-loads dxcore.dll d3d12.dll dxgi.dll DirectML.dll
--
--   OpenCL:                        YES (SVM NVD3D11)
--     Include path:                C:/temp/opencv-src/opencv/3rdparty/include/opencl/1.2
--     Link libraries:              Dynamic load
--
--   ONNX Runtime:                  YES (ver 1.30.0)
--     Include path:                C:/temp/opencv-src/ort-nested/include/onnxruntime/core/session
--     Link libraries:              C:/runtime/lib/onnxruntime-source/lib/onnxruntime.lib
--
--   Python 3:
-- Configuring done (76.4s)
True
'@
# The real cpu-lane configure of 2026-09-22 (bk-20260922-231204 ...-opencv.log:770-772, 874, 877, 1115-1118), unprefixed.
$script:OrtCfgLogDownload = @'
-- DNN: ONNX Runtime download mode: CPU
-- DNN: ONNX Runtime was not found in system paths, attempting to download prebuilt package-- DNN: ONNX Runtime package: onnxruntime-win-x64-1.25.1.zip
-- DNN: Downloading ONNX Runtime package from https://github.com/microsoft/onnxruntime/releases/download/v1.25.1/onnxruntime-win-x64-1.25.1.zip
-- DNN: Extracting ONNX Runtime package to C:/temp/opencv-src/build/3rdparty/onnxruntime
-- DNN: ONNX Runtime enabled
--
--   ONNX Runtime:                  YES (ver 1.25.1)
--     Include path:                C:/temp/opencv-src/build/3rdparty/onnxruntime/onnxruntime-win-x64-1.25.1/include
--     Link libraries:              C:/temp/opencv-src/build/3rdparty/onnxruntime/onnxruntime-win-x64-1.25.1/lib/onnxruntime.lib
--
'@
$script:OrtCache = @'
# This is the CMakeCache file.
//ONNX Runtime install directory
ONNXRT_ROOT_DIR:PATH=C:/temp/opencv-src/ort-nested
//Path to a file.
ORT_EP_INCLUDE:PATH=C:/temp/opencv-src/ort-nested/include/onnxruntime/core/providers/dml
//Path to a library.
ORT_LIB:FILEPATH=C:/runtime/lib/onnxruntime-source/lib/onnxruntime.lib
//ONNX Runtime availability
HAVE_ONNXRUNTIME:INTERNAL=1
'@
$script:OrtCacheDownload = @'
# This is the CMakeCache file.
ONNXRT_ROOT_DIR:PATH=C:/temp/opencv-src/build/3rdparty/onnxruntime/onnxruntime-win-x64-1.25.1
ORT_EP_INCLUDE:PATH=ORT_EP_INCLUDE-NOTFOUND
HAVE_ONNXRUNTIME:INTERNAL=1
'@
# build.ninja statements in CMake's Windows Ninja shape: backslash outputs, '$:'-escaped drive colons.
$script:OrtDefines = '-DCVAPI_EXPORTS -DHAVE_DIRECTML=1 -DHAVE_ONNX=1 -DHAVE_ONNX_DML=1 -D_USE_MATH_DEFINES -D__OPENCV_BUILD=1'
$script:OrtLinkFlags = '/machine:x64 /NODEFAULTLIB:libc /DEBUG /DELAYLOAD:dxcore.dll /DELAYLOAD:d3d12.dll /DELAYLOAD:dxgi.dll /DELAYLOAD:DirectML.dll'
$script:OrtNinjaOf = {
    param([string]$Defines = $script:OrtDefines, [string]$LinkFlags = $script:OrtLinkFlags)
    @"
# CMAKE generated file: DO NOT EDIT!

build modules\gapi\CMakeFiles\opencv_gapi.dir\src\backends\onnx\gonnxbackend.cpp.obj: CXX_COMPILER__opencv_gapi_unscanned_Release C`$:\temp\opencv-src\opencv_contrib\modules\gapi\src\backends\onnx\gonnxbackend.cpp || cmake_object_order_depends_target_opencv_gapi
  DEFINES = -DCVAPI_EXPORTS -DHAVE_ONNX=1
  FLAGS = /FIcstring /O2 /Ob2 /DNDEBUG -std:c++17 -MD

build modules\gapi\CMakeFiles\opencv_gapi.dir\src\backends\onnx\dml_ep.cpp.obj: CXX_COMPILER__opencv_gapi_unscanned_Release C`$:\temp\opencv-src\opencv_contrib\modules\gapi\src\backends\onnx\dml_ep.cpp || cmake_object_order_depends_target_opencv_gapi
  DEFINES = $Defines
  FLAGS = /FIcstring /O2 /Ob2 /DNDEBUG -std:c++17 -MD
  INCLUDES = -IC:\temp\opencv-src\ort-nested\include\onnxruntime\core\session

build bin\opencv_gapi500.dll lib\opencv_gapi500.lib: CXX_SHARED_LIBRARY_LINKER__opencv_gapi_Release modules\gapi\CMakeFiles\opencv_gapi.dir\src\backends\onnx\dml_ep.cpp.obj | lib\opencv_core500.lib
  LINK_FLAGS = $LinkFlags
  LINK_LIBRARIES = lib\opencv_core500.lib  C:\runtime\lib\onnxruntime-source\lib\onnxruntime.lib  delayimp.lib  wsock32.lib
  TARGET_FILE = bin\opencv_gapi500.dll

build opencv_gapi: phony bin\opencv_gapi500.dll
"@
}

Describe 'OpenCV ORT: CMake args (every lane)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtOcvScript -FunctionName 'Get-OpencvOrtCmakeArgs')
    $argsOf = { @(Get-OpencvOrtCmakeArgs -OrtRoot 'C:\runtime\lib\onnxruntime-source' -ShimRoot 'C:\temp\opencv-src\ort-nested\' `
                -OrtVersion $script:OrtVer -HooksDir 'C:\bkmnt\patches\opencv\cmake-hooks') -join '|' }

    It 'points FindONNX at the shim, the linker at the chain, and pre-empts the download' {
        $want = @(
            '-DONNXRT_ROOT_DIR=C:/temp/opencv-src/ort-nested'
            '-DCMAKE_LIBRARY_PATH:PATH=C:/runtime/lib/onnxruntime-source/lib'
            '-DHAVE_ONNXRUNTIME=ON'
            '-DONNXRUNTIME_VERSION=1.30.0'
            '-DCMAKE_DISABLE_FIND_PACKAGE_onnxruntime:BOOL=ON'
            '-DCMAKE_DISABLE_FIND_PACKAGE_ONNXRuntime:BOOL=ON'
            '-DOPENCV_CMAKE_HOOKS_DIR:PATH=C:/bkmnt/patches/opencv/cmake-hooks') -join '|'
        Assert-Equal $want (& $argsOf)
    }

    It 'passes HAVE_ONNXRUNTIME untyped, so Assert-CmakeArgsConsumed flags it when dnn never reads it' {
        Assert-Match '(^|\|)-DHAVE_ONNXRUNTIME=ON(\||$)' (& $argsOf)
        Assert-True ((& $argsOf) -notmatch 'DOWNLOAD_ONNXRUNTIME') 'never asks for a download'
    }

    It 'is the same on the cpu, nvidia and rocm lanes (a lane-independent change)' {
        $baseline = Invoke-WithEnv @{ GPU_TYPE = $null } { & $argsOf }
        foreach ($gpu in 'nvidia', 'rocm') {
            Assert-Equal $baseline (Invoke-WithEnv @{ GPU_TYPE = $gpu } { & $argsOf }) "GPU_TYPE=$gpu"
        }
    }
}

Describe 'OpenCV ORT: nested header shim' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtOcvScript -FunctionName 'New-OpencvOrtNestedInclude')
    # A flat ORT 1.30 install as cmake --install lays it out: public headers and EP factory headers side by side.
    $newFlatOrt = {
        param([string]$Dir, [string[]]$Skip = @())
        $flat = [System.IO.Path]::Combine($Dir, 'ort', 'include', 'onnxruntime')
        $null = [System.IO.Directory]::CreateDirectory($flat)
        foreach ($h in 'onnxruntime_c_api.h', 'onnxruntime_cxx_api.h', 'onnxruntime_cxx_inline.h', 'dml_provider_factory.h', 'cpu_provider_factory.h') {
            if ($Skip -notcontains $h) { [System.IO.File]::WriteAllText([System.IO.Path]::Combine($flat, $h), "// $h") }
        }
        Join-Path $Dir 'ort'
    }

    It 'builds the source-tree layout FindONNX and dml_ep.cpp expect, and returns it in forward slashes' {
        Invoke-InTestDir { param($dir)
            $shim = New-OpencvOrtNestedInclude -OrtRoot (& $newFlatOrt $dir) -ShimRoot (Join-Path $dir 'shim')
            Assert-Equal ((Join-Path $dir 'shim').Replace('\', '/')) $shim
            $session = Join-Path $dir 'shim\include\onnxruntime\core\session'
            Assert-Equal 'cpu_provider_factory.h,dml_provider_factory.h,onnxruntime_c_api.h,onnxruntime_cxx_api.h,onnxruntime_cxx_inline.h' `
                ((Get-ChildItem -LiteralPath $session -File | Sort-Object Name | ForEach-Object Name) -join ',')
            Assert-Equal '// dml_provider_factory.h' (Get-Content -LiteralPath (Join-Path $dir 'shim\include\onnxruntime\core\providers\dml\dml_provider_factory.h') -Raw)
        }
    }

    It 'makes FindONNX''s first suffix hit the session dir, resolves dml_ep.cpp''s relative include, and leaves CoreML out' {
        Invoke-InTestDir { param($dir)
            $shim = New-OpencvOrtNestedInclude -OrtRoot (& $newFlatOrt $dir) -ShimRoot (Join-Path $dir 'shim')
            # FindONNX.cmake:67-73 tries these suffixes in order; the first holding onnxruntime_cxx_api.h wins.
            $hit = @('include', 'include/onnxruntime', 'include/onnxruntime/core/session') |
                Where-Object { Test-Path -LiteralPath "$shim/$_/onnxruntime_cxx_api.h" } | Select-Object -First 1
            Assert-Equal 'include/onnxruntime/core/session' "$hit"
            Assert-True (Test-Path -LiteralPath "$shim/include/onnxruntime/core/session/../providers/dml/dml_provider_factory.h") 'dml_ep.cpp:14 include'
            Assert-False (Test-Path -LiteralPath "$shim/include/onnxruntime/core/providers/coreml") 'no CoreML dir'
            Assert-False (Test-Path -LiteralPath "$shim/bin") 'no bin: dnn''s install glob copies nothing'
        }
    }

    It 'refuses a chain ORT without the C++ API or the DirectML header, naming the file' {
        foreach ($missing in 'dml_provider_factory.h', 'onnxruntime_cxx_api.h') {
            Invoke-InTestDir { param($dir)
                $ort = & $newFlatOrt $dir @($missing)
                Assert-Throws { New-OpencvOrtNestedInclude -OrtRoot $ort -ShimRoot (Join-Path $dir 'shim') } $missing -MessagePattern ([regex]::Escape($missing))
            }
        }
    }

    It 'can run again over an existing shim' {
        Invoke-InTestDir { param($dir)
            $ort = & $newFlatOrt $dir
            $first = New-OpencvOrtNestedInclude -OrtRoot $ort -ShimRoot (Join-Path $dir 'shim')
            Assert-Equal $first (New-OpencvOrtNestedInclude -OrtRoot $ort -ShimRoot (Join-Path $dir 'shim'))
        }
    }
}

Describe 'OpenCV ORT: Get-NinjaBuildVariable' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtOcvScript -FunctionName 'Get-NinjaBuildVariable')
    $ninja = & $script:OrtNinjaOf

    It 'reads a variable of the statement whose outputs match' {
        Assert-Equal $script:OrtLinkFlags (Get-NinjaBuildVariable -BuildNinja $ninja -OutputPattern 'opencv_gapi500\.dll' -Variable 'LINK_FLAGS')
    }

    It 'matches outputs only, never the inputs after the colon' {
        # dml_ep.cpp.obj is an INPUT of the link statement; only its own compile statement may answer.
        Assert-Equal $script:OrtDefines (Get-NinjaBuildVariable -BuildNinja $ninja -OutputPattern 'dml_ep\.cpp\.obj$' -Variable 'DEFINES')
        Assert-Null (Get-NinjaBuildVariable -BuildNinja $ninja -OutputPattern 'opencv_core500\.lib' -Variable 'LINK_FLAGS')
    }

    It 'returns $null for no statement and an empty string for a missing variable, never the next statement''s' {
        Assert-Null (Get-NinjaBuildVariable -BuildNinja $ninja -OutputPattern 'opencv_nope' -Variable 'DEFINES')
        Assert-Equal '' (Get-NinjaBuildVariable -BuildNinja $ninja -OutputPattern 'gonnxbackend\.cpp\.obj$' -Variable 'INCLUDES')
        Assert-Equal '' (Get-NinjaBuildVariable -BuildNinja "build a.obj: CC a.c`n  FLAGS = -x" -OutputPattern 'a\.obj' -Variable 'DEFINES')
    }

    It 'skips a phony alias of the same output, even one written first' {
        $aliasFirst = "build opencv_gapi500.dll: phony bin\opencv_gapi500.dll`n`n$ninja"
        Assert-Equal $script:OrtLinkFlags (Get-NinjaBuildVariable -BuildNinja $aliasFirst -OutputPattern '(^|[\\/\s])opencv_gapi\d*\.dll(\s|$)' -Variable 'LINK_FLAGS')
    }

    It 'ends the outputs at the first unescaped colon' {
        $escaped = "build C`$:\x\out.obj: CXX C`$:\x\in.cpp`n  DEFINES = -DX=1"
        Assert-Equal '-DX=1' (Get-NinjaBuildVariable -BuildNinja $escaped -OutputPattern 'out\.obj$' -Variable 'DEFINES')
    }
}

Describe 'OpenCV ORT: configure gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OrtOcvScript -FunctionName 'Get-NinjaBuildVariable', 'Get-OpencvOrtConfigureFinding')
    $gateOf = {
        param([string]$Log = $script:OrtCfgLog, [string]$Cache = $script:OrtCache, [string]$Ninja = (& $script:OrtNinjaOf),
            [string]$Chain = $script:OrtChain, [string]$Shim = $script:OrtShim)
        @(Get-OpencvOrtConfigureFinding -ConfigureLog $Log -CMakeCache $Cache -BuildNinja $Ninja -OrtRoot $Chain -ShimRoot $Shim -OrtVersion $script:OrtVer)
    }

    It 'passes the healthy shape' {
        $found = @(& $gateOf)
        Assert-Equal 0 $found.Count ($found -join ' / ')
    }

    It 'accepts the roots in either slash form, any case, with a trailing separator' {
        Assert-Equal 0 @(& $gateOf -Chain 'c:\RUNTIME\lib\onnxruntime-source\' -Shim 'C:\temp\opencv-src\ort-nested\').Count
    }

    It 'fails the real 2026-09-22 configure: the download, the zip version, its headers and its import library' {
        $found = @(& $gateOf -Log $script:OrtCfgLogDownload -Cache $script:OrtCacheDownload -Ninja (& $script:OrtNinjaOf -Defines '-DHAVE_DIRECTML=1 -DHAVE_ONNX=1' -LinkFlags '/machine:x64 /NODEFAULTLIB:libc /DEBUG'))
        $text = $found -join ' / '
        Assert-Equal 4 @($found | Where-Object { $_ -match '^dnn fetched its own ONNX Runtime' }).Count $text
        foreach ($p in "reads 'ONNX Runtime: YES \(ver 1\.25\.1\)'", "include path is '.*onnxruntime-win-x64-1\.25\.1/include'",
            "links '.*onnxruntime-win-x64-1\.25\.1/lib/onnxruntime\.lib'", "DirectML probe resolved to 'ORT_EP_INCLUDE-NOTFOUND'",
            "names dnn's ORT download dir", 'without HAVE_ONNX_DML=1', 'hard-imports dxcore\.dll') {
            Assert-Match $p $text
        }
        Assert-Equal 4 @($found | Where-Object { $_ -match 'hard-imports' }).Count 'one per delay-loaded DLL'
    }

    It 'names only the version when nothing else is wrong' {
        $found = @(& $gateOf -Log ($script:OrtCfgLog -replace 'ver 1\.30\.0', 'ver 1.29.0'))
        Assert-Equal 1 $found.Count ($found -join ' / ')
        Assert-Match "reads 'ONNX Runtime: YES \(ver 1\.29\.0\)', not YES \(ver 1\.30\.0\)" $found[0]
    }

    It 'fails a missing or NO summary without reading a neighbour''s Include path' {
        $noOrt = ($script:OrtCfgLog -split '\r?\n' | Where-Object { $_ -notmatch 'ONNX Runtime:|ort-nested/include|onnxruntime\.lib' }) -join "`n"
        Assert-Match "no 'ONNX Runtime:' line" ((& $gateOf -Log $noOrt) -join ';')
        $off = @(& $gateOf -Log ($script:OrtCfgLog -replace 'YES \(ver 1\.30\.0\)', 'NO'))
        Assert-Equal 1 $off.Count ($off -join ' / ')
        Assert-Match "reads 'ONNX Runtime: NO'" $off[0]
    }

    It 'fails an include path that is the flat chain dir, and a copied import library' {
        $flat = & $gateOf -Log ($script:OrtCfgLog -replace 'C:/temp/opencv-src/ort-nested/include/onnxruntime/core/session', 'C:/runtime/lib/onnxruntime-source/include/onnxruntime')
        Assert-Match 'not the nested chain headers' ($flat -join ';')
        $copied = & $gateOf -Log ($script:OrtCfgLog -replace 'C:/runtime/lib/onnxruntime-source/lib/onnxruntime\.lib', 'C:/temp/opencv-src/ort-nested/lib/onnxruntime.lib')
        Assert-Match "not the chain's import library" ($copied -join ';')
    }

    It 'fails a DirectML probe that missed or hit a stray header, and a missing cache' {
        foreach ($ep in 'ORT_EP_INCLUDE-NOTFOUND', 'C:/Program Files/x/include') {
            Assert-Match "DirectML probe resolved to '$([regex]::Escape($ep))'" ((& $gateOf -Cache ($script:OrtCache -replace '(?m)^(ORT_EP_INCLUDE:PATH=).*$', "`${1}$ep")) -join ';')
        }
        Assert-Match 'CMakeCache\.txt is missing' ((& $gateOf -Cache '') -join ';')
    }

    It 'fails the stub compile, one finding per missing define' {
        foreach ($def in 'HAVE_ONNX_DML', 'HAVE_DIRECTML', 'HAVE_ONNX') {
            $found = @(& $gateOf -Ninja (& $script:OrtNinjaOf -Defines ($script:OrtDefines -replace " -D$def=1(?= |$)", '')))
            Assert-Equal 1 $found.Count "$def : $($found -join ' / ')"
            Assert-Match "without $def=1" $found[0]
        }
    }

    It 'fails a TU that defines HAVE_ONNX_COREML' {
        Assert-Match 'HAVE_ONNX_COREML' ((& $gateOf -Ninja (& $script:OrtNinjaOf -Defines "$script:OrtDefines -DHAVE_ONNX_COREML=1")) -join ';')
    }

    It 'fails each DirectX DLL the link line does not delay-load' {
        foreach ($dll in $script:OrtDelayLoads) {
            $found = @(& $gateOf -Ninja (& $script:OrtNinjaOf -LinkFlags ($script:OrtLinkFlags -replace " /DELAYLOAD:$([regex]::Escape($dll))", '')))
            Assert-Equal 1 $found.Count "$dll : $($found -join ' / ')"
            Assert-Match "hard-imports $([regex]::Escape($dll))" $found[0]
        }
    }

    It 'fails a build.ninja without the dml_ep.cpp statement, the gapi link, or any content' {
        $ninja = & $script:OrtNinjaOf
        Assert-Match "no compile statement for G-API's dml_ep\.cpp" ((& $gateOf -Ninja ($ninja -replace 'dml_ep\.cpp\.obj:', 'other.cpp.obj:')) -join ';')
        Assert-Match 'no link statement for opencv_gapi' ((& $gateOf -Ninja ($ninja -replace 'build bin\\opencv_gapi500\.dll', 'build bin\opencv_video500.dll')) -join ';')
        $empty = @(& $gateOf -Ninja '')
        Assert-Equal 1 $empty.Count ($empty -join ' / ')
        Assert-Match 'build\.ninja is missing or empty' $empty[0]
    }
}

Describe 'OpenCV ORT: the G-API delay-load hook' {
    $hookDir = Join-Path (Get-RepoRoot) $script:OrtOcvHooks
    $hook = Join-Path $hookDir 'POST_CREATE_MODULE_LIBRARY_opencv_gapi.cmake'

    It 'is the only .cmake in the hooks dir (OpenCV registers every one there as a hook named by its basename)' {
        Assert-Equal 'POST_CREATE_MODULE_LIBRARY_opencv_gapi.cmake' ((Get-ChildItem -LiteralPath $hookDir -Filter '*.cmake' -File | ForEach-Object Name) -join ',')
    }

    It 'delay-loads exactly the DLLs the gate requires, links delayimp.lib, and keeps LINK_FLAGS' {
        $body = [System.IO.File]::ReadAllText($hook)
        $loads = @([regex]::Matches($body, '/DELAYLOAD:([\w.]+)') | ForEach-Object { $_.Groups[1].Value })
        Assert-Equal ($script:OrtDelayLoads -join ',') ($loads -join ',')
        $gate = (Get-ScriptFunctionDefinition -ScriptPath $script:OrtOcvScript -FunctionName 'Get-OpencvOrtConfigureFinding').ToString()
        foreach ($dll in $script:OrtDelayLoads) { Assert-Match "'$([regex]::Escape($dll))'" $gate "the gate checks $dll" }
        Assert-Match 'target_link_libraries\(\$\{the_module\} PRIVATE delayimp\.lib\)' $body
        # ocv_create_module sets LINK_FLAGS (/NODEFAULTLIB:libc /DEBUG) just before this hook runs; overwriting it drops both.
        Assert-True ($body -notmatch 'LINK_FLAGS') 'uses target_link_options, never the LINK_FLAGS property'
    }

    It 'acts only when dml_ep.cpp really imports those DLLs' {
        Assert-Match '(?m)^if\(MSVC AND HAVE_ONNX AND HAVE_ONNX_DML AND HAVE_DIRECTML\)' ([System.IO.File]::ReadAllText($hook))
    }

    It 'is LF-only, like every other .cmake the images consume' {
        Assert-False ([System.IO.File]::ReadAllText($hook).Contains("`r")) 'CRLF in the hook'
    }
}

Describe 'OpenCV ORT: wiring in Build-OpencvFromSource.ps1' {
    $L = 'System.Management.Automation.Language'
    $tree = [System.Management.Automation.Language.Parser]::ParseInput([System.IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:OrtOcvScript)), [ref]$null, [ref]$null)
    $all = @($tree.FindAll({ $true }, $true))
    $callsTo = { param([string]$Name) @($all | Where-Object { $_ -is [type]"$L.CommandAst" -and $_.GetCommandName() -eq $Name }) }
    $underIf = { param($node) $up = $node.Parent; while ($up -and $up -isnot [type]"$L.IfStatementAst") { $up = $up.Parent }; $null -ne $up }
    $argsOf = {
        param($cmd)
        $bound = [System.Management.Automation.Language.StaticParameterBinder]::BindCommand($cmd, $false).BoundParameters
        $map = @{}
        foreach ($name in $bound.Keys) { $map[$name] = $bound[$name].Value.Extent.Text }
        $map
    }
    $configure = @(& $callsTo 'Invoke-CmakeConfigure')[0]

    It 'wires the shim, the args and the gate once each, under no lane condition' {
        foreach ($fn in 'New-OpencvOrtNestedInclude', 'Get-OpencvOrtCmakeArgs', 'Get-OpencvOrtConfigureFinding') {
            $calls = @(& $callsTo $fn)
            Assert-Equal 1 $calls.Count "$fn call sites"
            Assert-False (& $underIf $calls[0]) "$fn sits under an if; the ORT wiring is every-lane"
        }
    }

    It 'appends the args before configure, and nothing else names ONNXRT_ROOT_DIR' {
        $edits = @($all | Where-Object { $_ -is [type]"$L.AssignmentStatementAst" -and $_.Left.Extent.Text -eq '$cmakeExtra' })
        $append = @($edits | Where-Object { $_.Operator -eq 'PlusEquals' -and $_.Right.Extent.Text -eq '$ocvOrtArgs' })
        Assert-Equal 1 $append.Count '$cmakeExtra += $ocvOrtArgs'
        Assert-False (& $underIf $append[0]) 'the append is unconditional'
        Assert-True ($append[0].Extent.StartOffset -lt $configure.Extent.StartOffset) 'before Invoke-CmakeConfigure'
        Assert-Equal 0 @($edits | Where-Object { $_.Extent.Text -match 'ONNXRT_ROOT_DIR|DOWNLOAD_ONNXRUNTIME' }).Count 'no second ORT root or download switch'
    }

    It 'gates after configure on the teed log, the cache, build.ninja and the same roots the args got' {
        $gate = @(& $callsTo 'Get-OpencvOrtConfigureFinding')[0]
        Assert-True ($gate.Extent.StartOffset -gt $configure.Extent.StartOffset) 'gate reads what configure wrote'
        $bound = & $argsOf $gate
        Assert-Match '^"\$\(Get-Content -LiteralPath \$cfgLog -Raw\)"$' $bound['ConfigureLog']
        Assert-Match "Join-Path \`$buildDir 'CMakeCache\.txt'" $bound['CMakeCache']
        Assert-Match "Join-Path \`$buildDir 'build\.ninja'" $bound['BuildNinja']
        $argsCall = & $argsOf @(& $callsTo 'Get-OpencvOrtCmakeArgs')[0]
        foreach ($p in 'OrtRoot', 'ShimRoot', 'OrtVersion') { Assert-Equal $argsCall[$p] $bound[$p] "-$p is shared by args and gate" }
        Assert-Equal '$ortShimRoot' $bound['ShimRoot']
    }

    It 'throws on any gate finding, directly and unconditionally' {
        $gate = @(& $callsTo 'Get-OpencvOrtConfigureFinding')[0]
        $assign = $gate.Parent
        while ($assign -and $assign -isnot [type]"$L.AssignmentStatementAst") { $assign = $assign.Parent }
        Assert-Equal '$ocvOrtCfg' $assign.Left.Extent.Text
        $check = @($all | Where-Object { $_ -is [type]"$L.IfStatementAst" -and $_.Clauses[0].Item1.Extent.Text -eq '$ocvOrtCfg.Count -gt 0' })
        Assert-Equal 1 $check.Count 'one if ($ocvOrtCfg.Count -gt 0)'
        Assert-False (& $underIf $check[0]) 'the check is not nested in a lane condition'
        Assert-Null $check[0].ElseClause 'no else arm'
        Assert-Equal 1 @($check[0].Clauses[0].Item2.Statements | Where-Object { $_ -is [type]"$L.ThrowStatementAst" }).Count 'a direct throw'
    }
}
