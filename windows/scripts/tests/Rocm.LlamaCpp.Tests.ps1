#requires -Version 7.0
# llama.cpp HIP (source-built ggml-hip) + Vulkan on the rocm lane with downloads stubbed: gate, pins, layout, PE walk, loaders and wiring.

$script:LlamaInstall = 'windows\scripts\build\Install-LlamaCpp.ps1'
$script:LlamaCheck = 'windows\scripts\build\rocm-checks\LlamaCpp.ps1'
$script:LlamaBuild = 'windows\scripts\build\Build-LlamaCppHipFromSource.ps1'
$script:LlamaPinKeys = 'LLAMA_CPP_HIP_BUILD', 'LLAMA_CPP_HIP_COMMIT', 'LLAMA_CPP_HIP_SOURCE_SHA256', 'LLAMA_CPP_CPU_SHA256',
    'LLAMA_CPP_HIP_LICENSE_SHA256', 'LLAMA_CPP_VULKAN_SHA256'

Describe 'Install-LlamaCpp: lane gate (rocm only; cpu and nvidia refused for both backends)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Assert-LlamaCppLane')

    It 'refuses cpu and nvidia for either backend; only HIP needs hipBLAS/rocBLAS in the ROCm tree' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType File -Force -Path (Join-Path $dir 'bin\amdhip64_7.dll') -Value 'x' | Out-Null
            $rocm = @{ GpuType = 'rocm'; HasRocm = $true; RocmRoot = $dir }
            $hip = Get-LlamaCppBackendSpec -Backend hip
            $vk = Get-LlamaCppBackendSpec -Backend vulkan
            foreach ($spec in $hip, $vk) {
                foreach ($gpu in 'cpu', 'nvidia') {
                    Assert-Throws { Assert-LlamaCppLane -GpuEnvironment @{ GpuType = $gpu; HasRocm = $false; RocmRoot = $null } -Spec $spec } "$($spec.Label) on $gpu" -MessagePattern "rocm lane only.*'$gpu'"
                }
            }
            Assert-Throws { Assert-LlamaCppLane -GpuEnvironment $rocm -Spec $hip } 'HIP' -MessagePattern 'lacks bin\\hipblas\.dll, bin\\rocblas\.dll'
            Assert-Equal (Join-Path $dir 'bin') (Assert-LlamaCppLane -GpuEnvironment $rocm -Spec $vk) 'Vulkan links nothing of ROCm'
            foreach ($f in 'hipblas.dll', 'rocblas.dll') { New-Item -ItemType File -Path (Join-Path $dir "bin\$f") -Value 'x' | Out-Null }
            Assert-Equal (Join-Path $dir 'bin') (Assert-LlamaCppLane -GpuEnvironment $rocm -Spec $hip) 'a complete ROCm tree is accepted, and its bin returned'
            $noBin = @{ GpuType = 'rocm'; HasRocm = $true; RocmRoot = (Join-Path $dir 'nope') }
            Assert-Throws { Assert-LlamaCppLane -GpuEnvironment $noBin -Spec $vk } 'no bin' -MessagePattern 'has no bin directory'
        }
    }
}

Describe 'Install-LlamaCpp: pin parity (one build pin; HIP from source, CPU and Vulkan zips by digest)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Get-LlamaCppAsset')
    $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
    $hip = Get-LlamaCppBackendSpec -Backend hip
    $vk = Get-LlamaCppBackendSpec -Backend vulkan

    It 'accepts the versions.env pins as they stand (a one-key bump fails HERE, not in the build)' {
        $build = $pins['LLAMA_CPP_HIP_BUILD']
        $a = Get-LlamaCppAsset -Spec $hip -Build $build
        Assert-Equal ('https://github.com/ggml-org/llama.cpp/releases/download/b{0}/llama-b{0}-bin-win-cpu-x64.zip' -f $build) $a.Url 'HIP: the tag''s CPU zip'
        $a = Get-LlamaCppAsset -Spec $vk -Build $build
        Assert-Equal ('https://github.com/ggml-org/llama.cpp/releases/download/b{0}/llama-b{0}-bin-win-vulkan-x64.zip' -f $build) $a.Url 'the Vulkan zip of the same build'
        foreach ($key in 'LLAMA_CPP_HIP_SOURCE_SHA256', 'LLAMA_CPP_CPU_SHA256', 'LLAMA_CPP_HIP_LICENSE_SHA256', 'LLAMA_CPP_VULKAN_SHA256') {
            Assert-Match '^[0-9a-f]{64}$' $pins[$key] "$key is 64 lower-case hex"
        }
        Assert-Match '^[0-9a-f]{40}$' $pins['LLAMA_CPP_HIP_COMMIT'] 'the tag''s commit'
        Assert-Equal 3 @(@($pins['LLAMA_CPP_HIP_SOURCE_SHA256'], $pins['LLAMA_CPP_CPU_SHA256'], $pins['LLAMA_CPP_VULKAN_SHA256']) | Sort-Object -Unique).Count 'three archives, three digests'
        foreach ($key in 'LLAMA_CPP_VULKAN_BUILD', 'LLAMA_CPP_VULKAN_LICENSE_SHA256', 'LLAMA_CPP_HIP_ASSET', 'LLAMA_CPP_HIP_SHA256') {
            Assert-False $pins.Contains($key) "${key}: the build stays ONE pin, and no prebuilt HIP zip is pinned"
        }
    }

    It 'refuses a malformed build, and derives every asset name from the build alone' {
        foreach ($s in $hip, $vk) {
            foreach ($b in 'b11472', '', '11472a') {
                Assert-Throws { Get-LlamaCppAsset -Spec $s -Build $b } "$($s.Label) '$b'" -MessagePattern 'LLAMA_CPP_HIP_BUILD must be a build number'
            }
            Assert-Match ('^' + $s.AssetPattern.TrimStart('^')) (Get-LlamaCppAsset -Spec $s -Build '11115').Name "$($s.Label): the derived name is the upstream asset name"
        }
        Assert-Equal 'llama-b11115-bin-win-cpu-x64.zip' (Get-LlamaCppAsset -Spec $hip -Build '11115').Name 'HIP takes no ROCm zip at all'
    }

    It 'keeps Dockerfile.rocm-llama''s ARG defaults equal to versions.env' {
        $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.rocm-llama')
        foreach ($key in @($script:LlamaPinKeys) + 'ROCM_WINDOWS_GFX_FAMILY') {
            Assert-Equal $pins[$key] ([regex]::Match($df, "(?m)^ARG $key=(\S+)\r?$").Groups[1].Value) "ARG $key"
        }
    }
}

