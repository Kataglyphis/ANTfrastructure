#requires -Version 7.0
# llama.cpp HIP + Vulkan on the rocm lane (Install-LlamaCpp.ps1, rocm-checks\LlamaCpp.ps1, Dockerfile.rocm-llama):
# lane gate, pins, install with downloads stubbed, zip layout, manifest, PE walk, offload targets, HIP runtime,
# Vulkan loader resolution and load probe, PATH rule, --version, wiring, deps.json rows. NOT covered: real downloads, a real zip.

$script:LlamaInstall = 'windows\scripts\build\Install-LlamaCpp.ps1'
$script:LlamaCheck = 'windows\scripts\build\rocm-checks\LlamaCpp.ps1'
$script:LlamaPinKeys = 'LLAMA_CPP_HIP_BUILD', 'LLAMA_CPP_HIP_ASSET', 'LLAMA_CPP_HIP_SHA256', 'LLAMA_CPP_HIP_LICENSE_SHA256', 'LLAMA_CPP_VULKAN_SHA256'

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

Describe 'Install-LlamaCpp: pin parity (one build pin for both zips; asset and ROCm release agree)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Get-LlamaCppAssetUrl')
    $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')
    $hip = Get-LlamaCppBackendSpec -Backend hip
    $vk = Get-LlamaCppBackendSpec -Backend vulkan

    It 'accepts the versions.env pins as they stand (a one-key bump fails HERE, not in the build)' {
        $build = $pins['LLAMA_CPP_HIP_BUILD']
        $url = Get-LlamaCppAssetUrl -Spec $hip -Build $build -Asset $pins['LLAMA_CPP_HIP_ASSET'] -RocmRelease $pins['ROCM_WINDOWS_RELEASE']
        Assert-Equal ('https://github.com/ggml-org/llama.cpp/releases/download/b{0}/{1}' -f $build, $pins['LLAMA_CPP_HIP_ASSET']) $url 'HIP url'
        $url = Get-LlamaCppAssetUrl -Spec $vk -Build $build -Asset ($vk.AssetFormat -f $build)
        Assert-Equal ('https://github.com/ggml-org/llama.cpp/releases/download/b{0}/llama-b{0}-bin-win-vulkan-x64.zip' -f $build) $url 'the Vulkan zip of the same build'
        foreach ($key in 'LLAMA_CPP_HIP_SHA256', 'LLAMA_CPP_HIP_LICENSE_SHA256', 'LLAMA_CPP_VULKAN_SHA256') { Assert-Match '^[0-9a-f]{64}$' $pins[$key] "$key is 64 lower-case hex" }
        Assert-False ($pins['LLAMA_CPP_VULKAN_SHA256'] -eq $pins['LLAMA_CPP_HIP_SHA256']) 'two zips, two digests'
        foreach ($key in 'LLAMA_CPP_VULKAN_BUILD', 'LLAMA_CPP_VULKAN_ASSET', 'LLAMA_CPP_VULKAN_LICENSE_SHA256') { Assert-False $pins.Contains($key) "${key}: the build stays ONE pin" }
    }

    It 'refuses a malformed build or asset, a build mismatch and a ROCm mismatch' {
        $cases = @(
            @{ S = $hip; B = 'b11115'; A = 'llama-b11115-bin-win-rocm-10.0-x64.zip'; R = '10.0.0'; P = 'LLAMA_CPP_HIP_BUILD must be' },
            @{ S = $hip; B = '11115'; A = 'llama-b11115-bin-win-cuda-12.4-x64.zip'; R = '10.0.0'; P = 'HIP asset .* does not match' },
            @{ S = $hip; B = '11115'; A = 'llama-b11115-bin-win-vulkan-x64.zip'; R = '10.0.0'; P = 'HIP asset .* does not match' },
            @{ S = $hip; B = '11115'; A = 'llama-b11114-bin-win-rocm-10.0-x64.zip'; R = '10.0.0'; P = 'HIP asset names build 11114' },
            @{ S = $hip; B = '11115'; A = 'llama-b11115-bin-win-rocm-7.14-x64.zip'; R = '10.0.0'; P = 'built for ROCm 7\.14 but the image carries ROCm 10\.0\.0' },
            @{ S = $hip; B = '11115'; A = 'llama-b11115-bin-win-rocm-10.0-x64.zip'; R = '10.0'; P = 'ROCM_WINDOWS_RELEASE must be' },
            @{ S = $vk; B = '11115'; A = 'llama-b11115-bin-win-rocm-10.0-x64.zip'; R = '10.0.0'; P = 'Vulkan asset .* does not match' },
            @{ S = $vk; B = '11115'; A = 'llama-b11114-bin-win-vulkan-x64.zip'; R = ''; P = 'Vulkan asset names build 11114' },
            @{ S = $vk; B = ''; A = 'llama-b-bin-win-vulkan-x64.zip'; R = ''; P = 'LLAMA_CPP_HIP_BUILD must be' }
        )
        foreach ($c in $cases) {
            Assert-Throws { Get-LlamaCppAssetUrl -Spec $c.S -Build $c.B -Asset $c.A -RocmRelease $c.R } "$($c.S.Label) $($c.B) $($c.A) $($c.R)" -MessagePattern $c.P
        }
    }

    It 'couples only the HIP zip to the ROCm release' {
        Assert-Match 'b11115/llama-b11115-bin-win-vulkan-x64\.zip$' (Get-LlamaCppAssetUrl -Spec $vk -Build '11115' -Asset 'llama-b11115-bin-win-vulkan-x64.zip' -RocmRelease '') 'no ROCm release needed'
        Assert-Match '^llama-b11115-bin-win-vulkan-x64\.zip$' ($vk.AssetFormat -f '11115') 'the derived name is the upstream asset name'
    }

    It 'keeps Dockerfile.rocm-llama''s ARG defaults equal to versions.env' {
        $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.rocm-llama')
        foreach ($key in $script:LlamaPinKeys) {
            Assert-Equal $pins[$key] ([regex]::Match($df, "(?m)^ARG $key=(\S+)$").Groups[1].Value) "ARG $key"
        }
    }
}

