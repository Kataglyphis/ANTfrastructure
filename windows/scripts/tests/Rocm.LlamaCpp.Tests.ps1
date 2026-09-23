#requires -Version 7.0
# llama.cpp HIP on the rocm lane (Install-LlamaCppHip.ps1, rocm-checks\LlamaCpp.ps1,
# Dockerfile.rocm-llama): lane gate, pins, the install body with its downloads stubbed, zip layout,
# licence, manifest, PE walk, offload targets, HIP runtime identity, PATH rule, --version, check wiring.
# NOT covered: the real download and Invoke-DownloadWithRetry, a real ggml-hip.dll, the driver wiring.

$script:LlamaInstall = 'windows\scripts\build\Install-LlamaCppHip.ps1'
$script:LlamaCheck = 'windows\scripts\build\rocm-checks\LlamaCpp.ps1'
$script:LlamaPinKeys = 'LLAMA_CPP_HIP_BUILD', 'LLAMA_CPP_HIP_ASSET', 'LLAMA_CPP_HIP_SHA256', 'LLAMA_CPP_HIP_LICENSE_SHA256'

Describe 'Install-LlamaCppHip: lane gate (rocm only; cpu and nvidia refused)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Assert-LlamaCppHipLane')

    It 'refuses the cpu and nvidia lanes (neither image can ever carry it) and a ROCm tree without hipBLAS/rocBLAS' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType File -Force -Path (Join-Path $dir 'bin\amdhip64_7.dll') -Value 'x' | Out-Null
            $rocm = @{ GpuType = 'rocm'; HasRocm = $true; RocmRoot = $dir }
            foreach ($c in @(@{ Gpu = @{ GpuType = 'cpu'; HasRocm = $false; RocmRoot = $null }; P = "rocm lane only.*'cpu'" },
                    @{ Gpu = @{ GpuType = 'nvidia'; HasRocm = $false; RocmRoot = $null }; P = "rocm lane only.*'nvidia'" },
                    @{ Gpu = $rocm; P = 'lacks bin\\hipblas\.dll, bin\\rocblas\.dll' })) {
                Assert-Throws { Assert-LlamaCppHipLane -GpuEnvironment $c.Gpu } $c.P -MessagePattern $c.P
            }
            foreach ($f in 'hipblas.dll', 'rocblas.dll') { New-Item -ItemType File -Path (Join-Path $dir "bin\$f") -Value 'x' | Out-Null }
            Assert-Equal (Join-Path $dir 'bin') (Assert-LlamaCppHipLane -GpuEnvironment $rocm) 'a complete ROCm tree is accepted, and its bin returned'
        }
    }
}

Describe 'Install-LlamaCppHip: pin parity (build, asset and ROCm release agree)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Get-LlamaCppHipAssetUrl')
    $pins = ConvertFrom-VersionsEnv -Path (Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env')

    It 'accepts the versions.env pins as they stand (a one-key bump fails HERE, not in the build)' {
        $url = Get-LlamaCppHipAssetUrl -Build $pins['LLAMA_CPP_HIP_BUILD'] -Asset $pins['LLAMA_CPP_HIP_ASSET'] -RocmRelease $pins['ROCM_WINDOWS_RELEASE']
        Assert-Equal ('https://github.com/ggml-org/llama.cpp/releases/download/b{0}/{1}' -f $pins['LLAMA_CPP_HIP_BUILD'], $pins['LLAMA_CPP_HIP_ASSET']) $url 'url'
        foreach ($key in 'LLAMA_CPP_HIP_SHA256', 'LLAMA_CPP_HIP_LICENSE_SHA256') { Assert-Match '^[0-9a-f]{64}$' $pins[$key] "$key is 64 lower-case hex" }
    }

    It 'refuses a malformed build or asset, a build mismatch and a ROCm mismatch' {
        $cases = @(
            @{ B = 'b11115'; A = 'llama-b11115-bin-win-rocm-10.0-x64.zip'; R = '10.0.0'; P = 'LLAMA_CPP_HIP_BUILD must be' },
            @{ B = '11115'; A = 'llama-b11115-bin-win-cuda-12.4-x64.zip'; R = '10.0.0'; P = 'is not a llama-b<N>' },
            @{ B = '11115'; A = 'llama-b11114-bin-win-rocm-10.0-x64.zip'; R = '10.0.0'; P = 'names build 11114' },
            @{ B = '11115'; A = 'llama-b11115-bin-win-rocm-7.14-x64.zip'; R = '10.0.0'; P = 'built for ROCm 7\.14 but the image carries ROCm 10\.0\.0' },
            @{ B = '11115'; A = 'llama-b11115-bin-win-rocm-10.0-x64.zip'; R = '10.0'; P = 'ROCM_WINDOWS_RELEASE must be' }
        )
        foreach ($c in $cases) {
            Assert-Throws { Get-LlamaCppHipAssetUrl -Build $c.B -Asset $c.A -RocmRelease $c.R } "$($c.B) $($c.A) $($c.R)" -MessagePattern $c.P
        }
    }

    It 'keeps Dockerfile.rocm-llama''s ARG defaults equal to versions.env' {
        $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.rocm-llama')
        foreach ($key in $script:LlamaPinKeys) {
            Assert-Equal $pins[$key] ([regex]::Match($df, "(?m)^ARG $key=(\S+)$").Groups[1].Value) "ARG $key"
        }
    }
}

