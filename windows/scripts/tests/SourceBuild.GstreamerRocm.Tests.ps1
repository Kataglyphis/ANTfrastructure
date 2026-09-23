#requires -Version 7.0
# GStreamer's rocm lane (Build-GstreamerFromSource.ps1): AMD meson pins (none on cpu/nvidia), TheRock scrub +
# restore, leak gate, post-install AMD file check. NOT covered: a real meson setup, what cmake finds unscrubbed.

$script:gstScript = 'windows\scripts\build\Build-GstreamerFromSource.ps1'
$script:gstPins = @('-Dgst-plugins-bad:hip=enabled', '-Dgst-plugins-bad:amfcodec=enabled',
    '-Dgst-plugins-bad:d3d11=enabled', '-Dgst-plugins-bad:d3d12=enabled')

# Call-site tests read the script's text; Assert-GstScriptOrder needs every anchor present, in the given order.
function Get-GstScriptText { Get-Content (Join-Path (Get-RepoRoot) $script:gstScript) -Raw }
function Assert-GstScriptOrder {
    param([Parameter(Mandatory)][string[]]$Anchor, [Parameter(Mandatory)][string]$Label)
    $text = Get-GstScriptText
    $prev = -1
    foreach ($a in $Anchor) {
        $at = $text.IndexOf($a)
        Assert-True ($at -gt $prev) "${Label}: '$a' is present and follows the anchor before it"
        $prev = $at
    }
}

Describe 'Get-GstRocmMesonArgs (rocm lane only)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstScript -FunctionName 'Get-GstRocmMesonArgs')

    # A slice of the real amd64 meson line; the property is that NOTHING is spliced into it off-rocm.
    $script:baseArgs = @('setup', '--vsenv', '-Dwrap_mode=forcefallback', '-Dbad=enabled',
        '-Dgst-plugins-bad:nvcodec=disabled', '-Dglib:tests=false')

    # One fixture per lane: the env Get-GpuEnvironment reads, over a tree it accepts. HIP_PATH points at a
    # valid HIP tree on EVERY lane, so only GPU_TYPE can decide.
    function Get-GstLaneFixture {
        param([string]$Lane, [string]$Root)
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $Root 'lib\cmake\hip'))
        $vars = @{ GPU_TYPE = $Lane; HIP_PATH = $Root; ROCM_PATH = $null; TENSORRT_ROOT = ''
            CUDA_ROOT = $null; CUDA_PATH = $env:CUDA_PATH; CUDA_HOME = $env:CUDA_HOME; PATH = $env:PATH }
        if ($Lane -eq 'nvidia') { $vars['CUDA_ROOT'] = $Root }
        return $vars
    }

    It 'real Get-GpuEnvironment per lane: cpu and nvidia splice nothing, rocm the four pins in order' {
        $expect = [ordered]@{ '' = ''; cpu = ''; nvidia = ''; rocm = ($script:gstPins -join ' ') }
        foreach ($lane in $expect.Keys) {
            Invoke-InTestDir { param($dir)
                Invoke-WithEnv (Get-GstLaneFixture -Lane $lane -Root $dir) {
                    $gpu = Get-GpuEnvironment
                    Assert-Equal ($lane -eq 'nvidia') ([bool]$gpu.HasCuda) "fixture for '$lane' is that lane"
                    $line = @($script:baseArgs) + @(Get-GstRocmMesonArgs -GpuEnv $gpu)
                    $want = @($script:baseArgs) + @($expect[$lane] -split ' ' | Where-Object { $_ })
                    Assert-Equal ($want -join ' ') ($line -join ' ') "lane '$lane': meson line"
                }
            }
        }
    }

    It 'the script splices the pins once, after glib:tests and before the cross/caller args' {
        $text = Get-GstScriptText
        Assert-Match "(?s)'-Dglib:tests=false'\s*\)\s*\+\s*@\(Get-GstRocmMesonArgs -GpuEnv \`$gpuEnv\)\s*\+\s*\`$mesonCrossArgs\s*\+\s*\`$MesonSetupArgs" $text 'splice site'
        Assert-Equal 1 ([regex]::Matches($text, '\+ @\(Get-GstRocmMesonArgs')).Count 'spliced exactly once'
        foreach ($pin in $script:gstPins) {
            Assert-Equal 1 ([regex]::Matches($text, [regex]::Escape($pin))).Count "$pin is spelled only inside the rocm function"
        }
    }
}

