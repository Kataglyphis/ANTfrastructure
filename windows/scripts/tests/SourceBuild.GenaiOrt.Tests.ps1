#requires -Version 7.0
# GenAI on the chain's ONNX Runtime, every lane: the ORT_HOME shim, the -D set, the configure-record gate, the tree gate.
# NOT covered: a real GenAI configure/build, the DirectML/D3D12 packages GenAI still fetches, which ORT loads at run time.

$script:GenaiOrtScript = 'windows\scripts\build\Build-OnnxGenaiFromSource.ps1'
$script:GenaiOrtFns = @('ConvertTo-GenaiCmakePath', 'New-GenaiOrtHome', 'Get-GenaiOrtCmakeArgs', 'Get-GenaiOrtConfigureFinding',
    'Get-GenaiOrtNinjaFinding', 'Get-GenaiOrtTreeFinding')
$script:GenaiShim = 'C:/temp/onnx-genai-src/ort-home'
$script:GenaiBlock = 'C:/temp/onnx-genai-src/ort-fetch-blocked'

# ortlib.cmake's own STATUS lines (v0.15.2 :61-65, :227-228) in the teed onnx-genai-configure.log shape.
$script:GenaiLog = @'
CMake configure: -S C:\temp\onnx-genai-src -B C:\temp\onnx-genai-src\build\Windows-ClangCL\Release -DORT_HOME:PATH=C:/temp/onnx-genai-src/ort-home -DFETCHCONTENT_SOURCE_DIR_ORTLIB:PATH=C:/temp/onnx-genai-src/ort-fetch-blocked
-- The CXX compiler identification is Clang 23.1.1 with MSVC-like command-line
-- Using ONNX Runtime from: C:/temp/onnx-genai-src/ort-home [as provided]
-- Using ONNX Runtime from: C:/temp/onnx-genai-src/ort-home [absolute]
-- ORT_HEADER_DIR: C:/temp/onnx-genai-src/ort-home/include
-- ORT_LIB_DIR: C:/temp/onnx-genai-src/ort-home/lib
Loading Dependencies URLs ...
-- Configuring done (41.2s)
CMake Warning:
  Manually-specified variables were not used by the project:

    FETCHCONTENT_SOURCE_DIR_ONNXRUNTIME
    FETCHCONTENT_SOURCE_DIR_ORTLIB

