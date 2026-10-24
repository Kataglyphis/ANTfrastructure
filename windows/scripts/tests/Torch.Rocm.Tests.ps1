#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Torch ROCm fixture setup is shared by installer, smoke and Dockerfile contracts.

. (Join-Path $PSScriptRoot 'Import-TorchRocmTestSetup.ps1')

Describe 'Install-TorchRocm: lane gate (cpu and nvidia unchanged)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName 'Test-TorchRocmLane')

    It 'TORCH_ROCM unset or 0 is a no-op on every lane' {
        foreach ($gpu in @('', 'cpu', 'nvidia', 'rocm')) {
            foreach ($value in @('', '0')) {
                Assert-False (Test-TorchRocmLane -TorchRocm $value -GpuType $gpu) "TORCH_ROCM='$value' GPU_TYPE='$gpu'"
            }
        }
    }

    It 'TORCH_ROCM=1 on the rocm sdk layer installs' {
        Assert-True (Test-TorchRocmLane -TorchRocm '1' -GpuType 'rocm') 'rocm lane'
    }

    It 'TORCH_ROCM=1 off the rocm lane throws instead of putting ROCm torch into a cpu/nvidia image' {
        foreach ($gpu in @('', 'cpu', 'nvidia')) {
            Assert-Throws { Test-TorchRocmLane -TorchRocm '1' -GpuType $gpu } "GPU_TYPE '$gpu'" -MessagePattern 'GPU_TYPE'
        }
    }

    It 'anything but 0 or 1 throws rather than silently meaning cpu' {
        foreach ($bad in @('true', 'yes', '2', 'on', 'rocm')) {
            Assert-Throws { Test-TorchRocmLane -TorchRocm $bad -GpuType 'rocm' } "TORCH_ROCM '$bad'" -MessagePattern "'0' or '1'"
        }
    }

    It 'the script is a no-op with TORCH_ROCM=0, before it imports or touches anything' {
        Invoke-InTestScriptDir -ScriptPath $script:TorchRocmScript -Body { param($dir, $script)
            $cache = Join-Path $dir 'cache'
            $out = Invoke-WithEnv @{ GPU_TYPE = 'nvidia'; TORCH_ROCM = $null } {
                & pwsh -NoProfile -NonInteractive -File $script -TorchRocm '0' -AppDir (Join-Path $dir 'no-app') -WheelCache $cache 2>&1 | Out-String
            }
            Assert-Equal 0 $LASTEXITCODE "no-op exit code; output: $out"
            Assert-Match 'keeps its torch' $out 'no-op message'
            Assert-False (Test-Path $cache) 'the no-op must not create the wheel cache'
        }
    }
}