Describe 'Get-GstRocmScrubbedSearchPath (TheRock out of every meson lookup)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstScript -FunctionName 'Get-GstRocmScrubbedSearchPath')

    It 'drops every entry under the root, in any slash or case form, and keeps order' {
        $envIn = @{
            PATH              = 'C:\runtime\bin;C:\TheRock\build\bin;C:\tools;c:/therock/build/lib/llvm/bin/'
            PKG_CONFIG_PATH   = 'C:\runtime\lib\pkgconfig;C:\TheRock\build\lib\rocm_sysdeps\lib\pkgconfig;C:\TheRock\build\share\pkgconfig'
            CMAKE_PREFIX_PATH = '"C:\TheRock\build"'
            LIB               = 'C:\vs\lib'
        }
        $r = Get-GstRocmScrubbedSearchPath -RocmRoot 'C:\TheRock\build' -Environment $envIn
        Assert-Equal 'CMAKE_PREFIX_PATH|PATH|PKG_CONFIG_PATH' (@($r.Keys) -join '|') 'only the variables that change'
        Assert-Equal 'C:\runtime\bin;C:\tools' $r['PATH'].Value 'PATH keeps the rest in order'
        Assert-Equal 'C:\TheRock\build\bin|c:/therock/build/lib/llvm/bin/' ($r['PATH'].Removed -join '|') 'PATH removals, as written'
        Assert-Equal 'C:\runtime\lib\pkgconfig' $r['PKG_CONFIG_PATH'].Value 'rocm_sysdeps + share pkgconfig gone'
        Assert-Equal '' $r['CMAKE_PREFIX_PATH'].Value 'a quoted root alone empties the variable'
    }

    It 'a sibling that only shares a prefix string is not the ROCm tree' {
        $r = Get-GstRocmScrubbedSearchPath -RocmRoot 'C:\TheRock\build\' -Environment @{ PATH = 'C:\TheRock\build2\bin;C:\TheRock\buildtools' }
        Assert-Equal 0 $r.Count 'build2 and buildtools survive'
    }

    It 'reads every search-path variable meson or its cmake probe uses from the process when none is passed' {
        # PATH is the route to TheRock's lib/cmake; dropping any name from the default list must go red here.
        $names = @('CMAKE_INCLUDE_PATH', 'CMAKE_LIBRARY_PATH', 'CMAKE_PREFIX_PATH', 'CMAKE_PROGRAM_PATH', 'INCLUDE', 'LIB',
            'PATH', 'PKG_CONFIG_LIBDIR', 'PKG_CONFIG_PATH')
        $vars = @{}
        foreach ($n in $names) { $vars[$n] = "C:\keep\$n;D:\rocm\$n" }
        Invoke-WithEnv $vars {
            $r = Get-GstRocmScrubbedSearchPath -RocmRoot 'D:\rocm'
            # Keys keep the process spelling (Windows says 'Path'); the dictionary itself ignores case.
            Assert-Equal ($names -join '|') (@($r.Keys | ForEach-Object { $_.ToUpperInvariant() }) -join '|') 'the whole default list, no more'
            Assert-Equal 'C:\keep\PKG_CONFIG_PATH' $r['PKG_CONFIG_PATH'].Value 'process PKG_CONFIG_PATH scrubbed'
        }
    }

}

