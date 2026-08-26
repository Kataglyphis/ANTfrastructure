#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Select-MesonLogExcerpt (build-gstreamer-from-source.ps1): the bounded
# meson-log.txt excerpt that replaced streaming 400k-800k lines through `log`
# after a failed `meson setup` (30-60 min per attempt on arm64 runs 23-25).
# The function is lifted out of the script's AST -- it is a pure function, and
# the script itself is a build. Pins: diagnostic lines are kept with 1-based
# numbers, a "Sanity check" header pulls its block along, probe `error:` noise
# is NOT kept, the cap holds, the tail is exact, and empty input is safe.

Describe 'Select-MesonLogExcerpt' {

    BeforeAll {

        $script:fixture = @(
            'Build started at 2026-08-26T02:07:07',                                         # 1
            'glib| Using cached compile:',                                                   # 2
            'glib| testfile.c(3): error: use of undeclared identifier ''strlcpy''',           # 3  probe noise, NOT kept
            'glib| Checking for function "strlcpy" : NO',                                    # 4
            'Sanity check compiler command line: clang-cl /nologo sanity.c',                 # 5  block header
            'Sanity check compile stdout:',                                                  # 6  context
            '-----',                                                                         # 7  context
            'Sanity check compile stderr:',                                                  # 8  block header (again)
            'lld-link: error: libcmt.lib(exe_main.obj): machine type arm64 conflicts with x64', # 9 diag + context
            '-----',                                                                         # 10 context
            'glib| meson.build:2777:0: Exception: Summary section already have key',         # 11 diag
            'gstreamer| Subproject subprojects\glib-2.86.3 is buildable: NO (disabling)',     # 12 diag
            'libnice| meson.build:214:4: Exception: Subproject "subprojects/glib" required but not found.', # 13 diag
            'WARNING: Project targets ''>= 0.52'' but uses feature introduced in ''0.54.0''', # 14 NOT kept
            'filler line A',                                                                 # 15
            'filler line B',                                                                 # 16
            'nice/meson.build:16:14: ERROR: Subproject "subprojects/libnice" required but not found.' # 17 diag
        )
    }

    It 'keeps every diagnostic line with its 1-based number and drops probe noise' {
        $r = Select-MesonLogExcerpt -Lines $script:fixture -TailLines 2 -BlockContext 2
        Assert-Equal 17 $r.Total 'total'
        $numbers = @($r.Diagnostics | ForEach-Object { [int]($_ -replace '^\s*(\d+):.*$', '$1') })
        Assert-True ($numbers -contains 11) 'Exception line kept'
        Assert-True ($numbers -contains 12) 'buildable: NO line kept'
        Assert-True ($numbers -contains 13) 'required but not found kept'
        Assert-True ($numbers -contains 17) 'ERROR line kept'
        Assert-True ($numbers -contains 9)  'conflicts with kept'
        Assert-False ($numbers -contains 3) 'probe error: noise not kept'
        Assert-False ($numbers -contains 14) 'WARNING not kept'
        Assert-False ($numbers -contains 15) 'filler not kept'
        Assert-True ($r.Diagnostics[0] -match '^\s+5: Sanity check compiler command line') 'first picked line is numbered and ordered'
    }

    It 'pulls the block after a Sanity check header along (BlockContext lines)' {
        $r = Select-MesonLogExcerpt -Lines $script:fixture -TailLines 1 -BlockContext 2
        $numbers = @($r.Diagnostics | ForEach-Object { [int]($_ -replace '^\s*(\d+):.*$', '$1') })
        # header 5 -> 6,7 ; header 8 -> 9,10
        foreach ($n in 5, 6, 7, 8, 9, 10) { Assert-True ($numbers -contains $n) "block line $n kept" }
        Assert-False ($numbers -contains 4) 'line before the header not kept'
    }

    It 'counts every diagnostic but caps what it returns' {
        $r = Select-MesonLogExcerpt -Lines $script:fixture -TailLines 1 -BlockContext 0 -MaxDiagnostics 2
        Assert-Equal 2 $r.Diagnostics.Count 'cap honoured'
        Assert-True ($r.DiagnosticTotal -ge 6) "all diagnostics counted (got $($r.DiagnosticTotal))"
    }

    It 'returns exactly the last N lines as the tail, in order' {
        $r = Select-MesonLogExcerpt -Lines $script:fixture -TailLines 3
        Assert-Equal 3 $r.Tail.Count 'tail length'
        Assert-Equal 'filler line A' $r.Tail[0] 'tail start'
        Assert-True ($r.Tail[2] -like 'nice/meson.build:16:14: ERROR*') 'tail end'
    }

    It 'handles empty input and a tail longer than the file' {
        $r = Select-MesonLogExcerpt -Lines @() -TailLines 5
        Assert-Equal 0 $r.Total 'empty total'
        Assert-Equal 0 $r.Diagnostics.Count 'empty diagnostics'
        Assert-Equal 0 $r.Tail.Count 'empty tail'
        $r2 = Select-MesonLogExcerpt -Lines @('only line') -TailLines 5
        Assert-Equal 1 $r2.Tail.Count 'tail clipped to file length'
    }
}