Describe 'Install-TorchRocm: pinned set (versions.env)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName $script:TorchRocmSetFunction)

    It 'versions.env carries one URL and one SHA256 key per pin name, plus the two source commits' {
        $pins = Get-TorchRocmTestPin
        $names = @((Get-TorchRocmPinMap).Keys)
        $expected = @(@($names | ForEach-Object { "TORCH_ROCM_WINDOWS_${_}_URL"; "TORCH_ROCM_WINDOWS_${_}_SHA256" }) +
            'TORCH_ROCM_WINDOWS_PYTORCH_COMMIT', 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT' | Sort-Object)
        $actual = @($pins.Keys | Where-Object { $_ -like 'TORCH_ROCM_WINDOWS_*' } | Sort-Object)
        Assert-Equal ($expected -join ',') ($actual -join ',') 'TORCH_ROCM_WINDOWS_* keys'
        foreach ($k in 'TORCH_ROCM_WINDOWS_PYTORCH_COMMIT', 'TORCH_ROCM_WINDOWS_TORCHVISION_COMMIT') { Assert-Match '^[0-9a-f]{40}$' $pins[$k] $k }
    }

    It 'the real pins parse, stay on AMD''s repo and name both GPUs of the gfx120X family, gfx1201 first' {
        $set = Get-TorchRocmTestSet
        $pins = $set.Pins
        Assert-Equal 5 $set.Wheels.Count 'pinned AMD runtime files'
        Assert-Equal 'gfx1201' $set.GfxTarget 'the GPU ROCM_SDK_TARGET_FAMILY names'
        Assert-Equal 'gfx1201,gfx1200' ($set.GfxTargets -join ',') 'GPU targets, in pin order'
        $byDist = @{}; foreach ($w in $set.Wheels) { $byDist[$w.Distribution] = $w }
        foreach ($dist in 'rocm-sdk-core', 'rocm-sdk-libraries', 'rocm-sdk-device-gfx1200', 'rocm-sdk-device-gfx1201') {
            Assert-Equal $pins['ROCM_WINDOWS_RELEASE'] $byDist[$dist].Version $dist
        }
        Assert-True $byDist['rocm'].IsSdist 'rocm ships only as an sdist'
    }

    It 'no torch or torchvision wheel is pinned any more: both are built from source' {
        $pins = Get-TorchRocmTestPin
        $gone = @($pins.Keys | Where-Object { $_ -match '^TORCH_ROCM_WINDOWS_(TORCH|TORCHVISION|BOOTSTRAP|TORCH_DEVICE\w*|TORCHVISION_DEVICE\w*)_(URL|SHA256)$' })
        Assert-Equal '' ($gone -join ',') 'AMD torch pins left in versions.env'
        Assert-Equal '' (@((Get-TorchRocmPinMap).Values | Where-Object { $_ -match '^(torch|torchvision)$' }) -join ',') 'pin map'
    }

    It 'no cp wheel is pinned: the built torch/torchvision are held to the venv at install, ai-edge-litert comes from the chain (CON91)' {
        $cp = @((Get-TorchRocmTestSet).Wheels | Where-Object { $_.PythonTag -like 'cp*' })
        Assert-Equal '' (($cp | ForEach-Object { $_.FileName }) -join ',') 'cp wheels pinned'
    }

    It 'no prebuilt ORT EP and no PyPI extra is pinned (owner rule 2026-09-23: the chain ORT builds its WebGPU EP; CON91)' {
        $pins = Get-TorchRocmTestPin
        Assert-NoTorchRocmPinKeys -Pins $pins -Pattern 'ORT_EP|EP_WEBGPU|^TORCH_ROCM_WINDOWS_AI_EDGE' -Message 'versions.env keys'
        Assert-False ((Get-TorchDockerfileText) -match 'onnxruntime[_-]ep|ai_edge_litert') 'Dockerfile.torch'
    }

    It 'reports a forbidden pin key instead of passing an empty verdict' {
        Assert-Throws { Assert-NoTorchRocmPinKeys -Pins @{ ORT_EP = 'present' } -Pattern '^ORT_EP$' -Message 'forbidden pin' } -MessagePattern 'ORT_EP'
    }

    It 'the GPU targets belong to ROCM_WINDOWS_GFX_FAMILY, the tarball the sdk layer installs' {
        $set = Get-TorchRocmTestSet
        $familyPrefix = $set.Pins['ROCM_WINDOWS_GFX_FAMILY'] -replace 'X-.*$', ''
        foreach ($gfx in $set.GfxTargets) { Assert-True ($gfx.StartsWith($familyPrefix)) "$gfx vs family $($set.Pins['ROCM_WINDOWS_GFX_FAMILY'])" }
    }

    It 'coupling: a ROCM_WINDOWS_RELEASE bump without re-pinning the wheels throws' {
        # Derived from the pins, so the case survives every release bump: the next patch release is the drift.
        $pins = Get-TorchRocmTestPin
        $release = $pins['ROCM_WINDOWS_RELEASE']
        $parts = $release -split '\.'
        $next = '{0}.{1}.{2}' -f $parts[0], $parts[1], ([int]$parts[2] + 1)
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release $next } 'release drift' -MessagePattern ('ROCM_WINDOWS_RELEASE=' + [regex]::Escape($next))
        $pins['TORCH_ROCM_WINDOWS_SDK_CORE_URL'] = $pins['TORCH_ROCM_WINDOWS_SDK_CORE_URL'] -replace [regex]::Escape($release), $next
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release $release } 'one file drifted' -MessagePattern 'SDK_CORE_URL'
        $pins = Get-TorchRocmTestPin
        $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL'] = $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL'] -replace [regex]::Escape($release), $next
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release $release } 'the second GPU drifted' -MessagePattern 'SDK_DEVICE_GFX1200_URL'
    }

    It 'refuses a bad release, a bad SHA256, a URL off AMD''s repo, swapped keys and a non-Windows wheel' {
        $core = 'https://stable.repo.amd.com/rocm/core/whl-next'
        Assert-TorchRocmPinRefusal -Resolve { param($Pins, $Release) Get-TorchRocmWheelSet -Pins $Pins -Release $Release } -Case @(
                @{ Release = ''; P = 'x\.y\.z' }
                @{ Release = '10.0'; P = 'x\.y\.z' }
                @{ Release = 'v10.0.0'; P = 'x\.y\.z' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_SHA256'; Value = ''; P = 'SDK_CORE_SHA256' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_SHA256'; Value = 'abc'; P = 'SDK_CORE_SHA256' }
                @{ Key = 'TORCH_ROCM_WINDOWS_ROCM_URL'; Value = ''; P = 'ROCM_URL' }
                @{ Key = 'TORCH_ROCM_WINDOWS_ROCM_URL'; Value = "https://pypi.org/packages/rocm-$($script:TorchRocmRelease).tar.gz"; P = 'stable\.repo\.amd\.com' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_URL'; Value = "http://stable.repo.amd.com/rocm/core/whl-next/rocm-sdk-core/rocm_sdk_core-$($script:TorchRocmRelease)-py3-none-win_amd64.whl"; P = 'stable\.repo\.amd\.com' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_CORE_URL'; Value = "$core/rocm-sdk-libraries/rocm_sdk_libraries-$($script:TorchRocmRelease)-py3-none-win_amd64.whl"; P = 'expected rocm-sdk-core' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_DEVICE_URL'; Value = "$core/rocm-sdk-device-gfx1201/rocm_sdk_device_gfx1201-$($script:TorchRocmRelease)-py3-none-manylinux_2_28_x86_64.whl"; P = 'win_amd64' }
                @{ Key = 'TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL'; Value = "$core/rocm-sdk-device-gfx1201/rocm_sdk_device_gfx1201-$($script:TorchRocmRelease)-py3-none-win_amd64.whl"; P = 'SDK_DEVICE_GFX1200_URL names rocm-sdk-device-gfx1201, expected rocm-sdk-device-gfx1200' })
    }

    It 'one GPU pinned twice, a device pin with no SDK_DEVICE pin, and no device pin at all are refused' {
        $pins = Get-TorchRocmTestPin
        $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_URL'] = $pins['TORCH_ROCM_WINDOWS_SDK_DEVICE_GFX1200_URL']
        Assert-Throws { Get-TorchRocmWheelSet -Pins $pins -Release $pins['ROCM_WINDOWS_RELEASE'] } 'gfx1200 twice' -MessagePattern 'pins gfx1200 a second time'
        $set = Get-TorchRocmTestSet
        $byName = [ordered]@{}
        foreach ($w in $set.Wheels) { $byName[$w.Name] = $w }
        $byName['EXTRA_DEVICE'] = $set.Wheels[0]
        Assert-Throws { Get-TorchRocmGpuTarget -ByName $byName } 'orphaned device pin' -MessagePattern 'no SDK_DEVICE pin.*EXTRA_DEVICE'
        $none = [ordered]@{}
        foreach ($w in $set.Wheels) { if ($w.Name -notlike 'SDK_DEVICE*') { $none[$w.Name] = $w } }
        Assert-Throws { Get-TorchRocmGpuTarget -ByName $none } 'no device pins' -MessagePattern 'no TORCH_ROCM_WINDOWS_SDK_DEVICE pin'
    }
}

