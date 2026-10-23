#requires -Version 7.0
# Faked downloads and extractors verify pin forwarding and ordering; PE bytes, registry writes and real upstream archives stay separately gated.

function Invoke-LavapipeAcquisitionFixture {
    param([scriptblock]$Body = { param($state) Assert-LavapipeAcquisition $state }, [string]$Find = '', [string]$Replace = '', [string]$Expected = '')
    $state = New-TestCallState @{ Failure = ''; DownloadContent = 'pinned archive'; Download = {
        param($record, $state)
        $record.Kind = if ($record.Url -like '*.7z') { 'mesa-fetch' } else { 'loader-fetch' }
        if ($state.Failure -eq $record.Kind) { throw "fixture $($record.Kind) failed" }
    } }
    $prelude = (Get-TestDownloadPrelude) + [Environment]::NewLine + @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Expand-LavapipeArchive {
    param($ArchivePath, $Destination)
    $State.Calls.Add(@{ Kind = 'mesa-expand'; Path = $ArchivePath; Destination = $Destination })
    if ($State.Failure -eq 'mesa-expand') { throw 'fixture mesa-expand failed' }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($file in @('lvp_icd.x86_64.json', 'lvp_icd.aarch64.json', 'vulkan_lvp.dll')) {
        Set-Content -LiteralPath (Join-Path $Destination $file) -Value x -Encoding ASCII
    }
}
function Expand-VulkanRuntimeComponents {
    param($ZipPath, $Destination, $BinPrefix, $BinNames)
    $State.Calls.Add(@{ Kind = 'loader-expand'; Path = $ZipPath; Destination = $Destination; Prefix = $BinPrefix; Names = $BinNames })
    if ($State.Failure -eq 'loader-expand') { throw 'fixture loader-expand failed' }
    foreach ($file in $BinNames) { Set-Content -LiteralPath (Join-Path $Destination $file) -Value x -Encoding ASCII }
}
'@
    $module = @{ ScriptPath = 'windows/scripts/modules/WindowsContainerImage.Common.psm1'; Prelude = $prelude; FixtureState = $state
        FunctionName = @(
            'Assert-LavapipeReleaseVersion', 'Get-LavapipeArchFact', 'Get-LavapipeAssetUrl', 'Get-LavapipeWindowsUrl',
            'Get-VulkanRuntimeComponentsUrl', 'Get-LavapipePinName', 'Resolve-LavapipeAssets', 'Get-LavapipePinValues',
            'Install-LavapipeRuntime') }
    if ($Find) { Invoke-TestFunctionMutations -ModuleArguments $module -IncludeControl -Find $Find -Replace $Replace -Expected $Expected -Body $Body }
    else { Invoke-WithFunctionModule @module -Body $Body }
}