Describe 'Install-LlamaCpp: zip layout' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Assert-LlamaCppZipEntry')
    $hip = Get-LlamaCppBackendSpec -Backend hip
    $vk = Get-LlamaCppBackendSpec -Backend vulkan
    # The b11472 CPU zip as upstream ships it (flat), and TheRock 10.1.0's bin DLLs.
    $script:CpuZipB11472 = @('ggml-base.dll', 'ggml-cpu-alderlake.dll', 'ggml-cpu-cannonlake.dll', 'ggml-cpu-cascadelake.dll',
        'ggml-cpu-cooperlake.dll', 'ggml-cpu-haswell.dll', 'ggml-cpu-icelake.dll', 'ggml-cpu-ivybridge.dll', 'ggml-cpu-piledriver.dll',
        'ggml-cpu-sandybridge.dll', 'ggml-cpu-sapphirerapids.dll', 'ggml-cpu-skylakex.dll', 'ggml-cpu-sse42.dll', 'ggml-cpu-x64.dll',
        'ggml-cpu-zen4.dll', 'ggml-rpc-server.exe', 'ggml-rpc.dll', 'ggml.dll', 'libomp.dll', 'LICENSE-LLVM-OpenMP',
        'llama-batched-bench-impl.dll', 'llama-batched-bench.exe', 'llama-bench-impl.dll', 'llama-bench.exe', 'llama-cli-impl.dll',
        'llama-cli.exe', 'llama-common.dll', 'llama-completion-impl.dll', 'llama-completion.exe', 'llama-fit-params-impl.dll',
        'llama-fit-params.exe', 'llama-gemma3-cli.exe', 'llama-gguf-split.exe', 'llama-imatrix.exe', 'llama-llava-cli.exe',
        'llama-minicpmv-cli.exe', 'llama-mtmd-cli.exe', 'llama-mtmd-debug.exe', 'llama-perplexity-impl.dll', 'llama-perplexity.exe',
        'llama-quantize-impl.dll', 'llama-quantize.exe', 'llama-qwen2vl-cli.exe', 'llama-results.exe', 'llama-server-impl.dll',
        'llama-server.exe', 'llama-tokenize.exe', 'llama-tts.exe', 'llama.dll', 'llama.exe', 'mtmd.dll')
    # Measured: the Vulkan zip is the same 51 files (same CRC32) plus ggml-vulkan.dll.
    $script:VulkanZipB11472 = @($script:CpuZipB11472) + 'ggml-vulkan.dll'
    $script:RocmBin1010 = @('MIOpen.dll', 'MIOpenCKGroupedConv_gfx1200.dll', 'MIOpenCKGroupedConv_gfx1201.dll', 'OpenCL.dll', 'amd_comgr.dll',
        'amdhip64_7.dll', 'amdocl64.dll', 'cltrace.dll', 'hipblas.dll', 'hipdnn_backend.dll', 'hipfft.dll', 'hipfftw.dll',
        'hiprand.dll', 'hiprtc-builtins0716.dll', 'hiprtc0716.dll', 'hipsolver.dll', 'hipsparse.dll', 'hiptensor.dll',
        'libhipblaslt.dll', 'origami.dll', 'rocalution.dll', 'rocblas.dll', 'rocfft.dll', 'rocm-openblas.dll',
        'rocm-openblas64.dll', 'rocm_kpack.dll', 'rocrand.dll', 'rocsolver.dll', 'rocsparse.dll')

    It 'accepts both b11472 zips: neither carries anything of ROCm''s' {
        Assert-Equal 51 $script:CpuZipB11472.Count 'the whole b11472 CPU listing'
        Assert-Equal 29 $script:RocmBin1010.Count 'every bin\*.dll of the 10.1.0 gfx120X-all tarball'
        Assert-LlamaCppZipEntry -Spec $hip -EntryName $script:CpuZipB11472 -RocmBinDllName $script:RocmBin1010
        Assert-LlamaCppZipEntry -Spec $vk -EntryName $script:VulkanZipB11472 -RocmBinDllName $script:RocmBin1010
        Assert-True $true 'accepted'
    }

    It 'refuses a zip that lacks any load-bearing file, naming it' {
        foreach ($c in @(@{ S = $hip; Zip = $script:CpuZipB11472; Need = 'llama-server.exe', 'llama-cli.exe', 'ggml-base.dll', 'llama.dll' },
                @{ S = $vk; Zip = $script:VulkanZipB11472; Need = 'ggml-vulkan.dll', 'llama-server.exe', 'ggml-base.dll', 'llama.dll' })) {
            foreach ($r in $c.Need) {
                $entries = @($c.Zip | Where-Object { $_ -ne $r })
                Assert-Throws { Assert-LlamaCppZipEntry -Spec $c.S -EntryName $entries -RocmBinDllName $script:RocmBin1010 } "$($c.S.Label) missing $r" -MessagePattern ('missing ' + [regex]::Escape($r))
            }
        }
    }

    It 'refuses a zip that would shadow ROCm (the HIP runtime too), is no longer flat, brings a prebuilt ggml-hip or its own loader' {
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $hip -EntryName ($script:CpuZipB11472 + 'amdhip64_7.dll' + 'rocm_kpack.dll') -RocmBinDllName $script:RocmBin1010 } 'runtime' -MessagePattern "shadow ROCm's own amdhip64_7\.dll, rocm_kpack\.dll"
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $hip -EntryName ($script:CpuZipB11472 + 'ggml-hip.dll') -RocmBinDllName $script:RocmBin1010 } 'prebuilt' -MessagePattern 'carries ggml-hip\.dll: ggml-hip\.dll is built from source here'
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $hip -EntryName ($script:CpuZipB11472 + 'llama-b11472/ggml.dll') -RocmBinDllName $script:RocmBin1010 } 'nested' -MessagePattern 'not flat'
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $vk -EntryName ($script:VulkanZipB11472 + 'vulkan-1.dll') -RocmBinDllName $script:RocmBin1010 } 'loader' -MessagePattern 'carries vulkan-1\.dll: the Vulkan loader must come from the image'
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $vk -EntryName ($script:VulkanZipB11472 + 'hipblas.dll') -RocmBinDllName $script:RocmBin1010 } 'ROCm' -MessagePattern "(?s)refusing the Vulkan zip:.*shadow ROCm's own hipblas\.dll"
    }
}