Describe 'Install-TorchRocm: the source-built wheels (torch-rocm-wheels stage)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName $script:TorchRocmSetFunction)

    It 'reads exactly the torch and torchvision wheels, with their own SHA256 and path' {
        Invoke-InTestDir { param($dir)
            $wd = New-TorchRocmBuiltWheelDir -Dir $dir
            $built = @(Get-TorchRocmBuiltWheel -WheelDir $wd -Release $script:TorchRocmRelease)
            Assert-Equal 'torch,torchvision' (($built | ForEach-Object Distribution) -join ',') 'torch first, then torchvision'
            Assert-Equal "2.14.0+rocm$($script:TorchRocmRelease),0.29.0+rocm$($script:TorchRocmRelease)" (($built | ForEach-Object Version) -join ',') 'versions'
            foreach ($w in $built) {
                Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $w.LocalPath).Hash.ToLowerInvariant() $w.Sha256 "$($w.FileName) hash"
                Assert-True (Test-Path -LiteralPath $w.LocalPath -PathType Leaf) "$($w.FileName) path"
            }
        }
    }

    It 'refuses a missing directory, a stray file, a second torch, another platform, another ROCm and a missing torchvision' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Get-TorchRocmBuiltWheel -WheelDir (Join-Path $dir 'none') -Release $script:TorchRocmRelease } 'no dir' -MessagePattern 'no source-built wheels'
            $i = 0
            foreach ($c in @(
                    @{ N = $script:TorchRocmBuiltName + 'numpy-2.3.0-cp314-cp314-win_amd64.whl'; P = 'only the torch and torchvision wheels' }
                    @{ N = $script:TorchRocmBuiltName + "torch-2.14.0+rocm$($script:TorchRocmRelease)-cp313-cp313-win_amd64.whl"; P = 'two torch wheels' }
                    @{ N = @("torch-2.14.0+rocm$($script:TorchRocmRelease)-cp314-cp314-linux_x86_64.whl", $script:TorchRocmBuiltName[1]); P = 'linux_x86_64 wheel' }
                    @{ N = @('torch-2.14.0+rocm9.9.9-cp314-cp314-win_amd64.whl', $script:TorchRocmBuiltName[1]); P = "not a '\+rocm$([regex]::Escape($script:TorchRocmRelease))' build" }
                    @{ N = @($script:TorchRocmBuiltName[0]); P = 'has no torchvision wheel' })) {
                $wd = New-TorchRocmBuiltWheelDir -Dir (Join-Path $dir "case$i") -Name $c.N
                Assert-Throws { Get-TorchRocmBuiltWheel -WheelDir $wd -Release $script:TorchRocmRelease } "case $i" -MessagePattern $c.P
                $i++
            }
        }
    }
}