Describe 'Install-LlamaCppHip: zip layout' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Assert-LlamaCppHipZipEntry')
    # The b11115 zip as upstream ships it (flat), and TheRock 10.0.0's bin DLLs.
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
    $script:RocmBin1000 = @('MIOpen.dll', 'MIOpenCKGroupedConv_gfx1200.dll', 'MIOpenCKGroupedConv_gfx1201.dll', 'OpenCL.dll', 'amd_comgr.dll',
        'amdhip64_7.dll', 'amdocl64.dll', 'cltrace.dll', 'hipblas.dll', 'hipdnn_backend.dll', 'hipfft.dll', 'hipfftw.dll',
        'hiprand.dll', 'hiprtc-builtins0715.dll', 'hiprtc0715.dll', 'hipsolver.dll', 'hipsparse.dll', 'hiptensor.dll',
        'libhipblaslt.dll', 'origami.dll', 'rocalution.dll', 'rocblas.dll', 'rocfft.dll', 'rocm-openblas.dll',
        'rocm-openblas64.dll', 'rocm_kpack.dll', 'rocrand.dll', 'rocsolver.dll', 'rocsparse.dll')

    It 'accepts the b11115 zip: its only ROCm names are the three HIP runtime DLLs' {
        Assert-Equal 55 $script:ZipB11115.Count 'the whole b11115 listing'
        Assert-Equal 29 $script:RocmBin1000.Count 'every bin\*.dll of the 10.0.0 gfx120X-all tarball'
        Assert-LlamaCppHipZipEntry -EntryName $script:ZipB11115 -RocmBinDllName $script:RocmBin1000
        Assert-True $true 'accepted'
    }

    It 'refuses a zip that lacks any load-bearing file, naming it' {
        foreach ($r in 'ggml-hip.dll', 'llama-server.exe', 'amdhip64_7.dll', 'rocm_kpack.dll', 'ggml-base.dll') {
            $entries = @($script:ZipB11115 | Where-Object { $_ -ne $r })
            Assert-Throws { Assert-LlamaCppHipZipEntry -EntryName $entries -RocmBinDllName $script:RocmBin1000 } "missing $r" -MessagePattern ('missing ' + [regex]::Escape($r))
        }
    }

    It 'refuses a zip that would shadow ROCm''s hipBLAS/rocBLAS, or is no longer flat' {
        Assert-Throws { Assert-LlamaCppHipZipEntry -EntryName ($script:ZipB11115 + 'hipblas.dll' + 'rocblas.dll') -RocmBinDllName $script:RocmBin1000 } 'shadow' -MessagePattern "shadow ROCm's own hipblas\.dll, rocblas\.dll"
        Assert-Throws { Assert-LlamaCppHipZipEntry -EntryName ($script:ZipB11115 + 'llama-b11115/ggml.dll') -RocmBinDllName $script:RocmBin1000 } 'nested' -MessagePattern 'not flat'
    }
}