function Assert-LavapipeAcquisition {
    param($State)
    Invoke-InTestDir -Files @{ 'archives [pins]/.keep' = '' } -Body { param($dir)
        $pins = @{ LAVAPIPE_VERSION = '2.3.4'; VULKAN_VERSION = '1.2.3.4'; LAVAPIPE_WINDOWS_X64_SHA256 = ('a' * 64)
            LAVAPIPE_WINDOWS_ARM64_SHA256 = ('b' * 64); VULKAN_RT_WINDOWS_ZIP_SHA256 = ('c' * 64); VULKAN_RT_WINDOWS_ARM64_ZIP_SHA256 = ('d' * 64) }
        $lookup = { param($name) $pins[$name] }
        $cache = Join-Path $dir 'archives [pins]'
        $destination = Join-Path $dir 'runtime tree'
        foreach ($case in @(
                @{ Arch = 'amd64'; Mesa = 'x64'; Loader = 'windows/VulkanRT-X64'; Prefix = 'x64/'; Icd = 'x86_64'; MesaSha = ('a' * 64); LoaderSha = ('c' * 64) },
                @{ Arch = 'arm64'; Mesa = 'arm64'; Loader = 'warm/VulkanRT-ARM64'; Prefix = ''; Icd = 'aarch64'; MesaSha = ('b' * 64); LoaderSha = ('d' * 64) })) {
            $State.Calls.Clear()
            $requiredFiles = if ($case.Arch -eq 'amd64') { @('vulkan_lvp.dll', 'vulkan-1.dll', 'vulkaninfo.exe') } else { @('vulkaninfo.exe', 'vulkan-1.dll') }
            $runtime = @(Install-MutLavapipeRuntime -Arch $case.Arch -Lookup $lookup -ArchiveDirectory $cache -Destination $destination `
                -Operation 'Install-Lavapipe' -RequiredFile $requiredFiles 6>$null)
            Assert-Equal 1 $runtime.Count 'only the runtime descriptor reaches stdout'
            Assert-Equal '2.3.4|1.2.3.4' (($runtime[0].MesaVersion, $runtime[0].VulkanVersion) -join '|')
            Assert-Equal "lvp_icd.$($case.Icd).json" $runtime[0].IcdName
            Assert-Equal 'mesa-fetch|mesa-expand|loader-fetch|loader-expand' ($State.Calls.Kind -join '|') 'both pins are fetched and expanded in order'
            $mesa = $State.Calls[0]; $loader = $State.Calls[2]; $expand = $State.Calls[3]
            Assert-Equal "https://github.com/mmozeiko/build-mesa/releases/download/2.3.4/mesa-lavapipe-$($case.Mesa)-2.3.4.7z" $mesa.Url
            Assert-Equal "https://sdk.lunarg.com/sdk/download/1.2.3.4/$($case.Loader)-1.2.3.4-Components.zip" $loader.Url
            Assert-Equal $case.MesaSha $mesa.Sha 'Mesa SHA must be forwarded'
            Assert-Equal $case.LoaderSha $loader.Sha 'loader SHA must be forwarded'
            Assert-Equal PK $loader.Signature 'loader signature must be checked'
            Assert-Equal 'lavapipe 2.3.4' $mesa.Description
            Assert-Equal 'Vulkan Runtime Components 1.2.3.4' $loader.Description
            Assert-Equal $mesa.Destination $State.Calls[1].Path 'Mesa extracts the downloaded archive'
            Assert-Equal $loader.Destination $expand.Path 'loader extracts the downloaded archive'
            Assert-Equal $destination $State.Calls[1].Destination
            Assert-Equal $destination $expand.Destination
            Assert-Equal $case.Prefix $expand.Prefix 'loader extraction retains the arch prefix'
            Assert-Equal 'vulkan-1.dll|vulkaninfo.exe' ($expand.Names -join '|') 'both loader binaries are required'
            foreach ($archive in @($mesa.Destination, $loader.Destination)) {
                Assert-Equal $cache (Split-Path $archive) 'caller archive directory is retained'
                Assert-False (Test-Path -LiteralPath $archive) 'successful archives must be removed literally'
            }
        }
        $State.Calls.Clear()
        Assert-Throws {
            Install-MutLavapipeRuntime -Arch amd64 -Lookup $lookup -ArchiveDirectory $cache -Destination $destination `
                -Operation 'Install-LavapipeHost' -RequiredFile @('missing.dll') 6>$null
        } -MessagePattern 'Install-LavapipeHost: .*missing\.dll is missing after the unpack'
        Assert-Equal 'mesa-fetch|mesa-expand|loader-fetch|loader-expand' ($State.Calls.Kind -join '|') 'required-file verification follows extraction'
        Assert-False (Test-Path -LiteralPath $State.Calls[0].Destination) 'required-file verification keeps the existing post-cleanup order'
        $stages = @('mesa-fetch', 'mesa-expand', 'loader-fetch', 'loader-expand')
        for ($index = 0; $index -lt $stages.Count; $index++) {
            $stage = $stages[$index]
            $State.Failure = $stage
            $State.Calls.Clear()
            Assert-Throws {
                Install-MutLavapipeRuntime -Arch amd64 -Lookup $lookup -ArchiveDirectory $cache -Destination $destination `
                    -Operation 'Install-Lavapipe' -RequiredFile @('vulkan_lvp.dll', 'vulkan-1.dll', 'vulkaninfo.exe') 6>$null
            } -MessagePattern "fixture $stage failed"
            Assert-Equal ($stages[0..$index] -join '|') ($State.Calls.Kind -join '|') 'failure stops later acquisition work'
            if ($index -gt 0) { Assert-True (Test-Path -LiteralPath $State.Calls[0].Destination) 'failed staging retains its downloaded evidence' }
        }
        $State.Failure = ''
    }
}

Describe 'Shared lavapipe acquisition' {
    It 'keeps the ARM64 loader under warm/ and detects the wrong release directory' {
        Invoke-LavapipeAcquisitionFixture -Find "VulkanDirectory = 'warm'" -Replace "VulkanDirectory = 'windows'" -Expected 'expected .*warm.*VulkanRT-ARM64.* but got .*windows.*VulkanRT-ARM64'
    }

    It 'forwards the Mesa hash and detects its omission' {
        Invoke-LavapipeAcquisitionFixture -Find '-ExpectedSha256 $pins.MesaSha256' -Replace '' -Expected 'Mesa SHA must be forwarded'
    }

    It 'forwards the loader hash and detects its omission' {
        Invoke-LavapipeAcquisitionFixture -Find '-ExpectedSha256 $pins.LoaderSha256' -Replace '' -Expected 'loader SHA must be forwarded'
    }

    It 'checks the loader ZIP signature and detects a wrong signature' {
        Invoke-LavapipeAcquisitionFixture -Find '-ExpectSignature PK' -Replace '-ExpectSignature MZ' -Expected 'loader signature must be checked'
    }

    It 'retains the architecture prefix and detects selecting the root for x64' {
        Invoke-LavapipeAcquisitionFixture -Find '-BinPrefix $assets.BinPrefix' -Replace "-BinPrefix ''" -Expected 'loader extraction retains the arch prefix'
    }

    It 'requires both loader binaries and detects dropping vulkaninfo' {
        Invoke-LavapipeAcquisitionFixture -Find "@('vulkan-1.dll', 'vulkaninfo.exe')" -Replace "@('vulkan-1.dll')" -Expected 'both loader binaries are required'
    }

    It 'cleans literal archive names and detects wildcard cleanup' {
        Invoke-LavapipeAcquisitionFixture -Find 'Remove-Item -LiteralPath $mesaArchive, $loaderZip' -Replace 'Remove-Item -Path $mesaArchive, $loaderZip' -Expected 'successful archives must be removed literally'
    }

    It 'propagates acquisition failures and rejects missing files without extra cleanup' {
        Invoke-LavapipeAcquisitionFixture
        Invoke-LavapipeAcquisitionFixture -Find 'if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {' -Replace 'if ($false) {' `
            -Expected 'expected an exception but none was thrown' -Body { param($state) Assert-LavapipeAcquisition $state }
    }

    It 'rejects an absent or malformed pin before any download' {
        Invoke-LavapipeAcquisitionFixture -Body { param($state)
            foreach ($lookup in @({ '' }, { param($name) if ($name -like '*SHA256') { 'bad hash' } elseif ($name -eq 'LAVAPIPE_VERSION') { '2.3.4' } else { '1.2.3.4' } })) {
                Assert-Throws { Install-MutLavapipeRuntime -Arch arm64 -Lookup $lookup -ArchiveDirectory unused -Destination unused `
                    -Operation 'Install-LavapipeHost' -RequiredFile @('vulkaninfo.exe', 'vulkan-1.dll') } -MessagePattern 'pin is unset|SHA256 pins'
                Assert-Equal 0 $state.Calls.Count 'invalid pins cannot start a download'
            }
        }
    }

    It 'routes both installers through the shared operation and exports its public entry point' {
        foreach ($script in @('Install-Lavapipe.ps1', 'Install-LavapipeHost.ps1')) {
            $calls = @(Get-TestScriptCommands -ScriptPath "windows/scripts/host/$script" -Name Install-LavapipeRuntime)
            Assert-Equal 1 $calls.Count 'each installer uses one shared acquisition'
            $options = Get-TestCommandArguments $calls[0]
            foreach ($name in @('Arch', 'Lookup', 'ArchiveDirectory', 'Destination', 'RequiredFile')) { Assert-True $options.Contains($name) "$script forwards $name" }
            Assert-Equal 0 @(Get-TestScriptCommands -ScriptPath "windows/scripts/host/$script" -Name Invoke-DownloadWithRetry).Count
            if ($script -eq 'Install-Lavapipe.ps1') {
                Assert-False $options.Contains('Operation') 'the image installer uses the shared default failure prefix'
                Assert-Match "'vulkan_lvp\.dll'.*'vulkan-1\.dll'.*'vulkaninfo\.exe'" $options.RequiredFile 'the image installer keeps its PE probe inputs'
            } else {
                Assert-True $options.Contains('Operation') 'the host installer overrides the image-context default'
                Assert-Equal "'Install-LavapipeHost'" $options.Operation 'the host installer keeps its failure prefix'
                Assert-Match "'vulkaninfo\.exe'.*'vulkan-1\.dll'" $options.RequiredFile 'the host installer keeps its loader and info inputs'
            }
        }
        $modulePath = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsContainerImage.Common.psm1'
        $moduleText = [IO.File]::ReadAllText($modulePath)
        Assert-Match "\[string\]\`$Operation = 'Install-Lavapipe'" $moduleText 'the shared image installer context remains the default'
        $module = Import-Module $modulePath -PassThru
        try {
            Assert-True $module.ExportedCommands.ContainsKey('Install-LavapipeRuntime') 'the entry point must be exported'
            Assert-True $module.ExportedCommands.ContainsKey('Register-LavapipeIcd') 'both installers use the shared registry write'
        }
        finally { Remove-Module $module }
    }

    It 'keeps registration after runtime verification and preserves each caller policy' {
        $containerPath = 'windows/scripts/host/Install-Lavapipe.ps1'
        $hostPath = 'windows/scripts/host/Install-LavapipeHost.ps1'
        $container = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $containerPath))
        $hostSource = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $hostPath))
        $containerCall = @(Get-TestScriptCommands -ScriptPath $containerPath -Name Register-LavapipeIcd)
        $hostCall = @(Get-TestScriptCommands -ScriptPath $hostPath -Name Register-LavapipeIcd)
        Assert-Equal 1 $containerCall.Count 'the image installer registers once'
        Assert-Equal 1 $hostCall.Count 'the host provisioner registers once'
        Assert-Equal '$icd' (Get-TestCommandArguments $containerCall[0]).IcdPath
        Assert-Equal '$icd' (Get-TestCommandArguments $hostCall[0]).IcdPath
        Assert-Match '(?s)\$icdJson = .*?if \(\$arch -eq ''amd64''\) \{ Register-LavapipeIcd -IcdPath \$icd \}' $container 'the verified amd64 ICD alone is registered in the image'
        Assert-Match '(?s)\$runtime = Install-LavapipeRuntime .*?\$env:VK_DRIVER_FILES = \$icd.*?if \(Test-Elevated\) \{\s*Register-LavapipeIcd -IcdPath \$icd\s*\}' $hostSource 'host registration remains elevation-gated and follows runtime file checks'
    }
}
