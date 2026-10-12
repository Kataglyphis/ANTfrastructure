#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# CON93: the torch venv's sdists build with clang-cl and lld-link; a real uv sync is probe P13's, not this file's.

$script:TorchAppPath = Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TorchApp.ps1'
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsTargetArch.Common.psm1') -Force -DisableNameChecking

# A file that is a PE as far as Test-PeRichHeader reads: MZ, e_lfanew 0x80, a DOS stub with or without MSVC's marker.
function New-FakePe([string]$Path, [switch]$Rich) {
    $bytes = [byte[]]::new(0x100)
    $bytes[0] = 0x4D; $bytes[1] = 0x5A
    [BitConverter]::GetBytes([int]0x80).CopyTo($bytes, 0x3C)
    if ($Rich) { [Text.Encoding]::ASCII.GetBytes('Rich').CopyTo($bytes, 0x70) }
    [Text.Encoding]::ASCII.GetBytes("PE`0`0").CopyTo($bytes, 0x80)
    New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
    [IO.File]::WriteAllBytes($Path, $bytes)
}

# A site-packages with line-profiler's dist-info: its pyd, and the kernprof launcher uv writes to Scripts.
function New-LineProfilerSite([string]$Root, [switch]$MsvcPyd) {
    $site = Join-Path $Root 'Lib\site-packages'
    New-FakePe (Join-Path $site 'line_profiler\_line_profiler.cp315-win_amd64.pyd') -Rich:$MsvcPyd
    New-FakePe (Join-Path $Root 'Scripts\kernprof.exe') -Rich
    $info = Join-Path $site 'line_profiler-5.0.2.dist-info'
    New-Item -ItemType Directory -Force $info | Out-Null
    Set-Content (Join-Path $info 'RECORD') @(
        'line_profiler/_line_profiler.cp315-win_amd64.pyd,sha256=x,1',
        'line_profiler/__init__.py,sha256=x,1',
        '../../Scripts/kernprof.exe,sha256=x,1',
        'line_profiler-5.0.2.dist-info/RECORD,,')
    return $site
}

Describe 'Build-TorchApp.ps1: Assert-TorchAppSdistCompiler' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchAppPath -FunctionName 'Assert-TorchAppSdistCompiler')
    $script:Built = @(' Resolved 180 packages in 2.1s', '   Building line-profiler==5.0.2', '      Built line-profiler==5.0.2', 'Prepared 1 package in 9.80s')

    It 'passes an lld-linked pyd and ignores uv''s own launcher in Scripts' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d
            Assert-TorchAppSdistCompiler -SyncOutput $script:Built -SitePackages $site
        }
    }

    It 'throws on a pyd that MSVC''s linker wrote, naming the distribution and the file (mutation)' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d -MsvcPyd
            Assert-Throws { Assert-TorchAppSdistCompiler -SyncOutput $script:Built -SitePackages $site } `
                -MessagePattern 'line-profiler: line_profiler/_line_profiler\.cp315-win_amd64\.pyd'
        }
    }

    It 'throws when uv built a distribution that left no dist-info to check' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d
            Assert-Throws { Assert-TorchAppSdistCompiler -SyncOutput @('      Built pyyaml==6.0.3') -SitePackages $site } -MessagePattern 'no dist-info for it'
        }
    }

    It 'checks nothing when uv built nothing from source' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d -MsvcPyd
            Assert-TorchAppSdistCompiler -SyncOutput @('Audited 180 packages in 0.4s') -SitePackages $site
        }
    }
}

Describe 'Build-TorchApp.ps1: Enable-TorchAppClangClSdist' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:TorchAppPath -FunctionName 'Enable-TorchAppClangClSdist')

    It 'puts clang-cl, lld-link and llvm-lib first on PATH as cl, link and lib, and returns what it changed' {
        Invoke-InTestDir { param($d)
            $llvm = Join-Path $d 'llvm\bin'
            New-Item -ItemType Directory -Force $llvm | Out-Null
            foreach ($n in 'clang-cl', 'lld-link', 'llvm-lib') { Set-Content (Join-Path $llvm "$n.exe") $n }
            $shim = Join-Path $d 'shim'
            Invoke-WithEnv @{ DISTUTILS_USE_SDK = $null; MSSdk = $null; PATH = $env:PATH } {
                $before = $env:PATH
                $previous = Enable-TorchAppClangClSdist -ShimDir $shim -LlvmBin $llvm
                Assert-Equal 'clang-cl' (Get-Content (Join-Path $shim 'cl.exe')) 'cl.exe is clang-cl'
                Assert-Equal 'lld-link' (Get-Content (Join-Path $shim 'link.exe')) 'link.exe is lld-link'
                Assert-Equal 'llvm-lib' (Get-Content (Join-Path $shim 'lib.exe')) 'lib.exe is llvm-lib'
                Assert-Equal '1' $env:DISTUTILS_USE_SDK 'setuptools takes cl, link and lib from PATH'
                Assert-Equal '1' $env:MSSdk 'the second half of the switch'
                Assert-True ($env:PATH.StartsWith("$shim;")) 'the shim comes first'
                Assert-Equal $before $previous['PATH'] 'the old PATH is returned for the restore'
                Assert-Null $previous['DISTUTILS_USE_SDK'] 'unset before'
            }
        }
    }

    It 'throws when an LLVM tool is missing rather than leave setuptools on VS''s cl' {
        Invoke-InTestDir { param($d)
            Assert-Throws { Enable-TorchAppClangClSdist -ShimDir (Join-Path $d 'shim') -LlvmBin (Join-Path $d 'none') } -MessagePattern 'needs .*clang-cl\.exe'
        }
    }
}

Describe 'Build-TorchApp.ps1: the sync runs inside the shim and the gate checks it after' {
    $script:TorchText = [IO.File]::ReadAllText($script:TorchAppPath)

    It 'enables the shim before both syncs, restores and removes it in a finally, then gates' {
        Assert-Match '(?s)\$sdistEnv = Enable-TorchAppClangClSdist -ShimDir \$shimDir\s+try \{.*uv sync --frozen.*uv sync \$syncArgs"\).*\} finally \{\s+foreach \(\$name in \$sdistEnv\.Keys\).*Remove-Item -LiteralPath \$shimDir.*\}\s+Assert-TorchAppSdistCompiler -SyncOutput \$syncOut -SitePackages \$venvSite' $script:TorchText
    }
}
