#requires -Version 7.0
# Tests for the source-patch helpers that decide whether every upstream patch lands.
# A silent regression here mis-patches a source tree and blows up mid-build, so these
# are the highest-value units in the suite.

Describe 'Invoke-InlineRegexPatch' {

    It 'replaces a match, writes the file, and returns $true' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'link ${DIR}/libfoo.a here' -NoNewline
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'lib([a-z]+)\.a' -Replacement '$1.lib' -Description 'c'
            Assert-True $r 'should report a modification'
            Assert-Equal 'link ${DIR}/foo.lib here' (Get-Content $f -Raw)
        }
    }

    It 'does nothing and returns $false when -Guard does not match' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'libfoo.a' -NoNewline
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'libfoo\.a' -Replacement 'foo.lib' -Guard 'THIS_IS_ABSENT' -Description 'c'
            Assert-False $r 'guard miss must skip'
            Assert-Equal 'libfoo.a' (Get-Content $f -Raw) 'file must be untouched'
        }
    }

    It 'applies when -Guard matches' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'MARKER libfoo.a' -NoNewline
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'libfoo\.a' -Replacement 'foo.lib' -Guard 'MARKER' -Description 'c'
            Assert-True $r
            Assert-Equal 'MARKER foo.lib' (Get-Content $f -Raw)
        }
    }

    It 'warns and returns $false when the pattern is present-but-unchanged (no-op)' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'hello world' -NoNewline
            $captured = & { Invoke-InlineRegexPatch -Path $f -Pattern 'no-such-token' -Replacement 'x' -Description 'c' } 3>&1
            $warns = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            Assert-True ($warns.Count -ge 1) 'a silent miss must surface a warning'
            Assert-Equal 'hello world' (Get-Content $f -Raw) 'file must be unchanged on no-op'
        }
    }

    It 'returns $false for a missing file (no -Require)' {
        Invoke-InTestDir { param($dir)
            $r = Invoke-InlineRegexPatch -Path (Join-Path $dir 'ghost.cmake') -Pattern 'a' -Replacement 'b'
            Assert-False $r
        }
    }

    It 'throws for a missing file with -Require' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Invoke-InlineRegexPatch -Path (Join-Path $dir 'ghost.cmake') -Pattern 'a' -Replacement 'b' -Require }
        }
    }

    It 'replaces ALL occurrences, not just the first' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'liba.a libb.a libc.a' -NoNewline
            [void](Invoke-InlineRegexPatch -Path $f -Pattern 'lib([a-z])\.a' -Replacement '$1.lib')
            Assert-Equal 'a.lib b.lib c.lib' (Get-Content $f -Raw)
        }
    }
}

Describe 'Add-FileBlockOnce' {

    It 'appends the block and returns $true on first application' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'patcher.cmake'
            Set-Content -Path $f -Value 'original' -NoNewline
            $r = Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block" -Description 'p'
            Assert-True $r
            Assert-Match 'original' (Get-Content $f -Raw)
            Assert-Match 'WINFIX-A block' (Get-Content $f -Raw)
        }
    }

    It 'is idempotent: a second call with the marker present is a no-op' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'patcher.cmake'
            Set-Content -Path $f -Value 'original' -NoNewline
            [void](Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block")
            $lenAfterFirst = (Get-Content $f -Raw).Length
            $r2 = Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block"
            Assert-False $r2 'second application must be skipped'
            Assert-Equal $lenAfterFirst (Get-Content $f -Raw).Length 'content must not grow on re-run'
        }
    }

    It '-Prepend inserts the block before existing content' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'src.cc'
            Set-Content -Path $f -Value 'int main(){}' -NoNewline
            [void](Add-FileBlockOnce -Path $f -Marker 'PRAGMA-X' -Content "// PRAGMA-X`n" -Prepend)
            $raw = Get-Content $f -Raw
            Assert-True ($raw.IndexOf('PRAGMA-X') -lt $raw.IndexOf('int main')) 'prepended block must come first'
        }
    }

    It 'returns $false for a missing file, throws with -Require' {
        Invoke-InTestDir { param($dir)
            Assert-False (Add-FileBlockOnce -Path (Join-Path $dir 'ghost') -Marker 'M' -Content 'x')
            Assert-Throws { Add-FileBlockOnce -Path (Join-Path $dir 'ghost') -Marker 'M' -Content 'x' -Require }
        }
    }
}