-- Build files have been written to: C:/temp/onnx-genai-src/build/Windows-ClangCL/Release
True
'@
# The same three lines as upstream prints them without ORT_HOME (reproduced with cmake 3.29 against the v0.15.2 file).
$script:GenaiLogFetched = @'
-- Using ONNX Runtime package Microsoft.ML.OnnxRuntime.DirectML version 1.24.4
-- ORT_HEADER_DIR: C:/temp/onnx-genai-src/build/Windows-ClangCL/Release/_deps/ortlib-src/build/native/include
-- ORT_LIB_DIR: C:/temp/onnx-genai-src/build/Windows-ClangCL/Release/_deps/ortlib-src/runtimes/win-x64/native
-- Configuring done (40.9s)
'@
$script:GenaiCache = @'
# This is the CMakeCache file.
//No help, variable specified on the command line.
FETCHCONTENT_SOURCE_DIR_ONNXRUNTIME:PATH=C:/temp/onnx-genai-src/ort-fetch-blocked
//No help, variable specified on the command line.
FETCHCONTENT_SOURCE_DIR_ORTLIB:PATH=C:/temp/onnx-genai-src/ort-fetch-blocked
//No help, variable specified on the command line.
ORT_HOME:PATH=C:/temp/onnx-genai-src/ort-home
//Build with DML support
USE_DML:BOOL=ON
'@
# CMake's Ninja output for clang-cl (shape measured with cmake 3.29): -I, -LIBPATH:, and onnxruntime.dll linked as onnxruntime.lib.
$script:GenaiNinjaOf = {
    param(
        [string]$Includes = '-IC:\temp\onnx-genai-src\ort-home\include -IC:\temp\onnx-genai-src\build\Windows-ClangCL\Release\_deps\onnxruntime_extensions-src\shared\api',
        [string]$DllLibs = '_deps\onnxruntime_extensions-build\lib\onnxruntime_extensions.lib  onnxruntime.lib  d3d12.lib  dxcore.lib  kernel32.lib',
        [string]$DllLibPath = '-LIBPATH:C:\temp\onnx-genai-src\ort-home\lib -LIBPATH:C:\temp\onnx-genai-src\build\Windows-ClangCL\Release\_deps\dmllib-src\bin\x64-win\native',
        [string]$PydLibPath = '-LIBPATH:C:\temp\onnx-genai-src\ort-home\lib'
    )
    @"
# CMAKE generated file: DO NOT EDIT!

build CMakeFiles\onnxruntime-genai-obj.dir\src\models\model.cpp.obj: CXX_COMPILER__onnxruntime-genai-obj_unscanned_Release C`$:\temp\onnx-genai-src\src\models\model.cpp || cmake_object_order_depends_target_onnxruntime-genai-obj
  DEFINES = -DBUILDING_ORT_GENAI_C -DUSE_DML=1
  FLAGS = /GR /EHsc /O2 -MD
  INCLUDES = $Includes

build CMakeFiles\onnxruntime-genai-obj.dir\src\dml\interface.cpp.obj: CXX_COMPILER__onnxruntime-genai-obj_unscanned_Release C`$:\temp\onnx-genai-src\src\dml\interface.cpp || cmake_object_order_depends_target_onnxruntime-genai-obj
  DEFINES = -DBUILDING_ORT_GENAI_C -DUSE_DML=1
  INCLUDES = -IC:\temp\onnx-genai-src\ort-home\include

build onnxruntime-genai.dll onnxruntime-genai.lib: CXX_SHARED_LIBRARY_LINKER__onnxruntime-genai_Release CMakeFiles\onnxruntime-genai-obj.dir\src\models\model.cpp.obj || onnxruntime-genai-obj
  LINK_FLAGS = /INCREMENTAL:NO
  LINK_LIBRARIES = $DllLibs
  LINK_PATH = $DllLibPath
  TARGET_FILE = onnxruntime-genai.dll

build src\python\onnxruntime_genai.cp314-win_amd64.pyd: CXX_MODULE_LIBRARY_LINKER__python_Release CMakeFiles\python.dir\src\python\python.cpp.obj | onnxruntime-genai.lib || onnxruntime-genai.dll
  LINK_LIBRARIES = onnxruntime-genai.lib  onnxruntime.lib  kernel32.lib
  LINK_PATH = $PydLibPath

build onnxruntime-genai: phony onnxruntime-genai.dll
"@
}

Describe 'GenAI ORT: CMake args (every lane)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:GenaiOrtScript -FunctionName $script:GenaiOrtFns)
    $joined = { (Get-GenaiOrtCmakeArgs -OrtHome 'C:\temp\onnx-genai-src\ort-home\' -FetchBlockDir 'C:\temp\onnx-genai-src\ort-fetch-blocked') -join '|' }

    It 'points ORT_HOME at the shim and pins both ORT FetchContent names to the empty block dir' {
        Assert-Equal ("-DORT_HOME:PATH=$script:GenaiShim|-DFETCHCONTENT_SOURCE_DIR_ORTLIB:PATH=$script:GenaiBlock|" +
            "-DFETCHCONTENT_SOURCE_DIR_ONNXRUNTIME:PATH=$script:GenaiBlock") (& $joined)
    }

    It 'types ORT_HOME, which ortlib.cmake reads without declaring it (untyped it would be cached UNINITIALIZED)' {
        Assert-Match '^-DORT_HOME:PATH=' (& $joined)
        Assert-True ((& $joined) -notmatch 'USE_WINML|ORT_VERSION|Microsoft\.ML') 'no WinML switch, no package version or name'
    }

    It 'does not depend on the lane' {
        $cpu = Invoke-WithEnv @{ GPU_TYPE = $null; WINDOWS_TARGET_ARCH = $null } { & $joined }
        foreach ($lane in @(@{ GPU_TYPE = 'nvidia' }, @{ GPU_TYPE = 'rocm' }, @{ WINDOWS_TARGET_ARCH = 'arm64' })) {
            Assert-Equal $cpu (Invoke-WithEnv $lane { & $joined }) ($lane.Keys -join ',')
        }
    }
}

Describe 'GenAI: its own tests are not built' {
    It 'passes ENABLE_TESTS=OFF, the option GenAI gates test\ on (BUILD_TESTING is not it) (mutation)' {
        # The rocm lane's CPU build could not link unit_tests (unexported Generators::Log,
        # g_log, 2026-09-24); nothing in the chain runs them.
        $text = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) $script:GenaiOrtScript)
        Assert-Match "(?m)^\s*'-DENABLE_TESTS=OFF'\s*$" $text 'GenAI must be configured without its test\ tree'
    }
}