Describe 'Install-LlamaCpp: the script body, with the module functions stood in for' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Assert-LlamaCppLane',
        'Get-LlamaCppAsset', 'Assert-LlamaCppZipEntry', 'Get-LlamaCppBuiltRecord', 'Write-LlamaCppManifest', 'Install-LlamaCpp')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppCheckSpec', 'Get-LlamaCppManifestFinding')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:ZipMinimal = @{
        hip    = @('ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe', 'llama-cli.exe', 'LICENSE-LLVM-OpenMP')
        vulkan = @('ggml-vulkan.dll', 'ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe', 'LICENSE-LLVM-OpenMP')
    }
    # Runs Install-LlamaCpp over a fixture zip, LICENSE and (HIP) build output; the stand-ins below shadow the module functions by scope.
    function Invoke-LlamaInstallFixture {
        param([string]$Root, [string]$Backend = 'hip', [string]$GpuType = 'rocm', [string[]]$ZipEntry = $script:ZipMinimal[$Backend], [hashtable]$Override = @{},
            [hashtable]$Record = @{ build = '11115'; rocm_release = '10.1.0' }, [string]$ImageRocm = '10.1.0')
        $fixtureRocm = Join-Path $Root 'rocm'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRocm 'bin'), (Join-Path $Root 'zip'), (Join-Path $Root 'built') | Out-Null
        foreach ($f in 'amdhip64_7.dll', 'amd_comgr.dll', 'rocm_kpack.dll', 'hipblas.dll', 'rocblas.dll') { Set-Content -LiteralPath (Join-Path $fixtureRocm "bin\$f") -Value $f }
        foreach ($f in $ZipEntry) { Set-Content -LiteralPath (Join-Path $Root "zip\$f") -Value "bytes of $f" }
        Set-Content -LiteralPath (Join-Path $Root 'built\ggml-hip.dll') -Value 'the source-built ggml-hip'
        $rec = @{ commit = ('c' * 40); source_sha256 = ('d' * 64); gpu_targets = 'gfx1200;gfx1201' }
        foreach ($k in $Record.Keys) { $rec[$k] = $Record[$k] }
        [System.IO.File]::WriteAllText((Join-Path $Root 'built\llama-cpp-hip-build.json'), ($rec | ConvertTo-Json))
        $fixtureZip = Join-Path $Root 'fixture.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $Root 'zip'), $fixtureZip)
        $fixtureLicense = Join-Path $Root 'LICENSE'
        Set-Content -LiteralPath $fixtureLicense -Value 'MIT License'
        $fixtureDownloads = [System.Collections.Generic.List[object]]::new()
        $fixtureEnvAsked = [System.Collections.Generic.List[string]]::new()
        function Get-GpuEnvironment { @{ GpuType = $GpuType; HasRocm = ($GpuType -eq 'rocm'); RocmRoot = $fixtureRocm } }
        function Resolve-ContainerImageValue { param([AllowEmptyString()][string]$Value, [string]$EnvironmentVariable) $fixtureEnvAsked.Add($EnvironmentVariable); $Value }
        function Initialize-ContainerImageTempDirectory { param([string]$TempDir) (New-Item -ItemType Directory -Force -Path $TempDir).FullName }
        function Clear-PendingFileHandle { }
        function Invoke-DownloadWithRetry {
            param([string]$Url, [string]$DestinationPath, [string]$Description, [string]$ExpectSignature = '', [string]$ExpectedSha256 = '')
            $fixtureDownloads.Add([pscustomobject]@{ Url = $Url; ExpectSignature = $ExpectSignature; ExpectedSha256 = $ExpectedSha256 })
            Copy-Item -LiteralPath $(if ($Url -like '*.zip') { $fixtureZip } else { $fixtureLicense }) -Destination $DestinationPath
        }
        $pins = @{ Backend = $Backend; TempDir = (Join-Path $Root 'tmp'); Build = '11115'; BuiltDir = (Join-Path $Root 'built')
            Sha256 = (Get-FileHash -LiteralPath $fixtureZip).Hash; LicenseSha256 = (Get-FileHash -LiteralPath $fixtureLicense).Hash
            InstallDir = (Join-Path $Root 'out') }
        foreach ($k in $Override.Keys) { $pins[$k] = $Override[$k] }
        # A holder, not a variable: the Invoke-WithEnv body runs in a child scope.
        $outcome = @{ Error = $null }
        Invoke-WithEnv @{ ROCM_WINDOWS_RELEASE = $ImageRocm } {
            try { Install-LlamaCpp @pins 6>$null } catch { $outcome.Error = $_.Exception.Message }
        }
        return [pscustomobject]@{ Error = $outcome.Error; Downloads = $fixtureDownloads.ToArray(); Pins = $pins; EnvAsked = $fixtureEnvAsked.ToArray() }
    }

    It 'downloads each zip and the tag''s LICENSE against their pins, ships them (HIP: with the built ggml-hip), and grades clean' {
        foreach ($c in @(@{ B = 'hip'; Asset = 'llama-b11115-bin-win-cpu-x64.zip' }, @{ B = 'vulkan'; Asset = 'llama-b11115-bin-win-vulkan-x64.zip' })) {
            Invoke-InTestDir { param($dir)
                $r = Invoke-LlamaInstallFixture -Root $dir -Backend $c.B
                Assert-Null $r.Error "$($c.B) installs"
                Assert-Equal 2 $r.Downloads.Count "$($c.B): two downloads"
                Assert-Equal "https://github.com/ggml-org/llama.cpp/releases/download/b11115/$($c.Asset)" $r.Downloads[0].Url "$($c.B) zip url"
                Assert-Equal $r.Pins.Sha256 $r.Downloads[0].ExpectedSha256 "$($c.B): the zip is verified against its SHA256 pin"
                Assert-Equal 'PK' $r.Downloads[0].ExpectSignature 'the zip signature'
                Assert-Equal 'https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/LICENSE' $r.Downloads[1].Url 'the LICENSE at the pinned tag'
                Assert-Equal $r.Pins.LicenseSha256 $r.Downloads[1].ExpectedSha256 'the LICENSE is verified against its pin'
                Assert-Equal 'MIT License' (Get-Content -Raw (Join-Path $r.Pins.InstallDir 'licenses\llama.cpp\LICENSE')).Trim() 'the LICENSE ships'
                Assert-Equal 0 @(Get-ChildItem -LiteralPath $r.Pins.TempDir -File).Count 'nothing left in the temp dir'
                $spec = Get-LlamaCppCheckSpec -Backend $c.B
                $manifest = Get-Content -Raw (Join-Path $r.Pins.InstallDir $spec.Manifest) | ConvertFrom-Json
                Assert-Equal 0 @(Get-LlamaCppManifestFinding -Dir $r.Pins.InstallDir -Build '11115' -ManifestName $spec.Manifest -Required $spec.Required).Count "$($c.B): graded clean"
                $shipsHip = Test-Path -LiteralPath (Join-Path $r.Pins.InstallDir 'ggml-hip.dll')
                Assert-Equal ($c.B -eq 'hip') $shipsHip "$($c.B): ggml-hip.dll only in the HIP home"
                Assert-Equal ($c.B -eq 'hip') ($null -ne $manifest.PSObject.Properties['built']) "$($c.B): the manifest records the source build only for HIP"
                if ($c.B -eq 'hip') {
                    Assert-Equal ('c' * 40) $manifest.built.commit 'the commit ggml-hip was built from'
                    Assert-False (Test-Path -LiteralPath (Join-Path $r.Pins.InstallDir 'llama-cpp-hip-build.json')) 'the build record is folded into the manifest, not shipped'
                }
            }
        }
    }

    It 'reads the build and LICENSE pins from the HIP keys for both backends (one build pin), each zip from its own key' {
        foreach ($c in @(@{ B = 'hip'; Keys = 'LLAMA_CPP_HIP_BUILD,LLAMA_CPP_CPU_SHA256,LLAMA_CPP_HIP_LICENSE_SHA256' },
                @{ B = 'vulkan'; Keys = 'LLAMA_CPP_HIP_BUILD,LLAMA_CPP_VULKAN_SHA256,LLAMA_CPP_HIP_LICENSE_SHA256' })) {
            Invoke-InTestDir { param($dir)
                Assert-Equal $c.Keys ((Invoke-LlamaInstallFixture -Root $dir -Backend $c.B).EnvAsked -join ',') "$($c.B) pin keys"
            }
        }
    }

    It 'refuses before any download: cpu and nvidia lanes (both backends), a malformed pin, a missing or foreign source build' {
        foreach ($c in @(
                @{ B = 'hip'; Gpu = 'cpu'; P = "rocm lane only.*'cpu'" },
                @{ B = 'hip'; Gpu = 'nvidia'; P = "rocm lane only.*'nvidia'" },
                @{ B = 'vulkan'; Gpu = 'cpu'; P = "rocm lane only.*'cpu'" },
                @{ B = 'vulkan'; Gpu = 'nvidia'; P = "rocm lane only.*'nvidia'" },
                @{ B = 'hip'; Override = @{ Sha256 = 'abc' }; P = "LLAMA_CPP_CPU_SHA256 must be a 64-hex SHA256.*got 'abc'" },
                @{ B = 'hip'; Override = @{ LicenseSha256 = '' }; P = "LLAMA_CPP_HIP_LICENSE_SHA256 must be a 64-hex SHA256.*got ''" },
                @{ B = 'hip'; Override = @{ BuiltDir = 'C:\nowhere-llama-built' }; P = 'lacks ggml-hip\.dll, llama-cpp-hip-build\.json -- run Build-LlamaCppHipFromSource\.ps1 first' },
                @{ B = 'hip'; Record = @{ build = '11114'; rocm_release = '10.1.0' }; P = 'built from b11114, but LLAMA_CPP_HIP_BUILD is 11115' },
                @{ B = 'hip'; Record = @{ build = '11115'; rocm_release = '10.0.0' }; P = "built against ROCm '10\.0\.0', but the image carries '10\.1\.0'" },
                @{ B = 'vulkan'; Override = @{ Sha256 = '' }; P = "LLAMA_CPP_VULKAN_SHA256 must be a 64-hex SHA256.*got ''" },
                @{ B = 'vulkan'; Override = @{ Build = 'b11115' }; P = 'LLAMA_CPP_HIP_BUILD must be a build number' })) {
            Invoke-InTestDir { param($dir)
                $fixture = @{ Root = $dir; Backend = $c.B; GpuType = $(if ($c['Gpu']) { $c['Gpu'] } else { 'rocm' }); Override = $(if ($c['Override']) { $c['Override'] } else { @{} }) }
                if ($c['Record']) { $fixture.Record = $c['Record'] }
                $r = Invoke-LlamaInstallFixture @fixture
                Assert-Match $c.P "$($r.Error)" "$($c.B) error for $($c.P)"
                Assert-Equal 0 $r.Downloads.Count "$($c.B): no download for $($c.P)"
                Assert-False (Test-Path -LiteralPath $r.Pins.InstallDir) "$($c.B): nothing installed for $($c.P)"
            }
        }
    }

    It 'refuses a used install dir before downloading, and a zip that shadows ROCm or brings a loader before extracting' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType File -Force -Path (Join-Path $dir 'out\ggml.dll') -Value 'an older build' | Out-Null
            $r = Invoke-LlamaInstallFixture -Root $dir -Backend vulkan
            Assert-Match 'already has content; refusing to mix' "$($r.Error)" 'used dir'
            Assert-Equal 0 $r.Downloads.Count 'no download into a used dir'
        }
        foreach ($c in @(@{ B = 'hip'; Extra = 'amdhip64_7.dll'; P = "shadow ROCm's own amdhip64_7\.dll" }, @{ B = 'hip'; Extra = 'ggml-hip.dll'; P = 'carries ggml-hip\.dll' },
                @{ B = 'vulkan'; Extra = 'vulkan-1.dll'; P = 'carries vulkan-1\.dll' })) {
            Invoke-InTestDir { param($dir)
                $r = Invoke-LlamaInstallFixture -Root $dir -Backend $c.B -ZipEntry ($script:ZipMinimal[$c.B] + $c.Extra)
                Assert-Match $c.P "$($r.Error)" "$($c.B) $($c.Extra)"
                Assert-False (Test-Path -LiteralPath $r.Pins.InstallDir) 'nothing extracted'
            }
        }
    }
}

Describe 'Build-LlamaCppHipFromSource: pins, configure args and the record the installer reads' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaBuild -FunctionName 'Get-LlamaCppHipSourcePin', 'Get-LlamaCppHipCmakeArgs', 'Write-LlamaCppHipBuildRecord')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Get-LlamaCppBuiltRecord')
    $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
    function Get-RocmLlvmToolPath { param([string]$RocmRoot, [string]$Tool) "$($RocmRoot -replace '\\', '/')/lib/llvm/bin/$Tool.exe" }

    It 'accepts the versions.env source pin and refuses a malformed build or commit before any fetch' {
        Invoke-WithEnv @{ LLAMA_CPP_HIP_BUILD = " $($pins['LLAMA_CPP_HIP_BUILD']) "; LLAMA_CPP_HIP_COMMIT = $pins['LLAMA_CPP_HIP_COMMIT'] } {
            $p = Get-LlamaCppHipSourcePin
            Assert-Equal "$($pins['LLAMA_CPP_HIP_BUILD'])|$($pins['LLAMA_CPP_HIP_COMMIT'])" "$($p.Build)|$($p.Commit)" 'trimmed build and commit'
        }
        foreach ($c in @(@{ B = 'b11472'; C = ('a' * 40); P = 'LLAMA_CPP_HIP_BUILD must be a build number' }, @{ B = $null; C = ('a' * 40); P = 'LLAMA_CPP_HIP_BUILD must be' }
                @{ B = '11472'; C = 'b11472'; P = 'LLAMA_CPP_HIP_COMMIT must be the 40-hex commit of tag b11472' }, @{ B = '11472'; C = ('A' * 40); P = 'LLAMA_CPP_HIP_COMMIT must be' })) {
            Invoke-WithEnv @{ LLAMA_CPP_HIP_BUILD = $c.B; LLAMA_CPP_HIP_COMMIT = $c.C } {
                Assert-Throws { Get-LlamaCppHipSourcePin } "$($c.B) $($c.C)" -MessagePattern $c.P
            }
        }
    }

    It 'configures upstream''s ggml-hip recipe with TheRock''s tools, explicit targets, and nothing that downloads' {
        $a = @(Get-LlamaCppHipCmakeArgs -RocmRoot 'C:\TheRock\build' -GpuTargets 'gfx1200;gfx1201' -Build '11472' -Commit ('d0b490f2' + 'e' * 32))
        foreach ($want in '-DGGML_HIP=ON', '-DGGML_BACKEND_DL=ON', '-DGGML_CPU=OFF', '-DGGML_NATIVE=OFF', '-DGPU_TARGETS:STRING=gfx1200;gfx1201',
                '-DLLAMA_BUILD_NUMBER:STRING=11472', '-DLLAMA_BUILD_COMMIT:STRING=d0b490f', '-DLLAMA_OPENSSL=OFF', '-DLLAMA_USE_PREBUILT_UI=OFF',
                '-DLLAMA_BUILD_TOOLS=OFF', '-DLLAMA_BUILD_SERVER=OFF', '-DFETCHCONTENT_FULLY_DISCONNECTED:BOOL=ON',
                '-DCMAKE_PREFIX_PATH:STRING=C:/TheRock/build', '-DCMAKE_AR:FILEPATH=C:/TheRock/build/lib/llvm/bin/llvm-ar.exe') {
            Assert-True ($a -contains $want) "missing $want"
        }
        Assert-Equal 0 @($a | Where-Object { $_ -match 'BORINGSSL|OPENMP_FETCH|GGML_HIP_ROCWMMA_FATTN=ON|AMDGPU_TARGETS' }).Count 'no fetching option, one target spelling'
    }

    It 'writes the record Install-LlamaCpp then accepts, and the installer refuses it for another build or ROCm' {
        Invoke-InTestDir { param($dir)
            Set-Content -LiteralPath (Join-Path $dir 'ggml-hip.dll') -Value 'x'
            $pin = [pscustomobject]@{ Build = '11472'; Commit = ('c' * 40) }
            [void](Write-LlamaCppHipBuildRecord -OutputDir $dir -Pin $pin -SourceSha256 ('D' * 64) -GpuTargets 'gfx1200;gfx1201' -RocmRelease '10.1.0')
            $spec = Get-LlamaCppBackendSpec -Backend hip
            $r = Get-LlamaCppBuiltRecord -Spec $spec -BuiltDir $dir -Build '11472' -RocmRelease '10.1.0'
            Assert-Equal ('d' * 64) $r.source_sha256 'the source digest, lower-cased'
            Assert-Throws { Get-LlamaCppBuiltRecord -Spec $spec -BuiltDir $dir -Build '11473' -RocmRelease '10.1.0' } 'build' -MessagePattern 'built from b11472'
            Assert-Throws { Get-LlamaCppBuiltRecord -Spec $spec -BuiltDir $dir -Build '11472' -RocmRelease '10.2.0' } 'rocm' -MessagePattern "built against ROCm '10\.1\.0'"
        }
    }
}