Describe 'Edit-SourceFile' {

    It 'runs the transform, writes the file, and returns $true' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'a.txt'
            Set-Content -Path $f -Value 'hello world' -NoNewline
            $r = Edit-SourceFile -Path $f -Transform { param($c) $c.Replace('world', 'there') }
            Assert-True $r 'should report a modification'
            Assert-Equal 'hello there' (Get-Content $f -Raw)
        }
    }

    It 'preserves a literal $-bearing injection verbatim (the reason this exists, not Invoke-InlineRegexPatch)' {
        # A CMake ${VAR} routed through -replace would be misread as a replacement group ref and vanish;
        # Edit-SourceFile keeps it because the transform is a scriptblock doing a literal .Replace.
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'b.cmake'
            Set-Content -Path $f -Value 'set(X ANCHOR)' -NoNewline
            $inject = 'set(FLATC "${FLATBUFFERS_INSTALL_PREFIX}/bin/flatc.exe")'
            [void](Edit-SourceFile -Path $f -Transform { param($c) $c.Replace('ANCHOR', ($inject + 'ANCHOR')) })
            Assert-Equal ('set(X ' + $inject + 'ANCHOR)') (Get-Content $f -Raw)
        }
    }

    It 'skips (returns $false) when -Marker is already present' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'c.txt'
            Set-Content -Path $f -Value 'already MARKER here' -NoNewline
            $r = Edit-SourceFile -Path $f -Marker 'MARKER' -Transform { param($c) $c.Replace('here', 'THERE') }
            Assert-False $r 'marker present must skip'
            Assert-Equal 'already MARKER here' (Get-Content $f -Raw) 'file must be untouched'
        }
    }

    It 'warns and returns $false when the transform makes no change (anchor absent)' {
        Invoke-InTestDir { param($dir)
            $f = Join-Path $dir 'd.txt'
            Set-Content -Path $f -Value 'unchanged' -NoNewline
            $captured = & { Edit-SourceFile -Path $f -Transform { param($c) $c.Replace('ZZZ', 'QQQ') } -WarnMessage 'anchor not found' } 3>&1
            $warns = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            Assert-True ($warns.Count -ge 1) 'a no-op transform must surface a warning'
            Assert-Equal 'unchanged' (Get-Content $f -Raw) 'file must be unchanged on no-op'
        }
    }

    It 'returns $false for a missing file, throws with -Require' {
        Invoke-InTestDir { param($dir)
            Assert-False (Edit-SourceFile -Path (Join-Path $dir 'ghost') -Transform { param($c) $c })
            Assert-Throws { Edit-SourceFile -Path (Join-Path $dir 'ghost') -Transform { param($c) $c } -Require }
        }
    }
}

Describe 'Invoke-SourcePatchWithFallback' {

    # Each test dir becomes a tiny git repo so Invoke-SourcePatch's rung-1
    # check runs through `git apply` (host patch.exe availability varies).
    $newPatchRepo = {
        param($dir)
        $null = & git -C $dir init 2>&1
        [System.IO.File]::WriteAllText((Join-Path $dir 't.txt'), "old`n")
    }
    $goodPatch = "--- a/t.txt`n+++ b/t.txt`n@@ -1 +1 @@`n-old`n+new`n"
    $badPatch = "--- a/t.txt`n+++ b/t.txt`n@@ -1 +1 @@`n-DOES NOT MATCH`n+whatever`n"

    It 'applies rung 1 and never invokes the fallback' {
        Invoke-InTestDir { param($dir)
            & $newPatchRepo $dir
            $patch = Join-Path $dir 'p.patch'
            [System.IO.File]::WriteAllText($patch, $goodPatch)
            $flag = Join-Path $dir 'fallback-ran.flag'
            $r = Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fallback { Set-Content -Path $flag -Value 'x'; $true }
            Assert-True $r 'rung 1 applied must report $true'
            # git apply rewrites EOLs under core.autocrlf - compare content only.
            Assert-Equal 'new' ([System.IO.File]::ReadAllText((Join-Path $dir 't.txt')).Trim()) 'the .patch content must have landed'
            Assert-False (Test-Path $flag) 'fallback must not run when the .patch applies'
        }
    }

    It 'falls back when the .patch does not apply and reports the fallback verdict' {
        Invoke-InTestDir { param($dir)
            & $newPatchRepo $dir
            $patch = Join-Path $dir 'p.patch'
            [System.IO.File]::WriteAllText($patch, $badPatch)
            $target = Join-Path $dir 't.txt'
            $r = Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fallback {
                Invoke-InlineRegexPatch -Path $target -Pattern 'old' -Replacement 'inline' -Description 't'
            }
            Assert-True $r 'a successful inline fallback must report $true'
            Assert-Equal 'inline' ([System.IO.File]::ReadAllText($target).Trim())
        }
    }

    It 'returns $false (no throw) when both rungs miss without -Fatal' {
        Invoke-InTestDir { param($dir)
            & $newPatchRepo $dir
            $patch = Join-Path $dir 'p.patch'
            [System.IO.File]::WriteAllText($patch, $badPatch)
            $r = & { Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fallback { $false } } 3>$null
            Assert-False $r 'double miss without -Fatal stays a warning-level verdict'
        }
    }

    It 'throws on a double miss with -Fatal (backlog #19: load-bearing patches must not rot silently)' {
        Invoke-InTestDir { param($dir)
            & $newPatchRepo $dir
            $patch = Join-Path $dir 'p.patch'
            [System.IO.File]::WriteAllText($patch, $badPatch)
            Assert-Throws { Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fatal -Fallback { $false } } `
                -MessagePattern 'BOTH the \.patch and the inline fallback' `
                'a rotted load-bearing patch must fail the build at patch time'
        }
    }
}
