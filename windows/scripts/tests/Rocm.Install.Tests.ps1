#requires -Version 7.0
# Windows ROCm sdk layer (Install-Rocm.ps1, Install-VulkanLoader.ps1, Dockerfile.rocm, Test-RocmImage.ps1,
# rocm-checks\GpuLoaders.ps1): guards, layout gate, ICD registration, loader install, env contract, PATH
# rules, check grading. NOT covered: the real downloads, hipcc, a real ICD or loader in the image, and the
# rest of the driver wiring (Driver.Variant.Tests.ps1).

Describe 'Install-Rocm: tarball URL' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Get-RocmWindowsTarballUrl')

    It 'builds AMD''s documented tarball URL for a family and release' {
        Assert-Equal 'https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-gfx120X-all-10.0.0.tar.gz' `
            (Get-RocmWindowsTarballUrl -Release '10.0.0' -GfxFamily 'gfx120X-all') 'gfx120X-all URL'
        Assert-Equal 'https://stable.repo.amd.com/rocm/core/tarball/therock-dist-windows-multiarch-10.0.0.tar.gz' `
            (Get-RocmWindowsTarballUrl -Release '10.0.0' -GfxFamily 'multiarch') 'multiarch URL'
    }

    It 'refuses a release that is not a full x.y.z (versions.env ROCM_VERSION is only x.y)' {
        foreach ($bad in @('', '10.0', 'v10.0.0', '10.0.0-rc1')) {
            Assert-Throws { Get-RocmWindowsTarballUrl -Release $bad -GfxFamily 'gfx120X-all' } "release '$bad'" -MessagePattern 'ROCM_WINDOWS_RELEASE'
        }
    }

    It 'refuses anything that is not a GPU family name, including path tricks' {
        foreach ($bad in @('', 'amd', 'rocm', 'GFX120X-ALL', 'gfx120X-all/../x', 'gfx120X-all.tar.gz?', 'gfx 120X')) {
            Assert-Throws { Get-RocmWindowsTarballUrl -Release '10.0.0' -GfxFamily $bad } "family '$bad'" -MessagePattern 'ROCM_WINDOWS_GFX_FAMILY'
        }
    }
}

Describe 'Install-Rocm: target arch' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Assert-RocmTargetArch')

    It 'accepts amd64' {
        Assert-RocmTargetArch -TargetArch 'amd64'
        Assert-True $true 'amd64 passed'
    }

    It 'refuses arm64 and anything else: AMD ships no Windows arm64 ROCm' {
        foreach ($bad in @('arm64', 'x64', '')) {
            Assert-Throws { Assert-RocmTargetArch -TargetArch $bad } "arch '$bad'" -MessagePattern 'amd64-only'
        }
    }
}

Describe 'Install-Rocm: layout gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Assert-RocmWindowsLayout')

    # What the gate requires, as the 10.0.0 gfx120X-all tarball ships it.
    $script:RocmRequired = @('bin\hipcc.exe', 'bin\hipconfig.exe', 'bin\hipInfo.exe', 'bin\amdhip64_7.dll',
        'bin\OpenCL.dll', 'bin\amdocl64.dll', 'include\hip\hip_runtime.h', 'lib\llvm\bin\clang.exe',
        'lib\llvm\amdgcn\bitcode\ocml.bc', '.info\version')
    # The gate reports these two by their glob; every other piece by its own path.
    $script:RocmGlobMessage = @{ 'bin\amdhip64_7.dll' = 'amdhip64_\*\.dll'; 'lib\llvm\amdgcn\bitcode\ocml.bc' = 'bitcode\\\*\.bc' }
    function New-FakeRocmTree {
        param([string]$Root, [string[]]$Skip = @(), [string]$Version = '10.0.0')
        foreach ($rel in @($script:RocmRequired | Where-Object { $_ -ne '.info\version' })) {
            if ($Skip -contains $rel) { continue }
            $p = Join-Path $Root $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
            Set-Content -LiteralPath $p -Value 'x' -Encoding ASCII
        }
        if ($Skip -notcontains '.info\version') {
            New-Item -ItemType Directory -Force -Path (Join-Path $Root '.info') | Out-Null
            Set-Content -LiteralPath (Join-Path $Root '.info\version') -Value $Version -Encoding ASCII
        }
    }

    It 'passes a complete tree' {
        Invoke-InTestDir { param($dir)
            New-FakeRocmTree -Root $dir
            Assert-RocmWindowsLayout -Root $dir -Release '10.0.0'
            Assert-True $true 'complete tree passed'
        }
    }

    It 'fails, naming the piece, when any one required piece is missing' {
        foreach ($rel in $script:RocmRequired) {
            $pattern = @($script:RocmGlobMessage[$rel], [regex]::Escape($rel)) | Where-Object { $_ } | Select-Object -First 1
            Invoke-InTestDir { param($dir)
                New-FakeRocmTree -Root $dir -Skip @($rel)
                Assert-Throws { Assert-RocmWindowsLayout -Root $dir -Release '10.0.0' } "missing $rel" -MessagePattern $pattern
            }
        }
    }

    It 'fails when the tree is a different release than the pin' {
        Invoke-InTestDir { param($dir)
            New-FakeRocmTree -Root $dir -Version '9.9.9'
            Assert-Throws { Assert-RocmWindowsLayout -Root $dir -Release '10.0.0' } 'version mismatch' -MessagePattern "says '9\.9\.9'"
        }
    }
}

