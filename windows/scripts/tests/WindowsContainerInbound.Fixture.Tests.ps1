#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# This tests wrapper wiring and mutants; it does not stream files or start a container.

Import-Module (Join-Path $PSScriptRoot 'WindowsContainerInbound.Fixture.psm1') -ErrorAction Stop

Describe 'Shared container inbound fixture' {
    It 'accepts a shared runner with exact root exclusions and patterns' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'Container.ps1'
            [IO.File]::WriteAllText($path, '& $runner -RepoRoot $repo -ContainerName fixture -BuildCommand $command -ExcludeRootEntries @(''build'', ''logs'') -ExcludeRootPatterns @(''build-*'')')
            Assert-ContainerRootSelection -ScriptPath $path -ExcludeEntries @('build', 'logs') -ExcludePatterns @('build-*')
        }
    }

    It 'rejects missing, changed, local and malformed selection' {
        Invoke-InTestDir -Files ([ordered]@{
                'missing.ps1' = '& $runner -RepoRoot $repo -ContainerName fixture -BuildCommand $command'
                'changed.ps1' = '& $runner -RepoRoot $repo -ContainerName fixture -BuildCommand $command -ExcludeRootEntries @(''build'') -ExcludeRootPatterns @(''build-*'')'
                'patterns.ps1' = '& $runner -RepoRoot $repo -ContainerName fixture -BuildCommand $command -ExcludeRootEntries @(''build'', ''logs'')'
                'private.ps1' = '& $runner -RepoRoot $repo -ContainerName fixture -BuildCommand $command -ExcludeRootEntries @(''build'', ''logs'') -ExcludeRootPatterns @(''build-*'') -InboundItems @(''src'')'
                'enumerator.ps1' = '$items = [IO.Directory]::GetFileSystemEntries($repo); & $runner -RepoRoot $repo -ContainerName fixture -BuildCommand $command -ExcludeRootEntries @(''build'', ''logs'') -ExcludeRootPatterns @(''build-*'')'
                'syntax.ps1' = '& $runner -RepoRoot $repo -ContainerName fixture -BuildCommand $command -ExcludeRootEntries @(''build'', ''logs'') -ExcludeRootPatterns @(''build-*'''
            }) -Body { param($dir)
                $cases = @(
                    @{ File = 'missing.ps1'; P = 'needs root exclusions' },
                    @{ File = 'changed.ps1'; P = 'root exclusions must keep' },
                    @{ File = 'patterns.ps1'; P = 'needs root patterns' },
                    @{ File = 'private.ps1'; P = 'must not select inbound items privately' },
                    @{ File = 'enumerator.ps1'; P = 'root enumeration belongs' },
                    @{ File = 'syntax.ps1'; P = 'parse errors' }
                )
                $exercise = { param($case)
                    try {
                        Assert-ContainerRootSelection -ScriptPath (Join-Path $dir $case.File) -ExcludeEntries @('build', 'logs') -ExcludePatterns @('build-*')
                        return @()
                    } catch { return $_.Exception.Message }
                }.GetNewClosure()
                Assert-TestSingleFindingCases -Cases $cases -Exercise $exercise -Message 'container root selection'
            }
    }
}