Describe 'Install-LlamaCpp + LlamaCpp check: the manifest proves the shipped bytes and licence' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Write-LlamaCppManifest')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppCheckSpec', 'Get-LlamaCppManifestFinding')
    $hipSpec = Get-LlamaCppCheckSpec -Backend hip
    function New-LlamaManifestFixture {
        param([string]$Dir, [string[]]$File = @('ggml-hip.dll', 'ggml-base.dll', 'llama-server.exe', 'llama-cli.exe', 'licenses\llama.cpp\LICENSE'), [hashtable]$Spec = $hipSpec)
        foreach ($f in $File) { New-Item -ItemType File -Force -Path (Join-Path $Dir $f) -Value "bytes of $f" | Out-Null }
        [void](Write-LlamaCppManifest -Dir $Dir -Name $Spec.Manifest -Build '11115' -Asset 'llama-b11115-bin-win-cpu-x64.zip' -Sha256 ('A' * 64))
    }
    function Get-Graded {
        param([string]$Dir, [string]$Build = '11115', [hashtable]$Spec = $hipSpec)
        return @(Get-LlamaCppManifestFinding -Dir $Dir -Build $Build -ManifestName $Spec.Manifest -Required $Spec.Required)
    }

    It 'has no finding for the tree the install left' {
        Invoke-InTestDir { param($dir)
            New-LlamaManifestFixture -Dir $dir
            Assert-Equal 0 @(Get-Graded -Dir $dir).Count 'clean'
        }
    }

    It 'reports a changed, a missing and a foreign file, a build mismatch, and a missing manifest' {
        Invoke-InTestDir { param($dir)
            New-LlamaManifestFixture -Dir $dir
            # Same length, other bytes: the SHA256 comparison, not the size check, must catch these two.
            Set-Content -NoNewline -LiteralPath (Join-Path $dir 'ggml-base.dll') -Value 'bytes of ggml-base.dlX'
            Set-Content -NoNewline -LiteralPath (Join-Path $dir 'licenses\llama.cpp\LICENSE') -Value 'bytes of licenses\llama.cpp\LICENSX'
            Remove-Item -LiteralPath (Join-Path $dir 'llama-server.exe')
            Set-Content -LiteralPath (Join-Path $dir 'amdhip64_7.dll') -Value 'x'
            $got = @(Get-Graded -Dir $dir -Build '11116') -join "`n"
            Assert-Match "records build '11115', LLAMA_CPP_HIP_BUILD is '11116'" $got 'build'
            Assert-Match 'ggml-base\.dll differs from the pinned bytes' $got 'changed'
            Assert-Match 'licenses\\llama\.cpp\\LICENSE differs from the pinned bytes' $got 'changed licence'
            Assert-Match 'llama-server\.exe is missing' $got 'missing'
            Assert-Match 'amdhip64_7\.dll is not in the manifest: it came from neither the pinned zip nor the build' $got 'foreign'
            Remove-Item -LiteralPath (Join-Path $dir 'llama-cpp-hip-manifest.json')
            Assert-Match 'no manifest at .*llama-cpp-hip-manifest\.json: Install-LlamaCpp\.ps1 did not finish' (@(Get-Graded -Dir $dir) -join ' ') 'no manifest'
        }
    }

    It 'reports a file it cannot read (an on-access scanner holding it) instead of throwing, and grades the rest' {
        Invoke-InTestDir { param($dir)
            New-LlamaManifestFixture -Dir $dir
            $held = [System.IO.File]::Open((Join-Path $dir 'ggml-hip.dll'), 'Open', 'Read', 'None')
            try { $got = @(Get-Graded -Dir $dir -Build '11116') -join "`n" } finally { $held.Dispose() }
            Assert-Match 'ggml-hip\.dll cannot be read: ' $got 'a named finding'
            Assert-Match "records build '11115'" $got 'the other checks still ran'
        }
    }

    It 'requires the licence, llama-cli (HIP) and the backend DLL in each backend''s own manifest' {
        Invoke-InTestDir { param($dir)
            New-LlamaManifestFixture -Dir $dir -File 'ggml-hip.dll', 'llama-server.exe'
            $got = @(Get-Graded -Dir $dir) -join ' '
            Assert-Match 'the manifest lists no licenses\\llama\.cpp\\LICENSE' $got 'no licence'
            Assert-Match 'the manifest lists no llama-cli\.exe' $got 'no llama-cli for the --list-devices smoke'
        }
        Invoke-InTestDir { param($dir)
            $vk = Get-LlamaCppCheckSpec -Backend vulkan
            New-LlamaManifestFixture -Dir $dir -File 'ggml-hip.dll', 'llama-server.exe', 'licenses\llama.cpp\LICENSE' -Spec $vk
            $got = @(Get-Graded -Dir $dir -Spec $vk) -join ' '
            Assert-Match 'the manifest lists no ggml-vulkan\.dll' $got 'a HIP tree is not a Vulkan tree'
            Assert-False ($got -match 'is not in the manifest') 'the Vulkan manifest is not taken for a foreign file'
        }
    }
}

Describe 'LlamaCpp check: PE import/export reader' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Invoke-PeReader', 'ConvertTo-PeFileOffset', 'Read-PeString', 'Get-PeSymbolTable')
    $script:Kernel32 = Join-Path $env:SystemRoot 'System32\kernel32.dll'

    It 'agrees with the hub''s Get-PeImportNames on which DLLs a real PE imports' {
        foreach ($pe in $script:Kernel32, (Get-Process -Id $PID).Path) {
            $mine = @((Get-PeSymbolTable -Path $pe).Imports.Keys | Sort-Object) -join ','
            Assert-Equal (@(Get-PeImportNames -Path $pe | Sort-Object) -join ',') $mine "imports of $pe"
        }
    }

    It 'reads imported and exported NAMES (kernel32 -> ntdll)' {
        $table = Get-PeSymbolTable -Path $script:Kernel32
        $ntdll = @($table.Imports.Keys | Where-Object { $_ -ieq 'ntdll.dll' })[0]
        Assert-True (@($table.Imports[$ntdll] | Where-Object { $_ -like 'Nt*' }).Count -gt 10) 'kernel32 imports Nt* functions by name'
        Assert-True ($table.Exports.Contains('LoadLibraryW') -and $table.Exports.Contains('CreateFileW')) 'kernel32 exports LoadLibraryW/CreateFileW'
        Assert-False $table.Exports.Contains('loadlibraryw') 'export names compare case-sensitively'
    }

    It 'throws on a file that is not a PE' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'not.dll'
            [System.IO.File]::WriteAllBytes($f, [byte[]](1..200 | ForEach-Object { 0x41 }))
            Assert-Throws { Get-PeSymbolTable -Path $f } 'not a PE'
        }
    }
}