Describe 'Install-Rocm: the rocm sdk builds FROM the plain base' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Assert-RocmForkBase')

    It 'accepts the plain base (no GPU_TYPE, or GPU_TYPE=cpu, and no CUDA env)' {
        Assert-RocmForkBase -GpuType '' -CudaRoot '' -CudaPath ''
        Assert-RocmForkBase -GpuType 'cpu' -CudaRoot '' -CudaPath ''
        Assert-True $true 'plain bases passed'
    }

    It 'refuses a CUDA-lineage base, naming every leaked variable' {
        Assert-Throws { Assert-RocmForkBase -GpuType 'nvidia' -CudaRoot '' -CudaPath '' } 'GPU_TYPE=nvidia' -MessagePattern 'GPU_TYPE=nvidia'
        Assert-Throws { Assert-RocmForkBase -GpuType '' -CudaRoot 'C:\cuda' -CudaPath '' } 'CUDA_ROOT' -MessagePattern 'CUDA_ROOT=C:\\cuda'
        Assert-Throws { Assert-RocmForkBase -GpuType 'nvidia' -CudaRoot 'C:\a' -CudaPath 'C:\b' } 'all three' -MessagePattern 'CUDA_PATH=C:\\b, CUDA_ROOT=C:\\a, GPU_TYPE=nvidia'
        Assert-Throws { Assert-RocmForkBase -GpuType 'nvidia' -CudaRoot '' -CudaPath '' } 'message' -MessagePattern 'builds FROM the plain base'
    }

    It 'refuses a base that already carries ROCm (no stacking a second layer)' {
        Assert-Throws { Assert-RocmForkBase -GpuType 'rocm' -CudaRoot '' -CudaPath '' } 'GPU_TYPE=rocm' -MessagePattern 'GPU_TYPE=rocm'
    }

    It 'Dockerfile.rocm defaults its BASE_IMAGE to the plain base, not media' {
        $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.rocm')
        Assert-Match '(?m)^ARG BASE_IMAGE=local/kataglyphis:windows-base\s*$' $df 'ARG BASE_IMAGE default'
        Assert-False ($df -match 'windows-media') 'no media lineage left in Dockerfile.rocm'
    }
}

Describe 'Test-RocmImage: rocm-checks aggregation' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-RocmImage.ps1' -FunctionName 'Get-RocmCheckFinding')
    function New-FakeCheck([string]$Dir, [string]$Name, [string]$Body) {
        Set-Content -LiteralPath (Join-Path $Dir $Name) -Value "#requires -Version 7.0`n$Body" -Encoding utf8
    }

    It 'passes when every check writes nothing, and ignores non-ps1 files' {
        Invoke-InTestDir { param($dir)
            New-FakeCheck $dir 'A-Quiet.ps1' '$null = 1'
            New-FakeCheck $dir 'B-Empty.ps1' "Write-Output ''"
            Set-Content -LiteralPath (Join-Path $dir 'notes.txt') -Value 'Write-Output nope'
            Assert-Equal 0 @(Get-RocmCheckFinding -ChecksDir $dir).Count 'no findings'
        }
    }

    It 'collects each finding with its file name, sorted by file; a throw is a finding and the later checks still run' {
        Invoke-InTestDir { param($dir)
            # Written out of order on purpose: the verdict must not depend on directory order.
            New-FakeCheck $dir 'C-Two.ps1' "Write-Output 'first gap'; Write-Output 'second gap'"
            New-FakeCheck $dir 'A-Throws.ps1' "throw 'boom'"
            New-FakeCheck $dir 'B-Pass.ps1' '$null = 1'
            $got = @(Get-RocmCheckFinding -ChecksDir $dir)
            Assert-Equal 'A-Throws.ps1 threw: boom|C-Two.ps1: first gap|C-Two.ps1: second gap' ($got -join '|') 'findings in file order'
        }
    }

    It 'reports a missing folder and a folder with no checks' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('no-rocm-checks-' + [guid]::NewGuid().ToString('N'))
        $got = @(Get-RocmCheckFinding -ChecksDir $missing)
        Assert-Equal 1 $got.Count 'missing folder'
        Assert-Match 'rocm-checks folder missing' $got[0] 'missing folder message'
        Invoke-InTestDir { param($dir)
            $got = @(Get-RocmCheckFinding -ChecksDir $dir)
            Assert-Equal 1 $got.Count 'empty folder'
            Assert-Match 'no \*\.ps1 checks' $got[0] 'empty folder message'
        }
    }

    It 'runs after the built-in checks, from the folder beside the script, and feeds the same verdict' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-RocmImage.ps1')
        Assert-Match "\[string\]\`$ChecksDir = \(Join-Path \`$PSScriptRoot 'rocm-checks'\)" $src 'default folder'
        Assert-Match "(?s)Get-RocmKernelCompileFinding -Hipcc.+\`$failures \+= @\(Get-RocmCheckFinding -ChecksDir \`$ChecksDir\).+if \(\`$failures\.Count -gt 0\)" $src 'aggregated before the verdict'
    }
}

Describe 'Test-RocmImage: the image carries the spike mode the run asked for' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-RocmImage.ps1' -FunctionName 'Get-RocmSpikeFinding')
    # One case = expected mode, MIGRAPHX_ROOT, the marker's TVM_ROCM ($null = no marker file); Want = finding patterns, in order.
    function Invoke-SpikeCase([string]$Expect, [string]$Migraphx, $TvmRocm) {
        return Invoke-InTestDir { param($dir)
            $marker = Join-Path $dir 'ROCM-FEATURES.txt'
            if ($null -ne $TvmRocm) { Set-Content -LiteralPath $marker -Value @('# marker', "TVM_ROCM=$TvmRocm", 'USE_OPENCL=ON') -Encoding ascii }
            @(Get-RocmSpikeFinding -Expect $Expect -MigraphxRoot $Migraphx -TvmMarker $marker)
        }
    }

    It 'passes a matching image either way, and fails a parent from the other mode, an unset mode or a missing marker' {
        $mgx = 'C:\runtime\lib\migraphx'
        $cases = @(
            @{ Label = 'spikes on'; Args = @('1', $mgx, '1'); Want = @() }
            @{ Label = '-NoRocmSpikes'; Args = @('0', '', '0'); Want = @() }
            # The reviewed hole: a spikes-on torch,final run on top of -NoRocmSpikes parents.
            @{ Label = 'spikes on, no-spike parents'; Args = @('1', '', '0'); Want = @('MIGraphX present=False', 'TVM_ROCM=0 in .+EXPECT_ROCM_SPIKES=1') }
            @{ Label = '-NoRocmSpikes, spike parents'; Args = @('0', $mgx, '1'); Want = @('MIGraphX present=True', 'TVM_ROCM=1 in .+EXPECT_ROCM_SPIKES=0') }
            @{ Label = 'no marker'; Args = @('1', $mgx, $null); Want = @('TVM_ROCM=unknown .+ is missing') }
            @{ Label = 'unset mode'; Args = @('', $mgx, '1'); Want = @('not 0 or 1') }
            @{ Label = 'bogus mode'; Args = @('yes', $mgx, '1'); Want = @('not 0 or 1') }
        )
        foreach ($c in $cases) {
            $positional = $c.Args
            $got = @(Invoke-SpikeCase @positional)
            Assert-Equal $c.Want.Count $got.Count "$($c.Label): finding count ($($got -join ' | '))"
            for ($i = 0; $i -lt [Math]::Min($got.Count, $c.Want.Count); $i++) { Assert-Match $c.Want[$i] $got[$i] "$($c.Label): finding $i" }
        }
    }

    It 'grades the mode from the driver''s env before the verdict' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Test-RocmImage.ps1')
        Assert-Match "\[string\]\`$ExpectSpikes = \`$env:EXPECT_ROCM_SPIKES" $src 'param default from the env'
        Assert-Match "(?s)\`$failures \+= @\(Get-RocmSpikeFinding -Expect \`$ExpectSpikes -MigraphxRoot `"\`$env:MIGRAPHX_ROOT`".+if \(\`$failures\.Count -gt 0\)" $src 'graded before the verdict'
    }
}

