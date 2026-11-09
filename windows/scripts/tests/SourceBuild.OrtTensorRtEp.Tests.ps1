#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Synthetic PEs and fixture trees cover the pins, seeds, shim and gates; compiling and registering the plugins needs a chain run.

Import-TestRepoModule -Name 'WindowsScripts.Shared', 'WindowsTargetArch.Common', 'WindowsSourceBuild.Common', 'WindowsSmokeTest.Common',
    'WindowsOrtProvenance.Common', 'WindowsBuildDriver.Common', 'WindowsNativeProvenance.Common', 'WindowsOrtProvenance.Build'
$script:TrtEpScript = 'windows\scripts\build\Build-OrtTensorRtEpFromSource.ps1'
$script:OnnxScript = 'windows\scripts\build\Build-OnnxFromSource.ps1'
$script:TrtEpFunction = @('Get-OrtTensorRtEpPin', 'Get-OrtTensorRtEpDeclaration', 'Get-OrtTensorRtEpSeedGap', 'Get-OrtTensorRtMajor',
    'New-OrtTensorRtEpHome', 'Repair-OrtTensorRtProtobufRc', 'Get-OrtTensorRtEpCmakeArgs', 'Get-OrtTensorRtEpModuleFinding', 'Copy-OrtTensorRtEpLicense', 'Install-OrtTensorRtEpArtifact')
$script:PluginExports = @('CreateEpFactories', 'ReleaseEpFactory')
$script:TrtDelay = @('nvinfer_11.dll', 'nvinfer_plugin_11.dll', 'nvonnxparser_11.dll')

function Get-TrtEpPinTable {
    # The versions.env pins the driver forwards; a copy, so a case can blank one key.
    $table = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
    $pins = [ordered]@{}
    foreach ($k in @($table.Keys | Where-Object { $_ -like 'ORT_TENSORRT_EP_*' } | Sort-Object)) { $pins[$k] = $table[$k] }
    return $pins
}

function New-TrtEpPluginPe {
    # The plugin ABI, the chain ORT and TensorRT 11 delay-loaded, unless a case overrides one.
    param([Parameter(Mandatory)][string]$Path, [string[]]$Import = @('onnxruntime.dll'), [string[]]$DelayImport = $script:TrtDelay, [string[]]$Export = $script:PluginExports)
    New-OrtTestPe -Path $Path -Import $Import -DelayImport $DelayImport -Export $Export
}

function New-TrtRuntimeBin {
    # The TENSORRT_ROOT\current\bin set holding what the plugin delay-loads.
    param([Parameter(Mandatory)][string]$Dir, [string[]]$Extra = @())
    $files = @{}
    foreach ($name in @($script:TrtDelay) + $Extra) { $files[$name] = 'x' }
    Write-TestFileTree -Root $Dir -Files $files
    return $Dir
}

function New-TrtEpSeedRoot {
    # The plugin and its four seeds, each with the licence texts Copy-OrtTensorRtEpLicense takes.
    param([Parameter(Mandatory)][string]$Dir)
    $roots = [ordered]@{}
    foreach ($n in 'onnxruntime-ep-tensorrt', 'protobuf', 'onnx', 'gsl', 'flatbuffers') {
        $roots[$n] = Join-Path $Dir "$n-src"
        Write-TestFileTree -Root $roots[$n] -Files @{ 'LICENSE' = "$n text" }
    }
    Write-TestFileTree -Root $roots['protobuf'] -Files @{ 'third_party/utf8_range/LICENSE' = 'utf8 text' }
    return $roots
}

function Get-TrtEpCMakeFixture {
    param([string]$OnnxTag = 'e709452ef2bbc1d113faf678c24e6d3467696e83', [string]$Extra = '')
    return @"
FetchContent_Declare(
  protobuf
  GIT_REPOSITORY https://github.com/protocolbuffers/protobuf.git
  GIT_TAG        v21.12  # Use a specific tag or commit
)
FetchContent_Declare(
  onnx
  GIT_REPOSITORY https://github.com/onnx/onnx.git
  GIT_TAG        $OnnxTag # v1.18.0 Use a specific tag or commit
)
$Extra
  FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG        v1.14.0
  )
"@
}

