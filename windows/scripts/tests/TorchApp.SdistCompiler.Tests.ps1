#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# CON93: the torch venv's sdists build with clang-cl and lld-link; a real uv sync is probe P13's, not this file's.

$script:TorchAppPath = Join-Path (Get-RepoRoot) 'windows\scripts\build\Build-TorchApp.ps1'
Import-Module (Join-Path (Get-RepoRoot) 'windows\scripts\modules\WindowsSdistCompiler.Common.psm1') -Force -DisableNameChecking

# A fake LLVM tree the shim can copy.
function New-FakeLlvm([string]$Root, [switch]$NoResourceDir) {
    $llvm = Join-Path $Root 'llvm\bin'
    New-Item -ItemType Directory -Force $llvm | Out-Null
    if (-not $NoResourceDir) { New-Item -ItemType Directory -Force (Join-Path $Root 'llvm\lib\clang\23') | Out-Null }
    foreach ($n in 'clang-cl', 'lld-link', 'llvm-lib') { Set-Content (Join-Path $llvm "$n.exe") $n }
    return $llvm
}

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

Describe 'Assert-ClangClSdistBuild' {
    $script:Built = @(' Resolved 180 packages in 2.1s', '   Building line-profiler==5.0.2', '      Built line-profiler==5.0.2', 'Prepared 1 package in 9.80s')

    It 'passes an lld-linked pyd and ignores uv''s own launcher in Scripts' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d
            Assert-ClangClSdistBuild -SyncOutput $script:Built -SitePackages $site
        }
    }

    It 'throws on a pyd that MSVC''s linker wrote, naming the distribution and the file (mutation)' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d -MsvcPyd
            Assert-Throws { Assert-ClangClSdistBuild -SyncOutput $script:Built -SitePackages $site } `
                -MessagePattern 'line-profiler: line_profiler/_line_profiler\.cp315-win_amd64\.pyd'
        }
    }

    It 'throws when uv built a distribution that left no dist-info to check' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d
            Assert-Throws { Assert-ClangClSdistBuild -SyncOutput @('      Built pyyaml==6.0.3') -SitePackages $site } -MessagePattern 'no dist-info for it'
        }
    }

    It 'checks nothing when uv built nothing from source' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d -MsvcPyd
            Assert-ClangClSdistBuild -SyncOutput @('Audited 180 packages in 0.4s') -SitePackages $site
        }
    }
}

Describe 'Get-ClangClSdistVsLib' {
    It 'keeps the caller''s LIB without asking VS' {
        Invoke-WithEnv @{ LIB = 'C:\caller\lib' } {
            Assert-Equal 'C:\caller\lib' (Get-ClangClSdistVsLib -VsDevCmdPattern 'Z:\none\VsDevCmd.bat')
        }
    }
}

Describe 'Enable-ClangClSdistShim' {

    It 'puts clang-cl, lld-link and llvm-lib first on PATH as cl, link and lib, and returns what it changed' {
        Invoke-InTestDir { param($d)
            $llvm = New-FakeLlvm $d
            $resource = Get-Item -LiteralPath (Join-Path $d 'llvm\lib\clang\23')
            $shim = Join-Path $d 'shim'
            Invoke-WithEnv @{ DISTUTILS_USE_SDK = $null; MSSdk = $null; PATH = $env:PATH; CL = '/DKEPT'; LIB = 'C:\fixture\lib' } {
                $before = $env:PATH
                $previous = Enable-ClangClSdistShim -ShimDir $shim -LlvmBin $llvm
                Assert-Equal 'clang-cl' (Get-Content (Join-Path $shim 'cl.exe')) 'cl.exe is clang-cl'
                Assert-Equal 'lld-link' (Get-Content (Join-Path $shim 'link.exe')) 'link.exe is lld-link'
                Assert-Equal 'llvm-lib' (Get-Content (Join-Path $shim 'lib.exe')) 'lib.exe is llvm-lib'
                Assert-Equal '1' $env:DISTUTILS_USE_SDK 'setuptools takes cl, link and lib from PATH'
                Assert-Equal '1' $env:MSSdk 'the second half of the switch'
                Assert-True ($env:PATH.StartsWith("$shim;")) 'the shim comes first'
                Assert-Equal $before $previous['PATH'] 'the old PATH is returned for the restore'
                Assert-Null $previous['DISTUTILS_USE_SDK'] 'unset before'
                Assert-Equal "/clang:-fcommon `"/clang:-resource-dir=$($resource.FullName)`" /DKEPT" $env:CL 'the copy finds its builtin headers and keeps the caller''s flags'
                Disable-ClangClSdistShim -Previous $previous -ShimDir $shim
                Assert-Equal $before $env:PATH 'PATH comes back'
                Assert-Null $env:DISTUTILS_USE_SDK 'an unset switch is unset again'
                Assert-Equal '/DKEPT' $env:CL 'CL comes back'
                Assert-False (Test-Path -LiteralPath $shim) 'the shim is gone'
            }
        }
    }

    It 'throws when an LLVM tool is missing rather than leave setuptools on VS''s cl' {
        Invoke-InTestDir { param($d)
            Assert-Throws { Enable-ClangClSdistShim -ShimDir (Join-Path $d 'shim') -LlvmBin (Join-Path $d 'none') } -MessagePattern 'needs .*clang-cl\.exe'
        }
    }

    It 'sets LIB for an sdist naming a system library on its link line, and removes it again' {
        Invoke-InTestDir { param($d)
            $llvm = New-FakeLlvm $d
            $shim = Join-Path $d 'shim'
            Invoke-WithEnv @{ DISTUTILS_USE_SDK = $null; MSSdk = $null; CL = $null; PATH = $env:PATH; LIB = $null } {
                $previous = Enable-ClangClSdistShim -ShimDir $shim -LlvmBin $llvm -VsLib 'C:\vs\lib'
                Assert-Equal 'C:\vs\lib' $env:LIB 'lld-link searches LIB for an explicit input'
                Disable-ClangClSdistShim -Previous $previous -ShimDir $shim
                Assert-False (Test-Path -LiteralPath Env:LIB) 'an absent LIB is absent again'
            }
        }
    }

    It 'throws without one resource directory, which a copied clang-cl cannot find alone' {
        Invoke-InTestDir { param($d)
            $llvm = New-FakeLlvm $d -NoResourceDir
            $shim = Join-Path $d 'shim'
            Invoke-WithEnv @{ PATH = $env:PATH; LIB = 'C:\fixture\lib' } {
                $before = $env:PATH
                Assert-Throws { Enable-ClangClSdistShim -ShimDir $shim -LlvmBin $llvm } -MessagePattern 'one resource directory'
                Assert-Equal $before $env:PATH 'a refused shim changes nothing'
            }
        }
    }
}

