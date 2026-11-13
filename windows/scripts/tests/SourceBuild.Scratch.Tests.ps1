#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Private file trees and cmdlet failures cover cleanup boundaries, not Windows layer exports or device behavior.

$script:ScratchPrelude = @'
function Get-ScratchFixturePath {
    param([hashtable]$Binding)
    if ($Binding.ContainsKey('LiteralPath')) { return $Binding.LiteralPath }
    $Binding.Path
}
function Test-ScratchFixturePath {
    param([string]$Candidate)
    $Candidate.StartsWith($State.Root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Test-Path {
    [CmdletBinding()]
    param([string]$Path, [string]$LiteralPath)
    $candidate = Get-ScratchFixturePath $PSBoundParameters
    if (-not (Test-ScratchFixturePath $candidate)) { return $false }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Item {
    [CmdletBinding()]
    param([string]$LiteralPath, [switch]$Force)
    if ($LiteralPath -eq $State.Reparse) { return [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } }
    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function Remove-Item {
    [CmdletBinding()]
    param([string]$Path, [string]$LiteralPath, [switch]$Recurse, [switch]$Force)
    $candidate = Get-ScratchFixturePath $PSBoundParameters
    if (-not (Test-ScratchFixturePath $candidate)) {
        throw "Fixture refused cleanup outside its root: $candidate"
    }
    if ($candidate -eq $State.Sdk) {
        if ($State.FailDelete) { Write-Error 'synthetic QNN lock'; return }
        if ($State.SkipDelete) { return }
    }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
'@

function Invoke-QnnScratchCase {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $scratchCase = $Body
    Invoke-InTestDir -Files @{
        'build/qnn-sdk-extract/qairt/lib-safe/aarch64-android/libQnnHtpPrepare.so' = 'temporary SDK'
        'build/qnn-sdk-cache/qairt.zip' = 'pinned archive'
        'build/cpython/python.exe' = 'chain interpreter'
        'runtime/QnnCpu.dll' = 'selected runtime'
        'profile-temp/old.txt' = 'ordinary scratch'
    } -Body {
        param($root)
        $state = @{
            Root = $root; Build = (Join-Path $root 'build'); Sdk = (Join-Path $root 'build/qnn-sdk-extract')
            Cache = (Join-Path $root 'build/qnn-sdk-cache/qairt.zip'); Runtime = (Join-Path $root 'runtime/QnnCpu.dll')
            FailDelete = $false; SkipDelete = $false; Reparse = ''; Case = $scratchCase
            Environment = @{
                TEMP_DIR = (Join-Path $root 'build'); TEMP = (Join-Path $root 'profile-temp')
                USERPROFILE = (Join-Path $root 'profile'); LOCALAPPDATA = (Join-Path $root 'profile/local')
            }
        }
        $moduleArgs = @{
            ScriptPath = 'windows/scripts/modules/WindowsSourceBuild.Common.psm1'
            FunctionName = 'Clear-BuildScratch'; Prelude = $script:ScratchPrelude; FixtureState = $state
        }
        Invoke-WithFunctionModule @moduleArgs -Body {
            param($fixture)
            Invoke-WithEnv $fixture.Environment { & $fixture.Case $fixture }
        }
    }
}

Describe 'QNN SDK extraction before layer finalization' {
    It 'removes foreign SDK payloads while preserving the archive, interpreter and copied runtime' {
        Invoke-QnnScratchCase {
            param($s)
            $archiveHash = (Get-FileHash -LiteralPath $s.Cache).Hash
            Clear-MutBuildScratch
            Assert-False (Test-Path -LiteralPath $s.Sdk) 'the full extracted SDK must not enter the image layer'
            Assert-True (Test-Path -LiteralPath $s.Cache) 'the pinned download must remain present'
            Assert-Equal $archiveHash (Get-FileHash -LiteralPath $s.Cache).Hash 'the download cache remains reusable'
            Assert-Equal 'selected runtime' ((Get-Content -LiteralPath $s.Runtime -Raw).Trim()) 'runtime copies survive cleanup'
            Assert-True (Test-Path -LiteralPath (Join-Path $s.Build 'cpython/python.exe')) 'TEMP_DIR is not a broad cleanup root'
            Assert-False (Test-Path -LiteralPath (Join-Path $s.Root 'profile-temp/old.txt')) 'ordinary profile scratch is still cleared'
        }
    }

    It 'keeps the SDK tree when no source temporary root is configured' {
        Invoke-QnnScratchCase {
            param($s)
            Invoke-WithEnv @{ TEMP_DIR = $null } { Clear-MutBuildScratch }
            Assert-True (Test-Path -LiteralPath $s.Sdk) 'an unknown root does not become a relative delete'
        }
    }

    It 'refuses a relative source temporary root before deleting' {
        Invoke-QnnScratchCase {
            param($s)
            Invoke-WithEnv @{ TEMP_DIR = 'relative-build' } {
                Assert-Throws { Clear-MutBuildScratch } -MessagePattern 'TEMP_DIR must be absolute'
            }
            Assert-True (Test-Path -LiteralPath $s.Sdk) 'the source tree is unchanged after refusal'
        }
    }

    It 'refuses reparse metadata on the temporary parent and extraction root' {
        Invoke-QnnScratchCase {
            param($s)
            foreach ($path in @($s.Build, $s.Sdk)) {
                $s.Reparse = $path
                Assert-Throws { Clear-MutBuildScratch } -MessagePattern 'QNN SDK scratch must not be a reparse point'
                Assert-True (Test-Path -LiteralPath $s.Sdk) 'a refused tree remains untouched'
            }
        }
    }

    It 'retains the actual removal failure instead of reporting a successful scrub' {
        Invoke-QnnScratchCase {
            param($s)
            $s.FailDelete = $true
            Assert-Throws { Clear-MutBuildScratch } -MessagePattern 'synthetic QNN lock'
            Assert-True (Test-Path -LiteralPath $s.Sdk) 'the failed cleanup is visible'
        }
    }

    It 'refuses success when the removal command leaves SDK files behind' {
        Invoke-QnnScratchCase {
            param($s)
            $s.SkipDelete = $true
            Assert-Throws { Clear-MutBuildScratch } -MessagePattern 'QNN SDK extraction remains after cleanup'
        }
    }
}