Describe 'LlamaCpp check: ggml-hip device code covers ROCm''s GPUs' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Invoke-PeReader', 'Get-ClangOffloadBundleTarget', 'Get-HipOffloadTarget', 'Get-LlamaCppHipTargetFinding')
    function New-OffloadBundleHeader {
        param([string[]]$Id, [string]$Magic = '__CLANG_OFFLOAD_BUNDLE__')
        $ms = [System.IO.MemoryStream]::new()
        $w = [System.IO.BinaryWriter]::new($ms)
        $w.Write([System.Text.Encoding]::ASCII.GetBytes($Magic)); $w.Write([uint64]$Id.Count)
        foreach ($i in $Id) { $w.Write([uint64]4096); $w.Write([uint64]0); $w.Write([uint64]$i.Length); $w.Write([System.Text.Encoding]::ASCII.GetBytes($i)) }
        $w.Flush()
        return , $ms.ToArray()
    }

    It 'reads the gfx targets of an offload bundle header, as a ggml-hip.dll carries them' {
        $h = New-OffloadBundleHeader -Id @('host-x86_64-pc-windows-msvc', 'hipv4-amdgcn-amd-amdhsa--gfx1200', 'hipv4-amdgcn-amd-amdhsa--gfx90a:xnack+', 'hipv4-amdgcn-amd-amdhsa--gfx1201')
        Assert-Equal 'gfx1200,gfx90a,gfx1201' (@(Get-ClangOffloadBundleTarget -Header $h) -join ',') 'targets'
    }

    It 'refuses a compressed or truncated header rather than report no targets' {
        $ccob = [byte[]]([System.Text.Encoding]::ASCII.GetBytes('CCOB') + [byte[]]::new(60))
        Assert-Throws { Get-ClangOffloadBundleTarget -Header $ccob } 'CCOB' -MessagePattern "starts 'CCOB'"
        $h = New-OffloadBundleHeader -Id @('hipv4-amdgcn-amd-amdhsa--gfx1201')
        Assert-Throws { Get-ClangOffloadBundleTarget -Header $h[0..40] } 'truncated' -MessagePattern 'truncated|runs past'
    }

    It 'says so when a PE has no HIP device code at all' {
        Assert-Throws { Get-HipOffloadTarget -Path (Join-Path $env:SystemRoot 'System32\kernel32.dll') } 'no .hip_fat' -MessagePattern 'no \.hip_fat section'
    }

    It 'requires every GPU ROCm''s rocBLAS has kernels for, and says when it cannot tell' {
        Invoke-InTestDir { param($dir)
            Assert-Match 'no TensileLibrary_lazy_gfx' (Get-LlamaCppHipTargetFinding -Target @('gfx1201') -RocblasLibraryDir $dir) 'no dats'
            foreach ($g in 'gfx1200', 'gfx1201') { Set-Content -LiteralPath (Join-Path $dir "TensileLibrary_lazy_$g.dat") -Value 'x' }
            Assert-Null (Get-LlamaCppHipTargetFinding -Target @('gfx1201', 'gfx1200') -RocblasLibraryDir $dir) 'covered, as the source build targets them'
            Assert-Match 'no device code for gfx1201' (Get-LlamaCppHipTargetFinding -Target @('gfx1100', 'gfx1200') -RocblasLibraryDir $dir) 'gap'
        }
    }
}

Describe 'LlamaCpp check: the import walk into ROCm (real PEs as stand-ins)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Invoke-PeReader', 'ConvertTo-PeFileOffset', 'Read-PeString', 'Get-PeSymbolTable',
        'Resolve-LoaderDll', 'Test-SameDirectory', 'Get-LlamaCppHipLinkFinding')
    # kernel32 plays ggml-hip.dll (its one non-API-set import is ntdll.dll); ntdll plays a ROCm library.
    $sys = Join-Path $env:SystemRoot 'System32'
    function New-LinkFixture {
        param([string]$Root, [string]$GgmlHip = 'kernel32.dll', [string]$RocmName = 'ntdll.dll', [string]$RocmFrom, [string]$OtherFrom, [string]$LlamaFrom)
        $f = @{ Llama = (Join-Path $Root 'llama'); Rocm = (Join-Path $Root 'rocm'); Other = (Join-Path $Root 'other'); Sys = $sys }
        foreach ($d in $f.Llama, $f.Rocm, $f.Other) { New-Item -ItemType Directory -Path $d | Out-Null }
        Copy-Item (Join-Path $sys $GgmlHip) (Join-Path $f.Llama 'ggml-hip.dll')
        if ($RocmFrom) { Copy-Item (Join-Path $sys $RocmFrom) (Join-Path $f.Rocm $RocmName) }
        if ($OtherFrom) { Copy-Item (Join-Path $sys $OtherFrom) (Join-Path $f.Other 'ntdll.dll') }
        if ($LlamaFrom) { Copy-Item (Join-Path $sys $LlamaFrom) (Join-Path $f.Llama 'ntdll.dll') }
        return $f
    }

    It 'grades each import: resolved, exported, and loaded from ROCm''s bin or a byte-identical copy' {
        $cases = @(
            @{ Name = 'clean'; Rocm = 'ntdll.dll'; Search = 'Llama', 'Rocm', 'Sys'; P = '' },
            @{ Name = 'ABI mismatch'; Rocm = 'version.dll'; Search = 'Llama', 'Rocm', 'Sys'; P = 'ggml-hip\.dll needs \d+ name\(s\) \S+\\rocm\\ntdll\.dll does not export: \w+' },
            @{ Name = 'unresolved'; Rocm = ''; Search = 'Llama', 'Rocm'; P = 'imports ntdll\.dll, which nothing on the loader path provides' },
            @{ Name = 'loaded from elsewhere'; Rocm = 'ntdll.dll'; Other = 'version.dll'; Search = 'Llama', 'Other', 'Rocm', 'Sys'; P = 'loads ntdll\.dll from .*other\\ntdll\.dll, not .*rocm\\ntdll\.dll' },
            @{ Name = 'byte-identical copy elsewhere'; Rocm = 'ntdll.dll'; Other = 'ntdll.dll'; Search = 'Llama', 'Other', 'Rocm', 'Sys'; P = '' },
            # A bundled runtime in the llama dir wins the loader search; it must be ROCm's own.
            @{ Name = 'a different copy in the llama dir'; Rocm = 'ntdll.dll'; Llama = 'version.dll'; Search = 'Llama', 'Rocm', 'Sys'
                P = 'loads ntdll\.dll from .*llama\\ntdll\.dll, not .*rocm\\ntdll\.dll' },
            # msvcrt plays ggml-hip.dll: its KERNELBASE import lands in ROCm's bin, whose own ntdll import resolves nowhere.
            @{ Name = 'a ROCm DLL''s own imports are walked too'; GgmlHip = 'msvcrt.dll'; RocmName = 'KERNELBASE.dll'; Rocm = 'kernelbase.dll'
                Search = 'Llama', 'Rocm'; P = 'KERNELBASE\.dll imports ntdll\.dll, which nothing on the loader path provides' })
        foreach ($c in $cases) {
            Invoke-InTestDir { param($dir)
                $shape = @{ GgmlHip = $(if ($c['GgmlHip']) { $c['GgmlHip'] } else { 'kernel32.dll' }); RocmName = $(if ($c['RocmName']) { $c['RocmName'] } else { 'ntdll.dll' }) }
                $f = New-LinkFixture -Root $dir -RocmFrom $c['Rocm'] -OtherFrom $c['Other'] -LlamaFrom $c['Llama'] @shape
                $got = @(Get-LlamaCppHipLinkFinding -Dir $f.Llama -RocmBin $f.Rocm -SearchDir @($c.Search | ForEach-Object { $f[$_] }))
                if ($c.P) { Assert-Match $c.P ($got -join ' ') $c.Name } else { Assert-Equal '' ($got -join ' | ') $c.Name }
            }
        }
    }
}