Describe 'Build-OnnxFromSource: the rocm lane builds the cpu flags' {
    It 'has no ROCm EP request left (ORT >= 1.23 dropped onnxruntime_USE_ROCM), logs the lane and adds no flag' {
        $ort = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-OnnxFromSource.ps1')
        foreach ($dead in 'onnxruntime_USE_ROCM=ON', "GpuType -eq 'amd'") {
            Assert-False $ort.Contains($dead) "dead branch text '$dead' is back"
        }
        $at = $ort.IndexOf('} elseif ($gpuEnv.HasRocm) {')
        Assert-True ($at -ge 0) 'the HasRocm branch is gone'
        $rocmBranch = $ort.Substring($at, $ort.IndexOf('} else {', $at + 1) - $at)
        Assert-True $rocmBranch.Contains("Write-Host 'ROCm layer present: CPU+DML ORT'") 'rocm log line'
        Assert-False $rocmBranch.Contains('$gpuArgs') 'no GPU flag on the rocm lane'
    }
}

Describe 'Test-RocmImage: env contract' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-RocmImage.ps1' -FunctionName 'Get-RocmImageEnvFinding')
    function New-RocmGoodEnv {
        return @{ HIP_PATH = 'C:\TheRock\build'; ROCM_PATH = 'C:\TheRock\build'; HIP_PLATFORM = 'amd'; GPU_TYPE = 'rocm'
            HIP_DEVICE_LIB_PATH = 'C:\TheRock\build\lib\llvm\amdgcn\bitcode'; ROCM_WINDOWS_RELEASE = '10.0.0' }
    }

    It 'has no finding for the env Dockerfile.rocm sets' {
        Assert-Equal 0 @(Get-RocmImageEnvFinding -Environment (New-RocmGoodEnv)).Count 'good env'
    }

    It 'reports each broken piece of the contract' {
        $cases = @(
            @{ Key = 'HIP_PATH'; Value = $null; Pattern = 'HIP_PATH is not set' },
            @{ Key = 'ROCM_WINDOWS_RELEASE'; Value = ''; Pattern = 'ROCM_WINDOWS_RELEASE is not set' },
            @{ Key = 'GPU_TYPE'; Value = 'nvidia'; Pattern = "GPU_TYPE is 'nvidia'" },
            @{ Key = 'HIP_PLATFORM'; Value = 'nvidia'; Pattern = "HIP_PLATFORM is 'nvidia'" },
            @{ Key = 'ROCM_PATH'; Value = 'C:\elsewhere'; Pattern = 'differ' },
            @{ Key = 'CUDA_PATH'; Value = 'C:\cuda'; Pattern = 'CUDA lineage leaked' }
        )
        foreach ($c in $cases) {
            $e = New-RocmGoodEnv
            $e[$c.Key] = $c.Value
            $got = @(Get-RocmImageEnvFinding -Environment $e)
            Assert-Equal 1 $got.Count "exactly one finding for $($c.Key)"
            Assert-Match $c.Pattern $got[0] "finding for $($c.Key)"
        }
    }
}

Describe 'Test-RocmImage: AMD''s LLVM must not shadow the image toolchain' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Test-RocmImage.ps1' -FunctionName 'Get-RocmShadowFinding')

    It 'passes when every tool resolves outside ROCm (or not at all)' {
        $resolved = @{ 'clang-cl' = 'C:\Users\x\scoop\apps\llvm\current\bin\clang-cl.exe'; 'lld-link' = $null
            'clang' = 'C:\TheRock\buildx\bin\clang.exe' }   # a sibling dir sharing the prefix is NOT inside
        Assert-Equal 0 @(Get-RocmShadowFinding -Resolved $resolved -RocmRoot 'C:\TheRock\build').Count 'no shadow'
    }

    It 'flags a tool that resolves into ROCm''s tree, case-insensitively' {
        $got = @(Get-RocmShadowFinding -Resolved @{ 'clang-cl' = 'c:\therock\BUILD\lib\llvm\bin\clang-cl.exe' } -RocmRoot 'C:\TheRock\build\')
        Assert-Equal 1 $got.Count 'one shadowed tool'
        Assert-Match 'clang-cl resolves into ROCm' $got[0] 'names the tool'
    }
}

Describe 'Dockerfile.rocm: PATH and pins' {
    $df = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.rocm')
    $pathValue = [regex]::Match($df, '(?m)\bPATH="([^"]*)"').Groups[1].Value

    It 'appends ROCm''s bin AFTER the inherited PATH (its flatc.exe / OpenCL.dll must not shadow the image''s)' {
        Assert-Match '^\$\{PATH\};' $pathValue 'inherited PATH first'
        Assert-Match 'C:\\TheRock\\build\\bin$' $pathValue 'ROCm bin last'
    }

    It 'never puts AMD''s LLVM on PATH (lib\llvm\bin holds its own clang-cl.exe)' {
        # Instructions only: the header comment names lib\llvm\bin on purpose.
        $code = ($df -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        Assert-False ($code -match '(?i)llvm\\bin') 'lib\llvm\bin must not appear in any Dockerfile.rocm instruction'
    }

    It 'fails closed on the SHA256: the script refuses an empty or malformed pin' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\host\Install-Rocm.ps1')
        Assert-Match '\$TarballSha256 -notmatch ''\^\[0-9a-fA-F\]\{64\}\$''' $src 'SHA256 shape guard present'
        Assert-Match '-ExpectedSha256 \$TarballSha256' $src 'download verified against the pin'
    }
}

