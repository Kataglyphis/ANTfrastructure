#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# NOT covered: the Windows layer that lowercases a replaced file, which plain NTFS never does (proved in a buildctl replay, CON80).

Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSitePackages.Common.psm1') -Force -DisableNameChecking

# Writes -Files (relative path -> text) under -Root and a RECORD listing -Record into -DistInfo.
function script:New-SitePackagesFixture {
    param([Parameter(Mandatory)][string]$Root, [hashtable]$Files = @{}, [string]$DistInfo = '', [string[]]$Record = @())
    foreach ($entry in $Files.GetEnumerator()) {
        $target = [IO.Path]::Combine($Root, $entry.Key)
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::WriteAllText($target, $entry.Value)
    }
    if ($DistInfo) {
        $info = [IO.Directory]::CreateDirectory([IO.Path]::Combine($Root, $DistInfo))
        [IO.File]::WriteAllLines([IO.Path]::Combine($info.FullName, 'RECORD'), [string[]]@($Record | ForEach-Object { "$_,sha256=x,1" }))
    }
}

# A branch tree carrying Cython 3.3.0's Shadow.py with -Text, spelled as its RECORD names it, plus -More.
function script:New-CythonBranch([string]$Root, [string]$Text, [hashtable]$More = @{}) {
    New-SitePackagesFixture -Root $Root -Files (@{ 'Cython/Shadow.py' = $Text } + $More) -DistInfo 'cython-3.3.0.dist-info' -Record 'Cython/Shadow.py'
}

# The CON80 shape: a RECORD naming Cython/Shadow.py over a disk holding shadow.py, plus -More files and -Also entries.
function script:New-LoweredCython([string]$Root, [hashtable]$More = @{}, [string[]]$Also = @()) {
    New-SitePackagesFixture -Root $Root -Files (@{ 'Cython/shadow.py' = 'x' } + $More) -DistInfo 'cython-3.3.0.dist-info' -Record (@('Cython/Shadow.py') + $Also)
}

# Runs -Body with a fan-in's destination and its two branch trees, all under a fresh test dir.
function script:Invoke-InMergeDir([scriptblock]$Body) {
    Invoke-InTestDir { param($d) & $Body (Join-Path $d 'dest') (Join-Path $d 'core') (Join-Path $d 'tvm') }
}

# The exact spelling of every file under -Root, ordinal order, comma-joined.
function script:Get-ExactListing([string]$Root) {
    $names = [string[]]@(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName) -replace '\\', '/' })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return $names -join ','
}

Describe 'Get-DistInfoVersion and Find-SitePackagesVersionConflict' {

    It 'reads the PEP 503 name and the version off each dist-info directory, and skips other directories' {
        Invoke-InTestDir { param($d)
            foreach ($n in 'cython-3.3.0.dist-info', 'scikit_build_core-1.1.1.dist-info', 'iree_base_compiler-3.11.0.dev0+e4a3.dist-info', 'Cython', 'nodash.dist-info') {
                New-Item -ItemType Directory -Path (Join-Path $d $n) | Out-Null
            }
            $got = @(Get-DistInfoVersion -SitePackages $d | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Version)" }) -join ';'
            Assert-Equal 'cython=3.3.0;iree-base-compiler=3.11.0.dev0+e4a3;scikit-build-core=1.1.1' $got
        }
    }

    It 'names a distribution two trees carry at different versions, and nothing when they agree' {
        Invoke-InTestDir { param($d)
            $core = Join-Path $d 'core'; $tvm = Join-Path $d 'tvm'; $same = Join-Path $d 'same'
            New-SitePackagesFixture -Root $core -DistInfo 'cython-3.3.0.dist-info'
            New-SitePackagesFixture -Root $same -DistInfo 'Cython-3.3.0.dist-info'
            New-SitePackagesFixture -Root $tvm -DistInfo 'cython-3.2.9.dist-info'
            Assert-Equal 0 @(Find-SitePackagesVersionConflict -Tree $core, $same).Count 'one version spelled two ways is one version'
            $conflict = @(Find-SitePackagesVersionConflict -Tree $core, $tvm)
            Assert-Equal 1 $conflict.Count
            Assert-Match "^cython is 3\.3\.0 in .*core but 3\.2\.9 in .*tvm$" $conflict[0]
            Assert-Equal 0 @(Find-SitePackagesVersionConflict -Tree (Join-Path $d 'empty')).Count 'no dist-info, no conflict'
        }
    }
}

