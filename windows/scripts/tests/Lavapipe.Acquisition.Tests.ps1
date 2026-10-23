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
}
function Expand-VulkanRuntimeComponents {
    param($ZipPath, $Destination, $BinPrefix, $BinNames)
    $State.Calls.Add(@{ Kind = 'loader-expand'; Path = $ZipPath; Destination = $Destination; Prefix = $BinPrefix; Names = $BinNames })
    if ($State.Failure -eq 'loader-expand') { throw 'fixture loader-expand failed' }
}
'@
    $module = @{ ScriptPath = 'windows/scripts/modules/WindowsContainerImage.Common.psm1'; Prelude = $prelude; FixtureState = $state
        FunctionName = @('Get-LavapipeWindowsUrl', 'Get-VulkanRuntimeComponentsUrl', 'Get-LavapipePinName', 'Resolve-LavapipeAssets', 'Get-LavapipePinValues', 'Install-LavapipeRuntime') }
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
            $runtime = @(Install-MutLavapipeRuntime -Arch $case.Arch -Lookup $lookup -ArchiveDirectory $cache -Destination $destination 6>$null)
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
    }
}

Describe 'Shared lavapipe acquisition' {
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

    It 'propagates every acquisition failure and stops before later work or successful cleanup' {
        Invoke-LavapipeAcquisitionFixture -Body { param($state)
            Invoke-InTestDir { param($dir)
                $lookup = { param($name)
                    switch -Regex ($name) { '^LAVAPIPE_VERSION$' { '2.3.4' }; '^VULKAN_VERSION$' { '1.2.3.4' }; 'SHA256$' { 'a' * 64 } }
                }
                $steps = @('mesa-fetch', 'mesa-expand', 'loader-fetch', 'loader-expand')
                for ($i = 0; $i -lt $steps.Count; $i++) {
                    $state.Failure = $steps[$i]; $state.Calls.Clear()
                    Assert-Throws { Install-MutLavapipeRuntime -Arch amd64 -Lookup $lookup -ArchiveDirectory $dir -Destination (Join-Path $dir output) 6>$null } -MessagePattern "fixture $($steps[$i]) failed"
                    Assert-Equal ($steps[0..$i] -join '|') ($state.Calls.Kind -join '|') 'failure short-circuits later steps'
                    if ($i -gt 0) { Assert-True (Test-Path -LiteralPath $state.Calls[0].Destination) 'failed staging retains its downloaded evidence' }
                }
            }
        }
    }

    It 'rejects an absent or malformed pin before any download' {
        Invoke-LavapipeAcquisitionFixture -Body { param($state)
            foreach ($lookup in @({ '' }, { param($name) if ($name -like '*SHA256') { 'bad hash' } elseif ($name -eq 'LAVAPIPE_VERSION') { '2.3.4' } else { '1.2.3.4' } })) {
                Assert-Throws { Install-MutLavapipeRuntime -Arch arm64 -Lookup $lookup -ArchiveDirectory unused -Destination unused } -MessagePattern 'pin is unset|SHA256 pins'
                Assert-Equal 0 $state.Calls.Count 'invalid pins cannot start a download'
            }
        }
    }

    It 'routes both installers through the shared operation and exports its public entry point' {
        foreach ($script in @('Install-Lavapipe.ps1', 'Install-LavapipeHost.ps1')) {
            $calls = @(Get-TestScriptCommands -ScriptPath "windows/scripts/host/$script" -Name Install-LavapipeRuntime)
            Assert-Equal 1 $calls.Count 'each installer uses one shared acquisition'
            $options = Get-TestCommandArguments $calls[0]
            foreach ($name in @('Arch', 'Lookup', 'ArchiveDirectory', 'Destination')) { Assert-True $options.Contains($name) "$script forwards $name" }
            Assert-Equal 0 @(Get-TestScriptCommands -ScriptPath "windows/scripts/host/$script" -Name Invoke-DownloadWithRetry).Count
        }
        $modulePath = Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsContainerImage.Common.psm1'
        $module = Import-Module $modulePath -PassThru
        try { Assert-True $module.ExportedCommands.ContainsKey('Install-LavapipeRuntime') 'the entry point must be exported' }
        finally { Remove-Module $module }
    }
}