Describe 'Set-GstRocmIsolation / Restore-GstRocmPath (the scrub, applied to the process)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstScript -FunctionName 'Get-GstRocmScrubbedSearchPath', 'Set-GstRocmIsolation', 'Restore-GstRocmPath')
    # No real variable names this root, so each case touches only the variables its Invoke-WithEnv restores.
    $script:fakeRoot = "D:\rocm-$([guid]::NewGuid().ToString('N'))"

    It 'apply: TheRock leaves PATH and CMAKE_PREFIX_PATH, an emptied variable is removed, the rest is untouched' {
        $root = $script:fakeRoot
        Invoke-WithEnv @{ PATH = "C:\a;$root\bin;C:\b"; CMAKE_PREFIX_PATH = $root
            PKG_CONFIG_LIBDIR = "$root\lib\pkgconfig"; PKG_CONFIG_PATH = 'C:\p\pkgconfig' } {
            $scrub = Set-GstRocmIsolation -RocmRoot $root
            Assert-Equal 'C:\a;C:\b' $env:PATH 'PATH without the ROCm bin, order kept'
            Assert-False (Test-Path Env:CMAKE_PREFIX_PATH) 'CMAKE_PREFIX_PATH is gone, not set to ""'
            Assert-False (Test-Path Env:PKG_CONFIG_LIBDIR) 'PKG_CONFIG_LIBDIR is gone, so pkg-config keeps its defaults'
            Assert-Equal 'C:\p\pkgconfig' $env:PKG_CONFIG_PATH 'a clean variable is left alone'
            Assert-Equal "$root\bin" ($scrub['PATH'].Removed -join '|') 'the scrub is returned for the restore'
        }
    }

    It 'restore: the ROCm bin comes back LAST on PATH; an empty scrub (cpu/nvidia) changes nothing' {
        $root = $script:fakeRoot
        Invoke-WithEnv @{ PATH = "$root\bin;C:\a;C:\b" } {
            $scrub = Set-GstRocmIsolation -RocmRoot $root
            $env:PATH = "C:\added;$env:PATH"
            Restore-GstRocmPath -Scrub $scrub
            Assert-Equal "C:\added;C:\a;C:\b;$root\bin" $env:PATH 'appended last, in the image''s order'
            Restore-GstRocmPath -Scrub ([ordered]@{})
            Assert-Equal "C:\added;C:\a;C:\b;$root\bin" $env:PATH 'empty scrub is a no-op'
        }
    }
}

Describe 'Get-GstRocmMissingArtifact (hip=enabled cannot fail setup at 1.29.2)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstScript -FunctionName 'Get-GstRocmMissingArtifact')
    $script:amdFiles = @('bin\gsthip-0.dll', 'lib\gstreamer-1.0\gsthip.dll', 'lib\gstreamer-1.0\gstamfcodec.dll',
        'lib\gstreamer-1.0\gstd3d11.dll', 'lib\gstreamer-1.0\gstd3d12.dll')

    It 'names exactly the files a lost AMD path leaves out, and nothing on a complete install' {
        # Each case installs all five but the '|'-joined ones it names: none, each alone, all of them.
        foreach ($gone in @('') + $script:amdFiles + @($script:amdFiles -join '|')) {
            Invoke-InTestDir { param($dir)
                $script:amdFiles | Where-Object { ($gone -split '\|') -notcontains $_ } |
                    ForEach-Object { [void](New-Item -ItemType File -Force -Path (Join-Path $dir $_)) }
                Assert-Equal $gone (@(Get-GstRocmMissingArtifact -InstallDir $dir) -join '|') "install without [$gone]"
            }
        }
        Invoke-InTestDir { param($dir)
            $script:amdFiles | ForEach-Object { [void](New-Item -ItemType Directory -Force -Path (Join-Path $dir $_)) }
            Assert-Equal ($script:amdFiles -join '|') (@(Get-GstRocmMissingArtifact -InstallDir $dir) -join '|') 'a directory of that name is no DLL'
        }
    }

}

Describe 'Build-GstreamerFromSource.ps1: where the rocm steps run' {
    It 'scrub before every lookup, AMD file check after install, PATH back before phase 9; both gated on HasRocm' {
        $text = Get-GstScriptText
        Assert-Match '(?s)if \(\$gpuEnv\.HasRocm\) \{\s*\$rocmScrub = Set-GstRocmIsolation -RocmRoot \$gpuEnv\.RocmRoot' $text 'scrub: rocm only'
        Assert-Match '(?s)if \(\$gpuEnv\.HasRocm\) \{\s*\$rocmMissing = @\(Get-GstRocmMissingArtifact -InstallDir \$resolvedInstallDir\)\s*if \(\$rocmMissing\.Count -gt 0\) \{ throw ' $text 'file check: rocm only, fatal'
        Assert-GstScriptOrder -Label 'rocm steps' -Anchor @('$rocmScrub = Set-GstRocmIsolation', 'Assert-PkgConfigModule -Module',
            "Switch-BuildPhase '6. meson setup'", "Switch-BuildPhase '8. install'", "log 'Installation complete.'",
            '$rocmMissing = @(Get-GstRocmMissingArtifact', 'Restore-GstRocmPath -Scrub $rocmScrub', "Switch-BuildPhase '9. verify")
    }
}