Describe 'Install-Rocm: TheRock''s OpenCL ICD, registered the way the Khronos loader reads it' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Rocm.ps1' -FunctionName 'Register-OpenClIcd')
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\rocm-checks\GpuLoaders.ps1' -FunctionName 'Get-OpenClIcdRegistryEntry', 'Get-OpenClIcdRegistryFinding')
    # A throwaway HKCU key stands in for HKLM\SOFTWARE\Khronos\OpenCL\Vendors.
    function Invoke-InTestRegistry([scriptblock]$Body) {
        $sub = 'Software\ANTfrastructure-test-' + [guid]::NewGuid().ToString('N')
        try { & $Body ([Microsoft.Win32.Registry]::CurrentUser) $sub }
        finally { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($sub, $false) }
    }

    It 'writes the DLL path as the value name with REG_DWORD 0, once, and the rocm-check reads it back clean' {
        Invoke-InTestDir { param($dir)
            $dll = Join-Path $dir 'amdocl64.dll'
            Set-Content -LiteralPath $dll -Value 'x'
            Invoke-InTestRegistry { param($base, $sub)
                Register-OpenClIcd -IcdPath $dll -BaseKey $base -SubKey $sub
                Register-OpenClIcd -IcdPath $dll -BaseKey $base -SubKey $sub
                $entries = @(Get-OpenClIcdRegistryEntry -BaseKey $base -SubKey $sub)
                Assert-Equal 1 $entries.Count 'one value after two registrations'
                Assert-Equal $dll $entries[0].Name 'value name = the DLL path'
                Assert-Equal 'DWord' $entries[0].Kind 'REG_DWORD'
                Assert-Equal 0 $entries[0].Value 'data 0'
                Assert-Equal 0 @(Get-OpenClIcdRegistryFinding -Entry $entries -IcdPath $dll).Count 'the check grades it clean'
            }
        }
    }

    It 'refuses a relative or missing ICD path without creating the key' {
        Invoke-InTestRegistry { param($base, $sub)
            foreach ($bad in @('amdocl64.dll', 'C:\no-such-dir-4c1f\amdocl64.dll')) {
                Assert-Throws { Register-OpenClIcd -IcdPath $bad -BaseKey $base -SubKey $sub } "path '$bad'" -MessagePattern 'not an existing absolute path'
            }
            Assert-Null $base.OpenSubKey($sub) 'no key was created'
        }
    }

    It 'Install-Rocm registers bin\amdocl64.dll in HKLM''s 64-bit view, after the layout gate proved the file' {
        $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\scripts\host\Install-Rocm.ps1')
        Assert-Match "(?s)Assert-RocmWindowsLayout -Root \`$InstallDir -Release \`$RocmRelease\s+\`$icd = Join-Path \`$InstallDir 'bin\\amdocl64\.dll'\s+Register-OpenClIcd -IcdPath \`$icd\s" $src 'call order'
        Assert-Match "OpenBaseKey\('LocalMachine', 'Registry64'\)" $src '64-bit HKLM'
        Assert-Match "SubKey = 'SOFTWARE\\Khronos\\OpenCL\\Vendors'" $src 'the key the loader opens'
    }
}

Describe 'rocm-checks\GpuLoaders: the ICD registry grading' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\rocm-checks\GpuLoaders.ps1' -FunctionName 'Get-OpenClIcdRegistryFinding')

    It 'passes the registered ICD (any case, beside other vendors) and names each way the loader would skip it' {
        Invoke-InTestDir { param($dir)
            $dll = Join-Path $dir 'amdocl64.dll'
            Set-Content -LiteralPath $dll -Value 'x'
            $other = [pscustomobject]@{ Name = 'C:\Windows\System32\IntelOpenCL64.dll'; Kind = 'DWord'; Value = 0 }
            $cases = @(
                @{ Label = 'good'; Entry = @([pscustomobject]@{ Name = $dll; Kind = 'DWord'; Value = 0 }, $other); Want = '' }
                @{ Label = 'other case'; Entry = @([pscustomobject]@{ Name = $dll.ToUpperInvariant(); Kind = 'DWord'; Value = 0 }); Want = '' }
                @{ Label = 'absent'; Entry = @($other); Want = 'has no value named' }
                @{ Label = 'no key'; Entry = @(); Want = 'has no value named' }
                @{ Label = 'string'; Entry = @([pscustomobject]@{ Name = $dll; Kind = 'String'; Value = '0' }); Want = 'is String .+ REG_DWORD 0' }
                @{ Label = 'nonzero'; Entry = @([pscustomobject]@{ Name = $dll; Kind = 'DWord'; Value = 1 }); Want = "is DWord '1'" }
                @{ Label = 'missing file'; Entry = @([pscustomobject]@{ Name = "$dll.gone"; Kind = 'DWord'; Value = 0 }); Path = "$dll.gone"; Want = 'does not exist' }
            )
            foreach ($c in $cases) {
                $path = if ($c.ContainsKey('Path')) { $c.Path } else { $dll }
                $got = @(Get-OpenClIcdRegistryFinding -Entry $c.Entry -IcdPath $path)
                Assert-Equal ([int][bool]$c.Want) $got.Count "$($c.Label): finding count ($($got -join ' | '))"
                if ($c.Want) { Assert-Match $c.Want $got[0] "$($c.Label): finding" }
            }
        }
    }
}

