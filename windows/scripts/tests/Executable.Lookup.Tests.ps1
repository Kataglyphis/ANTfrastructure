#requires -Version 7.0
# Empty files cover lookup and path contracts; no Windows executable is started.

param([switch]$Standalone)

$moduleDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules'
if ($Standalone) {
    Import-Module (Join-Path $PSScriptRoot 'TestHarness.psm1') -Force
    Reset-TestState
}
Import-Module (Join-Path $moduleDir 'WindowsAppRunner.Common.psm1')
Import-Module (Join-Path $moduleDir 'WindowsTesting.Common.psm1')

function New-ExecutableLookupFile {
    param([string]$Path)
    [void](New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force)
    [void](New-Item -ItemType File -Path $Path)
}

function Assert-ExecutableLookupOrder {
    param([string]$Root, [string[]]$Paths, [string]$Resolver, [hashtable]$Options)
    foreach ($relative in $Paths) {
        New-ExecutableLookupFile (Join-Path $Root $relative)
    }
    foreach ($relative in $Paths) {
        $expected = Join-Path $Root $relative
        Assert-Equal $expected (& $Resolver -BuildRoot $Root -ExecutableName 'probe.exe' @Options)
        Remove-Item -LiteralPath $expected
    }
}

Describe 'Build executable lookup' {
    It 'keeps app root, bin and caller configuration priority' {
        Invoke-InTestDir { param($dir)
            $paths = @('probe.exe', 'bin/probe.exe', 'bin/Release/probe.exe', 'Release/probe.exe', 'bin/Debug/probe.exe', 'Debug/probe.exe')
            Assert-ExecutableLookupOrder $dir $paths Resolve-AppExecutablePath @{ Configurations = @('Release', 'Debug') }
        }
    }

    It 'keeps test root, standard configurations and extra-directory priority' {
        Invoke-InTestDir { param($dir)
            $paths = @('probe.exe', 'Debug/probe.exe', 'Release/probe.exe', 'RelWithDebInfo/probe.exe', 'custom tests/probe.exe')
            Assert-ExecutableLookupOrder $dir $paths Resolve-TestExecutable @{ AdditionalRelativeDirectory = @('custom tests') }
        }
    }

    It 'preserves the app resolved path and test caller path for direct hits' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'probe.exe'
            New-ExecutableLookupFile $path
            Invoke-InTestLocation -Path $dir -Body {
                Assert-Equal (Resolve-Path $path).Path (Resolve-AppExecutablePath -BuildRoot '.' -ExecutableName 'probe.exe')
                Assert-Equal (Join-Path '.' 'probe.exe') (Resolve-TestExecutable -BuildRoot '.' -ExecutableName 'probe.exe')
            }
        }
    }

    It 'uses recursive search after direct candidates and returns null on a miss' {
        Invoke-InTestDir { param($dir)
            $nested = Join-Path $dir 'nested space/deep/probe.exe'
            New-ExecutableLookupFile $nested
            Assert-Equal $nested (Resolve-AppExecutablePath -BuildRoot $dir -ExecutableName 'probe.exe')
            Assert-Equal $nested (Resolve-TestExecutable -BuildRoot $dir -ExecutableName 'probe.exe')
            Remove-Item -LiteralPath $nested
            Assert-Null (Resolve-AppExecutablePath -BuildRoot $dir -ExecutableName 'probe.exe')
            Assert-Null (Resolve-TestExecutable -BuildRoot $dir -ExecutableName 'probe.exe')
        }
    }
}

if ($Standalone) {
    $results = @(Get-TestResult)
    if ($results.Count -ne 4 -or @($results | Where-Object { -not $_.Ok }).Count -gt 0) { exit 1 }
    Write-Host '4 executable lookup cases passed'
    exit 0
}