Describe 'LlamaCpp check: nothing of ROCm''s beside llama-server, and the PATH rule' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppRocmShadowFinding', 'Get-LlamaCppPathFinding')
    function New-ShadowFixture {
        param([string]$Root)
        $llama = Join-Path $Root 'llama'; $rocm = Join-Path $Root 'rocm'
        foreach ($d in $llama, $rocm) { New-Item -ItemType Directory -Path $d | Out-Null }
        foreach ($f in 'amdhip64_7.dll', 'hipblas.dll') { Set-Content -LiteralPath (Join-Path $rocm $f) -Value "rocm $f" }
        foreach ($f in 'ggml.dll', 'ggml-hip.dll', 'libomp.dll') { Set-Content -LiteralPath (Join-Path $llama $f) -Value $f }
        return @{ Llama = $llama; Rocm = $rocm }
    }

    It 'passes a llama directory that carries no ROCm name' {
        Invoke-InTestDir { param($dir)
            $f = New-ShadowFixture -Root $dir
            Assert-Equal 0 @(Get-LlamaCppRocmShadowFinding -Dir $f.Llama -RocmBin $f.Rocm).Count 'none'
        }
    }

    It 'reports every ROCm name beside llama-server, a byte-identical HIP runtime too' {
        Invoke-InTestDir { param($dir)
            $f = New-ShadowFixture -Root $dir
            Copy-Item (Join-Path $f.Rocm 'amdhip64_7.dll') (Join-Path $f.Llama 'amdhip64_7.dll')
            Set-Content -LiteralPath (Join-Path $f.Llama 'hipblas.dll') -Value 'another hipblas'
            $got = @(Get-LlamaCppRocmShadowFinding -Dir $f.Llama -RocmBin $f.Rocm)
            Assert-Equal 2 $got.Count 'two'
            Assert-Match "amdhip64_7\.dll next to llama-server shadows ROCm's own copy: ggml-hip must load the image's HIP runtime" ($got -join "`n") 'runtime'
            Assert-Match "hipblas\.dll next to llama-server shadows ROCm's own copy" ($got -join "`n") 'library'
        }
    }

    It 'flags a llama directory on PATH in any spelling, with its reason, and nothing else' {
        foreach ($dir in 'C:\runtime\opt\llama.cpp-hip', 'C:\runtime\opt\llama.cpp-vulkan') {
            foreach ($p in "C:\a;$dir", "$($dir.ToUpperInvariant())\;C:\a", "C:\a;`"$dir`"") {
                Assert-Match 'is on PATH: why' (Get-LlamaCppPathFinding -Dir $dir -PathValue $p -Reason 'why') $p
            }
            Assert-Null (Get-LlamaCppPathFinding -Dir $dir -PathValue "C:\runtime\bin;${dir}2;C:\TheRock\build\bin" -Reason 'why') 'siblings are fine'
        }
    }
}

Describe 'LlamaCpp check: llama-server --version and llama-cli --list-devices' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Invoke-LlamaCppProcess', 'Get-LlamaCppRunFinding')
    function New-VersionStub {
        param([string]$Dir, [string]$Body, [string]$Name = 'llama-server.cmd')
        $p = Join-Path $Dir $Name
        Set-Content -LiteralPath $p -Value "@echo off`r`n$Body" -Encoding ASCII
        return $p
    }

    It 'passes when the binary reports the pinned build and exits 0' {
        Invoke-InTestDir { param($dir)
            $exe = New-VersionStub -Dir $dir -Body "echo version: 0.6.0-dev (build 11472, commit d0b490f25) 1>&2`r`nexit /b 0"
            Assert-Null (Get-LlamaCppRunFinding -Run version -Exe $exe -Build '11472' 6>$null) 'pinned build'
        }
    }

    It 'reports another build, a non-zero exit, a hang and a missing binary' {
        Invoke-InTestDir { param($dir)
            $exe = New-VersionStub -Dir $dir -Body "echo version: 0.6.0-dev (build 11472, commit d0b490f25)`r`nexit /b 0"
            Assert-Match 'does not report build 11473' (Get-LlamaCppRunFinding -Run version -Exe $exe -Build '11473' 6>$null) 'other build'
            $exe = New-VersionStub -Dir $dir -Body 'exit /b 3'
            Assert-Match 'exited 3 \(0x00000003\)' (Get-LlamaCppRunFinding -Run version -Exe $exe -Build '11472' 6>$null) 'exit code'
            $exe = New-VersionStub -Dir $dir -Body 'ping -n 30 127.0.0.1 > nul'
            Assert-Match 'did not exit within 1 s' (Get-LlamaCppRunFinding -Run version -Exe $exe -Build '11472' -TimeoutSeconds 1) 'hang'
            Assert-Match 'is missing' (Get-LlamaCppRunFinding -Run version -Exe (Join-Path $dir 'nope.exe') -Build '11472') 'missing'
        }
    }

    It '--list-devices passes only when ggml-hip got an answer from the HIP runtime, and reports every other outcome' {
        # P '' = no finding. The first answer is b11472's in the rocm container on 2026-10-07, verbatim; the second a GPU host's.
        $cases = @(
            @{ P = ''; Body = "echo 0.00.142.520 E ggml_cuda_init: failed to initialize ROCm: no ROCm-capable device is detected 1>&2`r`necho Available devices:`r`necho   (none)" }
            @{ P = ''; Body = "echo ggml_cuda_init: found 1 ROCm devices: 1>&2`r`necho   ROCm0: AMD Radeon RX 9070 XT" }
            @{ P = 'did not initialise ggml-hip on the HIP runtime'; Body = "echo Available devices:`r`necho   (none)" }
            @{ P = 'did not initialise ggml-hip'; Body = 'echo ggml_cuda_init: failed to initialize ROCm: invalid device function' }
            @{ P = 'exited -1073741515 \(0xC0000135\)'; Body = 'exit /b -1073741515' }
            @{ P = 'did not exit within 1 s'; Body = 'ping -n 30 127.0.0.1 > nul'; Timeout = 1 })
        Invoke-InTestDir { param($dir)
            foreach ($c in $cases) {
                $exe = New-VersionStub -Dir $dir -Name 'llama-cli.cmd' -Body $c.Body
                $got = Get-LlamaCppRunFinding -Run devices -Exe $exe -TimeoutSeconds $(if ($c['Timeout']) { $c['Timeout'] } else { 120 }) 6>$null
                if ($c.P) { Assert-Match $c.P "$got" $c.Body } else { Assert-Null $got $c.Body }
            }
            Assert-Match 'is missing' (Get-LlamaCppRunFinding -Run devices -Exe (Join-Path $dir 'nope.exe')) 'a missing llama-cli'
        }
    }
}

Describe 'LlamaCpp check: the Vulkan loader resolves from System32 or PATH, never from the llama dir' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Resolve-LoaderDll', 'Test-SameDirectory', 'Get-PathDirectory',
        'Get-LlamaCppSearchDir', 'Get-LlamaCppVulkanLoaderFinding')
    # A fixture Windows dir stands in for SystemRoot, so the host's own System32\vulkan-1.dll cannot decide a case.
    function Get-LoaderCase {
        param([string]$Root, [string[]]$LoaderIn)
        $d = @{ Llama = (Join-Path $Root 'llama'); Win = (Join-Path $Root 'win'); Path = (Join-Path $Root 'vulkan-loader') }
        $d.Sys32 = Join-Path $d.Win 'System32'
        foreach ($x in $d.Llama, $d.Sys32, $d.Path) { New-Item -ItemType Directory -Force -Path $x | Out-Null }
        foreach ($where in $LoaderIn) { Set-Content -LiteralPath (Join-Path $d[$where] 'vulkan-1.dll') -Value 'loader' }
        $pathValue = "C:\nowhere;`"$($d.Path)`""
        $loader = "$(Resolve-LoaderDll -Name 'vulkan-1.dll' -SearchDir (Get-LlamaCppSearchDir -Dir $d.Llama -WindowsDir $d.Win -PathValue $pathValue))"
        $allowed = @($d.Sys32) + @(Get-PathDirectory -PathValue $pathValue)
        return @{ Loader = $loader; Findings = @(Get-LlamaCppVulkanLoaderFinding -Loader $loader -AllowedDir $allowed 6>$null); Dirs = $d }
    }

    It 'accepts a loader in System32 or in a PATH directory, and says which one wins' {
        Invoke-InTestDir { param($dir)
            $r = Get-LoaderCase -Root $dir -LoaderIn 'Sys32', 'Path'
            Assert-Equal (Join-Path $r.Dirs.Sys32 'vulkan-1.dll') $r.Loader 'System32 comes before PATH'
            Assert-Equal 0 $r.Findings.Count 'System32'
        }
        Invoke-InTestDir { param($dir)
            $r = Get-LoaderCase -Root $dir -LoaderIn 'Path'
            Assert-Equal (Join-Path $r.Dirs.Path 'vulkan-1.dll') $r.Loader 'the PATH copy (a quoted entry)'
            Assert-Equal 0 $r.Findings.Count 'PATH'
        }
    }

    It 'reports a loader in the llama dir or the Windows dir, and a missing one' {
        Invoke-InTestDir { param($dir)
            Assert-Match 'resolves to .*\\llama\\vulkan-1\.dll, which is neither System32 nor on PATH' ((Get-LoaderCase -Root $dir -LoaderIn 'Llama', 'Sys32').Findings -join ' ') 'a private copy wins'
        }
        Invoke-InTestDir { param($dir)
            Assert-Match 'resolves to .*\\win\\vulkan-1\.dll, which is neither' ((Get-LoaderCase -Root $dir -LoaderIn 'Win').Findings -join ' ') 'Windows dir'
        }
        Invoke-InTestDir { param($dir)
            Assert-Match 'the image carries no Vulkan loader' ((Get-LoaderCase -Root $dir -LoaderIn @()).Findings -join ' ') 'none'
        }
    }
}

Describe 'LlamaCpp check: grading the load probes' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppProbeModuleFinding', 'Get-LlamaCppVulkanProbeFinding')
    $script:VkDir = 'C:\runtime\opt\llama.cpp-vulkan'
    $script:VkLoader = 'C:\vulkan-loader\vulkan-1.dll'
    function Get-ProbeText {
        param([string]$Base = "$script:VkDir\ggml-base.dll", [string]$Vk = 'C:\VULKAN-LOADER\vulkan-1.dll', [string]$Answer = '0,4211045')
        return "module ggml-base.dll=$Base`r`nmodule vulkan-1.dll=$Vk`r`nvkEnumerateInstanceVersion=$Answer"
    }

    It 'passes the report of a clean Vulkan load (API 1.4.357; the loader path in another case)' {
        Assert-Equal '' (@(Get-LlamaCppVulkanProbeFinding -Text (Get-ProbeText) -Dir $script:VkDir -Loader $script:VkLoader 6>$null) -join ' | ') 'clean'
        Assert-Equal '' (@(Get-LlamaCppVulkanProbeFinding -Text (Get-ProbeText -Answer '0,4202496') -Dir $script:VkDir -Loader $script:VkLoader 6>$null) -join ' | ') 'exactly 1.2.0 is enough'
    }

    It 'reports ggml-base or vulkan-1 from elsewhere, a failed or old loader, and a missing answer' {
        $cases = @(
            @{ T = (Get-ProbeText -Base 'C:\runtime\opt\llama.cpp-hip\ggml-base.dll'); P = "took ggml-base\.dll from 'C:\\runtime\\opt\\llama\.cpp-hip" },
            @{ T = (Get-ProbeText -Vk 'D:\elsewhere\vulkan-1.dll'); P = "took vulkan-1\.dll from 'D:\\elsewhere\\vulkan-1\.dll', not C:\\vulkan-loader" },
            @{ T = (Get-ProbeText -Answer '-9,0'); P = 'vkEnumerateInstanceVersion returned VkResult -9' },
            @{ T = (Get-ProbeText -Answer '0,4198400'); P = 'reports API 1\.1\.0; ggml-vulkan registers no device below 1\.2' },
            @{ T = 'module ggml-base.dll='; P = "took ggml-base\.dll from ''.*no vkEnumerateInstanceVersion result" })
        foreach ($c in $cases) {
            Assert-Match $c.P (@(Get-LlamaCppVulkanProbeFinding -Text $c.T -Dir $script:VkDir -Loader $script:VkLoader 6>$null) -join ' | ') $c.P
        }
    }

    It 'grades the ggml-hip probe: ggml-base from the llama dir, each ROCm import from ROCm''s bin, case-blind paths' {
        $want = [ordered]@{ 'ggml-base.dll' = 'C:\runtime\opt\llama.cpp-hip\ggml-base.dll'; 'amdhip64_7.dll' = 'C:\TheRock\build\bin\amdhip64_7.dll' }
        $clean = "module ggml-base.dll=C:\RUNTIME\opt\llama.cpp-hip\ggml-base.dll`r`nmodule amdhip64_7.dll=C:\TheRock\build\bin\amdhip64_7.dll"
        Assert-Equal '' (@(Get-LlamaCppProbeModuleFinding -Text $clean -Dll 'ggml-hip.dll' -Expected $want) -join ' | ') 'clean'
        $driver = "module ggml-base.dll=C:\runtime\opt\llama.cpp-hip\ggml-base.dll`r`nmodule amdhip64_7.dll=C:\Windows\System32\amdhip64_7.dll"
        Assert-Match "ggml-hip\.dll took amdhip64_7\.dll from 'C:\\Windows\\System32\\amdhip64_7\.dll', not C:\\TheRock" (@(Get-LlamaCppProbeModuleFinding -Text $driver -Dll 'ggml-hip.dll' -Expected $want) -join ' ') 'a driver''s runtime'
        Assert-Match "took amdhip64_7\.dll from ''" (@(Get-LlamaCppProbeModuleFinding -Text 'module ggml-base.dll=C:\runtime\opt\llama.cpp-hip\ggml-base.dll' -Dll 'ggml-hip.dll' -Expected $want) -join ' ') 'not loaded at all'
    }
}