# One writer for every fixture tree here: relative path -> text, parent dirs created by New-Item -Force.
$script:GenaiWrite = { param([string]$Root, [System.Collections.IDictionary]$Files) foreach ($rel in $Files.Keys) { $null = New-Item -ItemType File -Force -Path (Join-Path $Root $rel) -Value $Files[$rel] } }
# A chain ORT as cmake --install lays it out on Windows: flat headers (+ nested provider dirs), lib\*.lib, bin\*.dll.
$script:GenaiChainFiles = [ordered]@{
    'include\onnxruntime\onnxruntime_c_api.h' = '// chain c api'; 'include\onnxruntime\dml_provider_factory.h' = '// chain dml'
    'include\onnxruntime\core\providers\cuda\cuda_context.h' = '// chain cuda'; 'lib\onnxruntime.lib' = 'chain implib'
    'lib\onnxruntime_providers_cuda.dll' = 'chain cuda ep'; 'bin\onnxruntime.dll' = 'chain dll'
}

Describe 'GenAI ORT: the ORT_HOME shim' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:GenaiOrtScript -FunctionName $script:GenaiOrtFns)
    $chainAt = {
        param([string]$Root, [string]$Without = '')
        $kept = [ordered]@{}
        $script:GenaiChainFiles.Keys | Where-Object { (Split-Path $_ -Leaf) -ne $Without } | ForEach-Object { $kept[$_] = $script:GenaiChainFiles[$_] }
        & $script:GenaiWrite $Root $kept
        $Root
    }

    It 'lays out include\ and lib\ the way ortlib.cmake and global_variables.cmake read ORT_HOME, byte for byte' {
        Invoke-InTestDir { param($dir)
            $chain = & $chainAt (Join-Path $dir 'chain')
            $shim = New-GenaiOrtHome -OrtRoot $chain -ShimRoot (Join-Path $dir 'src\ort-home')
            Assert-Equal ((Join-Path $dir 'src\ort-home').Replace('\', '/')) $shim
            $sameAs = [ordered]@{ 'include/onnxruntime_c_api.h' = 'include\onnxruntime\onnxruntime_c_api.h'; 'lib/onnxruntime.dll' = 'bin\onnxruntime.dll'
                'lib/onnxruntime.lib' = 'lib\onnxruntime.lib'; 'include/core/providers/cuda/cuda_context.h' = 'include\onnxruntime\core\providers\cuda\cuda_context.h' }
            foreach ($inShim in $sameAs.Keys) {
                Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $chain $sameAs[$inShim]))) ([System.IO.File]::ReadAllText("$shim/$inShim")) $inShim
            }
            Assert-False (Test-Path -LiteralPath "$shim/lib/onnxruntime_providers_cuda.dll") 'only the import library and the DLL the EXISTS check names'
        }
    }

    It 'refuses a chain without the C API header, the DirectML header, the import library or the DLL, naming it (mutation)' {
        Invoke-InTestDir { param($dir)
            foreach ($gone in 'onnxruntime_c_api.h', 'dml_provider_factory.h', 'onnxruntime.lib', 'onnxruntime.dll') {
                $shimDir = Join-Path $dir "shim-$gone"
                $why = try { $null = New-GenaiOrtHome -OrtRoot (& $chainAt (Join-Path $dir "chain-$gone") $gone) -ShimRoot $shimDir; 'no error' } catch { "$_" }
                Assert-Match "has no .*$([regex]::Escape($gone))" $why $gone
                Assert-False (Test-Path -LiteralPath $shimDir) "$gone : nothing half-built"
            }
        }
    }

    It 'replaces a stale shim on a re-run and passes the tree gate against its own chain' {
        Invoke-InTestDir { param($dir)
            $chain = & $chainAt (Join-Path $dir 'chain')
            $shimDir = Join-Path $dir 'src\ort-home'
            $null = New-GenaiOrtHome -OrtRoot $chain -ShimRoot $shimDir
            & $script:GenaiWrite $shimDir @{ 'include\onnxruntime_c_api.h' = '// stale'; 'include\onnxruntime_training_c_api.h' = '// an older chain' }
            $null = New-GenaiOrtHome -OrtRoot $chain -ShimRoot $shimDir
            Assert-False (Test-Path -LiteralPath (Join-Path $shimDir 'include\onnxruntime_training_c_api.h')) 'a header the chain no longer ships is gone'
            $left = @(Get-GenaiOrtTreeFinding -TreeRoot (Join-Path $dir 'src') -OrtRoot $chain)
            Assert-Equal 0 $left.Count ($left -join ' / ')
        }
    }
}