Describe 'Get-GstRocmLeakFinding (the proof for the scrub)' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstScript -FunctionName 'Get-GstRocmLeakFinding')

    It 'names file and line for the root in any spelling, and stays silent on a clean build' {
        # file -> (content, expected finding pattern or '' for clean)
        $cases = [ordered]@{
            'clean.ninja' = @(@('build x.obj: c_COMPILER ../x.c', ' ARGS = -IC:/runtime/include'), '')
            'clean.json'  = @(@('[{"name": "zlib", "compile_args": ["-IC:\\runtime\\include"]}]'), '')
            'fwd.ninja'   = @(@('rule c', ' ARGS = -Ic:/therock/build/include'), '^fwd\.ninja:2 names the ROCm tree')
            'back.ninja'  = @(@('LINK_ARGS = C:\TheRock\build\lib\zlib.lib'), '^back\.ninja:1 ')
            'esc.json'    = @(@('[{"name": "flatbuffers", "include_directories": ["C:\\TheRock\\build\\include"]}]'), '^esc\.json:1 .*flatbuffers')
        }
        Invoke-InTestDir { param($dir)
            $cases.GetEnumerator() | ForEach-Object { [System.IO.File]::WriteAllLines((Join-Path $dir $_.Key), [string[]]$_.Value[0]) }
            $found = @(Get-GstRocmLeakFinding -RocmRoot 'C:\TheRock\build' -Path @($cases.Keys | ForEach-Object { Join-Path $dir $_ }))
            $want = @($cases.Values | ForEach-Object { $_[1] } | Where-Object { $_ })
            Assert-Equal $want.Count $found.Count "one finding per leaking file: $($found -join ' | ')"
            for ($i = 0; $i -lt $want.Count; $i++) { Assert-Match $want[$i] $found[$i] "finding $i" }
        }
    }

    It 'a missing file is a finding, never a vacuous pass' {
        Invoke-InTestDir { param($dir)
            Assert-Match 'missing, so nothing proves' @(Get-GstRocmLeakFinding -RocmRoot 'C:\TheRock\build' -Path (Join-Path $dir 'build.ninja'))[0] 'missing build.ninja'
        }
    }

    It 'the script runs it after meson setup on HasRocm, over build.ninja and intro-dependencies.json, and throws' {
        $text = Get-GstScriptText
        Assert-Match "(?s)log 'meson setup completed\.'\s*if \(\`$gpuEnv\.HasRocm\) \{\s*\`$rocmLeaks = @\(Get-GstRocmLeakFinding" $text 'gate right after setup, rocm only'
        Assert-Match "build\.ninja'\), \(Join-Path \`$resolvedBuildDir 'meson-info\\intro-dependencies\.json'\)" $text 'both files'
        Assert-Match 'if \(\$rocmLeaks\.Count -gt 0\) \{ throw ' $text 'a leak fails the build'
    }
}

# ---- rocm-checks/GStreamer.ps1 (runs in the final rocm image, no GPU) ----
# Fixtures are real System32 bytes: msimg32.dll imports ntdll + GDI32 and exports AlphaBlend & co; a copy
# with its GDI32 import renamed is the mutation that must go red.
$script:gstCheck = 'windows\scripts\build\rocm-checks\GStreamer.ps1'
$script:sys32 = Join-Path $env:SystemRoot 'System32'