Describe 'LlamaCpp check: the load probes run in a child pwsh' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Invoke-LlamaCppProcess', 'Get-LlamaCppProbeScript', 'Invoke-LlamaCppLoadProbe',
        'Get-LlamaCppProbeModuleFinding', 'Get-LlamaCppVulkanProbeFinding', 'Get-LlamaCppVulkanLoadFinding', 'Get-LlamaCppHipLoadFinding',
        'Invoke-PeReader', 'ConvertTo-PeFileOffset', 'Read-PeString', 'Get-PeSymbolTable')

    It 'reports a DLL that loads but is no ggml backend, and one that is not there' {
        Invoke-InTestDir { param($dir)
            Copy-Item (Join-Path $env:SystemRoot 'System32\version.dll') (Join-Path $dir 'ggml-vulkan.dll')
            Assert-Match 'ggml-vulkan\.dll does not load from .*ggml_backend_init' (Get-LlamaCppVulkanLoadFinding -Dir $dir -Loader 'C:\x\vulkan-1.dll') 'no entry'
            Assert-Match 'ggml-vulkan\.dll does not load from ' (Get-LlamaCppVulkanLoadFinding -Dir (Join-Path $dir 'none') -Loader 'C:\x\vulkan-1.dll') 'missing'
            Copy-Item (Join-Path $env:SystemRoot 'System32\version.dll') (Join-Path $dir 'ggml-hip.dll')
            Assert-Match 'ggml-hip\.dll does not load from .*ggml_backend_init' (Get-LlamaCppHipLoadFinding -Dir $dir -RocmBin (Join-Path $dir 'rocm')) 'HIP: no entry'
        }
    }
}

Describe 'LlamaCpp check: the whole script, run as the smoke gate and each stage run it' {
    $check = Join-Path (Get-RepoRoot) $script:LlamaCheck

    It 'reports one finding per backend whose stage never ran, and grades both by default (the smoke gate)' {
        Invoke-WithEnv @{ LLAMA_CPP_HIP_HOME = $null; LLAMA_CPP_VULKAN_HOME = $null } {
            foreach ($c in @(@{ B = 'hip'; P = 'LLAMA_CPP_HIP_HOME' }, @{ B = 'vulkan'; P = 'LLAMA_CPP_VULKAN_HOME' })) {
                $got = @(& $check -Backend $c.B)
                Assert-Equal 1 $got.Count "$($c.P): one finding"
                Assert-Match "$($c.P) .*the rocm-llama stage did not run" $got[0] 'names the stage'
            }
            $got = @(& $check)
            Assert-Equal 2 $got.Count 'no -Backend: both'
            Assert-Match 'LLAMA_CPP_HIP_HOME' $got[0] 'HIP first'
            Assert-Match 'LLAMA_CPP_VULKAN_HOME' $got[1] 'then Vulkan'
        }
    }

    It 'reports one finding when there is no ROCm tree for ggml-hip to link against' {
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ LLAMA_CPP_HIP_HOME = $dir; HIP_PATH = $null; ROCM_PATH = $null } {
                $got = @(& $check -Backend hip)
                Assert-Equal 1 $got.Count 'one finding'
                Assert-Match 'no ROCm bin under HIP_PATH/ROCM_PATH' $got[0] 'names ROCm'
            }
        }
    }

    # Runs the check as one Dockerfile RUN does (-Backend only) and asserts each finding, and none about the other build.
    function Assert-CheckWiring {
        param([string]$Backend, [hashtable]$Env, [string[]]$Want, [string]$Other, [string[]]$NotWant = @())
        Invoke-WithEnv ($Env + @{ LLAMA_CPP_HIP_BUILD = '11472' }) {
            $got = @(& $check -Backend $Backend 6>$null) -join "`n"
            foreach ($w in $Want) { Assert-Match $w $got $w }
            foreach ($n in $NotWant) { Assert-False ($got -match $n) "not: $n" }
            Assert-False ($got -match $Other) "-Backend $Backend grades nothing of the other build"
        }
    }

    It 'wires every HIP check: manifest, PATH, ROCm shadowing, import walk, offload bundle, --version; no load before a clean walk' {
        Invoke-InTestDir { param($dir)
            $llama = Join-Path $dir 'llama'; $rocm = Join-Path $dir 'rocm'
            New-Item -ItemType Directory -Path $llama, (Join-Path $rocm 'bin') | Out-Null
            $sys = Join-Path $env:SystemRoot 'System32'
            # kernel32 plays ggml-hip.dll; its ntdll import resolves in System32, not to ROCm's (a version.dll copy).
            Copy-Item (Join-Path $sys 'kernel32.dll') (Join-Path $llama 'ggml-hip.dll')
            Copy-Item (Join-Path $sys 'version.dll') (Join-Path $rocm 'bin\ntdll.dll')
            Set-Content -LiteralPath (Join-Path $rocm 'bin\amdhip64_7.dll') -Value 'ROCm HIP runtime'
            Set-Content -LiteralPath (Join-Path $llama 'amdhip64_7.dll') -Value 'ROCm HIP runtime'
            Assert-CheckWiring -Backend hip -Env @{ LLAMA_CPP_HIP_HOME = $llama; HIP_PATH = $rocm; ROCM_PATH = $null; PATH = "$llama;$env:PATH" } -Other 'vulkan' -Want @(
                'no manifest at .*llama-cpp-hip-manifest', 'is on PATH: its libomp\.dll', "amdhip64_7\.dll next to llama-server shadows ROCm's own copy",
                'ggml-hip\.dll loads ntdll\.dll from .*System32\\ntdll\.dll, not ', 'offload bundle is unreadable: .*no \.hip_fat section', 'llama-server\.exe is missing') `
                -NotWant 'does not load from', '--list-devices'
        }
    }

    It 'wires every Vulkan check: manifest, PATH, loader, the load probe, --version' {
        Invoke-InTestDir { param($dir)
            # version.dll plays ggml-vulkan.dll (loads, exports no ggml_backend_init) and, on a host without one, the loader.
            foreach ($f in 'vk\ggml-vulkan.dll', 'vulkan-loader\vulkan-1.dll') {
                New-Item -ItemType Directory -Force -Path (Split-Path (Join-Path $dir $f) -Parent) | Out-Null
                Copy-Item (Join-Path $env:SystemRoot 'System32\version.dll') (Join-Path $dir $f)
            }
            $vk = Join-Path $dir 'vk'
            Assert-CheckWiring -Backend vulkan -Env @{ LLAMA_CPP_VULKAN_HOME = $vk; PATH = "$vk;$(Join-Path $dir 'vulkan-loader');$env:PATH" } -Other 'ROCm|hip' -Want @(
                'no manifest at .*llama-cpp-vulkan-manifest', 'is on PATH: its libomp\.dll', 'ggml-vulkan\.dll does not load from .*ggml_backend_init', 'llama-server\.exe is missing')
        }
    }
}

Describe 'Installer, check, Dockerfile and deps.json agree per backend' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppCheckSpec')
    $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.rocm-llama')

    It 'names the same manifest, home and backend DLL on both sides, and the Dockerfile ENV sets that home' {
        foreach ($b in 'hip', 'vulkan') {
            $install = Get-LlamaCppBackendSpec -Backend $b
            $check = Get-LlamaCppCheckSpec -Backend $b
            Assert-Equal $install.Manifest $check.Manifest "$b manifest"
            Assert-Equal (@(@($install.Built) + @($install.Required))[0]) $check.Required[0] "$b backend DLL (HIP's is the built one)"
            Assert-Equal $install.Home ([regex]::Match($df, "$($check.HomeVar)=`"([^`"]+)`"").Groups[1].Value) "$b home"
        }
    }

    It 'gives each home a deps.json llama.cpp row on the one build pin, and names it in the libomp row (both zips ship libomp)' {
        $deps = Get-Content -LiteralPath (Join-Path (Get-RepoRoot) 'docs\deps\deps.json') -Raw | ConvertFrom-Json
        $subs = @(@($deps.sections | Where-Object { $_.title -eq 'Windows Image' }).subsections | Where-Object { $_.title -match '^llama\.cpp .*\(rocm variant only\)$' })
        Assert-Equal 1 $subs.Count 'one rocm-only llama.cpp subsection'
        $rows = @($subs[0].entries)
        Assert-Equal $rows.Count @($rows | Where-Object { $_.PSObject.Properties['spdx'] -and $_.spdx }).Count 'every row has an spdx id'
        foreach ($b in 'hip', 'vulkan') {
            $dir = [regex]::Escape((Get-LlamaCppBackendSpec -Backend $b).Home)
            $own = @($rows | Where-Object { $_.license -match "$dir\\licenses\\llama\.cpp" })
            Assert-Equal 1 $own.Count "$b`: one row ships llama.cpp's LICENSE in its home"
            Assert-Equal 'LLAMA_CPP_HIP_BUILD|MIT' "$($own[0].var)|$($own[0].spdx)" "$b`: MIT, versioned by the one build pin"
            Assert-Equal 1 @($rows | Where-Object { $_.name -match 'libomp\.dll' -and $_.license -match "$dir(?![\w.-])" }).Count "$b`: the libomp row names its home"
        }
        Assert-Equal 0 @($rows | Where-Object { $_.name -match 'amdhip64|rocm_kpack|amd_comgr' }).Count 'no bundled HIP runtime row: ggml-hip loads the image''s'
    }
}