Describe 'GenAI ORT: configure gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:GenaiOrtScript -FunctionName $script:GenaiOrtFns)
    # The healthy record, with any of its five inputs swapped out by name.
    $gate = {
        param([hashtable]$Swap = @{})
        $in = @{ ConfigureLog = $script:GenaiLog; CMakeCache = $script:GenaiCache; BuildNinja = (& $script:GenaiNinjaOf); OrtHome = $script:GenaiShim; FetchBlockDir = $script:GenaiBlock }
        foreach ($name in $Swap.Keys) { $in[$name] = $Swap[$name] }
        @(Get-GenaiOrtConfigureFinding @in)
    }
    $only = {
        param([hashtable]$Swap, [string]$Pattern)
        $got = @(& $gate $Swap)
        Assert-Equal 1 $got.Count "$Pattern <- $($got -join ' / ')"
        Assert-Match $Pattern $got[0]
    }

    It 'passes the healthy record, extensions'' own _deps included' {
        $clean = @(& $gate)
        Assert-Equal 0 $clean.Count ($clean -join ' / ')
    }

    It 'takes the roots in either slash form, any case, with a trailing separator' {
        Assert-Equal 0 @(& $gate @{ OrtHome = 'c:\TEMP\onnx-genai-src\ort-home\'; FetchBlockDir = 'C:\temp\onnx-genai-src\ort-fetch-blocked\' }).Count
    }

    It 'fails the upstream fallback: the NuGet line, its dirs, no ORT_HOME, the compiles and links reading _deps\ortlib-src' {
        $nuget = 'C:\temp\onnx-genai-src\build\Windows-ClangCL\Release\_deps\ortlib-src'
        $fetchedNinja = & $script:GenaiNinjaOf -Includes "-I$nuget\build\native\include" -DllLibPath "-LIBPATH:$nuget\runtimes\win-x64\native" -PydLibPath "-LIBPATH:$nuget\runtimes\win-x64\native"
        $bareCache = ($script:GenaiCache -split '\r?\n' | Where-Object { $_ -notmatch '^(ORT_HOME|FETCHCONTENT_SOURCE_DIR_)' }) -join "`n"
        $text = (& $gate @{ ConfigureLog = $script:GenaiLogFetched; CMakeCache = $bareCache; BuildNinja = $fetchedNinja }) -join ' / '
        foreach ($p in 'downloaded ONNX Runtime: -- Using ONNX Runtime package Microsoft\.ML\.OnnxRuntime\.DirectML', "no 'Using ONNX Runtime from",
            "set ORT_HEADER_DIR to '.*/_deps/ortlib-src/build/native/include'", "set ORT_LIB_DIR to '.*/_deps/ortlib-src/runtimes/win-x64/native'",
            'CMakeCache\.txt has no ORT_HOME', 'CMakeCache\.txt has no FETCHCONTENT_SOURCE_DIR_ORTLIB', 'onnxruntime-genai\.dll .*links onnxruntime\.lib without',
            'onnxruntime_genai\.cp314-win_amd64\.pyd links onnxruntime\.lib without', '1 of 2 GenAI compiles lack', 'build\.ninja names a downloaded ONNX Runtime') {
            Assert-Match $p $text
        }
    }

    It 'fails each ortlib.cmake line that is missing or names another dir, one finding apiece (mutation)' {
        $cases = [ordered]@{
            "no 'Using ONNX Runtime from"                               = @('(?m)^.*\[absolute\]\r?$', '')
            "took ORT_HOME 'C:/temp/onnx-genai-src/nuget'"              = @('ort-home \[absolute\]', 'nuget [absolute]')
            'no ORT_HEADER_DIR line'                                    = @('(?m)^-- ORT_HEADER_DIR:.*$', '')
            "set ORT_LIB_DIR to 'C:/temp/onnx-genai-src/other/lib'"    = @('ort-home/lib', 'other/lib')
            'downloaded ONNX Runtime: -- ONNX Runtime URL'              = @('(?m)^True$', '-- ONNX Runtime URL: https://github.com/microsoft/onnxruntime/releases/download/v1.19.2/onnxruntime-win-x64-1.19.2.zip')
        }
        foreach ($want in $cases.Keys) { & $only @{ ConfigureLog = ($script:GenaiLog -replace $cases[$want][0], $cases[$want][1]) } $want }
    }

    It 'fails a cache that is missing, lacks ORT_HOME or a fetch block, aims the block elsewhere, or names ortlib-src (mutation)' {
        & $only @{ CMakeCache = '' } 'CMakeCache\.txt is missing'
        foreach ($name in 'ORT_HOME', 'FETCHCONTENT_SOURCE_DIR_ORTLIB', 'FETCHCONTENT_SOURCE_DIR_ONNXRUNTIME') {
            & $only @{ CMakeCache = (($script:GenaiCache -split '\r?\n' | Where-Object { $_ -notmatch "^$name`:" }) -join "`n") } "CMakeCache\.txt has no $name$"
        }
        & $only @{ CMakeCache = ($script:GenaiCache -replace '(?m)^(FETCHCONTENT_SOURCE_DIR_ONNXRUNTIME:PATH=).*$', '${1}C:/x/elsewhere') } 'FETCHCONTENT_SOURCE_DIR_ONNXRUNTIME=C:/x/elsewhere, not'
        & $only @{ CMakeCache = "$script:GenaiCache`nortlib_SOURCE_DIR:INTERNAL=C:/b/_deps/ortlib-src" } 'names a downloaded ONNX Runtime: ortlib_SOURCE_DIR='
    }

    It 'fails build.ninja: empty, a compile without the shim include, an onnxruntime.lib link without the shim LIBPATH (mutation)' {
        & $only @{ BuildNinja = '' } 'build\.ninja is missing or empty'
        & $only @{ BuildNinja = (& $script:GenaiNinjaOf -Includes '-IC:\runtime\lib\onnxruntime-source\include\onnxruntime') } '^1 of 2 GenAI compiles lack -IC:/temp/onnx-genai-src/ort-home/include'
        & $only @{ BuildNinja = (& $script:GenaiNinjaOf -DllLibPath '-LIBPATH:C:\nuget\lib') } '^onnxruntime-genai\.dll onnxruntime-genai\.lib links onnxruntime\.lib without'
        & $only @{ BuildNinja = (& $script:GenaiNinjaOf -PydLibPath '') } '^src/python/onnxruntime_genai\.cp314-win_amd64\.pyd links onnxruntime\.lib without'
    }

    It 'fails an import library linked by full path from anywhere but the shim' {
        & $only @{ BuildNinja = (& $script:GenaiNinjaOf -DllLibs 'C:\nuget\native\onnxruntime.lib  kernel32.lib') } 'links C:/nuget/native/onnxruntime\.lib, not the chain shim'
        Assert-Equal 0 @(& $gate @{ BuildNinja = (& $script:GenaiNinjaOf -DllLibs 'C:\temp\onnx-genai-src\ort-home\lib\onnxruntime.lib') }).Count 'the shim''s own full path is fine'
    }

    It 'fails a GenAI DLL that links no onnxruntime.lib, or a build.ninja with no GenAI compile' {
        & $only @{ BuildNinja = (& $script:GenaiNinjaOf -DllLibs 'kernel32.lib') } 'no onnxruntime-genai\.dll link that names onnxruntime\.lib'
        & $only @{ BuildNinja = ((& $script:GenaiNinjaOf) -replace 'onnxruntime-genai-obj\.dir', 'other.dir') } 'no compile statement for onnxruntime-genai-obj'
    }
}

Describe 'GenAI ORT: tree gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:GenaiOrtScript -FunctionName $script:GenaiOrtFns)
    # The chain, and a GenAI tree after configure: shim copies, GenAI's own onnxruntime_* names, extensions, a wheel.
    $healthy = {
        param([string]$Dir)
        & $script:GenaiWrite (Join-Path $Dir 'chain') $script:GenaiChainFiles
        & $script:GenaiWrite (Join-Path $Dir 'src') ([ordered]@{
                'ort-home\include\onnxruntime_c_api.h' = '// chain c api'; 'ort-home\lib\onnxruntime.dll' = 'chain dll'; 'ort-home\lib\onnxruntime.lib' = 'chain implib'
                'src\models\onnxruntime_api.h' = 'genai'; 'src\models\onnxruntime_inline.h' = 'genai'; 'src\dll\resource.h' = 'rc'
                'build\_deps\onnxruntime_extensions-src\include\onnxruntime_extensions.h' = 'ext'; 'build\_deps\onnxruntime_extensions-build\ocos.lib' = 'ext'
                'build\onnxruntime-genai.dll' = 'genai'; 'build\wheel\dist\onnxruntime_genai-0.15.2-cp314-cp314-win_amd64.whl' = 'whl'; 'ort-fetch-blocked\.keep' = ''
            })
    }
    $treeOf = { param([string]$Dir, [string]$Sub = 'src', [switch]$Install) @(Get-GenaiOrtTreeFinding -TreeRoot (Join-Path $Dir $Sub) -OrtRoot (Join-Path $Dir 'chain') -ForbidCopies:$Install) }
    $lone = { param([object[]]$Seen, [string]$Pattern, [string]$Label = $Pattern) Assert-Equal 1 $Seen.Count "$Label <- $($Seen -join ' / ')"; Assert-Match $Pattern $Seen[0] }

    It 'passes chain-identical copies and ignores names the chain does not ship' {
        Invoke-InTestDir { param($dir)
            & $healthy $dir
            $seen = @(& $treeOf $dir)
            Assert-Equal 0 $seen.Count ($seen -join ' / ')
        }
    }

    It 'fails a foreign header, import library or DLL under a chain name, wherever it sits (mutation)' {
        foreach ($rel in 'build\_deps\ortpkg\include\onnxruntime_c_api.h', 'build\x\onnxruntime.lib', 'build\bin\onnxruntime.dll', 'build\y\onnxruntime_providers_cuda.dll') {
            Invoke-InTestDir { param($dir)
                & $healthy $dir
                & $script:GenaiWrite (Join-Path $dir 'src') @{ $rel = 'nuget bytes' }
                & $lone @(& $treeOf $dir) "$([regex]::Escape($rel)) is not the chain's" $rel
            }
        }
    }

    It 'sees a hidden file (mutation: AttributesToSkip back to its Hidden|System default)' {
        Invoke-InTestDir { param($dir)
            & $healthy $dir
            (New-Item -ItemType File -Force -Path (Join-Path $dir 'src\build\h\onnxruntime.dll') -Value 'nuget bytes').Attributes = 'Hidden'
            Assert-Match 'onnxruntime\.dll is not the chain' ((& $treeOf $dir) -join ' / ')
        }
    }

    It 'fails FetchContent''s ortlib/onnxruntime dirs and ORT archives, not extensions'' dirs or the GenAI wheel (mutation)' {
        Invoke-InTestDir { param($dir)
            & $healthy $dir
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $dir 'src\build\_deps\ortlib-subbuild'), (Join-Path $dir 'src\build\_deps\onnxruntime-src')
            & $script:GenaiWrite (Join-Path $dir 'src') @{ 'build\_deps\Microsoft.ML.OnnxRuntime.DirectML.1.24.4.nupkg' = 'pk'; 'dl\onnxruntime-win-x64-1.19.2.zip' = 'pk' }
            $all = (& $treeOf $dir) -join ' / '
            Assert-Equal 4 @(& $treeOf $dir).Count $all
            foreach ($want in 'populated ONNX Runtime content at .*ortlib-subbuild', 'populated ONNX Runtime content at .*onnxruntime-src',
                'archive sits in the tree: .*DirectML\.1\.24\.4\.nupkg', 'archive sits in the tree: .*onnxruntime-win-x64-1\.19\.2\.zip') { Assert-Match $want $all }
        }
    }

    It '-ForbidCopies fails even a chain-identical ORT file in an install dir (mutation)' {
        Invoke-InTestDir { param($dir)
            & $healthy $dir
            & $script:GenaiWrite (Join-Path $dir 'install') @{ 'lib\onnxruntime-genai.dll' = 'genai'; 'lib\D3D12Core.dll' = 'd3d'; 'include\ort_genai.h' = 'h' }
            Assert-Equal 0 @(& $treeOf $dir 'install' -Install).Count 'GenAI''s own install'
            & $script:GenaiWrite (Join-Path $dir 'install') @{ 'lib\onnxruntime.dll' = 'chain dll' }
            & $lone @(& $treeOf $dir 'install' -Install) 'ships inside the GenAI install: .*onnxruntime\.dll'
        }
    }

    It 'fails when the chain has nothing to compare against, or the tree is missing' {
        Invoke-InTestDir { param($dir)
            & $script:GenaiWrite (Join-Path $dir 'chain') @{ 'include\onnxruntime\onnxruntime_c_api.h' = 'c api'; 'lib\onnxruntime.lib' = 'implib' }
            & $script:GenaiWrite (Join-Path $dir 'src') @{ 'a.txt' = 'x' }
            & $lone @(& $treeOf $dir) 'has no onnxruntime\.dll to compare against'
            Assert-Match 'no tree at' ((& $treeOf $dir 'absent') -join ' / ')
        }
    }
}