function Get-TrtProtobufRcFixture {
    return @'
if (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
  add_definitions(/MP)
endif()
# add_definitions(/comment-only-option) is not a command
add_definitions(/utf-8)
add_definitions(
  /wd4065 # /bigobj in a comment (not a compiler argument)
  /wd4355 # compiler option after the comment closing parenthesis
)
add_definitions(/bigobj)
add_definitions(-DPROTOBUF_FIXTURE)
if (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")
  # Configure Resource Compiler
  enable_language(RC)
  set(rc_flags "/l0x409")
  set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> ${rc_flags} <DEFINES> /fo<OBJECT> <SOURCE>")
endif()
'@
}

Describe 'Build-OrtTensorRtEpFromSource.ps1' {
    $definition = Get-ScriptFunctionDefinition -ScriptPath $script:TrtEpScript -FunctionName $script:TrtEpFunction
    . $definition

    It 'takes the plugin commit and every seed from the pins, and refuses a missing ref or hash (mutation)' {
        $pins = Get-TrtEpPinTable
        Assert-Equal 10 $pins.Count 'the commit and four seeds, each with its hash'
        Invoke-WithProcessEnvironment -Environment $pins -ScriptBlock {
            $got = @(Get-OrtTensorRtEpPin)
            Assert-Equal 'onnxruntime-ep-tensorrt,protobuf,onnx,gsl,flatbuffers' ($got.Name -join ',') 'the plugin first, then its seeds'
            Assert-Equal "https://github.com/onnxruntime/onnxruntime-ep-tensorrt/archive/$($pins['ORT_TENSORRT_EP_COMMIT']).tar.gz" $got[0].Url 'the commit tarball versions.env hashes'
            Assert-Equal "https://github.com/protocolbuffers/protobuf.git@v$($pins['ORT_TENSORRT_EP_PROTOBUF_VERSION'])" "$($got[1].Repo)@$($got[1].Tag)" 'the GIT_TAG the seed must equal'
            Assert-Equal $pins['ORT_TENSORRT_EP_ONNX_COMMIT'] $got[2].Tag 'onnx is pinned by commit'
        }
        foreach ($blank in 'ORT_TENSORRT_EP_GSL_SHA256', 'ORT_TENSORRT_EP_ONNX_COMMIT') {
            $broken = Get-TrtEpPinTable
            $broken[$blank] = ''
            Invoke-WithProcessEnvironment -Environment $broken -ScriptBlock {
                Assert-Throws { Get-OrtTensorRtEpPin } "blank $blank" -MessagePattern ([regex]::Escape($blank))
            }
        }
    }

    It 'requires every FetchContent the plugin declares to be a seed of the same repository and tag, googletest aside (mutation)' {
        $pins = @(
            [pscustomobject]@{ Name = 'onnxruntime-ep-tensorrt'; Repo = ''; Tag = '' }
            [pscustomobject]@{ Name = 'protobuf'; Repo = 'https://github.com/protocolbuffers/protobuf.git'; Tag = 'v21.12' }
            [pscustomobject]@{ Name = 'onnx'; Repo = 'https://github.com/onnx/onnx.git'; Tag = 'e709452ef2bbc1d113faf678c24e6d3467696e83' }
        )
        $declared = Get-OrtTensorRtEpDeclaration -CMakeText (Get-TrtEpCMakeFixture)
        Assert-Equal 'https://github.com/protocolbuffers/protobuf.git@v21.12' $declared['protobuf'] 'the tag, not its comment'
        Assert-Equal 0 @(Get-OrtTensorRtEpSeedGap -Declared $declared -Pin $pins).Count 'every active declaration is seeded'
        $drift = @(Get-OrtTensorRtEpSeedGap -Declared (Get-OrtTensorRtEpDeclaration -CMakeText (Get-TrtEpCMakeFixture -OnnxTag 'v1.19.0')) -Pin $pins) -join ';'
        Assert-Match 'declares onnx https://github\.com/onnx/onnx\.git@v1\.19\.0, which no hash-pinned seed matches' $drift 'a moved tag'
        $extra = "FetchContent_Declare(`n  eigen`n  GIT_REPOSITORY https://gitlab.com/libeigen/eigen.git`n  GIT_TAG 3.4.0`n)"
        Assert-Match 'declares eigen .*, which no hash-pinned seed matches' (@(Get-OrtTensorRtEpSeedGap -Declared (Get-OrtTensorRtEpDeclaration -CMakeText (Get-TrtEpCMakeFixture -Extra $extra)) -Pin $pins) -join ';') 'a new download'
        $gone = Get-OrtTensorRtEpDeclaration -CMakeText ((Get-TrtEpCMakeFixture) -replace '(?s)FetchContent_Declare\(\s*onnx.*?\)', '')
        Assert-Match 'the seed onnx .* is no longer what the plugin declares' (@(Get-OrtTensorRtEpSeedGap -Declared $gone -Pin $pins) -join ';') 'a dropped seed'
        $caseDrift = @(Get-OrtTensorRtEpSeedGap -Declared ([ordered]@{ protobuf = 'https://github.com/protocolbuffers/Protobuf.git@v21.12'; onnx = $declared['onnx'] }) -Pin $pins) -join ';'
        Assert-Match 'declares protobuf https://github\.com/protocolbuffers/Protobuf\.git' $caseDrift 'a repository spelled otherwise is another download'
        Assert-Match 'declares no FetchContent' (@(Get-OrtTensorRtEpSeedGap -Declared (Get-OrtTensorRtEpDeclaration -CMakeText '') -Pin $pins) -join ';') 'a moved layout checks nothing'
    }

    It 'reads the TensorRT major from the SDK import library and refuses none or two' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Get-OrtTensorRtMajor -SdkRoot $dir } 'no SDK' -MessagePattern 'found 0'
            Write-TestFileTree -Root $dir -Files @{ 'lib/nvinfer_11.lib' = 'x'; 'lib/nvinfer_plugin_11.lib' = 'x'; 'lib/nvonnxparser_11.lib' = 'x' }
            Assert-Equal '11' (Get-OrtTensorRtMajor -SdkRoot $dir) 'nvinfer_<major>.lib, never the plugin library'
            Write-TestFileTree -Root $dir -Files @{ 'lib/nvinfer_10.lib' = 'x' }
            Assert-Throws { Get-OrtTensorRtMajor -SdkRoot $dir } 'two majors' -MessagePattern 'found 2'
        }
    }

    It 'builds an ORT_HOME of the chain''s flat headers and import library only, and refuses a chain without headers (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-TestOrtChainPrefix -Dir $dir
            $shim ={ New-OrtTensorRtEpHome -OrtPrefix $chain -Path (Join-Path $dir 'ort-home') }
            $ortHome = & $shim
            $tree = @(Get-ChildItem -LiteralPath $ortHome -Recurse -File | ForEach-Object {
                    "$([IO.Path]::GetRelativePath($ortHome, $_.FullName) -replace '\\', '/')=$([IO.File]::ReadAllText($_.FullName))" } | Sort-Object) -join ';'
            Assert-Equal 'include/onnxruntime_c_api.h=c;include/onnxruntime_cxx_api.h=cxx;lib/onnxruntime.lib=chain implib' $tree 'flat headers and the import library, no DLL the census would count'
            Remove-Item -LiteralPath (Join-Path $chain 'include/onnxruntime/onnxruntime_c_api.h')
            Assert-Throws $shim 'no headers' -MessagePattern 'installs no include'
        }
    }

    It 'scopes every protobuf compiler option to C/C++ and preserves definitions and the MSVC-only RC block (mutation)' {
        Invoke-InTestDir { param($dir)
            foreach ($lineEnding in @("`n", "`r`n")) {
                Write-TestFileTree -Root $dir -Files @{ 'CMakeLists.txt' = (Get-TrtProtobufRcFixture).Replace("`r`n", "`n").Replace("`n", $lineEnding) }
                Repair-OrtTensorRtProtobufRc -SeedRoot $dir
                $fixed = [IO.File]::ReadAllText((Join-Path $dir 'CMakeLists.txt'))
                $literals = @(foreach ($option in 'MP', 'utf-8', 'wd4065', 'wd4355', 'bigobj') { '"$<$<COMPILE_LANGUAGE:C,CXX>:/{0}>"' -f $option })
                Assert-TestScriptContains -ScriptPath (Join-Path $dir 'CMakeLists.txt') -Literal ($literals + @(
                    'add_definitions(-DPROTOBUF_FIXTURE)', 'if (CMAKE_CXX_COMPILER_ID STREQUAL "MSVC")',
                    '# /bigobj in a comment (not a compiler argument)',
                    '# add_definitions(/comment-only-option) is not a command',
                    'set(CMAKE_RC_COMPILE_OBJECT "<CMAKE_RC_COMPILER> ${rc_flags} <DEFINES> /fo<OBJECT> <SOURCE>")'
                )) -ReasonPrefix 'retained protobuf compiler/resource contract'
                Assert-False (($fixed -replace '(?m)#.*$', '') -match 'add_definitions\(\s*/') 'no compiler flag reaches the resource language'
                Assert-FileUnchanged -Path (Join-Path $dir 'CMakeLists.txt') -Action {
                    Repair-OrtTensorRtProtobufRc -SeedRoot $dir
                } -Reason 'already-fixed source is byte-stable'
            }
        }
    }

    It 'refuses missing or changed protobuf compiler-option inputs (mutation)' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Repair-OrtTensorRtProtobufRc -SeedRoot $dir } -MessagePattern 'file not found'
            foreach ($text in @(
                'add_compile_options("$<$<COMPILE_LANGUAGE:C,CXX>:/bigobj>")',
                (Get-TrtProtobufRcFixture).Replace('/bigobj', '/unexpected-option'),
                (Get-TrtProtobufRcFixture).Replace('/wd4065', '/wd4065 /unexpected-option'),
                (Get-TrtProtobufRcFixture).Replace('/wd4355', '/wd4355 /unexpected-option'),
                (Get-TrtProtobufRcFixture).Replace('add_definitions(/bigobj)', '')
            )) {
                Write-TestFileTree -Root $dir -Files @{ 'CMakeLists.txt' = $text }
                $pattern = if ($text.Contains('/unexpected-option')) { 'Unexpected protobuf compiler option: /unexpected-option' } else { 'protobuf.*scope' }
                Assert-FileUnchanged -Path (Join-Path $dir 'CMakeLists.txt') -Action {
                    Assert-Throws { Repair-OrtTensorRtProtobufRc -SeedRoot $dir } -MessagePattern $pattern
                } -Reason 'drift fails before rewriting the input'
            }
        }
    }

    It 'refuses unscoped arguments inside already-scoped protobuf option blocks (mutation)' {
        Invoke-InTestDir -Files @{ 'CMakeLists.txt' = (Get-TrtProtobufRcFixture) } -Body { param($dir)
            Repair-OrtTensorRtProtobufRc -SeedRoot $dir
            $fixed = [IO.File]::ReadAllText((Join-Path $dir 'CMakeLists.txt'))
            $warning = '"$<$<COMPILE_LANGUAGE:C,CXX>:/wd4065>"'
            foreach ($extra in '/bigobj', '"/bigobj"', '-DUNSCOPED', '"$<$<COMPILE_LANGUAGE:C,CXX>:/unexpected-option>"') {
                Write-TestFileTree -Root $dir -Files @{ 'CMakeLists.txt' = $fixed.Replace($warning, "$warning $extra") }
                Assert-Throws { Repair-OrtTensorRtProtobufRc -SeedRoot $dir } -MessagePattern 'protobuf.*scope'
            }
        }
    }

    It 'repairs the protobuf seed unconditionally before the TensorRT configure (mutation)' {
        $repair = @(Get-TestScriptCommands -ScriptPath $script:TrtEpScript -Name 'Repair-OrtTensorRtProtobufRc')
        Assert-TestAstCommand -Command $repair -Text "Repair-OrtTensorRtProtobufRc -SeedRoot `$roots['protobuf']" -Unconditional
        $configure = @(Get-TestScriptCommands -ScriptPath $script:TrtEpScript -Name 'Invoke-CmakeConfigureLogged')[-1]
        Assert-TestAstOrder -Before $repair[0] -After $configure
    }

    It 'configures against the shim, the SDK and every seed, with downloads and the plugin''s own cache launcher off (mutation)' {
        function Get-NvccCudaCmakeArgs { param($CudaRoot, $CudaStandard) @("-DCMAKE_CUDA_COMPILER:FILEPATH=$CudaRoot/bin/nvcc.exe", "-DCMAKE_CUDA_STANDARD:STRING=$CudaStandard") }
        $seeds = [ordered]@{ protobuf = 'C:\t\protobuf-src\protobuf-21.12'; gsl = 'C:\t\gsl-src\GSL-4.0.0' }
        $a = @(Get-OrtTensorRtEpCmakeArgs -OrtHome 'C:\t\ort-home' -TensorRtSdk 'C:\tensorrt-sdk\current' -TrtMajor '11' -CudaRoot 'C:\cuda' -Python 'C:\py\python.exe' -SeedRoot $seeds)
        $cxx = @($a | Where-Object { $_.StartsWith('-DCMAKE_CXX_FLAGS:STRING=') })
        Assert-Equal 1 $cxx.Count 'one complete C++ flag argument reaches CMake'
        Assert-Match '(?:=|\s)/EHsc(?:\s|$)' $cxx[0] 'the ORT C++ API throws, so plugin flags must retain exceptions'
        foreach ($want in '-DORT_HOME:PATH=C:/t/ort-home', '-DTENSORRT_HOME:PATH=C:/tensorrt-sdk/current', '-DTRT_MAJOR_VERSION:STRING=11',
            '-Donnxruntime_ep_tensorrt_OBJECT_CACHE=OFF', '-Donnxruntime_ep_tensorrt_INSTALL=OFF', '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON',
            '-DCMAKE_POLICY_DEFAULT_CMP0170:STRING=NEW', '-DFETCHCONTENT_SOURCE_DIR_PROTOBUF:PATH=C:/t/protobuf-src/protobuf-21.12',
            '-DFETCHCONTENT_SOURCE_DIR_GSL:PATH=C:/t/gsl-src/GSL-4.0.0', '-DCMAKE_CUDA_STANDARD:STRING=17', '-DPython3_EXECUTABLE:FILEPATH=C:/py/python.exe') {
            Assert-True ($a -contains $want) "missing $want"
        }
    }

    It 'requires the plugin ABI, the chain ORT and every TensorRT DLL it delay-loads in the runtime set (mutation)' {
        Invoke-InTestDir { param($dir)
            $bin = New-TrtRuntimeBin -Dir (Join-Path $dir 'trt-bin')
            $dll = Join-Path $dir 'onnxruntime_ep_tensorrt.dll'
            New-TrtEpPluginPe -Path $dll -Import @('onnxruntime.dll', 'cudart64_13.dll')
            Assert-Equal 0 @(Get-OrtTensorRtEpModuleFinding -Dll $dll -TrtMajor '11' -TensorRtBin $bin).Count 'healthy'
            New-TrtEpPluginPe -Path $dll -Import @('onnxruntime.dll', 'onnxruntime_foreign.dll') -DelayImport @('nvinfer_11.dll', 'nvonnxparser_11.dll') -Export ($script:PluginExports + 'GetProvider')
            $f = @(Get-OrtTensorRtEpModuleFinding -Dll $dll -TrtMajor '11' -TensorRtBin $bin) -join ';'
            Assert-Match 'does not import nvinfer_plugin_11\.dll' $f 'a TensorRT DLL it no longer loads'
            Assert-Match 'onnxruntime_foreign\.dll, which is not the chain ORT' $f 'a foreign ORT import'
            Assert-Match 'exports GetProvider' $f 'the provider-bridge entry'
            New-TrtEpPluginPe -Path $dll
            Remove-Item -LiteralPath (Join-Path $bin 'nvonnxparser_11.dll')
            Assert-Match 'nvonnxparser_11\.dll is not in' (@(Get-OrtTensorRtEpModuleFinding -Dll $dll -TrtMajor '11' -TensorRtBin $bin) -join ';') 'a DLL the runtime set lacks'
        }
    }

    It 'stages the plugin''s and every statically linked seed''s licence texts and refuses a moved one' {
        Invoke-InTestDir { param($dir)
            $roots = New-TrtEpSeedRoot -Dir $dir
            $ep = Join-Path $dir 'ep'
            $texts = @(Copy-OrtTensorRtEpLicense -EpDir $ep -SourceRoot $roots)
            Assert-Equal 6 $texts.Count 'five LICENSE files and utf8_range'
            Assert-True ($texts -contains 'licenses\protobuf\third_party\utf8_range\LICENSE') 'the manifest names it relative to the EP'
            Assert-Equal 'utf8 text' (Get-Content -LiteralPath ([IO.Path]::Combine($ep, 'licenses', 'protobuf', 'third_party', 'utf8_range', 'LICENSE')) -Raw).Trim() 'the original text'
            Remove-Item -LiteralPath ([IO.Path]::Combine($roots['protobuf'], 'third_party', 'utf8_range', 'LICENSE'))
            Assert-Throws { Copy-OrtTensorRtEpLicense -EpDir $ep -SourceRoot $roots } 'a moved text' -MessagePattern 'utf8_range'
        }
    }

    It 'stages one directory over a stale one: the plugin, its licence texts and provenance, and no TensorRT DLL (mutation)' {
        Invoke-InTestDir { param($dir)
            $roots = New-TrtEpSeedRoot -Dir $dir
            $build = Join-Path $dir 'build'
            Write-TestFileTree -Root $build -Files @{ 'onnxruntime_ep_tensorrt.dll' = 'plugin'; 'nvinfer_11.dll' = 'POST_BUILD copy' }
            $ep = Invoke-TestPluginStage -Dir $dir -Expected @('provenance/onnxruntime-ep-tensorrt.json') -Install {
                param($ep, $pin) Install-OrtTensorRtEpArtifact -BuildDir $build -SourceRoot $roots -EpDir $ep -Pin $pin
            }
            Assert-Equal 'onnxruntime_ep_tensorrt.dll' (@(Get-ChildItem -LiteralPath $ep -Filter '*.dll' -File).Name -join ',') 'no TensorRT DLL and no stale stage beside it'
        }
    }
}