Describe 'Install-LlamaCppHip: the script body, with the module functions stood in for' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Assert-LlamaCppHipLane', 'Get-LlamaCppHipAssetUrl',
        'Assert-LlamaCppHipZipEntry', 'Write-LlamaCppHipManifest', 'Install-LlamaCppHip')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppHipManifestFinding')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $script:ZipMinimal = @('ggml-hip.dll', 'ggml-base.dll', 'ggml.dll', 'llama.dll', 'llama-server.exe', 'amdhip64_7.dll',
        'amd_comgr.dll', 'rocm_kpack.dll', 'LICENSE-LLVM-OpenMP')
    # Runs Install-LlamaCppHip over a fixture zip and LICENSE; the stand-ins below shadow the module functions by scope.
    function Invoke-LlamaInstallFixture {
        param([string]$Root, [string]$GpuType = 'rocm', [string[]]$ZipEntry = $script:ZipMinimal, [hashtable]$Override = @{})
        $fixtureRocm = Join-Path $Root 'rocm'
        New-Item -ItemType Directory -Path (Join-Path $fixtureRocm 'bin'), (Join-Path $Root 'zip') | Out-Null
        foreach ($f in 'amdhip64_7.dll', 'amd_comgr.dll', 'rocm_kpack.dll', 'hipblas.dll', 'rocblas.dll') { Set-Content -LiteralPath (Join-Path $fixtureRocm "bin\$f") -Value $f }
        foreach ($f in $ZipEntry) { Set-Content -LiteralPath (Join-Path $Root "zip\$f") -Value "bytes of $f" }
        $fixtureZip = Join-Path $Root 'fixture.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $Root 'zip'), $fixtureZip)
        $fixtureLicense = Join-Path $Root 'LICENSE'
        Set-Content -LiteralPath $fixtureLicense -Value 'MIT License'
        $fixtureDownloads = [System.Collections.Generic.List[object]]::new()
        function Get-GpuEnvironment { @{ GpuType = $GpuType; HasRocm = ($GpuType -eq 'rocm'); RocmRoot = $fixtureRocm } }
        function Resolve-ContainerImageValue { param([AllowEmptyString()][string]$Value, [string]$EnvironmentVariable) $Value }
        function Initialize-ContainerImageTempDirectory { param([string]$TempDir) (New-Item -ItemType Directory -Force -Path $TempDir).FullName }
        function Clear-PendingFileHandle { }
        function Invoke-DownloadWithRetry {
            param([string]$Url, [string]$DestinationPath, [string]$Description, [string]$ExpectSignature = '', [string]$ExpectedSha256 = '')
            $fixtureDownloads.Add([pscustomobject]@{ Url = $Url; ExpectSignature = $ExpectSignature; ExpectedSha256 = $ExpectedSha256 })
            Copy-Item -LiteralPath $(if ($Url -like '*.zip') { $fixtureZip } else { $fixtureLicense }) -Destination $DestinationPath
        }
        $pins = @{ TempDir = (Join-Path $Root 'tmp'); Build = '11115'; Asset = 'llama-b11115-bin-win-rocm-10.0-x64.zip'; RocmRelease = '10.0.0'
            Sha256 = (Get-FileHash -LiteralPath $fixtureZip).Hash; LicenseSha256 = (Get-FileHash -LiteralPath $fixtureLicense).Hash
            InstallDir = (Join-Path $Root 'out') }
        foreach ($k in $Override.Keys) { $pins[$k] = $Override[$k] }
        $failure = $null
        try { Install-LlamaCppHip @pins 6>$null } catch { $failure = $_.Exception.Message }
        return [pscustomobject]@{ Error = $failure; Downloads = $fixtureDownloads.ToArray(); Pins = $pins }
    }

    It 'downloads the zip and the tag''s LICENSE against their pins, ships both, and grades clean' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-LlamaInstallFixture -Root $dir
            Assert-Null $r.Error 'installs'
            Assert-Equal 2 $r.Downloads.Count 'two downloads'
            Assert-Equal 'https://github.com/ggml-org/llama.cpp/releases/download/b11115/llama-b11115-bin-win-rocm-10.0-x64.zip' $r.Downloads[0].Url 'zip url'
            Assert-Equal $r.Pins.Sha256 $r.Downloads[0].ExpectedSha256 'the zip is verified against LLAMA_CPP_HIP_SHA256'
            Assert-Equal 'PK' $r.Downloads[0].ExpectSignature 'the zip signature'
            Assert-Equal 'https://raw.githubusercontent.com/ggml-org/llama.cpp/b11115/LICENSE' $r.Downloads[1].Url 'the LICENSE at the pinned tag'
            Assert-Equal $r.Pins.LicenseSha256 $r.Downloads[1].ExpectedSha256 'the LICENSE is verified against LLAMA_CPP_HIP_LICENSE_SHA256'
            Assert-Equal 'MIT License' (Get-Content -Raw (Join-Path $r.Pins.InstallDir 'licenses\llama.cpp\LICENSE')).Trim() 'the LICENSE ships'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $r.Pins.TempDir -File).Count 'nothing left in the temp dir'
            Assert-Equal 0 @(Get-LlamaCppHipManifestFinding -Dir $r.Pins.InstallDir -Build '11115').Count 'the check grades the result clean'
        }
    }

    It 'refuses before any download: cpu and nvidia lanes, a malformed pin, a build mismatch' {
        foreach ($c in @(
                @{ Gpu = 'cpu'; Override = @{}; P = "rocm lane only.*'cpu'" },
                @{ Gpu = 'nvidia'; Override = @{}; P = "rocm lane only.*'nvidia'" },
                @{ Gpu = 'rocm'; Override = @{ Sha256 = 'abc' }; P = "LLAMA_CPP_HIP_SHA256 must be a 64-hex SHA256.*got 'abc'" },
                @{ Gpu = 'rocm'; Override = @{ LicenseSha256 = '' }; P = "LLAMA_CPP_HIP_LICENSE_SHA256 must be a 64-hex SHA256.*got ''" },
                @{ Gpu = 'rocm'; Override = @{ Asset = 'llama-b11114-bin-win-rocm-10.0-x64.zip' }; P = 'names build 11114' })) {
            Invoke-InTestDir { param($dir)
                $r = Invoke-LlamaInstallFixture -Root $dir -GpuType $c.Gpu -Override $c.Override
                Assert-Match $c.P "$($r.Error)" "error for $($c.P)"
                Assert-Equal 0 $r.Downloads.Count "no download for $($c.P)"
                Assert-False (Test-Path -LiteralPath $r.Pins.InstallDir) "nothing installed for $($c.P)"
            }
        }
    }

    It 'refuses a used install dir before downloading, and a zip that would shadow ROCm before extracting' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType File -Force -Path (Join-Path $dir 'out\ggml.dll') -Value 'an older build' | Out-Null
            $r = Invoke-LlamaInstallFixture -Root $dir
            Assert-Match 'already has content; refusing to mix' "$($r.Error)" 'used dir'
            Assert-Equal 0 $r.Downloads.Count 'no download into a used dir'
        }
        Invoke-InTestDir { param($dir)
            $r = Invoke-LlamaInstallFixture -Root $dir -ZipEntry ($script:ZipMinimal + 'hipblas.dll')
            Assert-Match "shadow ROCm's own hipblas\.dll" "$($r.Error)" 'shadow'
            Assert-False (Test-Path -LiteralPath $r.Pins.InstallDir) 'nothing extracted'
        }
    }
}

