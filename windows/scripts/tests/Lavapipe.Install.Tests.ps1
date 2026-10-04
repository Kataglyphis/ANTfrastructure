#requires -Version 7.0
# Install-Lavapipe: the URL builders, the arch->pin mapping and the loader-zip layout; no downloads.

Describe 'Install-Lavapipe: the mmozeiko release asset' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Lavapipe.ps1' -FunctionName 'Get-LavapipeWindowsUrl')

    It 'builds the arch-suffixed asset URL' {
        Assert-Equal 'https://github.com/mmozeiko/build-mesa/releases/download/26.2.3/mesa-lavapipe-x64-26.2.3.7z' `
            (Get-LavapipeWindowsUrl -Version '26.2.3' -Arch 'amd64') 'x64 URL'
        Assert-Equal 'https://github.com/mmozeiko/build-mesa/releases/download/26.2.3/mesa-lavapipe-arm64-26.2.3.7z' `
            (Get-LavapipeWindowsUrl -Version '26.2.3' -Arch 'arm64') 'arm64 URL'
    }

    It 'refuses a version that is not x.y.z' {
        foreach ($bad in @('', '26.2', 'v26.2.3', '26.2.3.1')) {
            Assert-Throws { Get-LavapipeWindowsUrl -Version $bad -Arch 'amd64' } "version '$bad'" -MessagePattern 'LAVAPIPE_VERSION'
        }
    }
}

Describe 'Install-Lavapipe: the LunarG loader zip' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Lavapipe.ps1' -FunctionName 'Get-VulkanRuntimeComponentsUrl')

    It 'builds the x64 URL under windows/ and the arm64 one under warm/' {
        Assert-Equal 'https://sdk.lunarg.com/sdk/download/1.4.357.0/windows/VulkanRT-X64-1.4.357.0-Components.zip' `
            (Get-VulkanRuntimeComponentsUrl -Version '1.4.357.0' -Arch 'amd64') 'x64 URL'
        Assert-Equal 'https://sdk.lunarg.com/sdk/download/1.4.357.0/warm/VulkanRT-ARM64-1.4.357.0-Components.zip' `
            (Get-VulkanRuntimeComponentsUrl -Version '1.4.357.0' -Arch 'arm64') 'arm64 URL'
    }

    It 'refuses a version that is not four-part' {
        foreach ($bad in @('', '1.4.357', 'v1.4.357.0')) {
            Assert-Throws { Get-VulkanRuntimeComponentsUrl -Version $bad -Arch 'amd64' } "version '$bad'" -MessagePattern 'VULKAN_VERSION'
        }
    }
}

Describe 'Install-Lavapipe: the versions.env pin names' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Lavapipe.ps1' -FunctionName 'Get-LavapipePinName')

    It 'maps each arch and kind to its versions.env key' {
        Assert-Equal 'LAVAPIPE_WINDOWS_X64_SHA256' (Get-LavapipePinName -Arch 'amd64' -Kind 'mesa') 'amd64 mesa pin'
        Assert-Equal 'LAVAPIPE_WINDOWS_ARM64_SHA256' (Get-LavapipePinName -Arch 'arm64' -Kind 'mesa') 'arm64 mesa pin'
        Assert-Equal 'VULKAN_RT_WINDOWS_ZIP_SHA256' (Get-LavapipePinName -Arch 'amd64' -Kind 'loader') 'amd64 loader pin'
        Assert-Equal 'VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256' (Get-LavapipePinName -Arch 'arm64' -Kind 'loader') 'arm64 loader pin'
    }
}

Describe 'Install-Lavapipe: the loader-zip layout' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-Lavapipe.ps1' -FunctionName 'Expand-VulkanRuntimeComponents')

    function New-FakeLoaderZip {
        # The real zips: x64 nests its binaries under x64\ beside an x86\ pair, arm64 keeps them at the root.
        param([string]$Path, [string]$Arch)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Create')
        try {
            if ($Arch -eq 'amd64') {
                $names = @(
                    'VulkanRT-X64-1.4.357.0-Components/x64/vulkan-1.dll',
                    'VulkanRT-X64-1.4.357.0-Components/x64/vulkaninfo.exe',
                    'VulkanRT-X64-1.4.357.0-Components/x86/vulkan-1.dll',
                    'VulkanRT-X64-1.4.357.0-Components/x86/vulkaninfo.exe',
                    'VulkanRT-X64-1.4.357.0-Components/VulkanRT-License.txt')
            } else {
                $names = @(
                    'VulkanRT-ARM64-1.4.357.0-Components/vulkan-1.dll',
                    'VulkanRT-ARM64-1.4.357.0-Components/vulkaninfo.exe',
                    'VulkanRT-ARM64-1.4.357.0-Components/VulkanRT-License.txt')
            }
            foreach ($n in $names) {
                $entry = $zip.CreateEntry($n)
                $stream = $entry.Open()
                $bytes = [System.Text.Encoding]::ASCII.GetBytes("from $n")
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Dispose()
            }
        } finally { $zip.Dispose() }
    }

    It 'flattens the x64 zip without taking the x86 pair' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'rt.zip'
            New-FakeLoaderZip -Path $zip -Arch 'amd64'
            $out = Join-Path $dir 'out'
            Expand-VulkanRuntimeComponents -ZipPath $zip -Destination $out -Arch 'amd64'
            Assert-True (Test-Path (Join-Path $out 'vulkan-1.dll')) 'loader extracted'
            Assert-Equal 'from VulkanRT-X64-1.4.357.0-Components/x64/vulkan-1.dll' (Get-Content (Join-Path $out 'vulkan-1.dll') -Raw) 'the x64 entry won, never x86'
            Assert-True (Test-Path (Join-Path $out 'vulkaninfo.exe')) 'vulkaninfo extracted'
            Assert-True (Test-Path (Join-Path $out 'VulkanRT-License.txt')) 'licence extracted'
        }
    }

    It 'takes the arm64 zip flat at the component root' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'rt.zip'
            New-FakeLoaderZip -Path $zip -Arch 'arm64'
            $out = Join-Path $dir 'out'
            Expand-VulkanRuntimeComponents -ZipPath $zip -Destination $out -Arch 'arm64'
            Assert-Equal 'from VulkanRT-ARM64-1.4.357.0-Components/vulkan-1.dll' (Get-Content (Join-Path $out 'vulkan-1.dll') -Raw) 'the root entry extracted'
        }
    }

    It 'fails loudly when a wanted entry is absent or ambiguous' {
        Invoke-InTestDir { param($dir)
            $zip = Join-Path $dir 'empty.zip'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
            try { $e = $z.CreateEntry('unrelated.txt'); $s = $e.Open(); $s.Dispose() } finally { $z.Dispose() }
            Assert-Throws { Expand-VulkanRuntimeComponents -ZipPath $zip -Destination (Join-Path $dir 'out') -Arch 'arm64' } `
                'no matching entry' -MessagePattern 'expected exactly 1'
        }
    }
}
