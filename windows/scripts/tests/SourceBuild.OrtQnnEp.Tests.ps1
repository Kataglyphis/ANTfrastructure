#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Fixture trees cover the pins, the --ort_home shim, the header copy and both gates; the fork's compile is proven only by a chain run.

Import-TestRepoModule -Name 'WindowsSourceBuild.Common', 'WindowsSmokeTest.Common', 'WindowsOrtProvenance.Common', 'WindowsNativeProvenance.Common'
$script:QnnEpScript = 'windows\scripts\build\Build-OrtQnnEpFromSource.ps1'
$script:QnnEpFunction = @('Get-OrtQnnEpPin', 'Get-OrtQnnEpCoreVersion', 'Get-OrtQnnEpChainFile', 'New-OrtQnnEpHome', 'Copy-OrtQnnEpHeader',
    'Get-OrtQnnEpCmakeArgs', 'Get-OrtQnnEpForeignCore', 'Get-OrtQnnEpModuleFinding', 'Get-OrtQnnEpBuiltDll', 'Copy-OrtQnnEpLicense',
    'Install-OrtQnnEpArtifact')

Describe 'Build-OrtQnnEpFromSource.ps1' {
    $definition = Get-ScriptFunctionDefinition -ScriptPath $script:QnnEpScript -FunctionName $script:QnnEpFunction
    . $definition

    It 'takes the fork tag and its tarball hash from the pins and refuses either missing (mutation)' {
        $pin = Get-OrtQnnEpPin -Version '2.7.0' -Sha256 ('AB' * 32)
        Assert-Equal 'https://github.com/onnxruntime/onnxruntime-qnn/archive/refs/tags/v2.7.0.tar.gz' $pin.Url 'the tag tarball versions.env hashes'
        Assert-Equal ('ab' * 32) $pin.Sha256 'lower-cased hash'
        Assert-Throws { Get-OrtQnnEpPin -Version '' -Sha256 ('ab' * 32) } 'no version' -MessagePattern 'ORT_QNN_EP_VERSION'
        Assert-Throws { Get-OrtQnnEpPin -Version '2.7.0' -Sha256 '' } 'no hash' -MessagePattern 'unverified'
        $table = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
        Assert-True ([bool](Get-OrtQnnEpPin -Version $table['ORT_QNN_EP_VERSION'] -Sha256 $table['ORT_QNN_EP_SOURCE_SHA256'])) 'the versions.env pins pass'
    }

    It 'reads the ort_core tag from deps.txt and refuses a deps.txt without one' {
        Invoke-InTestDir { param($dir)
            Write-TestFileTree -Root $dir -Files @{ 'cmake/deps.txt' = "abseil_cpp;https://x/a.zip;1`nort_core;https://github.com/microsoft/onnxruntime/archive/refs/tags/v1.29.0.zip;3b96`n" }
            Assert-Equal '1.29.0' (Get-OrtQnnEpCoreVersion -ForkRoot $dir) 'ort_core tag'
            Write-TestFileTree -Root $dir -Files @{ 'cmake/deps.txt' = "abseil_cpp;https://x/a.zip;1`n" }
            Assert-Throws { Get-OrtQnnEpCoreVersion -ForkRoot $dir } 'no ort_core' -MessagePattern 'names no ort_core'
        }
    }

    It 'builds an --ort_home whose lib\ is the chain''s bytes under the names the fork copies, and refuses a partial chain (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-TestOrtChainPrefix -Dir $dir
            $ortHome = New-OrtQnnEpHome -OrtPrefix $chain -Path (Join-Path $dir 'ort-home')
            $names = @(Get-ChildItem -LiteralPath (Join-Path $ortHome 'lib') -File | ForEach-Object Name | Sort-Object) -join ','
            $want = @('onnxruntime.dll', 'onnxruntime.lib', 'onnxruntime_providers_shared.dll', 'onnxruntime_providers_shared.lib' | Sort-Object) -join ','
            Assert-Equal $want $names 'the four names'
            Assert-Equal 'chain core' (Get-Content -LiteralPath (Join-Path $ortHome 'lib\onnxruntime.dll') -Raw).Trim() 'the chain''s bytes'
            Assert-True (Test-Path -LiteralPath (Join-Path $ortHome 'include') -PathType Container) 'include\ waits for the headers'
            Remove-Item -LiteralPath (Join-Path $chain 'lib\onnxruntime_providers_shared.lib')
            Assert-Throws { New-OrtQnnEpHome -OrtPrefix $chain -Path (Join-Path $dir 'ort-home') } 'partial chain' -MessagePattern 'holds no onnxruntime_providers_shared\.lib'
        }
    }

    It 'copies the fork''s ort_core public headers flat and refuses an unpopulated ort_core' {
        Invoke-InTestDir { param($dir)
            $ortHome = Join-Path $dir 'home'; $null = New-Item -ItemType Directory -Force -Path (Join-Path $ortHome 'include')
            $core = Join-Path $dir 'ort_core-src'
            Assert-Throws { Copy-OrtQnnEpHeader -OrtHome $ortHome -OrtCoreSource $core } 'no headers' -MessagePattern 'did not populate ort_core'
            Write-TestFileTree -Root $core -Files @{
                'include/onnxruntime/core/session/onnxruntime_c_api.h' = 'c'; 'include/onnxruntime/core/session/onnxruntime_cxx_inline.h' = 'i'
                'include/onnxruntime/core/providers/cpu/cpu_provider_factory.h' = 'p'; 'include/onnxruntime/core/framework/provider_options.h' = 'f'
                'include/onnxruntime/core/graph/basic_types.h' = 'not public'
            }
            Assert-Equal 4 (Copy-OrtQnnEpHeader -OrtHome $ortHome -OrtCoreSource $core) 'session, providers\cpu and framework'
            Assert-True (Test-Path -LiteralPath (Join-Path $ortHome 'include\onnxruntime_c_api.h')) 'flat, as a release package'
            Assert-False (Test-Path -LiteralPath (Join-Path $ortHome 'include\basic_types.h')) 'only the three public dirs'
        }
    }

    It 'configures QNN against the --ort_home shim with the QAIRT arch dir and no unit tests' {
        $a = @(Get-OrtQnnEpCmakeArgs -QnnHome 'C:\q\qairt\2.51' -QnnArchAbi 'aarch64-windows-msvc' -OrtHome 'C:\t\ort-home' -Python 'C:\py\python.exe')
        foreach ($want in '-Donnxruntime_USE_QNN=ON', '-Donnxruntime_BUILD_SHARED_LIB=ON', '-Donnxruntime_BUILD_UNIT_TESTS=OFF',
            '-Donnxruntime_QNN_HOME=C:/q/qairt/2.51', '-DQNN_ARCH_ABI=aarch64-windows-msvc', '-Donnxruntime_ORT_HOME=C:/t/ort-home') {
            Assert-True ($a -contains $want) "missing $want"
        }
    }

    It 'passes the fork''s copies of the chain library and fails a core the chain did not build (mutation)' {
        Invoke-InTestDir { param($dir)
            $chain = New-TestOrtChainPrefix -Dir $dir
            $build = Join-Path $dir 'build'
            Write-TestFileTree -Root $build -Files @{ 'onnxruntime.dll' = 'chain core'; 'onnxruntime_providers_shared.dll' = 'chain shared' }
            Assert-Equal 0 @(Get-OrtQnnEpForeignCore -BuildDir $build -OrtPrefix $chain).Count 'byte copies of the chain pass'
            Write-TestFileTree -Root $build -Files @{ '_deps/ort_core-build/Release/onnxruntime.dll' = 'a core of its own' }
            $foreign = @(Get-OrtQnnEpForeignCore -BuildDir $build -OrtPrefix $chain)
            Assert-Equal 1 $foreign.Count 'one foreign core'
            Assert-Match 'ort_core-build' $foreign[0] 'names the foreign file'
        }
    }

    It 'stages the link output at the build root, not the copy the fork puts in its wheel tree (mutation)' {
        Invoke-InTestDir { param($dir)
            Write-TestFileTree -Root $dir -Files @{ 'onnxruntime_qnn/onnxruntime_providers_qnn.dll' = 'wheel copy' }
            Assert-Throws { Get-OrtQnnEpBuiltDll -BuildDir $dir } 'only the wheel copy' -MessagePattern 'no link output'
            Write-TestFileTree -Root $dir -Files @{ 'onnxruntime_providers_qnn.dll' = 'link output' }
            Assert-Equal 'link output' (Get-Content -LiteralPath (Get-OrtQnnEpBuiltDll -BuildDir $dir).FullName -Raw).Trim() 'the build root wins over the wheel tree'
        }
    }

    It 'stages one directory over a stale one: the plugin, its backends and skels, the licence texts and provenance (mutation)' {
        Invoke-InTestDir { param($dir)
            $build = Join-Path $dir 'build'; $fork = Join-Path $dir 'fork'; $qairt = Join-Path $dir 'qairt'
            Write-TestFileTree -Root $build -Files @{ 'onnxruntime_providers_qnn.dll' = 'plugin'; 'onnxruntime_qnn/onnxruntime_providers_qnn.dll' = 'wheel copy' }
            Write-TestFileTree -Root $fork -Files @{ 'LICENSE' = 'mit'; 'ThirdPartyNotices.txt' = 'tpn' }
            Write-TestFileTree -Root $qairt -Files @{ 'LICENSE.pdf' = 'qairt'; 'lib/aarch64-windows-msvc/QnnHtp.dll' = 'htp'; 'lib/hexagon-v73/unsigned/libQnnHtpV73Skel.so' = 'skel' }
            $sdk = [pscustomobject]@{ Home = $qairt; LibDir = (Join-Path $qairt 'lib/aarch64-windows-msvc') }
            $beside = 'QnnHtp.dll', 'hexagon-v73/unsigned/libQnnHtpV73Skel.so', 'licenses/onnxruntime-qnn/ThirdPartyNotices.txt', 'licenses/qairt/LICENSE.pdf', 'provenance/onnxruntime-qnn.json'
            $null = Invoke-TestPluginStage -Dir $dir -Expected $beside -Install {
                param($ep, $pin) Install-OrtQnnEpArtifact -BuildDir $build -ForkRoot $fork -Sdk $sdk -EpDir $ep -Pin $pin 6>$null
            }
        }
    }

    It 'requires both plugin exports and an import closure of the chain, QAIRT beside it and the OS (mutation)' {
        Invoke-InTestDir { param($dir)
            Write-TestFileTree -Root $dir -Files @{ 'onnxruntime_providers_qnn.dll' = 'x'; 'QnnHtp.dll' = 'x' }
            $dll = Join-Path $dir 'onnxruntime_providers_qnn.dll'
            function Get-OrtPluginEpExportGap { param($Path, [switch]$ForbidProviderBridge) @() }
            function Get-PeImportNames { param($Path, [switch]$IncludeDelayLoad) @('KERNEL32.dll', 'onnxruntime.dll', 'QnnHtp.dll') }
            Assert-Equal 0 @(Get-OrtQnnEpModuleFinding -Dll $dll).Count 'healthy'
            function Get-OrtPluginEpExportGap { param($Path, [switch]$ForbidProviderBridge) @('onnxruntime_providers_qnn.dll does not export ReleaseEpFactory') }
            Assert-Match 'does not export ReleaseEpFactory' (@(Get-OrtQnnEpModuleFinding -Dll $dll) -join ';') 'the shared export gap reaches the finding'
            function Get-OrtPluginEpExportGap { param($Path, [switch]$ForbidProviderBridge) @() }
            function Get-PeImportNames { param($Path, [switch]$IncludeDelayLoad) @('onnxruntime_foreign.dll', 'QnnSystem.dll') }
            $f = @(Get-OrtQnnEpModuleFinding -Dll $dll) -join ';'
            Assert-Match 'onnxruntime_foreign\.dll, which is not the chain ORT' $f 'a foreign ORT import'
            Assert-Match 'QnnSystem\.dll, not staged beside it' $f 'an unstaged backend'
        }
    }
}