Describe 'Install-LlamaCppHip + LlamaCpp check: the manifest proves the shipped bytes and licence' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaInstall -FunctionName 'Write-LlamaCppHipManifest')
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaCppHipManifestFinding')
    function New-LlamaManifestFixture {
        param([string]$Dir, [string[]]$File = @('ggml-hip.dll', 'llama-server.exe', 'amdhip64_7.dll', 'licenses\llama.cpp\LICENSE'))
        foreach ($f in $File) { New-Item -ItemType File -Force -Path (Join-Path $Dir $f) -Value "bytes of $f" | Out-Null }
        [void](Write-LlamaCppHipManifest -Dir $Dir -Build '11115' -Asset 'llama-b11115-bin-win-rocm-10.0-x64.zip' -Sha256 ('A' * 64))
    }

    It 'has no finding for the tree the install left' {
        Invoke-InTestDir { param($dir)
            New-LlamaManifestFixture -Dir $dir
            Assert-Equal 0 @(Get-LlamaCppHipManifestFinding -Dir $dir -Build '11115').Count 'clean'
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
            $got = @(Get-LlamaCppHipManifestFinding -Dir $dir -Build '11116') -join "`n"
            Assert-Match "records build '11115', LLAMA_CPP_HIP_BUILD is '11116'" $got 'build'
            Assert-Match 'amdhip64_7\.dll differs from the pinned bytes' $got 'changed'
            Assert-Match 'licenses\\llama\.cpp\\LICENSE differs from the pinned bytes' $got 'changed licence'
            Assert-Match 'llama-server\.exe is missing' $got 'missing'
            Assert-Match 'hipblas\.dll did not come from the pinned zip' $got 'foreign'
            Remove-Item -LiteralPath (Join-Path $dir 'llama-cpp-hip-manifest.json')
            Assert-Match 'no manifest at' (@(Get-LlamaCppHipManifestFinding -Dir $dir -Build '11115') -join ' ') 'no manifest'
        }
    }

    It 'requires the licence in the manifest (MIT: the text ships with the binaries)' {
        Invoke-InTestDir { param($dir)
            New-LlamaManifestFixture -Dir $dir -File 'ggml-hip.dll', 'llama-server.exe'
            Assert-Match 'the manifest lists no licenses\\llama\.cpp\\LICENSE' (@(Get-LlamaCppHipManifestFinding -Dir $dir -Build '11115') -join ' ') 'no licence'
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
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-HipRuntimeIdentityFinding', 'Get-LlamaCppHipPathFinding')
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

    It 'flags the llama directory on PATH in any spelling, and nothing else' {
        $dir = 'C:\runtime\opt\llama.cpp-hip'
        foreach ($p in 'C:\a;C:\runtime\opt\llama.cpp-hip', 'C:\RUNTIME\opt\llama.cpp-hip\;C:\a', 'C:\a;"C:\runtime\opt\llama.cpp-hip"') {
            Assert-Match 'is on PATH' (Get-LlamaCppHipPathFinding -Dir $dir -PathValue $p) $p
        }
        Assert-Null (Get-LlamaCppHipPathFinding -Dir $dir -PathValue 'C:\runtime\bin;C:\runtime\opt\llama.cpp-hip2;C:\TheRock\build\bin') 'siblings are fine'
    }
}

Describe 'LlamaCpp check: llama-server --version' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:LlamaCheck -FunctionName 'Get-LlamaServerVersionFinding')
    function New-VersionStub {
        param([string]$Dir, [string]$Body)
        $p = Join-Path $Dir 'llama-server.cmd'
        Set-Content -LiteralPath $p -Value "@echo off`r`n$Body" -Encoding ASCII
        return $p
    }

    It 'passes when the binary reports the pinned build and exits 0' {
        Invoke-InTestDir { param($dir)
            $exe = New-VersionStub -Dir $dir -Body "echo version: 0.4.1-dev (build 11115, commit d5f66492e) 1>&2`r`nexit /b 0"
            Assert-Null (Get-LlamaServerVersionFinding -Exe $exe -Build '11115') 'pinned build'
        }
    }

    It 'reports another build, a non-zero exit, a hang and a missing binary' {
        Invoke-InTestDir { param($dir)
            $exe = New-VersionStub -Dir $dir -Body "echo version: 0.4.1-dev (build 11115, commit d5f66492e)`r`nexit /b 0"
            Assert-Match 'does not report build 11116' (Get-LlamaServerVersionFinding -Exe $exe -Build '11116') 'other build'
            $exe = New-VersionStub -Dir $dir -Body 'exit /b 3'
            Assert-Match 'exited 3 \(0x00000003\)' (Get-LlamaServerVersionFinding -Exe $exe -Build '11115') 'exit code'
            $exe = New-VersionStub -Dir $dir -Body 'ping -n 30 127.0.0.1 > nul'
            Assert-Match 'did not exit within 1 s' (Get-LlamaServerVersionFinding -Exe $exe -Build '11115' -TimeoutSeconds 1) 'hang'
            Assert-Match 'is missing' (Get-LlamaServerVersionFinding -Exe (Join-Path $dir 'nope.exe') -Build '11115') 'missing'
        }
    }
}