Describe 'Find-RecordCaseMismatch' {

    It 'reports each file RECORD spells otherwise than the disk, the dist-info files included (the CON80 shape)' {
        Invoke-InTestDir { param($d)
            New-LoweredCython $d @{ 'Cython/Utils.py' = 'x'; 'cython-3.3.0.dist-info/metadata' = 'x' } 'Cython/Utils.py', 'cython-3.3.0.dist-info/METADATA'
            $got = @(Find-RecordCaseMismatch -SitePackages $d | ForEach-Object { "$($_.Distribution)|$($_.Record)|$($_.OnDisk)" })
            Assert-Equal 'cython|Cython/Shadow.py|Cython/shadow.py;cython|cython-3.3.0.dist-info/METADATA|cython-3.3.0.dist-info/metadata' ($got -join ';')
        }
    }

    It 'ignores matching spellings, files that are missing and entries outside site-packages' {
        Invoke-InTestDir { param($d)
            New-SitePackagesFixture -Root $d -Files @{ 'numpy/LICENSE.txt' = 'x' } -DistInfo 'numpy-2.5.3.dist-info' `
                -Record 'numpy/LICENSE.txt', 'numpy/Gone.py', '../../Scripts/f2py.exe', '"numpy/a,b.py"'
            Assert-Equal 0 @(Find-RecordCaseMismatch -SitePackages $d).Count
        }
    }

    It 'checks only -Distribution when given, in any spelling, and reads a quoted path with a comma' {
        Invoke-InTestDir { param($d)
            New-LoweredCython $d @{ 'numpy/a,b.txt' = 'x' }
            New-SitePackagesFixture -Root $d -DistInfo 'numpy-2.5.3.dist-info' -Record '"numpy/A,B.txt"'
            Assert-Equal 'cython' (@(Find-RecordCaseMismatch -SitePackages $d -Distribution 'Cython').Distribution -join ',')
            Assert-Equal 'numpy/A,B.txt' (@(Find-RecordCaseMismatch -SitePackages $d -Distribution 'numpy').Record -join ',')
        }
    }

    It 'formats one line per distribution with its count and first entry' {
        $lines = @(@(
                [pscustomobject]@{ Distribution = 'numpy'; Record = 'numpy/LICENSE.txt'; OnDisk = 'numpy/license.txt' }
                [pscustomobject]@{ Distribution = 'cython'; Record = 'Cython/Shadow.py'; OnDisk = 'Cython/shadow.py' }
                [pscustomobject]@{ Distribution = 'cython'; Record = 'Cython/Utils.py'; OnDisk = 'Cython/utils.py' }
            ) | Format-RecordCaseMismatch)
        Assert-Equal 2 $lines.Count
        Assert-Equal 'cython: 2 RECORD entries spelled otherwise on disk, e.g. Cython/Shadow.py is Cython/shadow.py' $lines[0]
        Assert-Match '^numpy: 1 RECORD entry ' $lines[1]
        Assert-Equal 0 @(Format-RecordCaseMismatch).Count 'no mismatch, no line'
    }
}

Describe 'Merge-SitePackageTree' {

    It 'merges both branches over the base in order, the later one winning, and keeps every spelling' {
        Invoke-InMergeDir { param($dest, $core, $tvm)
            New-SitePackagesFixture -Root $dest -Files @{ 'README.txt' = 'base' }
            New-CythonBranch $core 'core' @{ 'README.txt' = 'base'; 'av/__init__.py' = 'core' }
            New-CythonBranch $tvm 'tvm-wins' @{ 'README.txt' = 'base'; 'tvm/__init__.py' = 'tvm' }
            Merge-SitePackageTree -Source $core, $tvm -Destination $dest *> $null
            Assert-Equal 'Cython/Shadow.py,README.txt,av/__init__.py,cython-3.3.0.dist-info/RECORD,tvm/__init__.py' (Get-ExactListing $dest)
            Assert-Equal 'tvm-wins' ([IO.File]::ReadAllText((Join-Path $dest 'Cython\Shadow.py'))) 'the later branch wins a file both carry'
            Assert-Equal 0 $global:LASTEXITCODE "robocopy's success code must not leak"
        }
    }

    It 'refuses branches that carry one distribution at two versions, before copying anything' {
        Invoke-InMergeDir { param($dest, $core, $tvm)
            New-CythonBranch $core 'core'
            New-SitePackagesFixture -Root $tvm -DistInfo 'Cython-3.2.9.dist-info'
            Assert-Throws { Merge-SitePackageTree -Source $core, $tvm -Destination $dest *> $null } -MessagePattern '(?s)mixed install.*cython is 3\.3\.0'
            Assert-Equal '' (Get-ExactListing $dest) 'nothing was copied'
        }
    }

    It 'refuses a result whose RECORD spelling is lost, as an already lowercased file stays lowercased' {
        Invoke-InMergeDir { param($dest, $core)
            New-SitePackagesFixture -Root $dest -Files @{ 'Cython/shadow.py' = 'old' }
            New-CythonBranch $core 'new-bytes'
            Assert-Throws { Merge-SitePackageTree -Source $core -Destination $dest *> $null } -MessagePattern '(?s)RECORD spelling lost.*cython: 1 RECORD entry .*Cython/Shadow\.py is Cython/shadow\.py'
        }
    }

    It 'refuses a source that does not exist' {
        Invoke-InMergeDir { param($dest, $core)
            Assert-Throws { Merge-SitePackageTree -Source $core -Destination $dest } -MessagePattern 'source .*core does not exist'
        }
    }
}