Describe 'Get-OrtQnnPluginFinding (smoke)' {
    It 'passes a staged plugin and names each gap: no plugin, no backend, an in-tree QNN EP (mutation)' {
        Invoke-InTestDir { param($dir)
            $ep = Join-Path $dir 'ep'; $ort = Join-Path $dir 'ort'
            Write-TestFileTree -Root $ort -Files @{ 'bin/onnxruntime.dll' = 'x' }
            Assert-Match 'no onnxruntime_providers_qnn\.dll' (@(Get-OrtQnnPluginFinding -EpRoot $ep -OrtRoot $ort) -join ';') 'missing plugin'
            Assert-Match "ORT_QNN_EP_ROOT=''" (@(Get-OrtQnnPluginFinding -EpRoot '' -OrtRoot $ort) -join ';') 'unset root'
            Write-TestFileTree -Root $ep -Files @{ 'onnxruntime_providers_qnn.dll' = 'x' }
            function global:Get-OrtPluginEpExportGap { param($Path, [switch]$ForbidProviderBridge) @() }
            try {
                Assert-Match 'no QAIRT backend DLL' (@(Get-OrtQnnPluginFinding -EpRoot $ep -OrtRoot $ort) -join ';') 'no backend'
                Write-TestFileTree -Root $ep -Files @{ 'QnnHtp.dll' = 'x' }
                Assert-Equal 0 @(Get-OrtQnnPluginFinding -EpRoot $ep -OrtRoot $ort).Count 'healthy'
                Write-TestFileTree -Root $ort -Files @{ 'bin/onnxruntime_providers_qnn.dll' = 'x' }
                Assert-Match 'in-tree QNN EP in the chain ORT' (@(Get-OrtQnnPluginFinding -EpRoot $ep -OrtRoot $ort) -join ';') 'in-tree EP'
            } finally { Remove-Item -LiteralPath 'Function:\Get-OrtPluginEpExportGap' -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'QNN plugin EP wiring' {
    It 'builds in the ORT RUN after ORT, with its script mounted and its pins declared; the driver side is BuildKit.TwinParity''s (mutation)' {
        $chain = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-MediaCoreAll.ps1'))
        Assert-Match "(?s)'ONNX Runtime'.*'QNN plugin EP'; Script = 'Build-OrtQnnEpFromSource\.ps1'.*'ONNX GenAI'" $chain 'after ORT, before GenAI'
        Assert-TestScriptContains -ScriptPath 'windows\Dockerfile.media-builder' -ReasonPrefix 'the ORT RUN carries' -Literal @(
            'source=windows/scripts/build/Build-OrtQnnEpFromSource.ps1,target=C:\bkmnt\Build-OrtQnnEpFromSource.ps1',
            'ORT_QNN_EP_VERSION="${ORT_QNN_EP_VERSION}"', 'ORT_QNN_EP_SOURCE_SHA256="${ORT_QNN_EP_SOURCE_SHA256}"')
        Assert-TestScriptContains -ScriptPath 'windows\Dockerfile.media-merge-builder' -ReasonPrefix 'the image names' -Literal @('ORT_QNN_EP_ROOT="C:\runtime\lib\onnxruntime-ep-qnn"')
        Assert-Match "(?s)Copy-OrtQnnEpHeader [^\r\n]+\r?\n[^\r\n]*\r?\nUpdate-NinjaFile -NinjaFile \(Join-Path \`$buildDir 'build\.ninja'\) -OrtMsvcOnlyFlags\r?\n\r?\nSwitch-BuildPhase '3\. build'" ([IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:QnnEpScript))) 'the fork loses ORT''s MSVC-only switches before ninja runs'
    }

    It 'the census counts the plugin''s fork tree as a chain root and its directory as a chain reference' {
        $src = [regex]::Match([IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:QnnEpScript)), '\[string\]\$SourceDir\s*=\s*''([^'']+)''').Groups[1].Value
        Assert-True ((Get-OrtChainSourceRoot) -contains $src) "Build-OrtQnnEpFromSource.ps1's -SourceDir ($src) is a chain root"
        Assert-Equal 'C:\runtime\lib\onnxruntime-ep-qnn' ((Get-OrtPluginEpDir) -join ',') 'the plugin directory'
        Assert-TestScriptContains -ScriptPath 'windows\scripts\modules\WindowsOrtProvenance.Common.psm1' -ReasonPrefix 'Invoke-OrtImageCensus' -Literal @(
            '-ReferenceDir (@("$prefix\bin", "$prefix\lib") + @(Get-OrtPluginEpDir))', 'AllowedHome = @($prefix, $wheelDir, $ftWheelDir) + @(Get-OrtPluginEpDir)')
    }
}