Describe 'LlamaCpp check: the whole script, run as the smoke gate runs it' {
    $check = Join-Path (Get-RepoRoot) $script:LlamaCheck

    It 'reports one finding when the rocm-llama stage never ran' {
        Invoke-WithEnv @{ LLAMA_CPP_HIP_HOME = $null } {
            $got = @(& $check)
            Assert-Equal 1 $got.Count 'one finding'
            Assert-Match 'the rocm-llama stage did not run' $got[0] 'names the stage'
        }
    }

    It 'reports one finding when there is no ROCm tree to link against' {
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ LLAMA_CPP_HIP_HOME = $dir; HIP_PATH = $null; ROCM_PATH = $null } {
                $got = @(& $check)
                Assert-Equal 1 $got.Count 'one finding'
                Assert-Match 'no ROCm bin under HIP_PATH/ROCM_PATH' $got[0] 'names ROCm'
            }
        }
    }

    It 'wires every check: manifest, PATH, HIP runtime identity, import walk, offload bundle, --version' {
        Invoke-InTestDir { param($dir)
            $llama = Join-Path $dir 'llama'; $rocm = Join-Path $dir 'rocm'
            New-Item -ItemType Directory -Path $llama, (Join-Path $rocm 'bin') | Out-Null
            $sys = Join-Path $env:SystemRoot 'System32'
            # kernel32 plays ggml-hip.dll; its ntdll import resolves in System32, not to ROCm's (a version.dll copy).
            Copy-Item (Join-Path $sys 'kernel32.dll') (Join-Path $llama 'ggml-hip.dll')
            Copy-Item (Join-Path $sys 'version.dll') (Join-Path $rocm 'bin\ntdll.dll')
            Set-Content -LiteralPath (Join-Path $rocm 'bin\amdhip64_7.dll') -Value 'ROCm HIP runtime'
            Set-Content -LiteralPath (Join-Path $llama 'amdhip64_7.dll') -Value 'another HIP runtime'
            Invoke-WithEnv @{ LLAMA_CPP_HIP_HOME = $llama; HIP_PATH = $rocm; ROCM_PATH = $null; LLAMA_CPP_HIP_BUILD = '11115'; PATH = "$llama;$env:PATH" } {
                $got = @(& $check) -join "`n"
                foreach ($want in 'no manifest at', 'is on PATH', "amdhip64_7\.dll next to llama-server is not ROCm's",
                    'ggml-hip\.dll loads ntdll\.dll from .*System32\\ntdll\.dll, not ', 'offload bundle is unreadable: .*no \.hip_fat section',
                    'llama-server\.exe is missing') {
                    Assert-Match $want $got $want
                }
            }
        }
    }
}

Describe 'Dockerfile.rocm-llama: rocm-only stage, off PATH, closure mounted, check armed' {
    $root = Get-RepoRoot
    $df = Get-Content -Raw (Join-Path $root 'windows\Dockerfile.rocm-llama')
    $code = ($df -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

    It 'builds a ''built'' target FROM the BASE_IMAGE the driver passes' {
        Assert-Match '(?m)^FROM \$\{BASE_IMAGE\} AS built$' $code 'target built'
    }

    It 'never touches PATH (its HIP runtime must not shadow ROCm''s for other processes)' {
        Assert-False ($code -match '(?i)\bPATH=') 'no PATH in any instruction'
        Assert-Match 'LLAMA_CPP_HIP_HOME="C:\\runtime\\opt\\llama\.cpp-hip"' $code 'home is exposed by ENV'
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
    }

    It 'runs the rocm-check in the same RUN and fails the stage on any finding' {
        Assert-Match "(?s)Install-LlamaCppHip\.ps1' .*-InstallDir \`$env:LLAMA_CPP_HIP_HOME.*@\(& 'C:\\bkmnt\\LlamaCpp\.ps1'\).*throw" $code 'check armed'
    }
}
