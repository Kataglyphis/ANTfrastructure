#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The WebGPU static plugin's configure line and gate; host-portable, so its recipes prove on Linux pwsh, unlike Rocm.OrtWebGpu.Tests.ps1.

Describe 'Build-OnnxFromSource WebGPU static plugin: configure line and gate' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-OnnxFromSource.ps1' -FunctionName 'Get-OrtWebGpuCmakeArgs', 'Get-OrtWebGpuConfigureFinding')

    It 'off the spike the configure line gains nothing; on it, the static plugin and the Dawn switches with forward slashes (mutation)' {
        Assert-Equal 0 @(Get-OrtWebGpuCmakeArgs -Plan ([pscustomobject]@{ OnLane = $true; WebGpu = $false })).Count 'rocm, spike off'
        Assert-Equal 0 @(Get-OrtWebGpuCmakeArgs -Plan ([pscustomobject]@{ OnLane = $false; WebGpu = $false })).Count 'cpu/nvidia'
        $a = @(Get-OrtWebGpuCmakeArgs -Plan ([pscustomobject]@{ OnLane = $true; WebGpu = $true }) -DawnSrc 'C:\w\dawn' -DxcDir 'C:\w\dxc')
        Assert-Equal ('-Donnxruntime_USE_WEBGPU=ON,-Donnxruntime_USE_EP_API_ADAPTERS=ON,-Donnxruntime_WEBGPU_STATIC_PLUGIN=ON,' +
            '-Donnxruntime_ENABLE_DAWN_BACKEND_D3D12=ON,-Donnxruntime_ENABLE_DAWN_BACKEND_VULKAN=OFF,' +
            '-Donnxruntime_CUSTOM_DAWN_SRC_PATH=C:/w/dawn,-DDAWN_PREBUILT_DXC_DIR:PATH=C:/w/dxc') ($a -join ',') 'spike args'
    }

    It 'the configure gate: each switch, the static plugin, the prebuilt-DXC branch and no Dawn self-fetch (mutation)' {
        $cache = "onnxruntime_USE_WEBGPU:BOOL=ON`r`nonnxruntime_USE_EP_API_ADAPTERS:BOOL=ON`r`nonnxruntime_WEBGPU_STATIC_PLUGIN:BOOL=ON`r`n" +
            "DAWN_FETCH_DEPENDENCIES:BOOL=OFF`r`nDAWN_USE_BUILT_DXC:BOOL=ON`r`nDAWN_ENABLE_D3D12:BOOL=ON`r`nDAWN_ENABLE_VULKAN:BOOL=OFF`r`n"
        $log = "-- Dawn: prebuilt DXC from C:/w/dxc`n"
        Assert-Equal 0 @(Get-OrtWebGpuConfigureFinding -CacheText $cache -LogText $log).Count 'healthy'
        Assert-TestSingleFindingCases -Message 'configure gate' -Cases @(
                @{ C = $cache.Replace('USE_WEBGPU:BOOL=ON', 'USE_WEBGPU:BOOL=OFF'); L = $log; P = 'onnxruntime_USE_WEBGPU=OFF' }
                @{ C = $cache.Replace('USE_EP_API_ADAPTERS:BOOL=ON', 'USE_EP_API_ADAPTERS:BOOL=OFF'); L = $log; P = 'onnxruntime_USE_EP_API_ADAPTERS=OFF' }
                @{ C = $cache.Replace("onnxruntime_WEBGPU_STATIC_PLUGIN:BOOL=ON`r`n", ''); L = $log; P = 'onnxruntime_WEBGPU_STATIC_PLUGIN=<unset>' }
                @{ C = $cache.Replace("DAWN_FETCH_DEPENDENCIES:BOOL=OFF`r`n", ''); L = $log; P = 'DAWN_FETCH_DEPENDENCIES=<unset>' }
                @{ C = $cache.Replace('BUILT_DXC:BOOL=ON', 'BUILT_DXC:BOOL=OFF'); L = $log; P = 'DAWN_USE_BUILT_DXC=OFF' }
                @{ C = $cache.Replace('D3D12:BOOL=ON', 'D3D12:BOOL=OFF'); L = $log; P = 'DAWN_ENABLE_D3D12=OFF' }
                @{ C = $cache.Replace('VULKAN:BOOL=OFF', 'VULKAN:BOOL=ON'); L = $log; P = 'DAWN_ENABLE_VULKAN=ON' }
                @{ C = $cache; L = ''; P = 'prebuilt-DXC branch' }
                @{ C = $cache; L = $log + "-- Running fetch_dawn_dependencies:`n"; P = 'fetch_dawn_dependencies' }
        ) -Exercise { param($c) Get-OrtWebGpuConfigureFinding -CacheText $c.C -LogText $c.L }
    }
}