Describe 'Get-OrtPluginEpExportGap' {
    It 'names a missing plugin entry point, and the provider-bridge entry only when asked (mutation)' {
        Invoke-InTestDir { param($dir)
            $dll = Join-Path $dir 'plugin.dll'
            New-OrtTestPe -Path $dll -Export $script:PluginExports
            Assert-Equal 0 @(Get-OrtPluginEpExportGap -Path $dll -ForbidProviderBridge).Count 'the plugin ABI alone'
            New-OrtTestPe -Path $dll -Export @('CreateEpFactories')
            Assert-Match 'plugin\.dll does not export ReleaseEpFactory' (@(Get-OrtPluginEpExportGap -Path $dll) -join ';') 'a missing entry point'
            New-OrtTestPe -Path $dll -Export ($script:PluginExports + 'GetProvider')
            Assert-Equal 0 @(Get-OrtPluginEpExportGap -Path $dll).Count 'QNN may keep the bridge entry'
            Assert-Match 'exports GetProvider' (@(Get-OrtPluginEpExportGap -Path $dll -ForbidProviderBridge) -join ';') 'a provider-bridge build under the plugin''s name'
        }
    }
}

Describe 'Get-OrtNvidiaPluginFinding (smoke)' {
    It 'passes both plugins and names each gap: a bridge CUDA EP, an in-tree TensorRT EP, a missing or unexpected TensorRT plugin, a DLL the runtime lacks (mutation)' {
        Invoke-InTestDir { param($dir)
            $ort = Join-Path $dir 'ort'; $ep = Join-Path $dir 'ep-trt'
            $cuda = Join-Path $ort 'bin/onnxruntime_providers_cuda.dll'; $trt = Join-Path $ep 'onnxruntime_ep_tensorrt.dll'
            New-OrtTestPe -Path $cuda -Import @('onnxruntime.dll', 'nvcuda.dll') -Export $script:PluginExports
            New-TrtEpPluginPe -Path $trt
            $bin = New-TrtRuntimeBin -Dir (Join-Path $dir 'trt-bin') -Extra 'nvinfer_builder_resource_win_11.dll'
            $finding = { param([bool]$Staged = $true) @(Get-OrtNvidiaPluginFinding -OrtRoot $ort -TensorRtEpRoot $ep -TensorRtBinDir $bin -TensorRtStaged $Staged) -join ';' }
            Assert-Equal '' (& $finding) 'healthy'
            Assert-Match 'is staged although no TensorRT runtime is' (& $finding $false) 'a plugin without its runtime'
            Remove-Item -LiteralPath (Join-Path $bin 'nvinfer_plugin_11.dll')
            Assert-Match 'nvinfer_plugin_11\.dll' (& $finding) 'the runtime set lacks a DLL the plugin loads'
            Write-TestFileTree -Root $bin -Files @{ 'nvinfer_plugin_11.dll' = 'x' }
            New-OrtTestPe -Path (Join-Path $ort 'bin/onnxruntime_providers_tensorrt.dll') -Export @('GetProvider')
            Assert-Match 'in-tree TensorRT EP in the chain ORT' (& $finding) 'the in-tree TensorRT EP'
            Remove-Item -LiteralPath (Join-Path $ort 'bin/onnxruntime_providers_tensorrt.dll')
            New-OrtTestPe -Path $cuda -Export ($script:PluginExports + 'GetProvider')
            Assert-Match 'onnxruntime_providers_cuda\.dll exports GetProvider' (& $finding) 'a provider-bridge CUDA EP'
            Remove-Item -LiteralPath $cuda, $trt
            $f = & $finding
            Assert-Match 'no onnxruntime_providers_cuda\.dll' $f 'no CUDA plugin'
            Assert-Match 'no onnxruntime_ep_tensorrt\.dll under ORT_TENSORRT_EP_ROOT' $f 'no TensorRT plugin'
        }
    }
}

