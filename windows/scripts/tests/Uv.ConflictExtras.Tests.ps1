#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# `uv sync --all-extras` fails on declared conflicts, so the module ports python_uv.sh's keep-first-member choice.

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsUv.Common.psm1') -Force -DisableNameChecking

function script:New-PyprojectFixture {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Body)
    $path = Join-Path $Dir 'pyproject.toml'
    Set-Content -LiteralPath $path -Value $Body -Encoding utf8NoBOM
    return $path
}

# One family, the whole table on one line - the layout uv's own docs show.
$script:OnePair = @'
[project]
name = "x"
[tool.uv]
conflicts = [ [ { extra = "a" }, { extra = "b" } ] ]
'@

# The table OrchestrANT writes: three families, one member per line, another table after it.
$script:ThreeFamilies = @'
[tool.uv]
conflicts = [
  [
    { extra = "ml-ai" },
    { extra = "ml-ai-webgpu" },
  ],
  [
    { extra = "ml-ai" },
    { extra = "ml-ai-cuda" },
  ],
  [
    { extra = "pytorch-cpu" },
    { extra = "pytorch-cu130" },
  ],
]
[tool.uv.sources]
'@

# Write a table, parse it, flatten to 'a b|c d': one string per case to assert.
function script:Get-ParsedFamilies {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Body)
    $p = New-PyprojectFixture -Dir $Dir -Body $Body
    $groups = @(Get-UvConflictGroups -PyprojectPath $p)
    return (($groups | ForEach-Object { $_ -join ' ' }) -join '|')
}

# Returns the arguments uv would receive for one conflicts pair under the given UV_SYNC_EXTRAS.
function script:Get-SyncArguments {
    param([Parameter(Mandatory)][string]$Dir, [AllowNull()][string]$Extras, [switch]$UseLocked)
    $p = New-PyprojectFixture -Dir $Dir -Body $script:OnePair
    $script:captured = $null
    $runner = { param($exe, $arguments) $script:captured = @($arguments) }
    $saved = [Environment]::GetEnvironmentVariable('UV_SYNC_EXTRAS')
    [Environment]::SetEnvironmentVariable('UV_SYNC_EXTRAS', $Extras)
    try {
        Sync-UvProjectDependencies -PyprojectPath $p -CommandRunner $runner -UseLocked:$UseLocked
    } finally {
        [Environment]::SetEnvironmentVariable('UV_SYNC_EXTRAS', $saved)
    }
    return ($script:captured -join ' ')
}

Describe 'WindowsUv.Common: the conflicts table is read the way python_uv.sh reads it' {

    # One case per layout uv accepts; the members come back in declaration order.
    foreach ($layout in @(
        @{ Name = 'the inline layout'; Body = $script:OnePair; Want = 'a b' },
        @{ Name = 'the multi-line layout OrchestrANT writes, three families'; Body = $script:ThreeFamilies; Want = 'ml-ai ml-ai-webgpu|ml-ai ml-ai-cuda|pytorch-cpu pytorch-cu130' }
    )) {
        It "parses $($layout.Name)" {
            Invoke-InTestDir { param($d) Assert-Equal $layout.Want (Get-ParsedFamilies -Dir $d -Body $layout.Body) 'families and order' }
        }
    }

    It 'returns nothing for a project without a conflicts table, or without the file' {
        Invoke-InTestDir {
            param($d)
            $p = New-PyprojectFixture -Dir $d -Body "[project]`nname = `"x`"`n"
            Assert-Equal 0 (@(Get-UvConflictGroups -PyprojectPath $p)).Count 'no table, no groups'
            Assert-Equal 0 (@(Get-UvExtrasToExclude -PyprojectPath $p)).Count 'no table, nothing excluded'
            Assert-Equal 0 (@(Get-UvExtrasToExclude -PyprojectPath (Join-Path $d 'missing.toml'))).Count 'no file, nothing excluded'
        }
    }
}

Describe 'WindowsUv.Common: --all-extras keeps the first-declared member of each family' {

    It 'excludes the later members, greedy in declaration order' {
        Invoke-InTestDir {
            param($d)
            $p = New-PyprojectFixture -Dir $d -Body $script:ThreeFamilies
            $excluded = @(Get-UvExtrasToExclude -PyprojectPath $p)
            Assert-Equal 'ml-ai-webgpu ml-ai-cuda pytorch-cu130' ($excluded -join ' ') 'the same answer python_uv.sh gives'
        }
    }

    It 'Sync-UvProjectDependencies hands uv --all-extras plus one --no-extra per excluded extra' {
        Invoke-InTestDir {
            param($d)
            Assert-Equal '-v sync --dev --all-extras --no-extra b' (Get-SyncArguments -Dir $d -Extras $null) 'the argument shape uv receives'
        }
    }

    It 'UV_SYNC_EXTRAS wins: explicit extras, no --all-extras, no exclusion' {
        Invoke-InTestDir {
            param($d)
            Assert-Equal '-v sync --dev --extra b --extra c --locked' (Get-SyncArguments -Dir $d -Extras 'b, c' -UseLocked) 'explicit extras, locked'
        }
    }
}