Describe 'Install-TorchRocm: the wheels must fit the app venv' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName ($script:TorchRocmSetFunction + 'Assert-TorchRocmVenvMatch'))
    $testSet = Get-TorchRocmTestSet
    $script:TorchRocmWheels = @(Get-TorchRocmBuiltWheelFact) + @($testSet.Wheels)
    function New-TorchRocmVenvFact { param([hashtable]$Override = @{})
        $v = @{ tag = $script:TorchRocmVenvTag; torch = '2.14.0+cpu'; torchvision = '0.29.0+cpu'; setuptools = '83.0.0' }
        foreach ($k in $Override.Keys) { $v[$k] = $Override[$k] }
        return $v
    }

    It 'accepts the venv uv sync builds today (the pinned cpXY, the app lock''s torch 2.14.0 / torchvision 0.29.0)' {
        Assert-TorchRocmVenvMatch -Wheels $script:TorchRocmWheels -Venv (New-TorchRocmVenvFact)
        Assert-True $true 'no throw'
    }

    It 'refuses another interpreter, another app torch, no torch and no setuptools' {
        foreach ($case in @(
                @{ O = @{ tag = 'cp313' }; P = 'cp313' }
                @{ O = @{ tag = "$($script:TorchRocmVenvTag)t" }; P = "$($script:TorchRocmVenvTag)t" }
                @{ O = @{ torch = '2.13.0+cpu' }; P = 'PYTORCH_VERSION/TORCHVISION_VERSION' }
                @{ O = @{ torchvision = '0.28.0' }; P = 'the ROCm build is 0\.29\.0' }
                @{ O = @{ torch = '' }; P = 'PYTORCH_EXTRA' }
                @{ O = @{ setuptools = '' }; P = 'setuptools' })) {
            Assert-Throws { Assert-TorchRocmVenvMatch -Wheels $script:TorchRocmWheels -Venv (New-TorchRocmVenvFact -Override $case.O) } `
                ($case.O | ConvertTo-Json -Compress) -MessagePattern $case.P
        }
    }

}

Describe 'Install-TorchRocm: rocBLAS GPU coverage and the chain onnxruntime' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchRocmScript -FunctionName ($script:TorchRocmSetFunction + 'Assert-TorchRocmGpuCoverage', 'Assert-TorchRocmOrtUnchanged'))

    It 'the real pins cover the GPUs the gfx120X-all rocBLAS serves (gfx1200, gfx1201)' {
        Assert-TorchRocmGpuCoverage -GfxTarget (Get-TorchRocmTestSet).GfxTargets -RocmGpu @('gfx1200', 'gfx1201')
        Assert-True $true 'no throw'
    }

    It 'a GPU rocBLAS serves without device pins throws, and so does an empty rocBLAS set' {
        Assert-Throws { Assert-TorchRocmGpuCoverage -GfxTarget @('gfx1201') -RocmGpu @('gfx1200', 'gfx1201') } 'gfx1201 only (the old pin set)' -MessagePattern 'serves gfx1200, the device pins cover only gfx1201'
        Assert-Throws { Assert-TorchRocmGpuCoverage -GfxTarget @('gfx1201', 'gfx1200') -RocmGpu @() } 'no rocBLAS GPU' -MessagePattern 'names no GPU'
    }

    It 'more pinned GPUs than rocBLAS serves is fine: the rocm-sdk wheels carry their own ROCm runtime' {
        Assert-TorchRocmGpuCoverage -GfxTarget @('gfx1201', 'gfx1200', 'gfx1036') -RocmGpu @('gfx1201')
        Assert-True $true 'no throw'
    }

    It 'the install must leave the chain onnxruntime exactly as it found it' {
        Assert-TorchRocmOrtUnchanged -Before 'abc' -After 'abc'
        Assert-Throws { Assert-TorchRocmOrtUnchanged -Before 'abc' -After 'def' } 'replaced' -MessagePattern 'replaced the venv''s onnxruntime'
        Assert-Throws { Assert-TorchRocmOrtUnchanged -Before 'abc' -After '' } 'uninstalled' -MessagePattern 'replaced the venv''s onnxruntime'
        Assert-Throws { Assert-TorchRocmOrtUnchanged -Before '' -After '' } 'never there' -MessagePattern 'has no onnxruntime'
    }
}