function New-GstFixtureDll {
    param([string]$Path, [string]$RenameImport = '')
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:sys32 'msimg32.dll'))
    if ($RenameImport) {
        $at = [System.Text.Encoding]::Latin1.GetString($bytes).IndexOf("GDI32.dll`0")
        if ($at -lt 0) { throw 'fixture: msimg32.dll no longer imports GDI32.dll' }
        [System.Text.Encoding]::ASCII.GetBytes($RenameImport).CopyTo($bytes, $at)
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function New-GstFakeInspect {
    param([string]$Path)
    Set-Content -LiteralPath $Path -Encoding ASCII -Value @(
        '@echo off', 'if "%~1"=="good" (echo   2 features:& exit /b 0)', 'exit /b 255')
}

Describe 'rocm-checks/GStreamer.ps1: PE readers' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstCheck -FunctionName 'Get-GstPeExportName', 'Get-GstDllClosure')

    It 'reads export names from real system DLLs and refuses a non-PE' {
        $k32 = @(Get-GstPeExportName -Path (Join-Path $script:sys32 'kernel32.dll'))
        Assert-True ($k32 -contains 'LoadLibraryW' -and $k32.Count -gt 1000) 'kernel32 exports'
        Assert-Equal 'AlphaBlend|DllInitialize|GradientFill|TransparentBlt|vSetDdrawflag' ((Get-GstPeExportName -Path (Join-Path $script:sys32 'msimg32.dll')) -join '|') 'msimg32, in table order'
        Invoke-InTestDir { param($dir)
            Set-Content -LiteralPath (Join-Path $dir 'x.dll') -Value 'not a PE file at all'
            Assert-Throws { Get-GstPeExportName -Path (Join-Path $dir 'x.dll') } 'text file'
        }
    }

    It 'the closure resolves on the search dirs, skips API sets and never searches the DLL''s own folder' {
        Invoke-InTestDir { param($dir)
            $good = Join-Path $dir 'ok\a.dll'
            $mutant = Join-Path $dir 'bad\a.dll'
            New-GstFixtureDll -Path $good
            New-GstFixtureDll -Path $mutant -RenameImport 'GDQ32.dll'
            New-GstFixtureDll -Path (Join-Path $dir 'bad\GDQ32.dll')
            $edges = @(Get-GstDllClosure -Path $good -SearchDir $script:sys32)
            Assert-Equal 'GDI32.dll=True|ntdll.dll=True' (@($edges | Sort-Object Name | ForEach-Object { "$($_.Name)=$([bool]$_.Path)" }) -join '|') 'two real edges, API sets skipped, both in System32'
            $unresolved = { param($d) @(Get-GstDllClosure -Path $mutant -SearchDir $d | Where-Object { -not $_.Path } | ForEach-Object { "$($_.From) -> $($_.Name)" }) -join '|' }
            Assert-Equal 'a.dll -> GDQ32.dll' (& $unresolved @($script:sys32)) 'a sibling file does not count'
            Assert-Equal '' (& $unresolved @($script:sys32, (Split-Path $mutant -Parent))) 'resolves once its folder is a search dir'
            # Transitive: GDQ32.dll on a search dir that itself imports a missing GDZ32.dll.
            New-GstFixtureDll -Path (Join-Path $dir 'deep\GDQ32.dll') -RenameImport 'GDZ32.dll'
            Assert-Equal 'GDQ32.dll -> GDZ32.dll' (& $unresolved @($script:sys32, (Join-Path $dir 'deep'))) 'walks into non-System32 hits'
        }
    }
}