Describe 'Build-TorchApp.ps1: the sync runs inside the shim and the gate checks it after' {
    $script:TorchText = [IO.File]::ReadAllText($script:TorchAppPath)

    It 'the torch stage copies the module with both siblings it imports, as its parent may carry none (mutation)' {
        $copy = @((Get-TestRepoText 'windows\Dockerfile.torch') -split '(?m)^COPY ' | Where-Object { $_.Contains('WindowsSdistCompiler.Common.psm1') })
        Assert-Equal 1 $copy.Count 'one COPY carries the shim'
        foreach ($sibling in 'WindowsTargetArch.Common.psm1', 'WindowsScripts.Shared.psm1') { Assert-True $copy[0].Contains($sibling) "the COPY carries $sibling" }
    }

    It 'enables the shim before both syncs, restores and removes it in a finally, then gates' {
        Assert-Match '(?s)\$sdistEnv = Enable-ClangClSdistShim -ShimDir \$shimDir\s+try \{.*uv sync --frozen.*uv sync \$syncArgs"\).*\} finally \{\s+Disable-ClangClSdistShim -Previous \$sdistEnv -ShimDir \$shimDir\s+\}\s+Assert-ClangClSdistBuild -SyncOutput \$syncOut -SitePackages \$venvSite' $script:TorchText
    }
}

# Runs -Test with a fake LLVM under a clean shim environment; $before is the PATH the shim must restore.
function Invoke-InFakeShimEnvironment([scriptblock]$Test) {
    Invoke-InTestDir { param($d)
        $llvm = New-FakeLlvm $d
        Invoke-WithEnv @{ DISTUTILS_USE_SDK = $null; MSSdk = $null; CL = $null; PATH = $env:PATH; LIB = 'C:\fixture\lib' } {
            $before = $env:PATH
            & $Test $d $llvm $before
        }
    }
}