Describe 'Dockerfile.rocm-llama: rocm-only stage, two layers off PATH, closure mounted, checks armed' {
    $root = Get-RepoRoot
    $df = Get-Content -Raw (Join-Path $root 'windows\Dockerfile.rocm-llama')
    $code = ($df -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

    It 'builds a ''built'' target FROM the BASE_IMAGE the driver passes' {
        Assert-Match '(?m)^FROM \$\{BASE_IMAGE\} AS built$' $code 'target built'
    }

    It 'never touches PATH (neither directory may shadow anything for other processes)' {
        Assert-False ($code -match '(?i)\bPATH=') 'no PATH in any instruction'
        Assert-Match 'LLAMA_CPP_HIP_HOME="C:\\runtime\\opt\\llama\.cpp-hip"' $code 'HIP home is exposed by ENV'
        Assert-Match 'LLAMA_CPP_VULKAN_HOME="C:\\runtime\\opt\\llama\.cpp-vulkan"' $code 'Vulkan home is exposed by ENV'
    }

    It 'mounts a closed module set: what every script imports, and what every mounted module imports' {
        # Closed under imports, so it holds the transitive closure without walking it.
        $copy = [regex]::Match($code, '(?s)FROM \$\{BASE_IMAGE\} AS llamamods\nCOPY (.+?) C:\\bkmods\\').Groups[1].Value
        $mounted = @([regex]::Matches($copy, 'windows\\scripts\\modules\\([\w.]+)\.psm1') | ForEach-Object { $_.Groups[1].Value })
        $needed = @{}
        foreach ($s in $script:LlamaInstall, $script:LlamaCheck, $script:LlamaBuild) {
            foreach ($m in [regex]::Matches((Get-Content -Raw (Join-Path $root $s)), 'modules\\([\w.]+)\.psm1')) { $needed[$m.Groups[1].Value] = $s }
        }
        foreach ($m in $mounted) {
            foreach ($sib in [regex]::Matches((Get-Content -Raw (Join-Path $root "windows\scripts\modules\$m.psm1")), "PSScriptRoot\s+'([\w.]+)\.psm1'")) { $needed[$sib.Groups[1].Value] = "$m.psm1" }
        }
        Assert-True ($needed.Count -ge 4) "the scan found $($needed.Count) needed module(s)"
        foreach ($m in $needed.Keys) { Assert-True ($mounted -contains $m) "$m (imported by $($needed[$m])) is not in the llamamods closure" }
        Assert-Equal 2 @([regex]::Matches($code, 'from=llamamods,source=/bkmods,target=C:\\bkmnt\\modules')).Count 'both RUNs mount the closure'
    }

    It 'builds, installs and checks HIP in one RUN and Vulkan in another, failing the stage on any finding' {
        $runs = @([regex]::Matches($code, '(?s)RUN --mount.*?throw \(.*?\)\s*\}') | ForEach-Object { $_.Value })
        Assert-Equal 2 $runs.Count 'two RUNs'
        Assert-Match ("(?s)Build-LlamaCppHipFromSource\.ps1' -OutputDir '(?<out>[^']+)'.*Install-LlamaCpp\.ps1' -Backend hip .*-InstallDir \`$env:LLAMA_CPP_HIP_HOME -BuiltDir '\k<out>'" +
            ".*@\(& 'C:\\bkmnt\\LlamaCpp\.ps1' -Backend hip\).*throw") $runs[0] 'HIP built, installed from that output, armed'
        Assert-Match 'type=cache,target=C:\\sccache,' $runs[0] 'the compile shares the lane''s sccache'
        Assert-Match "(?s)Install-LlamaCpp\.ps1' -Backend vulkan .*-InstallDir \`$env:LLAMA_CPP_VULKAN_HOME.*@\(& 'C:\\bkmnt\\LlamaCpp\.ps1' -Backend vulkan\).*throw" $runs[1] 'Vulkan armed'
    }

    It 'declares the HIP pins before the HIP RUN and the Vulkan pin after it, so bumping it keeps the HIP layer cached' {
        foreach ($k in 'LLAMA_CPP_HIP_COMMIT', 'LLAMA_CPP_HIP_SOURCE_SHA256', 'LLAMA_CPP_CPU_SHA256', 'ROCM_WINDOWS_GFX_FAMILY') {
            Assert-Match "(?s)\nARG $k=.*Build-LlamaCppHipFromSource\.ps1' -OutputDir" $code "ARG $k precedes the HIP RUN"
        }
        Assert-Match '(?s)-Backend hip -TempDir.*\nARG LLAMA_CPP_VULKAN_SHA256=' $code 'ARG LLAMA_CPP_VULKAN_SHA256 follows the HIP RUN'
        Assert-False ($code -match '(?s)ARG LLAMA_CPP_VULKAN_SHA256=.*-Backend hip -TempDir') 'and never precedes it'
    }
}

Describe 'Build-Buildkit.ps1: the llama pins reach the llama stage only' {
    $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1')

    It 'sends the LLAMA_CPP_* pins in $llamaArgs and nowhere else (cpu and nvidia never solve that stage)' {
        $block = [regex]::Match($src, "(?s)\`$llamaArgs = @\{(.+?\r?\n\s*\}[^\r\n]*)").Groups[1].Value
        foreach ($k in $script:LlamaPinKeys) {
            Assert-Match "$k\s*= Get-Ver '$k'" $block "$k in the llama block"
            Assert-Equal ([regex]::Matches($block, "\b$k\b")).Count ([regex]::Matches($src, "\b$k\b")).Count "every $k mention sits in that block"
        }
        Assert-Match '\}\s*\+ \$sccache' $block 'ggml-hip compiles there, so the sccache endpoint goes along'
        Assert-Match "(?s)if \(\`$Stages -contains 'llama'\) \{\s+#[^\n]*\n\s+\`$llamaArgs = @\{" $src 'only inside the llama stage'
    }
}