Describe 'rocm-checks/GStreamer.ps1: the HIP runtime gsthip opens' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstCheck -FunctionName 'Get-GstPeExportName', 'Get-GstDllClosure',
        'Get-GstHiprtcDllName', 'Get-GstHipRuntimeFinding')

    It 'derives hiprtc<MMmm>.dll the way gsthiprtc.cpp does' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir '.hipVersion'
            Set-Content -LiteralPath $f -Value '# cmake', 'HIP_VERSION_MAJOR=7', 'HIP_VERSION_MINOR=15', 'HIP_VERSION_PATCH=26333'
            Assert-Equal 'hiprtc0715.dll' (Get-GstHiprtcDllName -HipVersionFile $f) 'TheRock 10.0.0'
            Set-Content -LiteralPath $f -Value 'HIP_VERSION_MINOR=2', 'HIP_VERSION_MAJOR=10'
            Assert-Equal 'hiprtc1002.dll' (Get-GstHiprtcDllName -HipVersionFile $f) 'two-digit pad, any order'
            Set-Content -LiteralPath $f -Value 'HIP_VERSION_MAJOR=7'
            Assert-Null (Get-GstHiprtcDllName -HipVersionFile $f) 'no minor, no name'
        }
    }

    # A HIP root of msimg32 copies (TheRock 10.0.0 names); -BreakImport renames amdhip64's GDI32 import.
    function New-GstFakeHipRoot {
        param([string]$Root, [switch]$BreakImport, [switch]$WithBuiltins)
        New-GstFixtureDll -Path (Join-Path $Root 'bin\amdhip64_7.dll') -RenameImport $(if ($BreakImport) { 'GDQ32.dll' } else { '' })
        New-GstFixtureDll -Path (Join-Path $Root 'bin\hiprtc0715.dll')
        [System.IO.File]::WriteAllLines((Join-Path $Root 'bin\.hipVersion'), [string[]]@('HIP_VERSION_MAJOR=7', 'HIP_VERSION_MINOR=15'))
        if ($WithBuiltins) { [System.IO.File]::WriteAllText((Join-Path $Root 'bin\hiprtc-builtins0715.dll'), 'x') }
    }

    It 'passes a complete runtime and names each breach of a broken one' {
        Invoke-InTestDir { param($dir)
            New-GstFakeHipRoot -Root (Join-Path $dir 'good') -WithBuiltins
            New-GstFakeHipRoot -Root (Join-Path $dir 'bad') -BreakImport
            $clean = @(Get-GstHipRuntimeFinding -HipRoot (Join-Path $dir 'good') -SearchDir @($script:sys32, (Join-Path $dir 'good\bin')) `
                    -HipSymbol 'AlphaBlend' -RtcSymbol 'GradientFill')
            Assert-Equal 0 $clean.Count "complete runtime: $($clean -join ' | ')"
            $broken = @(Get-GstHipRuntimeFinding -HipRoot (Join-Path $dir 'bad') -SearchDir @($script:sys32))
            $all = $broken -join "`n"
            Assert-Match 'amdhip64_7\.dll does not export hipInit, .*hipGraphicsGLRegisterBuffer' $all 'the full 1.29.2 loader list is required'
            Assert-Match 'hiprtc0715\.dll does not export hiprtcCreateProgram' $all 'hiprtc list'
            Assert-Match 'amdhip64_7\.dll -> GDQ32\.dll resolves nowhere' $all 'unresolved import'
            Assert-Match 'hiprtc-builtins0715\.dll is not on PATH' $all 'builtins'
            Assert-Equal 4 $broken.Count 'exactly those four'
        }
    }

    It 'no runtime or no .hipVersion is a finding, not a pass' {
        Invoke-InTestDir { param($dir)
            Assert-Match 'no amdhip64_\*\.dll' @(Get-GstHipRuntimeFinding -HipRoot $dir -SearchDir @($script:sys32))[0] 'empty root'
            New-GstFixtureDll -Path (Join-Path $dir 'bin\amdhip64_7.dll')
            Assert-Match '\.hipVersion is missing' @(Get-GstHipRuntimeFinding -HipRoot $dir -SearchDir @($script:sys32))[0] 'no .hipVersion'
        }
    }
}