Describe 'CUDA plugin EP (Build-OnnxFromSource.ps1)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:OnnxScript -FunctionName @('Assert-OrtCudaPluginEp'))

    It 'builds CUDA as the plugin with no in-tree TensorRT, and stops on a staged DLL that is not the plugin (mutation)' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:OnnxScript))
        Assert-Match ([regex]::Escape("'-Donnxruntime_USE_CUDA=ON', '-Donnxruntime_BUILD_CUDA_EP_AS_PLUGIN=ON', '-Donnxruntime_USE_TENSORRT=OFF'")) $text 'plugin on, TensorRT off'
        Assert-False ($text -match 'USE_TENSORRT=ON|TENSORRT_ROOT|TensorRtRoot') 'no in-tree TensorRT path is left'
        Assert-Match ([regex]::Escape('if ($cudaUsable) { Assert-OrtCudaPluginEp -OrtInstallDir $ortInstallDir }')) $text 'the gate runs on every CUDA lane'
        Invoke-InTestDir { param($dir)
            Assert-Throws { Assert-OrtCudaPluginEp -OrtInstallDir $dir } 'nothing staged' -MessagePattern 'was not installed'
            $dll = Join-Path $dir 'bin/onnxruntime_providers_cuda.dll'
            New-OrtTestPe -Path $dll -Export $script:PluginExports
            Assert-OrtCudaPluginEp -OrtInstallDir $dir 6>$null
            New-OrtTestPe -Path $dll -Export @('GetProvider')
            Assert-Throws { Assert-OrtCudaPluginEp -OrtInstallDir $dir 6>$null } 'the provider bridge' -MessagePattern 'does not export CreateEpFactories.*exports GetProvider'
        }
    }

    It 'rewrites every force-include test to the frontend variant when the patch drifts (mutation)' {
        $calls = @(Get-TestAstCommands -Ast (Get-TestScriptAst -ScriptPath $script:OnnxScript) -Name 'Invoke-OrtRegexPatchWithFallback' | Where-Object { "$_" -match 'cuda_plugin' })
        Assert-Equal 1 $calls.Count 'one fallback for the plugin CMake'
        $a = Get-TestCommandArguments -Command $calls[0]
        $text = '"$<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CXX_COMPILER_ID:MSVC>>>:-include>" "$<$<CXX_COMPILER_ID:MSVC>:/FI>"'
        Assert-Equal '"$<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CXX_COMPILER_FRONTEND_VARIANT:MSVC>>>:-include>" "$<$<CXX_COMPILER_FRONTEND_VARIANT:MSVC>:/FI>"' `
            ($text -replace $a.Pattern.Trim("'"), $a.Replacement.Trim("'")) 'clang-cl gets /FI from both tests'
    }

    It 'patches the plugin CMake for clang-cl and carries no patch for the in-tree CUDA CMake' {
        $patches = Join-Path (Get-RepoRoot) 'windows\scripts\patches\onnxruntime'
        $patch = [IO.File]::ReadAllText((Join-Path $patches '008-cuda-plugin-clangcl-force-include.patch'))
        Assert-Match '\+\+\+ b/cmake/onnxruntime_providers_cuda_plugin\.cmake' $patch 'the plugin CMake'
        Assert-Equal 4 ([regex]::Matches($patch, '(?m)^\+.*CXX_COMPILER_FRONTEND_VARIANT:MSVC')).Count 'all four force-include tests'
        Assert-False (Test-Path -LiteralPath (Join-Path $patches '002-disable-cuda-pch.patch')) 'the PCH patch targeted the in-tree CUDA CMake, which the plugin build never includes'
    }
}

Describe 'NVIDIA plugin EP wiring' {
    It 'builds the TensorRT plugin in the ORT RUN after the QNN plugin, with its script, the G2 gate and every pin (mutation)' {
        $chain = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-MediaCoreAll.ps1'))
        Assert-Match "(?s)'QNN plugin EP'.*'TensorRT plugin EP'; Script = 'Build-OrtTensorRtEpFromSource\.ps1'.*'ONNX GenAI'" $chain 'after the QNN plugin, before GenAI'
        $envLines = @((Get-TrtEpPinTable).Keys | ForEach-Object { "$_=`"`${$_}`"" })
        Assert-TestScriptContains -ScriptPath 'windows\Dockerfile.media-builder' -ReasonPrefix 'the ORT RUN carries' -Literal (@(
                "-Until 'TensorRT plugin EP'", 'source=windows/scripts/build/Build-OrtTensorRtEpFromSource.ps1,target=C:\bkmnt\Build-OrtTensorRtEpFromSource.ps1'
                'source=windows/scripts/modules/WindowsOrtProvenance.Build.psm1,target=C:\bkmnt\ortmods\WindowsOrtProvenance.Build.psm1') + $envLines)
        Assert-TestScriptContains -ScriptPath 'windows\Dockerfile.media-merge-builder' -ReasonPrefix 'the image names' -Literal @('ORT_TENSORRT_EP_ROOT="C:\runtime\lib\onnxruntime-ep-tensorrt"')
        $table = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        $forwarded = (Get-MediaBranchVersionArg -Branch 'media-core' -VersionTable $table).Keys
        foreach ($k in (Get-TrtEpPinTable).Keys) { Assert-True ($forwarded -contains $k) "the driver forwards $k to media-core" }
    }

    It 'stamps G2 unconditionally after its own checks, over its whole tree, the shim and its CMake records (mutation)' {
        $ast = Get-TestScriptAst -ScriptPath $script:TrtEpScript
        $gate = @(Get-TestAstCommands -Ast $ast -Name 'Assert-ChainOrtOnly')
        Assert-TestAstCommand -Command $gate -Text "Assert-ChainOrtOnly -Consumer 'tensorrt-ep' -OrtRoot `$ortPrefix -TreeRoot `$SourceDir -Shim `$ortHome -Log `$cfgLog -CmakeBuildDir `$buildDir" -Unconditional
        $checks = @(Get-TestAstCommands -Ast $ast -Name 'Get-OrtTensorRtEpModuleFinding')[-1]
        Assert-True ($checks.Extent.EndOffset -lt $gate[0].Extent.StartOffset) 'after the module checks'
    }

    It 'the G2 gate reads a -CmakeBuildDir tree''s CMakeCache.txt and build.ninja, and a plugin EP''s files are no foreign ORT (mutation)' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'configure.log'
            Set-Content -LiteralPath $log -Value 'configured'
            $gate = @{ Consumer = 'probe'; TreeRoot = $dir; OrtRoot = (New-TestOrtChainPrefix -Dir $dir); WheelDir = ''; OrtVersion = ''; CacheRoot = @(); Log = $log; StampDir = (Join-Path $dir 'stamp') }
            Write-TestFileTree -Root $dir -Files @{ 'build/onnxruntime_ep_tensorrt.dll' = 'plugin'; 'build/onnxruntime_ep_tensorrt.lib' = 'implib'
                'src/csharp/Microsoft.ML.OnnxRuntime.EP.TensorRT/TensorRTEp.cs' = 'cs' }
            $why = try { Assert-ChainOrtOnly @gate -CmakeBuildDir (Join-Path $dir 'nope') 6>$null; '' } catch { $_.Exception.Message }
            Assert-Match 'nope.CMakeCache\.txt is missing.*nope.build\.ninja is missing' $why 'both records of a missing tree'
            Assert-False ($why -match 'onnxruntime_ep_tensorrt|OnnxRuntime\.EP') 'the plugin''s own module and C# package are a consumer''s, not a foreign ORT'
        }
    }

    It 'the census holds the TensorRT plugin to the gated consumer contract, and the smoke grades both plugins' {
        $entry = @(Get-OrtConsumerContract | Where-Object Name -EQ 'tensorrt-ep')
        Assert-Equal 1 $entry.Count 'one contract entry'
        Assert-Equal 'onnxruntime_ep_tensorrt.dll' ($entry[0].Pattern -join ',') 'by its DLL name'
        Assert-TestScriptContains -ScriptPath 'windows\scripts\build\Test-Container.ps1' -ReasonPrefix 'the ORT smoke' -Literal @(
            'Assert-OrtNvidiaPluginSmoke -OnnxRoot $onnxRoot -OnnxLink $onnxLink -OnnxEpProbeSource $onnxEpProbeSource'
            "-ExpectMatch 'trt=0 dml=\d cudaplugin=1'")
    }

    It 'bakes each plugin path into the registration probe as an escaped wide string' {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-Container.ps1' -FunctionName @('Get-OrtPluginRegistrationProbeSource'))
        $src = Get-OrtPluginRegistrationProbeSource -Plugin ([ordered]@{ CUDAExecutionProvider = 'C:\runtime\lib\onnxruntime-source\bin\onnxruntime_providers_cuda.dll' })
        Assert-Match ([regex]::Escape('{"CUDAExecutionProvider", L"C:\\runtime\\lib\\onnxruntime-source\\bin\\onnxruntime_providers_cuda.dll"},')) $src 'one row per plugin'
        Assert-Match 'RegisterExecutionProviderLibrary\(env, p\.name, p\.path\)' $src 'registers by library path'
        Assert-Match 'plugins registered=%zu' $src 'the count the smoke matches'
    }
}