Describe 'rocm-checks\GpuLoaders: the loader probe grading' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\rocm-checks\GpuLoaders.ps1' -FunctionName 'Get-GpuLoaderProbeFinding', 'Get-VulkanSdkHeaderVersion',
        'Get-VulkanLoaderCopyFinding')
    # What the rocm image should print: System32's loader, TheRock's OpenCL.dll, AMD's platform with no device.
    $script:VkSys = 'vulkan|C:\Windows\System32\vulkan-1.dll|'
    $script:ProbeGood = [ordered]@{
        vulkan = "${script:VkSys}True|True|0|1|4|357"
        opencl = 'opencl|C:\TheRock\build\bin\OpenCL.dll|0|1'
        platform = 'platform|AMD Accelerated Parallel Processing|-1|0'
        icd = 'icd|C:\TheRock\build\bin\amdocl64.dll|True|True'
    }
    function Get-ProbeCaseFinding([hashtable]$Replace = @{}, $ExitCode = 0, [int]$Sdk = 357) {
        $lines = @(foreach ($k in $script:ProbeGood.Keys) { if ($Replace.ContainsKey($k)) { $Replace[$k] } else { $script:ProbeGood[$k] } }) |
            Where-Object { $_ }
        return @(Get-GpuLoaderProbeFinding -ExitCode $ExitCode -Line @($lines) -LoaderPath 'C:\Windows\System32\vulkan-1.dll' `
                -IcdPath 'C:\TheRock\build\bin\amdocl64.dll' -SdkHeaderVersion $Sdk)
    }

    It 'passes the rocm image''s answer (System32 in any case, a newer loader) and an unknown SDK' {
        Assert-Equal 0 @(Get-ProbeCaseFinding).Count 'the image answer'
        Assert-Equal 0 @(Get-ProbeCaseFinding -Replace @{ vulkan = 'vulkan|C:\WINDOWS\system32\vulkan-1.dll|True|True|0|1|4|361' }).Count 'GetModuleFileName casing'
        Assert-Equal 0 @(Get-ProbeCaseFinding -Replace @{ vulkan = "${script:VkSys}True|True|0|1|4|300" } -Sdk 0).Count 'no SDK header: no floor'
    }

    It 'names every broken piece with its own finding' {
        $cases = @(
            @{ R = @{}; X = $null; Want = 'hung past its timeout' }
            @{ R = @{}; X = -1073741819; Want = 'exited -1073741819' }
            @{ R = @{ vulkan = 'vulkan-load|126' }; Want = 'vulkan-1\.dll does not load .+Win32 126' }
            @{ R = @{ vulkan = 'vulkan|C:\tools\vulkan-1.dll|True|True|0|1|4|357' }; Want = 'resolves to C:\\tools\\vulkan-1\.dll, not C:\\Windows\\System32\\vulkan-1\.dll \(a copy shadows' }
            @{ R = @{ vulkan = 'vulkan|C:\vulkan-loader\vulkan-1.dll|True|True|0|1|4|357' }; Want = 'resolves to C:\\vulkan-loader\\.+System32 has none' }
            @{ R = @{ vulkan = "${script:VkSys}True|False|-1|0|0|0" }; Want = 'does not export vkGetInstanceProcAddr and vkEnumerateInstanceVersion' }
            @{ R = @{ vulkan = "${script:VkSys}True|True|-9|0|0|0" }; Want = 'vkEnumerateInstanceVersion returned -9' }
            @{ R = @{ vulkan = "${script:VkSys}True|True|0|1|4|300" }; Want = '1\.4\.300, older than the SDK headers \(357\)' }
            @{ R = @{ vulkan = '' }; Want = 'nothing about vulkan-1\.dll' }
            @{ R = @{ opencl = 'opencl-load|126'; platform = '' }; Want = 'no OpenCL\.dll loads .+Win32 126' }
            @{ R = @{ opencl = 'opencl|C:\x\OpenCL.dll|nosym|0'; platform = '' }; Want = 'exports no clGetPlatformIDs' }
            @{ R = @{ opencl = 'opencl|C:\x\OpenCL.dll|-5|0'; platform = '' }; Want = 'clGetPlatformIDs through C:\\x\\OpenCL\.dll returned -5' }
            @{ R = @{ opencl = 'opencl|C:\x\OpenCL.dll|-1001|0'; platform = '' }; Want = 'lists no AMD platform \(none\)' }
            @{ R = @{ platform = 'platform|Intel(R) OpenCL|0|1' }; Want = 'lists no AMD platform \(Intel\(R\) OpenCL\)' }
            @{ R = @{ icd = 'icd-load|193' }; Want = 'amdocl64\.dll does not load \(Win32 193\)' }
            @{ R = @{ icd = 'icd|C:\TheRock\build\bin\amdocl64.dll|False|True' }; Want = 'does not export clIcdGetPlatformIDsKHR' }
            @{ R = @{ icd = '' }; Want = 'nothing about C:\\TheRock\\build\\bin\\amdocl64\.dll' }
        )
        foreach ($c in $cases) {
            $x = if ($c.ContainsKey('X')) { $c.X } else { 0 }
            $got = @(Get-ProbeCaseFinding -Replace $c.R -ExitCode $x)
            Assert-Equal 1 $got.Count "/$($c.Want)/: exactly one finding ($($got -join ' | '))"
            Assert-Match $c.Want $got[0] 'finding text'
        }
    }

    It 'reads VK_HEADER_VERSION from the SDK, 0 when there is none' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'Include\vulkan') | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Include\vulkan\vulkan_core.h') -Value @('// Version of this file', '#define VK_HEADER_VERSION 357',
                '#define VK_HEADER_VERSION_COMPLETE VK_MAKE_API_VERSION(0, 1, 4, VK_HEADER_VERSION)')
            Assert-Equal 357 (Get-VulkanSdkHeaderVersion -SdkRoot $dir) 'the SDK header'
            Assert-Equal 0 (Get-VulkanSdkHeaderVersion -SdkRoot (Join-Path $dir 'nope')) 'no header'
            Assert-Equal 0 (Get-VulkanSdkHeaderVersion -SdkRoot '') 'VULKAN_SDK unset'
        }
    }

    It 'traces System32''s loader to the pinned copy byte for byte, naming a missing or foreign copy' {
        Invoke-InTestDir { param($dir)
            $pinned = Join-Path $dir 'pinned.dll'; $sys = Join-Path $dir 'sys.dll'
            Set-Content -LiteralPath $pinned -Value 'loader 1.4.357'
            Assert-Match 'sys\.dll is missing; FFmpeg''s dlopen' "$(Get-VulkanLoaderCopyFinding -SystemCopy $sys -PinnedCopy $pinned)" 'no System32 copy'
            Copy-Item -LiteralPath $pinned -Destination $sys
            Assert-Equal 0 @(Get-VulkanLoaderCopyFinding -SystemCopy $sys -PinnedCopy $pinned).Count 'identical bytes'
            Set-Content -LiteralPath $sys -Value 'a driver''s loader'
            Assert-Match 'differs from the pinned' "$(Get-VulkanLoaderCopyFinding -SystemCopy $sys -PinnedCopy $pinned)" 'foreign bytes'
            Assert-Match 'verified loader .+ is missing' "$(Get-VulkanLoaderCopyFinding -SystemCopy $sys -PinnedCopy "$pinned.gone")" 'no pinned copy'
        }
    }

    It 'runs before GStreamer.ps1, whose amfcodec load probe it arms (vulkan-1.dll was its reason to skip)' {
        Assert-Equal 'GpuLoaders.ps1' (@('GStreamer.ps1', 'GpuLoaders.ps1') | Sort-Object | Select-Object -First 1) 'Test-RocmImage sorts by name'
        Assert-True (Test-Path -LiteralPath (Join-Path (Get-RepoRoot) 'windows\scripts\build\rocm-checks\GpuLoaders.ps1')) 'the check ships in rocm-checks'
    }
}

Describe 'Install-VulkanLoader: LunarG''s pinned loader zip' {
    $script:VkInstall = 'windows\scripts\host\Install-VulkanLoader.ps1'
    . (Get-ScriptFunctionDefinition -ScriptPath $script:VkInstall -FunctionName 'Get-VulkanRuntimeZipUrl', 'Expand-VulkanLoaderZip',
        'Get-PeFileVersionNumber', 'Install-VulkanLoaderSystemCopy', 'Install-VulkanLoader')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # A zip with LunarG's layout; -Entry maps zip paths to the file whose bytes they carry.
    function New-VulkanFixtureZip([string]$Root, [hashtable]$Entry) {
        $tree = Join-Path $Root 'tree'
        foreach ($rel in $Entry.Keys) {
            $p = Join-Path $tree $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
            Copy-Item -LiteralPath $Entry[$rel] -Destination $p
        }
        $zip = Join-Path $Root 'fixture.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($tree, $zip)
        return $zip
    }
    $script:VkPe = Join-Path $env:SystemRoot 'System32\version.dll'
    $script:VkPeVersion = Get-PeFileVersionNumber -Path $script:VkPe

    It 'builds LunarG''s Components URL and refuses anything but a four-part version' {
        Assert-Equal 'https://sdk.lunarg.com/sdk/download/1.4.357.0/windows/VulkanRT-X64-1.4.357.0-Components.zip' (Get-VulkanRuntimeZipUrl -Version '1.4.357.0') 'url'
        foreach ($bad in @('', '1.4.357', 'v1.4.357.0', '1.4.357.0/../x', '1.4.357.0 ')) {
            Assert-Throws { Get-VulkanRuntimeZipUrl -Version $bad } "version '$bad'" -MessagePattern 'four-part LunarG SDK version'
        }
    }

    It 'extracts only the x64 loader and the licence, flat, and refuses a zip without exactly one of each' {
        Invoke-InTestDir { param($dir)
            $x64 = Join-Path $dir 'x64.bin'; $x86 = Join-Path $dir 'x86.bin'; $lic = Join-Path $dir 'lic.txt'
            Set-Content -LiteralPath $x64 -Value 'x64 loader'; Set-Content -LiteralPath $x86 -Value 'x86 loader'; Set-Content -LiteralPath $lic -Value 'MIT'
            $top = 'VulkanRT-X64-1.4.357.0-Components'
            $zip = New-VulkanFixtureZip -Root (Join-Path $dir 'ok') -Entry @{ "$top\x64\vulkan-1.dll" = $x64; "$top\x86\vulkan-1.dll" = $x86
                "$top\x64\vulkaninfo.exe" = $x86; "$top\VulkanRT-License.txt" = $lic }
            $out = Join-Path $dir 'out'
            Expand-VulkanLoaderZip -ZipPath $zip -Destination $out
            Assert-Equal 'vulkan-1.dll,VulkanRT-License.txt' ((Get-ChildItem -LiteralPath $out -File | Sort-Object Name).Name -join ',') 'two files, flat'
            Assert-Equal 'x64 loader' (Get-Content -Raw (Join-Path $out 'vulkan-1.dll')).Trim() 'the x64 loader, not the x86 one'
            $none = New-VulkanFixtureZip -Root (Join-Path $dir 'none') -Entry @{ "$top\x86\vulkan-1.dll" = $x86; "$top\VulkanRT-License.txt" = $lic }
            Assert-Throws { Expand-VulkanLoaderZip -ZipPath $none -Destination (Join-Path $dir 'o2') } 'no x64' -MessagePattern 'holds 0 entries matching .+x64/vulkan-1'
            $two = New-VulkanFixtureZip -Root (Join-Path $dir 'two') -Entry @{ 'a\x64\vulkan-1.dll' = $x64; 'b\x64\vulkan-1.dll' = $x64; 'VulkanRT-License.txt' = $lic }
            Assert-Throws { Expand-VulkanLoaderZip -ZipPath $two -Destination (Join-Path $dir 'o3') } 'two x64' -MessagePattern 'holds 2 entries'
            $nolic = New-VulkanFixtureZip -Root (Join-Path $dir 'nolic') -Entry @{ "$top\x64\vulkan-1.dll" = $x64 }
            Assert-Throws { Expand-VulkanLoaderZip -ZipPath $nolic -Destination (Join-Path $dir 'o4') } 'no licence' -MessagePattern 'holds 0 entries matching .+License'
        }
    }

    It 'reads the numeric file version of a PE, and nothing from a file without one' {
        Assert-Match '^\d+\.\d+\.\d+\.\d+$' $script:VkPeVersion 'a four-part version'
        Invoke-InTestDir { param($dir)
            $txt = Join-Path $dir 'plain.dll'
            Set-Content -LiteralPath $txt -Value 'not a PE'
            Assert-Equal '' (Get-PeFileVersionNumber -Path $txt) 'no version resource'
        }
    }

    # Install-VulkanLoader over a file:// mirror of LunarG's layout: the real download, SHA256 and version checks.
    # The loader is a real PE (System32\version.dll), so its version resource is real too.
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsContainerImage.Common.psm1' -FunctionName 'Resolve-ContainerImageValue',
        'Initialize-ContainerImageTempDirectory', 'Clear-PendingFileHandle')
    # A fixture SystemDir stands in for System32; -SystemCopy pre-seeds its vulkan-1.dll with that file's bytes.
    function Invoke-VulkanInstallFixture([string]$Root, [hashtable]$Override = @{}, [string]$SystemCopy = '') {
        $pins = @{ TempDir = (Join-Path $Root 'tmp'); VulkanVersion = $script:VkPeVersion; InstallDir = (Join-Path $Root 'vulkan-loader')
            TargetArch = 'amd64'; SystemDir = (Join-Path $Root 'system32'); BaseUrl = ([uri](Join-Path $Root 'site')).AbsoluteUri }
        foreach ($k in $Override.Keys) { $pins[$k] = $Override[$k] }
        New-Item -ItemType Directory -Force -Path $pins.SystemDir | Out-Null
        if ($SystemCopy) { Copy-Item -LiteralPath $SystemCopy -Destination (Join-Path $pins.SystemDir 'vulkan-1.dll') }
        $v = $pins.VulkanVersion
        $mirror = Join-Path $Root "site\$v\windows\VulkanRT-X64-$v-Components.zip"
        New-Item -ItemType Directory -Force -Path (Split-Path $mirror -Parent) | Out-Null
        Move-Item -LiteralPath (New-VulkanFixtureZip -Root (Join-Path $Root 'zip') -Entry @{
                'VulkanRT-X64-9-Components\x64\vulkan-1.dll' = $script:VkPe; 'VulkanRT-X64-9-Components\VulkanRT-License.txt' = $script:VkPe }) -Destination $mirror
        if (-not $pins.ContainsKey('ZipSha256')) { $pins.ZipSha256 = (Get-FileHash -LiteralPath $mirror).Hash }
        $PSDefaultParameterValues = @{ 'Invoke-DownloadWithRetry:InitialDelaySeconds' = 0 }
        $failure = Invoke-WithEnv @{ VULKAN_VERSION = $null; VULKAN_RT_WINDOWS_ZIP_SHA256 = $null; WINDOWS_TARGET_ARCH = $null } {
            try { Install-VulkanLoader @pins 6>$null; $null } catch { $_.Exception.Message }
        }
        $sysLoader = Join-Path $pins.SystemDir 'vulkan-1.dll'
        return [pscustomobject]@{ Error = $failure; Pins = $pins; SystemHash = $(if (Test-Path -LiteralPath $sysLoader) { (Get-FileHash -LiteralPath $sysLoader).Hash }) }
    }
    $script:VkPeHash = (Get-FileHash -LiteralPath $script:VkPe).Hash

    It 'downloads the zip through the real download and SHA256 check, installs the loader into System32 and the pinned copy with its licence, keeps no zip' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-VulkanInstallFixture -Root $dir
            Assert-Null $r.Error 'installs'
            Assert-Equal 'vulkan-1.dll,VulkanRT-License.txt' ((Get-ChildItem -LiteralPath $r.Pins.InstallDir -File | Sort-Object Name).Name -join ',') 'installed files'
            Assert-Equal $script:VkPeHash (Get-FileHash -LiteralPath (Join-Path $r.Pins.InstallDir 'vulkan-1.dll')).Hash 'the x64 loader bytes'
            Assert-Equal $script:VkPeHash $r.SystemHash 'System32 holds the same loader'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $r.Pins.TempDir -File).Count 'the zip is gone'
        }
    }

    It 'keeps an identical System32 loader and refuses a foreign one without overwriting it' {
        Invoke-InTestDir { param($dir)
            Assert-Null (Invoke-VulkanInstallFixture -Root (Join-Path $dir 'same') -SystemCopy $script:VkPe).Error 'a rerun over its own copy'
            $foreign = Join-Path $dir 'foreign.dll'
            Set-Content -LiteralPath $foreign -Value 'a driver''s loader'
            $r = Invoke-VulkanInstallFixture -Root (Join-Path $dir 'other') -SystemCopy $foreign
            Assert-Match 'vulkan-1\.dll already exists with other bytes' "$($r.Error)" 'refused'
            Assert-Equal (Get-FileHash -LiteralPath $foreign).Hash $r.SystemHash 'the foreign copy is untouched'
        }
    }

    It 'refuses a zip that does not match VULKAN_RT_WINDOWS_ZIP_SHA256, installing nothing' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-VulkanInstallFixture -Root $dir -Override @{ ZipSha256 = ('ab' * 32) }
            Assert-Match 'SHA256 mismatch' "$($r.Error)" 'the pin is checked'
            Assert-False (Test-Path -LiteralPath $r.Pins.InstallDir) 'nothing installed'
            Assert-Null $r.SystemHash 'nothing in System32'
        }
    }

    It 'refuses before any download: arm64, a malformed pin, a malformed version' {
        foreach ($c in @(
                @{ O = @{ TargetArch = 'arm64' }; P = "x64 loader only; got -TargetArch 'arm64'" },
                @{ O = @{ ZipSha256 = 'abc' }; P = "VULKAN_RT_WINDOWS_ZIP_SHA256 must be a 64-hex SHA256.*got 'abc'" },
                @{ O = @{ ZipSha256 = '' }; P = 'VULKAN_RT_WINDOWS_ZIP_SHA256 must be a 64-hex' },
                @{ O = @{ VulkanVersion = '1.4' }; P = 'four-part LunarG SDK version' })) {
            Invoke-InTestDir { param($dir)
                $r = Invoke-VulkanInstallFixture -Root $dir -Override $c.O
                Assert-Match $c.P "$($r.Error)" "error for $($c.P)"
                Assert-False (Test-Path -LiteralPath $r.Pins.TempDir) "no download started for $($c.P)"
                Assert-False (Test-Path -LiteralPath $r.Pins.InstallDir) "nothing installed for $($c.P)"
                Assert-Null $r.SystemHash "nothing in System32 for $($c.P)"
            }
        }
    }

    It 'refuses a loader whose version is not VULKAN_VERSION' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-VulkanInstallFixture -Root $dir -Override @{ VulkanVersion = '1.4.357.0' }
            Assert-Match "reports version '$([regex]::Escape($script:VkPeVersion))', expected VULKAN_VERSION '1\.4\.357\.0'" "$($r.Error)" 'version gate'
            Assert-Null $r.SystemHash 'a wrong loader never reaches System32'
        }
    }
}

Describe 'Dockerfile.rocm: the Vulkan loader layer, rocm lane only' {
    $root = Get-RepoRoot
    $df = Get-Content -Raw (Join-Path $root 'windows\Dockerfile.rocm')
    $driver = Get-Content -Raw (Join-Path $root 'windows\Build-Buildkit.ps1')
    $pins = ConvertFrom-VersionsEnv -Path (Join-Path $root 'linux\scripts\01-core\versions.env')

    It 'declares the loader pins after the ROCm RUN (a Vulkan bump keeps the tarball layer) with versions.env defaults' {
        $rocmRun = $df.IndexOf("RUN & 'C:\temp\scripts\Install-Rocm.ps1'")
        $vkRun = $df.IndexOf("RUN & 'C:\temp\scripts\Install-VulkanLoader.ps1'")
        Assert-True ($rocmRun -ge 0 -and $vkRun -gt $rocmRun) 'the loader RUN follows the ROCm RUN'
        foreach ($k in 'VULKAN_VERSION', 'VULKAN_RT_WINDOWS_ZIP_SHA256') {
            $m = [regex]::Match($df, "(?m)^ARG $k=(\S+)\s*$")
            Assert-True $m.Success "ARG $k declared"
            Assert-True ($m.Index -gt $rocmRun -and $m.Index -lt $vkRun) "ARG $k sits between the two RUNs"
            Assert-Equal $pins[$k] $m.Groups[1].Value "ARG $k default = versions.env"
        }
    }

    It 'names the pinned copy''s directory in VULKAN_LOADER_DIR and keeps it off PATH: the loaded copy is System32''s' {
        $dir = [regex]::Match($df, "Install-VulkanLoader\.ps1' -TempDir \`$env:TEMP_DIR -InstallDir '([^']+)'(.*)").Groups
        Assert-Equal 'C:\vulkan-loader' $dir[1].Value 'install dir'
        Assert-Equal '' $dir[2].Value.Trim() 'no -SystemDir override: the script''s default is the real System32'
        Assert-Match ('(?m)^\s+VULKAN_LOADER_DIR="' + [regex]::Escape($dir[1].Value) + '" `') $df 'VULKAN_LOADER_DIR'
        Assert-Equal '${PATH};C:\TheRock\build\bin' ([regex]::Match($df, '(?m)\bPATH="([^"]*)"').Groups[1].Value) 'PATH as before the loader'
        $src = Get-Content -Raw (Join-Path $root 'windows\scripts\host\Install-VulkanLoader.ps1')
        Assert-Equal 2 ([regex]::Matches($src, '\[string\]\$SystemDir = \[System\.Environment\]::SystemDirectory')).Count 'script and function default to System32'
    }

    It 'names the shipped loader in a Windows deps.json row with an spdx id, which the licence page and SBOM render' {
        $deps = Get-Content -LiteralPath (Join-Path $root 'docs\deps\deps.json') -Raw | ConvertFrom-Json
        $rows = @(@($deps.sections | Where-Object { $_.title -eq 'Windows Image' }).subsections.entries |
                Where-Object { $_.PSObject.Properties['spdx'] -and $_.spdx -and $_.name -match 'vulkan-1\.dll' })
        Assert-Equal 1 $rows.Count 'one Windows row names vulkan-1.dll'
        Assert-Equal 'VULKAN_VERSION' "$($rows[0].var)" 'versioned by the pin that selects the zip'
        Assert-Match '^Apache-2\.0 AND MIT$' "$($rows[0].spdx)" 'VulkanRT-License.txt: MIT and Apache 2.0'
    }

    It 'gets every versions.env pin it declares from the driver''s rocm sdk branch, under its own name' {
        $at = $driver.IndexOf("Invoke-BkStage -Dockerfile 'windows/Dockerfile.rocm'")
        Assert-True ($at -ge 0) 'rocm sdk stage found'
        $block = $driver.Substring($at, $driver.IndexOf('}', $at) - $at)
        $sent = @([regex]::Matches($block, "(?m)^\s*(\w+)\s*= Get-Ver '(\w+)'") | ForEach-Object {
                Assert-Equal $_.Groups[1].Value $_.Groups[2].Value 'build-arg = versions.env key'
                $_.Groups[1].Value })
        $declared = @([regex]::Matches($df, '(?m)^ARG (\w+)=') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $pins.Contains($_) })
        Assert-Equal (($declared | Sort-Object) -join ',') (($sent | Sort-Object) -join ',') 'sent = declared'
    }

    It 'leaves cpu and nvidia untouched: only Dockerfile.rocm and the driver''s rocm branch know the loader' {
        $hits = @(Get-ChildItem -LiteralPath (Join-Path $root 'windows') -Filter 'Dockerfile*' -File |
                Where-Object { (Get-Content -Raw $_.FullName) -match 'Install-VulkanLoader|vulkan-loader|VULKAN_RT_WINDOWS_ZIP_SHA256|VULKAN_LOADER_DIR' } | ForEach-Object Name)
        Assert-Equal 'Dockerfile.rocm' ($hits -join ',') 'Dockerfiles that ship the loader'
        Assert-Equal 1 ([regex]::Matches($driver, 'VULKAN_RT_WINDOWS_ZIP_SHA256\s*= Get-Ver')).Count 'the driver sends the pin once'
        $rocmBranch = [regex]::Match($driver, "(?s)\} elseif \(\`$Variant -eq 'rocm'\) \{\s+#[^\r\n]*\s+Invoke-BkStage -Dockerfile 'windows/Dockerfile\.rocm'.+?\n\s+\}").Value
        Assert-Match 'VULKAN_RT_WINDOWS_ZIP_SHA256 = Get-Ver' $rocmBranch 'and only in the rocm sdk branch'
    }
}