Describe 'rocm-checks/GStreamer.ps1: plugins and the load probe' {
    . (Get-ScriptFunctionDefinition -ScriptPath $script:gstCheck -FunctionName 'Get-GstDllClosure', 'Invoke-GstInspectProbe', 'Get-GstPluginFinding')

    It 'probe: exit code and output of the inspector, $null on a hang' {
        Invoke-InTestDir { param($dir)
            $fake = Join-Path $dir 'inspect.cmd'
            New-GstFakeInspect -Path $fake
            $ok = Invoke-GstInspectProbe -GstInspect $fake -Plugin 'good'
            Assert-Equal 0 $ok.ExitCode 'good exits 0'
            Assert-Match '2 features' $ok.Output 'stdout captured'
            Assert-Equal 255 (Invoke-GstInspectProbe -GstInspect $fake -Plugin 'bad').ExitCode 'unknown plugin'
            Set-Content -LiteralPath $fake -Encoding ASCII -Value '@echo off', 'ping -n 30 127.0.0.1 >nul'
            Assert-Null (Invoke-GstInspectProbe -GstInspect $fake -Plugin 'good' -TimeoutSec 2).ExitCode 'hang reported'
            $left = @(Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" | Where-Object { "$($_.CommandLine)".Contains($fake) })
            Assert-Equal 0 $left.Count 'the hung tree is killed, not orphaned'
        }
    }

    It 'one finding per breach: missing, unresolved, static vendor link, failed load; host-provided skips the probe' {
        # Plugin 'nope' makes the fake inspector fail, so a row expecting '' also proves the probe was skipped.
        $rows = @(
            [pscustomobject]@{ Name = 'good'; File = 'clean.dll'; With = @{}; Expect = '' }
            [pscustomobject]@{ Name = 'hip'; File = 'absent.dll'; With = @{}; Expect = '^hip plugin was not built' }
            [pscustomobject]@{ Name = 'good'; File = 'mutant.dll'; With = @{}; Expect = 'mutant\.dll -> GDQ32\.dll resolves nowhere' }
            [pscustomobject]@{ Name = 'good'; File = 'clean.dll'; With = @{ Forbid = '^GDI32' }; Expect = 'links GDI32\.dll statically' }
            [pscustomobject]@{ Name = 'nope'; File = 'clean.dll'; With = @{}; Expect = 'exited 255, the plugin did not load' }
            [pscustomobject]@{ Name = 'nope'; File = 'mutant.dll'; With = @{ HostProvided = '^GDQ32\.dll$' }; Expect = '' }
        )
        Invoke-InTestDir { param($dir)
            New-GstFixtureDll -Path (Join-Path $dir 'clean.dll')
            New-GstFixtureDll -Path (Join-Path $dir 'mutant.dll') -RenameImport 'GDQ32.dll'
            New-GstFakeInspect -Path (Join-Path $dir 'inspect.cmd')
            foreach ($row in $rows) {
                $with = $row.With
                $got = @(Get-GstPluginFinding -Plugin $row.Name -Dll (Join-Path $dir $row.File) -SearchDir $script:sys32 `
                        -GstInspect (Join-Path $dir 'inspect.cmd') @with)
                $label = "$($row.Name)/$($row.File): got [$($got -join ' | ')]"
                if ($row.Expect) { Assert-True ($got.Count -eq 1 -and $got[0] -match $row.Expect) $label } else { Assert-Equal 0 $got.Count $label }
            }
        }
    }

    It 'the default host-provided set is exactly GL and Vulkan' {
        $text = Get-Content (Join-Path (Get-RepoRoot) $script:gstCheck) -Raw
        Assert-Match "\[string\]\`$HostProvided = '\^\(opengl32\|vulkan-1\)\\\.dll\`$'" $text 'OPENGL32 (gstgl) and vulkan-1 (gstvulkan) only'
    }
}

Describe 'rocm-checks/GStreamer.ps1: the whole script' {
    It 'writes only finding strings, one per missing piece, and restores GST_REGISTRY' {
        Invoke-InTestDir { param($dir)
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'bin'), (Join-Path $dir 'hip') | Out-Null
            Invoke-WithEnv @{ GSTREAMER_BIN = (Join-Path $dir 'bin'); HIP_PATH = (Join-Path $dir 'hip'); GST_REGISTRY = 'C:\keep\me.bin' } {
                $out = @(& (Join-Path (Get-RepoRoot) $script:gstCheck))
                Assert-True (@($out | Where-Object { $_ -isnot [string] }).Count -eq 0) 'nothing but strings on the pipeline'
                $all = $out -join "`n"
                foreach ($p in 'd3d11', 'd3d12', 'amfcodec', 'hip') { Assert-Match "$p plugin was not built" $all "$p reported" }
                Assert-Match 'gst-inspect-1\.0\.exe missing' $all 'inspector reported'
                Assert-Match 'no amdhip64_\*\.dll' $all 'HIP runtime reported'
                Assert-Equal 6 $out.Count 'exactly six findings'
                Assert-Equal 'C:\keep\me.bin' $env:GST_REGISTRY 'registry override restored'
            }
        }
    }

    It 'with HIP_PATH unset it says so instead of skipping silently' {
        Invoke-InTestDir { param($dir)
            Invoke-WithEnv @{ GSTREAMER_BIN = $dir; HIP_PATH = $null } {
                Assert-Match 'HIP_PATH is not set' (@(& (Join-Path (Get-RepoRoot) $script:gstCheck)) -join "`n") 'HIP_PATH finding'
            }
        }
    }
}