Describe 'Invoke-WithClangClSdist' {
    It 'runs the step under the shim, restores the environment and grades what uv built' {
        Invoke-InFakeShimEnvironment { param($d, $llvm, $before)
            $site = New-LineProfilerSite $d -MsvcPyd
            $out = [Collections.Generic.List[string]]::new()
            $seen = [Collections.Generic.List[string]]::new()
            Assert-Throws {
                Invoke-WithClangClSdist -LlvmBin $llvm -BuiltOutput $out -SitePackages $site -Script {
                    $seen.Add((Get-Content -LiteralPath (Join-Path ($env:PATH -split ';')[0] 'cl.exe')))
                    $seen.Add($env:DISTUTILS_USE_SDK)
                    $out.Add('   Built line-profiler==5.0.2')
                }
            } -MessagePattern "MSVC's linker.*line-profiler"
            Assert-Equal 'clang-cl|1' ($seen -join '|') 'the step saw the shim'
            Assert-Equal $before $env:PATH 'the shim left PATH'
        }
    }

    It 'restores the environment and skips the gate when the step fails' {
        Invoke-InFakeShimEnvironment { param($d, $llvm, $before)
            Assert-Throws { Invoke-WithClangClSdist -LlvmBin $llvm -SitePackages (Join-Path $d 'absent') -Script { throw 'fixture step failure' } } -MessagePattern 'fixture step failure'
            Assert-Equal $before $env:PATH 'a failed step still restores PATH'
            Assert-Null $env:DISTUTILS_USE_SDK 'and the switch'
        }
    }

    It 'outside the image runs the step as it stands, says so, and grades nothing' {
        Invoke-InTestDir { param($d)
            $site = New-LineProfilerSite $d -MsvcPyd
            $out = [Collections.Generic.List[string]]::new()
            $out.Add('   Built line-profiler==5.0.2')
            $log = [Collections.Generic.List[string]]::new()
            Invoke-WithEnv @{ DISTUTILS_USE_SDK = $null; PATH = $env:PATH } {
                $ran = [Collections.Generic.List[string]]::new()
                Invoke-WithClangClSdist -LlvmBin (Join-Path $d 'none') -BuiltOutput $out -SitePackages $site -LogInfo { param($m) $log.Add($m) } -Script { $ran.Add("$env:DISTUTILS_USE_SDK") }
                Assert-Equal 1 $ran.Count 'the step ran'
                Assert-Equal '' $ran[0] 'without the shim'
                Assert-Match 'setuptools keeps its own compiler' ($log -join ' ')
            }
        }
    }
}

Describe 'The consumer lanes build under the shim' {
    It 'wraps each native sync and build; the cross lane stays out, as the shim names no target' {
        $pythonDir = Join-Path (Get-RepoRoot) 'windows\scripts\python'
        $packaging = [IO.File]::ReadAllText((Join-Path $pythonDir 'Invoke-CiPackaging.ps1'))
        Assert-Match '(?s)Invoke-WithClangClSdist -BuiltOutput \$syncOut -SitePackages \(Join-Path \$envPath ''Lib\\site-packages''\).*?Sync-UvProjectDependencies @syncUv\s+Invoke-BuildExternal.*?\$buildArgs' $packaging
        Assert-Match '(?s)Invoke-WithClangClSdist [^\n]*-Script \{\s+Invoke-BuildExternal[^\n]*''--out-dir'', \$out' $packaging
        Assert-Match '(?s)if \(\$cross\) \{\s+Invoke-BuildExternal[^\n]*\$buildArgs' $packaging 'the cross source build has no shim'
        $build = [IO.File]::ReadAllText((Join-Path $pythonDir 'Invoke-PythonCiBuild.ps1'))
        Assert-Match '(?s)Invoke-WithClangClSdist -BuiltOutput \$syncOut -SitePackages \(Join-Path \$envPath ''Lib\\site-packages''\).*?Sync-UvProjectDependencies [^\n]*@syncUv' $build
    }
}
