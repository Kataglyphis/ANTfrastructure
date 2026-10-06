#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The dependency plan comes from VVL's own known_good.json, so a tag bump can drop or add a repo under us.

Describe 'Build-VulkanValidationLayers: the dependency plan' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-VulkanValidationLayers.ps1' -FunctionName 'Get-VvlDependencyPlan')
        # The vulkan-sdk-1.4.357.0 file, cut to the fields the plan reads.
        $script:knownGood = @'
{
  "repos": [
    { "name": "Vulkan-Headers", "url": "https://github.com/KhronosGroup/Vulkan-Headers.git", "sub_dir": "Vulkan-Headers", "commit": "v1.4.357" },
    { "name": "Vulkan-Utility-Libraries", "url": "https://github.com/KhronosGroup/Vulkan-Utility-Libraries.git", "sub_dir": "Vulkan-Utility-Libraries", "commit": "v1.4.357" },
    { "name": "SPIRV-Headers", "url": "https://github.com/KhronosGroup/SPIRV-Headers.git", "sub_dir": "SPIRV-Headers", "commit": "29981f65241605e08b0ede4cfeb999fe3b723c6a" },
    { "name": "SPIRV-Tools", "url": "https://github.com/KhronosGroup/SPIRV-Tools.git", "sub_dir": "SPIRV-Tools",
      "cmake_options": ["-DSPIRV-Headers_SOURCE_DIR={repo_dir}/../SPIRV-Headers", "-DSPIRV_WERROR=OFF", "-DSPIRV_SKIP_TESTS=ON", "-DSPIRV_SKIP_EXECUTABLES=OFF"],
      "commit": "b707790a898e44038547df54580022fc1cf89c3d" },
    { "name": "mimalloc", "url": "https://github.com/microsoft/mimalloc.git", "sub_dir": "mimalloc",
      "cmake_options": ["-DMI_BUILD_STATIC=ON", "-DMI_BUILD_SHARED=OFF"], "commit": "v3.3.2", "build_platforms": ["windows"] },
    { "name": "googletest", "url": "https://github.com/google/googletest.git", "sub_dir": "googletest", "commit": "v1.14.0", "optional": ["tests"] },
    { "name": "slang", "url": "https://github.com/shader-slang/slang.git", "sub_dir": "slang", "commit": "v2026.1", "optional": ["tests"], "build_platforms": ["linux", "macos", "windows"] },
    { "name": "linux-only", "url": "https://example.invalid/x.git", "sub_dir": "x", "commit": "v1", "build_platforms": ["linux"] }
  ]
}
'@
    }

    It 'keeps the five build repos in file order and drops tests-only and non-Windows ones' {
        $plan = Get-VvlDependencyPlan -KnownGoodJson $script:knownGood -WorkDir 'C:\temp\vvl'
        Assert-Equal 'Vulkan-Headers,Vulkan-Utility-Libraries,SPIRV-Headers,SPIRV-Tools,mimalloc' (($plan | ForEach-Object Name) -join ',') 'repos in order'
        Assert-Equal 'b707790a898e44038547df54580022fc1cf89c3d' $plan[3].Commit 'SPIRV-Tools commit'
        Assert-Equal 'C:\temp\vvl\SPIRV-Tools' $plan[3].SourceDir 'checkout under the work dir'
    }

    It 'expands {repo_dir} with forward slashes and skips the SPIRV-Tools executables last' {
        $tools = (Get-VvlDependencyPlan -KnownGoodJson $script:knownGood -WorkDir 'C:\temp\vvl')[3]
        Assert-Equal '-DSPIRV-Headers_SOURCE_DIR=C:/temp/vvl/SPIRV-Tools/../SPIRV-Headers' $tools.CmakeOptions[0] 'repo_dir expanded'
        Assert-Equal '-DSPIRV_SKIP_EXECUTABLES=ON' $tools.CmakeOptions[-1] 'the override comes after the file''s OFF'
    }

    It 'refuses a file that lost a needed repo or a commit' {
        $cases = @(
            @{ Find = '"name": "SPIRV-Tools"'; Into = '"name": "SPIRV-Tools-renamed"'; Pattern = 'names no SPIRV-Tools' },
            @{ Find = '"commit": "v3.3.2"'; Into = '"commit": ""'; Pattern = 'mimalloc has no commit' }
        )
        foreach ($case in $cases) {
            $broken = $script:knownGood.Replace($case.Find, $case.Into)
            Assert-Throws { Get-VvlDependencyPlan -KnownGoodJson $broken -WorkDir 'C:\temp\vvl' } $case.Pattern -MessagePattern $case.Pattern
        }
    }
}

Describe 'Build-VulkanValidationLayers: the layer manifest' {

    BeforeAll {
        . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\build\Build-VulkanValidationLayers.ps1' -FunctionName 'Assert-ValidationLayerManifest')
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) ('vvl-manifest-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:dir | Out-Null
        $script:written = 0
        function New-Manifest([string]$Name, [string]$Library) {
            $script:written++
            $path = Join-Path $script:dir "layer-$($script:written).json"
            @{ file_format_version = '1.2.0'; layer = @{ name = $Name; library_path = $Library } } | ConvertTo-Json | Set-Content -LiteralPath $path
            return $path
        }
    }

    AfterAll { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'accepts the layer with its DLL beside it' {
        Assert-ValidationLayerManifest -Path (New-Manifest 'VK_LAYER_KHRONOS_validation' '.\VkLayer_khronos_validation.dll')
    }

    It 'refuses another layer or a library elsewhere' {
        Assert-Throws { Assert-ValidationLayerManifest -Path (New-Manifest 'VK_LAYER_LUNARG_api_dump' '.\VkLayer_khronos_validation.dll') } 'another layer' -MessagePattern 'names layer'
        Assert-Throws { Assert-ValidationLayerManifest -Path (New-Manifest 'VK_LAYER_KHRONOS_validation' 'C:\sdk\VkLayer_khronos_validation.dll') } 'an absolute library' -MessagePattern 'library_path'
    }
}