Describe 'Install-LlamaCpp: zip layout' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Assert-LlamaCppZipEntry')
    $hip = Get-LlamaCppBackendSpec -Backend hip
    $vk = Get-LlamaCppBackendSpec -Backend vulkan
    # The b11115 zips as upstream ships them (flat), and TheRock 10.0.0's bin DLLs.
    $script:ZipB11115 = @('amdhip64_7.dll', 'amd_comgr.dll', 'ggml-hip.dll', 'rocm_kpack.dll', 'llama.dll', 'llama-server.exe',
        'llama-quantize-impl.dll', 'llama-batched-bench-impl.dll', 'ggml-cpu-skylakex.dll', 'llama-gguf-split.exe', 'llama-cli-impl.dll',
        'ggml-cpu-haswell.dll', 'ggml-cpu-x64.dll', 'llama-minicpmv-cli.exe', 'ggml-cpu-sandybridge.dll', 'llama-tts.exe',
        'ggml-cpu-piledriver.dll', 'ggml-rpc.dll', 'llama-fit-params.exe', 'llama-completion.exe', 'llama-completion-impl.dll',
        'llama-batched-bench.exe', 'llama-perplexity-impl.dll', 'llama-cli.exe', 'ggml-cpu-sse42.dll', 'llama-server-impl.dll',
        'llama-llava-cli.exe', 'llama-fit-params-impl.dll', 'ggml-cpu-cascadelake.dll', 'ggml-cpu-ivybridge.dll', 'llama-bench.exe',
        'llama-perplexity.exe', 'ggml-cpu-alderlake.dll', 'ggml-cpu-zen4.dll', 'ggml-cpu-cooperlake.dll', 'llama-tokenize.exe',
        'libomp.dll', 'ggml-rpc-server.exe', 'llama-common.dll', 'llama-qwen2vl-cli.exe', 'ggml-base.dll', 'llama-quantize.exe',
        'ggml-cpu-icelake.dll', 'llama-mtmd-debug.exe', 'llama-mtmd-cli.exe', 'LICENSE-LLVM-OpenMP', 'ggml-cpu-cannonlake.dll',
        'ggml.dll', 'llama-imatrix.exe', 'llama.exe', 'mtmd.dll', 'llama-results.exe', 'ggml-cpu-sapphirerapids.dll',
        'llama-gemma3-cli.exe', 'llama-bench-impl.dll')
    # Measured: the Vulkan zip is the same 51 files (same CRC32) with ggml-vulkan.dll in place of the HIP four.
    $script:VulkanZipB11115 = @($script:ZipB11115 | Where-Object { $_ -notin 'amdhip64_7.dll', 'amd_comgr.dll', 'ggml-hip.dll', 'rocm_kpack.dll' }) + 'ggml-vulkan.dll'
    $script:RocmBin1000 = @('MIOpen.dll', 'MIOpenCKGroupedConv_gfx1200.dll', 'MIOpenCKGroupedConv_gfx1201.dll', 'OpenCL.dll', 'amd_comgr.dll',
        'amdhip64_7.dll', 'amdocl64.dll', 'cltrace.dll', 'hipblas.dll', 'hipdnn_backend.dll', 'hipfft.dll', 'hipfftw.dll',
        'hiprand.dll', 'hiprtc-builtins0715.dll', 'hiprtc0715.dll', 'hipsolver.dll', 'hipsparse.dll', 'hiptensor.dll',
        'libhipblaslt.dll', 'origami.dll', 'rocalution.dll', 'rocblas.dll', 'rocfft.dll', 'rocm-openblas.dll',
        'rocm-openblas64.dll', 'rocm_kpack.dll', 'rocrand.dll', 'rocsolver.dll', 'rocsparse.dll')

    It 'accepts both b11115 zips: HIP''s only ROCm names are its runtime, Vulkan''s are none' {
        Assert-Equal 55 $script:ZipB11115.Count 'the whole b11115 HIP listing'
        Assert-Equal 52 $script:VulkanZipB11115.Count 'the whole b11115 Vulkan listing'
        Assert-Equal 29 $script:RocmBin1000.Count 'every bin\*.dll of the 10.0.0 gfx120X-all tarball'
        Assert-LlamaCppZipEntry -Spec $hip -EntryName $script:ZipB11115 -RocmBinDllName $script:RocmBin1000
        Assert-LlamaCppZipEntry -Spec $vk -EntryName $script:VulkanZipB11115 -RocmBinDllName $script:RocmBin1000
        Assert-True $true 'accepted'
    }

    It 'refuses a zip that lacks any load-bearing file, naming it' {
        foreach ($c in @(@{ S = $hip; Zip = $script:ZipB11115; Need = 'ggml-hip.dll', 'llama-server.exe', 'amdhip64_7.dll', 'rocm_kpack.dll', 'ggml-base.dll' },
                @{ S = $vk; Zip = $script:VulkanZipB11115; Need = 'ggml-vulkan.dll', 'llama-server.exe', 'ggml-base.dll', 'llama.dll' })) {
            foreach ($r in $c.Need) {
                $entries = @($c.Zip | Where-Object { $_ -ne $r })
                Assert-Throws { Assert-LlamaCppZipEntry -Spec $c.S -EntryName $entries -RocmBinDllName $script:RocmBin1000 } "$($c.S.Label) missing $r" -MessagePattern ('missing ' + [regex]::Escape($r))
            }
        }
    }

    It 'refuses a zip that would shadow ROCm, is no longer flat, or (Vulkan) brings its own loader' {
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $hip -EntryName ($script:ZipB11115 + 'hipblas.dll' + 'rocblas.dll') -RocmBinDllName $script:RocmBin1000 } 'shadow' -MessagePattern "shadow ROCm's own hipblas\.dll, rocblas\.dll"
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $hip -EntryName ($script:ZipB11115 + 'llama-b11115/ggml.dll') -RocmBinDllName $script:RocmBin1000 } 'nested' -MessagePattern 'not flat'
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $vk -EntryName ($script:VulkanZipB11115 + 'vulkan-1.dll') -RocmBinDllName $script:RocmBin1000 } 'loader' -MessagePattern 'carries vulkan-1\.dll: the Vulkan loader must come from the image'
        Assert-Throws { Assert-LlamaCppZipEntry -Spec $vk -EntryName ($script:VulkanZipB11115 + 'amdhip64_7.dll') -RocmBinDllName $script:RocmBin1000 } 'HIP runtime' -MessagePattern "(?s)refusing the Vulkan zip:.*shadow ROCm's own amdhip64_7\.dll"
    }
}