$script:GenaiScriptAst = (Get-Command -Name (Join-Path (Get-RepoRoot) $script:GenaiOrtScript)).ScriptBlock.Ast

Describe 'GenAI ORT: wiring in Build-OnnxGenaiFromSource.ps1' {
    $find = { param([scriptblock]$Predicate) @($script:GenaiScriptAst.FindAll($Predicate, $true)) }
    # Unconditional wiring = a statement no function body, if or loop encloses.
    $always = {
        param($Node)
        for ($up = $Node.Parent; $null -ne $up; $up = $up.Parent) {
            if ($up -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $up -is [System.Management.Automation.Language.IfStatementAst] -or
                $up -is [System.Management.Automation.Language.LoopStatementAst]) { return $false }
        }
        $true
    }
    $callsOf = { param([string]$Name) @(& $find { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name } | Where-Object { & $always $_ }) }
    $assignsTo = { param([string]$Var) @(& $find { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Var }) }
    $argOf = {
        param($Call, [string]$Param)
        $els = $Call.CommandElements
        for ($i = 1; $i -lt $els.Count - 1; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $Param) { return $els[$i + 1].Extent.Text }
        }
    }
    $configure = @(& $callsOf 'Invoke-CmakeConfigure')

    It 'calls the shim, the args and the configure gate once each, unconditionally' {
        foreach ($fn in 'New-GenaiOrtHome', 'Get-GenaiOrtCmakeArgs', 'Get-GenaiOrtConfigureFinding') { Assert-Equal 1 @(& $callsOf $fn).Count "$fn unconditional calls" }
        Assert-Equal 3 @(& $callsOf 'Get-GenaiOrtTreeFinding').Count 'tree gate: after configure, then source tree + install after the build'
        Assert-Equal 1 $configure.Count 'one unconditional Invoke-CmakeConfigure'
    }

    It 'appends the args before configure and names ORT_HOME nowhere else' {
        $append = @(& $assignsTo '$cmakeExtraGenAi' | Where-Object { $_.Right.Extent.Text -eq '$genaiOrtArgs' })
        Assert-Equal 1 $append.Count '$cmakeExtraGenAi += $genaiOrtArgs'
        Assert-Equal 'PlusEquals' "$($append[0].Operator)"
        Assert-True ((& $always $append[0]) -and $append[0].Extent.EndOffset -lt $configure[0].Extent.StartOffset) 'unconditional, before Invoke-CmakeConfigure'
        $body = $script:GenaiScriptAst.Extent.Text
        Assert-Equal 1 ([regex]::Matches($body, 'ORT_HOME:PATH=')).Count 'one ORT_HOME, in Get-GenaiOrtCmakeArgs'
        Assert-True ($body -notmatch 'USE_WINML|-DORT_VERSION') 'no WinML ORT, no package version'
    }

    It 'tees configure into the log the gate reads, never Out-Null' {
        $pipe = $configure[0].Parent
        Assert-True ($pipe -is [System.Management.Automation.Language.PipelineAst]) 'configure sits in a pipeline'
        Assert-Equal 'Tee-Object -FilePath $genaiCfgLog' $pipe.PipelineElements[$pipe.PipelineElements.Count - 1].Extent.Text
        Assert-True ($pipe.Extent.Text -notmatch 'Out-Null') 'no Out-Null'
        Assert-Equal "'onnx-genai-configure.log'" (& $argOf @(& $callsOf 'Get-PersistentBuildLogPath')[0] 'Name')
    }

    It 'gates after configure on the log, the cache and build.ninja it just wrote, with the shim and block the args got' {
        $gateCall = @(& $callsOf 'Get-GenaiOrtConfigureFinding')[0]
        $argsCall = @(& $callsOf 'Get-GenaiOrtCmakeArgs')[0]
        $reads = @(& $find { param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] -and $n.Variable.Extent.Text -eq '$recordFile' })
        Assert-Equal 1 $reads.Count 'one record-reading loop'
        Assert-True ((& $always $reads[0]) -and $reads[0].Extent.StartOffset -gt $configure[0].Extent.EndOffset) 'read unconditionally, after configure'
        Assert-Equal "@(`$genaiCfgLog, (Join-Path `$genaiBuildDir 'CMakeCache.txt'), (Join-Path `$genaiBuildDir 'build.ninja'))" $reads[0].Condition.Extent.Text
        foreach ($p in @(@('ConfigureLog', 'onnx-genai-configure.log'), @('CMakeCache', 'CMakeCache.txt'), @('BuildNinja', 'build.ninja'))) {
            Assert-Equal "`$genaiRecord['$($p[1])']" (& $argOf $gateCall $p[0]) "-$($p[0])"
        }
        foreach ($p in 'OrtHome', 'FetchBlockDir') { Assert-Equal (& $argOf $argsCall $p) (& $argOf $gateCall $p) "-$p shared by args and gate" }
    }

    It 'throws on any finding, directly: after configure and after the build, before the tree is removed (mutation)' {
        $cleanup = @(& $callsOf 'Remove-SourceBuildTree')
        # The post-build findings throw through G2 (Assert-ChainOrtOnly -Finding), which stamps only a clean pass.
        $g2 = @(& $callsOf 'Assert-ChainOrtOnly')
        Assert-Equal 1 $g2.Count 'one unconditional G2 call'
        Assert-Equal '$genaiOrtPost' (& $argOf $g2[0] 'Finding') 'G2 folds the post-build tree gate in'
        Assert-True ($g2[0].Extent.EndOffset -lt $cleanup[0].Extent.StartOffset) 'G2 before Remove-SourceBuildTree'
        foreach ($var in '$genaiOrtCfg') {
            $checks = @(& $find { param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq "$var.Count -gt 0" })
            Assert-Equal 1 $checks.Count "one if ($var.Count -gt 0)"
            Assert-Null $checks[0].ElseClause "$var : no else arm"
            Assert-True ($checks[0].Clauses[0].Item2.Statements[0] -is [System.Management.Automation.Language.ThrowStatementAst]) "$var : a direct throw"
            Assert-True (& $always $checks[0]) "$var : unconditional"
            Assert-True ($checks[0].Extent.EndOffset -lt $cleanup[0].Extent.StartOffset) "$var : before Remove-SourceBuildTree"
        }
        $post = @(& $assignsTo '$genaiOrtPost')
        Assert-Match '-TreeRoot \$SourceDir -OrtRoot \$genaiOrtRoot\)' $post[0].Right.Extent.Text
        Assert-Match '-TreeRoot \$genaiInstallDir -OrtRoot \$genaiOrtRoot -ForbidCopies' $post[0].Right.Extent.Text
        $wheels = @(& $find { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-PythonWheelBuild' })
        Assert-True ($post[0].Extent.StartOffset -gt $wheels[$wheels.Count - 1].Extent.EndOffset) 'the post-build gate follows the wheel build'
    }
}