Describe 'Install-LlamaCpp: the script body, with the module functions stood in for' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppBackendSpec', 'Assert-LlamaCppLane',
        'Get-LlamaCppAssetUrl', 'Assert-LlamaCppZipEntry', 'Write-LlamaCppManifest', 'Install-LlamaCpp')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppCheckSpec', 'Get-LlamaCppManifestFinding')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:ZipMinimal = @{
        hip    = @('ggml-hip.dll', 'ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe', 'amdhip64_7.dll', 'amd_comgr.dll', 'rocm_kpack.dll', 'LICENSE-LLVM-OpenMP')
        vulkan = @('ggml-vulkan.dll', 'ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe', 'LICENSE-LLVM-OpenMP')
    }
    $script:FixtureAsset = @{ hip = 'llama-b11115-bin-win-rocm-10.0-x64.zip'; vulkan = '' }
    # Runs Install-LlamaCpp over a fixture zip and LICENSE; the stand-ins below shadow the module functions by scope.
    function Invoke-LlamaInstallFixture {
        param([string]$Root, [string]$Backend = 'hip', [string]$GpuType = 'rocm', [string[]]$ZipEntry = $script:ZipMinimal[$Backend], [hashtable]$Override = @{})
        $fixtureRocm = Join-Path $Root 'rocm'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRocm 'bin'), (Join-Path $Root 'zip') | Out-Null
        foreach ($f in 'amdhip64_7.dll', 'amd_comgr.dll', 'rocm_kpack.dll', 'hipblas.dll', 'rocblas.dll') { Set-Content -LiteralPath (Join-Path $fixtureRocm "bin\$f") -Value $f }
        foreach ($f in $ZipEntry) { Set-Content -LiteralPath (Join-Path $Root "zip\$f") -Value "bytes of $f" }
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
        $pins = @{ Backend = $Backend; TempDir = (Join-Path $Root 'tmp'); Build = '11115'; Asset = $script:FixtureAsset[$Backend]; RocmRelease = '10.0.0'
            Sha256 = (Get-FileHash -LiteralPath $fixtureZip).Hash; LicenseSha256 = (Get-FileHash -LiteralPath $fixtureLicense).Hash
            InstallDir = (Join-Path $Root 'out') }
        foreach ($k in $Override.Keys) { $pins[$k] = $Override[$k] }
        $failure = $null
        try { Install-LlamaCpp @pins 6>$null } catch { $failure = $_.Exception.Message }
        return [pscustomobject]@{ Error = $failure; Downloads = $fixtureDownloads.ToArray(); Pins = $pins; EnvAsked = $fixtureEnvAsked.ToArray() }
    }

    It 'downloads each zip and the tag''s LICENSE against their pins, ships both, and grades clean' {
        foreach ($c in @(@{ B = 'hip'; Asset = 'llama-b11115-bin-win-rocm-10.0-x64.zip' }, @{ B = 'vulkan'; Asset = 'llama-b11115-bin-win-vulkan-x64.zip' })) {
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
                Assert-True (Test-Path -LiteralPath (Join-Path $r.Pins.InstallDir $spec.Manifest)) "$($c.B): the check's manifest name"
                Assert-Equal 0 @(Get-LlamaCppManifestFinding -Dir $r.Pins.InstallDir -Build '11115' -ManifestName $spec.Manifest -Required $spec.Required).Count "$($c.B): graded clean"
            }
        }
    }

    It 'reads the build and LICENSE pins from the HIP keys for both backends (one build pin), HIP''s keys unchanged' {
        foreach ($c in @(@{ B = 'hip'; Keys = 'LLAMA_CPP_HIP_BUILD,LLAMA_CPP_HIP_ASSET,LLAMA_CPP_HIP_SHA256,LLAMA_CPP_HIP_LICENSE_SHA256,ROCM_WINDOWS_RELEASE' },
                @{ B = 'vulkan'; Keys = 'LLAMA_CPP_HIP_BUILD,LLAMA_CPP_VULKAN_SHA256,LLAMA_CPP_HIP_LICENSE_SHA256,ROCM_WINDOWS_RELEASE' })) {
            Invoke-InTestDir { param($dir)
                Assert-Equal $c.Keys ((Invoke-LlamaInstallFixture -Root $dir -Backend $c.B).EnvAsked -join ',') "$($c.B) pin keys"
            }
        }
    }

    It 'refuses before any download: cpu and nvidia lanes (both backends), a malformed pin, a build mismatch' {
        foreach ($c in @(
                @{ B = 'hip'; Gpu = 'cpu'; Override = @{}; P = "rocm lane only.*'cpu'" },
                @{ B = 'hip'; Gpu = 'nvidia'; Override = @{}; P = "rocm lane only.*'nvidia'" },
                @{ B = 'vulkan'; Gpu = 'cpu'; Override = @{}; P = "rocm lane only.*'cpu'" },
                @{ B = 'vulkan'; Gpu = 'nvidia'; Override = @{}; P = "rocm lane only.*'nvidia'" },
                @{ B = 'hip'; Gpu = 'rocm'; Override = @{ Sha256 = 'abc' }; P = "LLAMA_CPP_HIP_SHA256 must be a 64-hex SHA256.*got 'abc'" },
                @{ B = 'hip'; Gpu = 'rocm'; Override = @{ LicenseSha256 = '' }; P = "LLAMA_CPP_HIP_LICENSE_SHA256 must be a 64-hex SHA256.*got ''" },
                @{ B = 'hip'; Gpu = 'rocm'; Override = @{ Asset = 'llama-b11114-bin-win-rocm-10.0-x64.zip' }; P = 'names build 11114' },
                @{ B = 'vulkan'; Gpu = 'rocm'; Override = @{ Sha256 = '' }; P = "LLAMA_CPP_VULKAN_SHA256 must be a 64-hex SHA256.*got ''" },
                @{ B = 'vulkan'; Gpu = 'rocm'; Override = @{ Build = 'b11115' }; P = 'LLAMA_CPP_HIP_BUILD must be a build number' })) {
            Invoke-InTestDir { param($dir)
                $r = Invoke-LlamaInstallFixture -Root $dir -Backend $c.B -GpuType $c.Gpu -Override $c.Override
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
        foreach ($c in @(@{ B = 'hip'; Extra = 'hipblas.dll'; P = "shadow ROCm's own hipblas\.dll" }, @{ B = 'vulkan'; Extra = 'vulkan-1.dll'; P = 'carries vulkan-1\.dll' })) {
            Invoke-InTestDir { param($dir)
                $r = Invoke-LlamaInstallFixture -Root $dir -Backend $c.B -ZipEntry ($script:ZipMinimal[$c.B] + $c.Extra)
                Assert-Match $c.P "$($r.Error)" "$($c.B) $($c.Extra)"
                Assert-False (Test-Path -LiteralPath $r.Pins.InstallDir) 'nothing extracted'
            }
        }
    }
}

Describe 'Install-LlamaCpp + LlamaCpp check: the manifest proves the shipped bytes and licence' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Write-LlamaCppManifest')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppCheckSpec', 'Get-LlamaCppManifestFinding')
    $hipSpec = Get-LlamaCppCheckSpec -Backend hip
    function New-LlamaManifestFixture {
        param([string]$Dir, [string[]]$File = @('ggml-hip.dll', 'llama-server.exe', 'amdhip64_7.dll', 'licenses\llama.cpp\LICENSE'), [hashtable]$Spec = $hipSpec)
        foreach ($f in $File) { New-Item -ItemType File -Force -Path (Join-Path $Dir $f) -Value "bytes of $f" | Out-Null }
        [void](Write-LlamaCppManifest -Dir $Dir -Name $Spec.Manifest -Build '11115' -Asset 'llama-b11115-bin-win-rocm-10.0-x64.zip' -Sha256 ('A' * 64))
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
            Set-Content -NoNewline -LiteralPath (Join-Path $dir 'amdhip64_7.dll') -Value 'bytes of amdhip64_7.dlX'
            Set-Content -NoNewline -LiteralPath (Join-Path $dir 'licenses\llama.cpp\LICENSE') -Value 'bytes of licenses\llama.cpp\LICENSX'
            Remove-Item -LiteralPath (Join-Path $dir 'llama-server.exe')
            Set-Content -LiteralPath (Join-Path $dir 'hipblas.dll') -Value 'x'
            $got = @(Get-Graded -Dir $dir -Build '11116') -join "`n"
            Assert-Match "records build '11115', LLAMA_CPP_HIP_BUILD is '11116'" $got 'build'
            Assert-Match 'amdhip64_7\.dll differs from the pinned bytes' $got 'changed'
            Assert-Match 'licenses\\llama\.cpp\\LICENSE differs from the pinned bytes' $got 'changed licence'
            Assert-Match 'llama-server\.exe is missing' $got 'missing'
            Assert-Match 'hipblas\.dll did not come from the pinned zip' $got 'foreign'
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

    It 'requires the licence and the backend DLL in each backend''s own manifest' {
        Invoke-InTestDir { param($dir)
            New-LlamaManifestFixture -Dir $dir -File 'ggml-hip.dll', 'llama-server.exe'
            Assert-Match 'the manifest lists no licenses\\llama\.cpp\\LICENSE' (@(Get-Graded -Dir $dir) -join ' ') 'no licence'
        }
        Invoke-InTestDir { param($dir)
            $vk = Get-LlamaCppCheckSpec -Backend vulkan
            New-LlamaManifestFixture -Dir $dir -File 'ggml-hip.dll', 'llama-server.exe', 'licenses\llama.cpp\LICENSE' -Spec $vk
            $got = @(Get-Graded -Dir $dir -Spec $vk) -join ' '
            Assert-Match 'the manifest lists no ggml-vulkan\.dll' $got 'a HIP tree is not a Vulkan tree'
            Assert-False ($got -match 'did not come from') 'the Vulkan manifest is not taken for a foreign file'
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

    It 'reads the gfx targets of an offload bundle header, as upstream''s ggml-hip.dll carries them' {
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
            Assert-Null (Get-LlamaCppHipTargetFinding -Target @('gfx1100', 'gfx1200', 'gfx1201') -RocblasLibraryDir $dir) 'covered'
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
        param([string]$Root, [string]$GgmlHip = 'kernel32.dll', [string]$RocmName = 'ntdll.dll', [string]$RocmFrom, [string]$OtherFrom)
        $f = @{ Llama = (Join-Path $Root 'llama'); Rocm = (Join-Path $Root 'rocm'); Other = (Join-Path $Root 'other'); Sys = $sys }
        foreach ($d in $f.Llama, $f.Rocm, $f.Other) { New-Item -ItemType Directory -Path $d | Out-Null }
        Copy-Item (Join-Path $sys $GgmlHip) (Join-Path $f.Llama 'ggml-hip.dll')
        if ($RocmFrom) { Copy-Item (Join-Path $sys $RocmFrom) (Join-Path $f.Rocm $RocmName) }
        if ($OtherFrom) { Copy-Item (Join-Path $sys $OtherFrom) (Join-Path $f.Other 'ntdll.dll') }
        return $f
    }

    It 'grades each import: resolved, exported, and loaded from where it belongs or a byte-identical copy' {
        $cases = @(
            @{ Name = 'clean'; Rocm = 'ntdll.dll'; Search = 'Llama', 'Rocm', 'Sys'; P = '' },
            @{ Name = 'ABI mismatch'; Rocm = 'version.dll'; Search = 'Llama', 'Rocm', 'Sys'; P = 'ggml-hip\.dll needs \d+ name\(s\) \S+\\rocm\\ntdll\.dll does not export: \w+' },
            @{ Name = 'unresolved'; Rocm = ''; Search = 'Llama', 'Rocm'; P = 'imports ntdll\.dll, which nothing on the loader path provides' },
            @{ Name = 'loaded from elsewhere'; Rocm = 'ntdll.dll'; Other = 'version.dll'; Search = 'Llama', 'Other', 'Rocm', 'Sys'; P = 'loads ntdll\.dll from .*other\\ntdll\.dll, not .*rocm\\ntdll\.dll' },
            @{ Name = 'byte-identical copy elsewhere'; Rocm = 'ntdll.dll'; Other = 'ntdll.dll'; Search = 'Llama', 'Other', 'Rocm', 'Sys'; P = '' },
            @{ Name = 'HIP runtime from ROCm, not the llama dir'; Rocm = 'ntdll.dll'; Search = 'Llama', 'Rocm', 'Sys'; Runtime = '^ntdll\.dll$'
                P = 'loads ntdll\.dll from .*rocm\\ntdll\.dll, not .*llama\\ntdll\.dll' },
            # msvcrt plays ggml-hip.dll: its KERNELBASE import lands in ROCm's bin, whose own ntdll import resolves nowhere.
            @{ Name = 'a ROCm DLL''s own imports are walked too'; GgmlHip = 'msvcrt.dll'; RocmName = 'KERNELBASE.dll'; Rocm = 'kernelbase.dll'
                Search = 'Llama', 'Rocm'; P = 'KERNELBASE\.dll imports ntdll\.dll, which nothing on the loader path provides' })
        foreach ($c in $cases) {
            Invoke-InTestDir { param($dir)
                $shape = @{ GgmlHip = $(if ($c['GgmlHip']) { $c['GgmlHip'] } else { 'kernel32.dll' }); RocmName = $(if ($c['RocmName']) { $c['RocmName'] } else { 'ntdll.dll' }) }
                $f = New-LinkFixture -Root $dir -RocmFrom $c['Rocm'] -OtherFrom $c['Other'] @shape
                $runtime = if ($c['Runtime']) { @{ RuntimePattern = $c['Runtime'] } } else { @{} }
                $got = @(Get-LlamaCppHipLinkFinding -Dir $f.Llama -RocmBin $f.Rocm -SearchDir @($c.Search | ForEach-Object { $f[$_] }) @runtime)
                if ($c.P) { Assert-Match $c.P ($got -join ' ') $c.Name } else { Assert-Equal '' ($got -join ' | ') $c.Name }
            }
        }
    }
}

Describe 'LlamaCpp check: HIP runtime identity and the PATH rule' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-HipRuntimeIdentityFinding', 'Get-LlamaCppPathFinding')
    function New-IdentityFixture {
        param([string]$Root, [string]$LlamaHip = 'hip runtime bytes')
        $llama = Join-Path $Root 'llama'; $rocm = Join-Path $Root 'rocm'
        foreach ($d in $llama, $rocm) { New-Item -ItemType Directory -Path $d | Out-Null }
        Set-Content -LiteralPath (Join-Path $rocm 'amdhip64_7.dll') -Value 'hip runtime bytes'
        Set-Content -LiteralPath (Join-Path $rocm 'hipblas.dll') -Value 'blas'
        Set-Content -LiteralPath (Join-Path $llama 'amdhip64_7.dll') -Value $LlamaHip
        Set-Content -LiteralPath (Join-Path $llama 'ggml.dll') -Value 'ggml'
        return @{ Llama = $llama; Rocm = $rocm }
    }

    It 'passes when the bundled HIP runtime is byte-identical to ROCm''s' {
        Invoke-InTestDir { param($dir)
            $f = New-IdentityFixture -Root $dir
            Assert-Equal 0 @(Get-HipRuntimeIdentityFinding -Dir $f.Llama -RocmBin $f.Rocm).Count 'identical'
        }
    }

    It 'reports a different HIP runtime, a shadowed ROCm library, and a missing runtime' {
        Invoke-InTestDir { param($dir)
            $f = New-IdentityFixture -Root $dir -LlamaHip 'another HIP build'
            Set-Content -LiteralPath (Join-Path $f.Llama 'hipblas.dll') -Value 'blas'
            $got = @(Get-HipRuntimeIdentityFinding -Dir $f.Llama -RocmBin $f.Rocm) -join "`n"
            Assert-Match "amdhip64_7\.dll next to llama-server is not ROCm's" $got 'different runtime'
            Assert-Match "hipblas\.dll next to llama-server shadows ROCm's own copy" $got 'shadow'
            Remove-Item -LiteralPath (Join-Path $f.Llama 'amdhip64_7.dll')
            Assert-Match 'no HIP runtime DLL next to llama-server' (@(Get-HipRuntimeIdentityFinding -Dir $f.Llama -RocmBin $f.Rocm) -join ' ') 'missing'
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

Describe 'LlamaCpp check: llama-server --version' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Invoke-LlamaCppProcess', 'Get-LlamaServerVersionFinding')
    function New-VersionStub {
        param([string]$Dir, [string]$Body)
        $p = Join-Path $Dir 'llama-server.cmd'
        Set-Content -LiteralPath $p -Value "@echo off`r`n$Body" -Encoding ASCII
        return $p
    }

    It 'passes when the binary reports the pinned build and exits 0' {
        Invoke-InTestDir { param($dir)
            $exe = New-VersionStub -Dir $dir -Body "echo version: 0.4.1-dev (build 11115, commit d5f66492e) 1>&2`r`nexit /b 0"
            Assert-Null (Get-LlamaServerVersionFinding -Exe $exe -Build '11115' 6>$null) 'pinned build'
        }
    }

    It 'reports another build, a non-zero exit, a hang and a missing binary' {
        Invoke-InTestDir { param($dir)
            $exe = New-VersionStub -Dir $dir -Body "echo version: 0.4.1-dev (build 11115, commit d5f66492e)`r`nexit /b 0"
            Assert-Match 'does not report build 11116' (Get-LlamaServerVersionFinding -Exe $exe -Build '11116' 6>$null) 'other build'
            $exe = New-VersionStub -Dir $dir -Body 'exit /b 3'
            Assert-Match 'exited 3 \(0x00000003\)' (Get-LlamaServerVersionFinding -Exe $exe -Build '11115' 6>$null) 'exit code'
            $exe = New-VersionStub -Dir $dir -Body 'ping -n 30 127.0.0.1 > nul'
            Assert-Match 'did not exit within 1 s' (Get-LlamaServerVersionFinding -Exe $exe -Build '11115' -TimeoutSeconds 1) 'hang'
            Assert-Match 'is missing' (Get-LlamaServerVersionFinding -Exe (Join-Path $dir 'nope.exe') -Build '11115') 'missing'
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

Describe 'LlamaCpp check: grading the ggml-vulkan load probe' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppVulkanProbeFinding')
    $script:VkDir = 'C:\runtime\opt\llama.cpp-vulkan'
    $script:VkLoader = 'C:\vulkan-loader\vulkan-1.dll'
    function Get-ProbeText {
        param([string]$Base = "$script:VkDir\ggml-base.dll", [string]$Vk = 'C:\VULKAN-LOADER\vulkan-1.dll', [string]$Answer = '0,4211045')
        return "module ggml-base.dll=$Base`r`nmodule vulkan-1.dll=$Vk`r`nvkEnumerateInstanceVersion=$Answer"
    }

    It 'passes the report of a clean load (API 1.4.357; the loader path in another case)' {
        Assert-Equal '' (@(Get-LlamaCppVulkanProbeFinding -Text (Get-ProbeText) -Dir $script:VkDir -Loader $script:VkLoader 6>$null) -join ' | ') 'clean'
        Assert-Equal '' (@(Get-LlamaCppVulkanProbeFinding -Text (Get-ProbeText -Answer '0,4202496') -Dir $script:VkDir -Loader $script:VkLoader 6>$null) -join ' | ') 'exactly 1.2.0 is enough'
    }

    It 'reports ggml-base or vulkan-1 from elsewhere, a failed or old loader, and a missing answer' {
        $cases = @(
            @{ T = (Get-ProbeText -Base 'C:\runtime\opt\llama.cpp-hip\ggml-base.dll'); P = "took ggml-base\.dll from 'C:\\runtime\\opt\\llama\.cpp-hip" },
            @{ T = (Get-ProbeText -Vk 'D:\elsewhere\vulkan-1.dll'); P = "took vulkan-1\.dll from 'D:\\elsewhere\\vulkan-1\.dll', not the C:\\vulkan-loader" },
            @{ T = (Get-ProbeText -Answer '-9,0'); P = 'vkEnumerateInstanceVersion returned VkResult -9' },
            @{ T = (Get-ProbeText -Answer '0,4198400'); P = 'reports API 1\.1\.0; ggml-vulkan registers no device below 1\.2' },
            @{ T = 'module ggml-base.dll='; P = "took ggml-base\.dll from ''.*no vkEnumerateInstanceVersion result" })
        foreach ($c in $cases) {
            Assert-Match $c.P (@(Get-LlamaCppVulkanProbeFinding -Text $c.T -Dir $script:VkDir -Loader $script:VkLoader 6>$null) -join ' | ') $c.P
        }
    }
}

Describe 'LlamaCpp check: the ggml-vulkan load probe runs in a child pwsh' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Invoke-LlamaCppProcess', 'Get-LlamaCppVulkanProbeScript',
        'Get-LlamaCppVulkanProbeFinding', 'Get-LlamaCppVulkanLoadFinding')

    It 'reports a DLL that loads but is no ggml backend, and one that is not there' {
        Invoke-InTestDir { param($dir)
            Copy-Item (Join-Path $env:SystemRoot 'System32\version.dll') (Join-Path $dir 'ggml-vulkan.dll')
            Assert-Match 'ggml-vulkan\.dll does not load from .*ggml_backend_init' (Get-LlamaCppVulkanLoadFinding -Dir $dir -Loader 'C:\x\vulkan-1.dll') 'no entry'
            Assert-Match 'ggml-vulkan\.dll does not load from ' (Get-LlamaCppVulkanLoadFinding -Dir (Join-Path $dir 'none') -Loader 'C:\x\vulkan-1.dll') 'missing'
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
        param([string]$Backend, [hashtable]$Env, [string[]]$Want, [string]$Other)
        Invoke-WithEnv ($Env + @{ LLAMA_CPP_HIP_BUILD = '11115' }) {
            $got = @(& $check -Backend $Backend 6>$null) -join "`n"
            foreach ($w in $Want) { Assert-Match $w $got $w }
            Assert-False ($got -match $Other) "-Backend $Backend grades nothing of the other build"
        }
    }

    It 'wires every HIP check: manifest, PATH, HIP runtime identity, import walk, offload bundle, --version' {
        Invoke-InTestDir { param($dir)
            $llama = Join-Path $dir 'llama'; $rocm = Join-Path $dir 'rocm'
            New-Item -ItemType Directory -Path $llama, (Join-Path $rocm 'bin') | Out-Null
            $sys = Join-Path $env:SystemRoot 'System32'
            # kernel32 plays ggml-hip.dll; its ntdll import resolves in System32, not to ROCm's (a version.dll copy).
            Copy-Item (Join-Path $sys 'kernel32.dll') (Join-Path $llama 'ggml-hip.dll')
            Copy-Item (Join-Path $sys 'version.dll') (Join-Path $rocm 'bin\ntdll.dll')
            Set-Content -LiteralPath (Join-Path $rocm 'bin\amdhip64_7.dll') -Value 'ROCm HIP runtime'
            Set-Content -LiteralPath (Join-Path $llama 'amdhip64_7.dll') -Value 'another HIP runtime'
            Assert-CheckWiring -Backend hip -Env @{ LLAMA_CPP_HIP_HOME = $llama; HIP_PATH = $rocm; ROCM_PATH = $null; PATH = "$llama;$env:PATH" } -Other 'vulkan' -Want @(
                'no manifest at .*llama-cpp-hip-manifest', 'is on PATH: its HIP runtime', "amdhip64_7\.dll next to llama-server is not ROCm's",
                'ggml-hip\.dll loads ntdll\.dll from .*System32\\ntdll\.dll, not ', 'offload bundle is unreadable: .*no \.hip_fat section', 'llama-server\.exe is missing')
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
            Assert-Equal $install.Required[0] $check.Required[0] "$b backend DLL"
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

    It 'mounts a closed module set: what either script imports, and what every mounted module imports' {
        # Closed under imports, so it holds the transitive closure without walking it.
        $mounted = @([regex]::Matches($code, 'source=windows/scripts/modules/([\w.]+)\.psm1,target=C:\\bkmnt\\modules\\\1\.psm1') | ForEach-Object { $_.Groups[1].Value })
        $needed = @{}
        foreach ($s in $script:LlamaInstall, $script:LlamaCheck) {
            foreach ($m in [regex]::Matches((Get-Content -Raw (Join-Path $root $s)), 'modules\\([\w.]+)\.psm1')) { $needed[$m.Groups[1].Value] = $s }
        }
        foreach ($m in $mounted) {
            foreach ($sib in [regex]::Matches((Get-Content -Raw (Join-Path $root "windows\scripts\modules\$m.psm1")), "PSScriptRoot\s+'([\w.]+)\.psm1'")) { $needed[$sib.Groups[1].Value] = "$m.psm1" }
        }
        Assert-True ($needed.Count -ge 2) "the scan found $($needed.Count) needed module(s)"
        foreach ($m in $needed.Keys) { Assert-True ($mounted -contains $m) "$m (imported by $($needed[$m])) is not mounted at C:\bkmnt\modules" }
        Assert-Equal 2 @([regex]::Matches($code, 'source=windows/scripts/modules/WindowsSourceBuild\.Cuda\.psm1')).Count 'both RUNs mount the closure'
    }

    It 'installs and checks each backend in its own RUN, failing the stage on any finding' {
        $runs = @([regex]::Matches($code, '(?s)RUN --mount.*?throw \(.*?\)\s*\}') | ForEach-Object { $_.Value })
        Assert-Equal 2 $runs.Count 'two RUNs'
        Assert-Match "(?s)Install-LlamaCpp\.ps1' -Backend hip .*-InstallDir \`$env:LLAMA_CPP_HIP_HOME.*@\(& 'C:\\bkmnt\\LlamaCpp\.ps1' -Backend hip\).*throw" $runs[0] 'HIP armed'
        Assert-Match "(?s)Install-LlamaCpp\.ps1' -Backend vulkan .*-InstallDir \`$env:LLAMA_CPP_VULKAN_HOME.*@\(& 'C:\\bkmnt\\LlamaCpp\.ps1' -Backend vulkan\).*throw" $runs[1] 'Vulkan armed'
    }

    It 'declares the Vulkan pin after the HIP RUN, so bumping it keeps the HIP layer cached' {
        Assert-Match '(?s)-Backend hip -TempDir.*\nARG LLAMA_CPP_VULKAN_SHA256=' $code 'ARG LLAMA_CPP_VULKAN_SHA256 follows the HIP RUN'
        Assert-False ($code -match '(?s)ARG LLAMA_CPP_VULKAN_SHA256=.*-Backend hip -TempDir') 'and never precedes it'
    }
}

Describe 'Build-Buildkit.ps1: the Vulkan pin reaches the llama stage only' {
    $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1')

    It 'sends LLAMA_CPP_VULKAN_SHA256 in $llamaArgs and nowhere else (cpu and nvidia never solve that stage)' {
        $block = [regex]::Match($src, "(?s)\`$llamaArgs = @\{(.+?\r?\n\s*\})").Groups[1].Value
        Assert-Match "LLAMA_CPP_VULKAN_SHA256\s*= Get-Ver 'LLAMA_CPP_VULKAN_SHA256'" $block 'in the llama block'
        Assert-Equal ([regex]::Matches($block, 'LLAMA_CPP_VULKAN')).Count ([regex]::Matches($src, 'LLAMA_CPP_VULKAN')).Count 'every mention sits in that block'
        Assert-Match "(?s)if \(\`$Stages -contains 'llama'\) \{\s+#[^\n]*\n\s+\`$llamaArgs = @\{" $src 'only inside the llama stage'
    }
}
