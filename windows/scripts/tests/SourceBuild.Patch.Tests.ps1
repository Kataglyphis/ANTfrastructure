#requires -Version 7.0
# The patch helpers decide whether every upstream patch lands; a silent regression blows up mid-build.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -DisableNameChecking

Describe 'Invoke-InlineRegexPatch' {

    It 'replaces a match, writes the file, and returns $true' {
        Invoke-InTestDir -Files @{ 'c.cmake' = 'link ${DIR}/libfoo.a here' } -Body { param($dir)
            $f = Join-Path $dir 'c.cmake'
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'lib([a-z]+)\.a' -Replacement '$1.lib' -Description 'c'
            Assert-True $r 'should report a modification'
            Assert-Equal 'link ${DIR}/foo.lib here' (Get-Content $f -Raw)
        }
    }

    It 'does nothing and returns $false when -Guard does not match' {
        Invoke-InTestDir -Files @{ 'c.cmake' = 'libfoo.a' } -Body { param($dir)
            $f = Join-Path $dir 'c.cmake'
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'libfoo\.a' -Replacement 'foo.lib' -Guard 'THIS_IS_ABSENT' -Description 'c'
            Assert-False $r 'guard miss must skip'
            Assert-Equal 'libfoo.a' (Get-Content $f -Raw) 'file must be untouched'
        }
    }

    It 'applies when -Guard matches' {
        Invoke-InTestDir -Files @{ 'c.cmake' = 'MARKER libfoo.a' } -Body { param($dir)
            $f = Join-Path $dir 'c.cmake'
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'libfoo\.a' -Replacement 'foo.lib' -Guard 'MARKER' -Description 'c'
            Assert-True $r
            Assert-Equal 'MARKER foo.lib' (Get-Content $f -Raw)
        }
    }

    It 'warns and returns $false when the pattern is present-but-unchanged (no-op)' {
        Invoke-InTestDir -Files @{ 'c.cmake' = 'hello world' } -Body { param($dir)
            $f = Join-Path $dir 'c.cmake'
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
        Invoke-InTestDir -Files @{ 'c.cmake' = 'liba.a libb.a libc.a' } -Body { param($dir)
            $f = Join-Path $dir 'c.cmake'
            [void](Invoke-InlineRegexPatch -Path $f -Pattern 'lib([a-z])\.a' -Replacement '$1.lib')
            Assert-Equal 'a.lib b.lib c.lib' (Get-Content $f -Raw)
        }
    }
}

Describe 'Add-FileBlockOnce' {

    It 'appends the block and returns $true on first application' {
        Invoke-InTestDir -Files @{ 'patcher.cmake' = 'original' } -Body { param($dir)
            $f = Join-Path $dir 'patcher.cmake'
            $r = Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block" -Description 'p'
            Assert-True $r
            Assert-Match 'original' (Get-Content $f -Raw)
            Assert-Match 'WINFIX-A block' (Get-Content $f -Raw)
        }
    }

    It 'is idempotent: a second call with the marker present is a no-op' {
        Invoke-InTestDir -Files @{ 'patcher.cmake' = 'original' } -Body { param($dir)
            $f = Join-Path $dir 'patcher.cmake'
            [void](Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block")
            $lenAfterFirst = (Get-Content $f -Raw).Length
            $r2 = Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block"
            Assert-False $r2 'second application must be skipped'
            Assert-Equal $lenAfterFirst (Get-Content $f -Raw).Length 'content must not grow on re-run'
        }
    }

    It '-Prepend inserts the block before existing content' {
        Invoke-InTestDir -Files @{ 'src.cc' = 'int main(){}' } -Body { param($dir)
            $f = Join-Path $dir 'src.cc'
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
        Invoke-SourceFileDiagnosticCase -InitialText 'hello world' -ExpectedText 'hello there' -Changed $true `
            -Transform { param($text) $text.Replace('world', 'there') }
    }

    It 'preserves a literal $-bearing injection verbatim (the reason this exists, not Invoke-InlineRegexPatch)' {
        # -replace would read CMake's ${VAR} as a group reference; the scriptblock's literal .Replace keeps it.
        Invoke-InTestDir -Files @{ 'b.cmake' = 'set(X ANCHOR)' } -Body { param($dir)
            $f = Join-Path $dir 'b.cmake'
            $inject = 'set(FLATC "${FLATBUFFERS_INSTALL_PREFIX}/bin/flatc.exe")'
            Assert-False (Edit-SourceFile -Path $f -Guard absent -Transform { throw 'guard must skip callback' } -Quiet)
            [void](Edit-SourceFile -Path $f -Guard ANCHOR -Transform { param($c) $c.Replace('ANCHOR', ($inject + 'ANCHOR')) })
            Assert-Equal ('set(X ' + $inject + 'ANCHOR)') (Get-Content $f -Raw)
        }
    }

    It 'skips (returns $false) when -Marker is already present' {
        Invoke-InTestDir -Files @{ 'c.txt' = 'already MARKER here' } -Body { param($dir)
            $f = Join-Path $dir 'c.txt'
            foreach ($quiet in $false, $true) {
                $r = Edit-SourceFile -Path $f -Marker 'MARKER' -Transform { throw 'must not run' } -Quiet:$quiet
                Assert-False $r 'marker present must skip'
                Assert-Equal 'already MARKER here' (Get-Content $f -Raw) 'file must be untouched'
            }
        }
    }

    It 'warns on a no-op by default and returns only the verdict when quiet' {
        Invoke-SourceFileDiagnosticCase -InitialText unchanged -ExpectedText unchanged -Changed $false `
            -Transform { param($text) $text.Replace('ZZZ', 'QQQ') }
    }

    It 'returns $false for a missing file, throws with -Require' {
        Invoke-InTestDir { param($dir)
            foreach ($quiet in $false, $true) {
                Assert-False (Edit-SourceFile -Path (Join-Path $dir 'ghost') -Transform { param($c) $c } -Quiet:$quiet)
                Assert-Throws { Edit-SourceFile -Path (Join-Path $dir 'ghost') -Transform { param($c) $c } -Require -Quiet:$quiet }
            }
        }
    }
}

Describe 'Invoke-SourcePatchWithFallback' {

    function Invoke-SourcePatchFallbackFixture {
        param([Parameter(Mandatory)][scriptblock]$Body, [switch]$Unmatched)
        $action = $Body
        Invoke-InTestDir { param($dir)
            $null = Invoke-TestGitCommand -Path $dir -ArgumentList init
            $patch = Join-Path $dir 'p.patch'
            $anchor = if ($Unmatched) { 'DOES NOT MATCH' } else { 'old' }
            Write-TestFileTree -Root $dir -Files @{ 't.txt' = "old`n"; 'p.patch' = "--- a/t.txt`n+++ b/t.txt`n@@ -1 +1 @@`n-$anchor`n+new`n" }
            & $action $dir $patch
        }.GetNewClosure()
    }

    It 'applies rung 1 and never invokes the fallback' {
        Invoke-SourcePatchFallbackFixture { param($dir, $patch)
            $flag = Join-Path $dir 'fallback-ran.flag'
            $r = Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fallback { Set-Content -Path $flag -Value 'x'; $true }
            Assert-True $r 'rung 1 applied must report $true'
            # git apply rewrites EOLs under core.autocrlf - compare content only.
            Assert-Equal 'new' ([System.IO.File]::ReadAllText((Join-Path $dir 't.txt')).Trim()) 'the .patch content must have landed'
            Assert-False (Test-Path $flag) 'fallback must not run when the .patch applies'
        }
    }

    It 'falls back when the .patch does not apply and reports the fallback verdict' {
        Invoke-SourcePatchFallbackFixture -Unmatched -Body { param($dir, $patch)
            $target = Join-Path $dir 't.txt'
            $r = Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fallback {
                Invoke-InlineRegexPatch -Path $target -Pattern 'old' -Replacement 'inline' -Description 't'
            }
            Assert-True $r 'a successful inline fallback must report $true'
            Assert-Equal 'inline' ([System.IO.File]::ReadAllText($target).Trim())
        }
    }

    It 'returns $false (no throw) when both rungs miss without -Fatal' {
        Invoke-SourcePatchFallbackFixture -Unmatched -Body { param($dir, $patch)
            $r = & { Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fallback { $false } } 3>$null
            Assert-False $r 'double miss without -Fatal stays a warning-level verdict'
        }
    }

    It 'throws on a double miss with -Fatal (backlog #19: load-bearing patches must not rot silently)' {
        Invoke-SourcePatchFallbackFixture -Unmatched -Body { param($dir, $patch)
            Assert-Throws { Invoke-SourcePatchWithFallback -PatchFile $patch -SourceDir $dir -Fatal -Fallback { $false } } `
                -MessagePattern 'BOTH the \.patch and the inline fallback' `
                'a rotted load-bearing patch must fail the build at patch time'
        }
    }
}

Describe 'Assert-SourceFileContent' {
    It 'verifies written bytes and preserves the caller diagnostic on failure' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'patched.cpp'
            [IO.File]::WriteAllText($path, 'required macro')
            Assert-SourceFileContent -Path $path -Condition { param($text) $text -eq 'required macro' } -FailureMessage 'patch missing'
            [IO.File]::WriteAllText($path, 'upstream drift')
            Assert-Throws { Assert-SourceFileContent -Path $path -Condition { param($text) $text -eq 'required macro' } -FailureMessage 'patch missing' } -MessagePattern 'patch missing'
        }
    }

    It 'refuses empty, textual and multiple predicate results' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'patched.cpp'
            [IO.File]::WriteAllText($path, 'content')
            foreach ($condition in @({ }, { 'true' }, { $true; $false })) {
                Assert-Throws { Assert-SourceFileContent -Path $path -Condition $condition -FailureMessage 'invalid verdict' } -MessagePattern 'invalid verdict'
            }
        }
    }

    It 'cannot report success for an absent file' {
        Invoke-InTestDir { param($dir)
            Assert-Throws { Assert-SourceFileContent -Path (Join-Path $dir 'missing.cpp') -Condition { $true } -FailureMessage 'missing' }
        }
    }
}

Describe 'Regex patch postconditions' {
    It 'refuses missing files, missing anchors and partially removed required patterns' {
        foreach ($quiet in $false, $true) {
            Invoke-InTestDir { param($dir)
                $path = Join-Path $dir 'source.cpp'
                Assert-Throws { Invoke-InlineRegexPatch -Quiet:$quiet -Path $path -Pattern old -AssertGone old } -MessagePattern 'file not found'
                [IO.File]::WriteAllText($path, 'old old')
                Assert-Throws { Invoke-InlineRegexPatch -Quiet:$quiet -Path $path -Pattern absent -AssertGone old } -MessagePattern 'pattern not found'
                Assert-Throws { Invoke-InlineRegexPatch -Quiet:$quiet -Path $path -Pattern old -Guard absent -AssertGone old } -MessagePattern 'guard not found'
                Assert-Throws { Invoke-InlineRegexPatch -Quiet:$quiet -Path $path -Pattern '^old' -Replacement new -AssertGone old } -MessagePattern 'still present after patching'
                Assert-Equal 'new old' ([IO.File]::ReadAllText($path)) 'the postcondition checks the transformed text'
            }
        }
    }
}

Describe 'OpenCV ARM source patch verification' {
    $checks = @(Get-TestScriptCommandBlock -ScriptPath 'windows/scripts/build/Build-OpencvFromSource.ps1' -Name Assert-SourceFileContent -ExpectedCount 2)

    function Invoke-OpencvArmVerificationCase {
        param([int]$Index, [string[]]$ValidText, [string]$InvalidText, [string]$MessagePattern)
        Invoke-InTestDir { param($dir)
            $sfCpp = Join-Path $dir 'source.cpp'
            $mlasiH = $sfCpp
            foreach ($text in $ValidText) {
                [IO.File]::WriteAllText($sfCpp, $text)
                . $checks[$Index]
            }
            [IO.File]::WriteAllText($mlasiH, $InvalidText)
            Assert-Throws { . $checks[$Index] } -MessagePattern $MessagePattern
        }
    }

    It 'requires the softfloat macro in the actual caller predicate' {
        Invoke-OpencvArmVerificationCase -Index 0 -ValidText @('#define float32_t softfloat') `
            -InvalidText 'typedef softfloat float32_t;' -MessagePattern 'typedefs were not converted'
    }

    It 'allows an absent remap or guarded remap and rejects an unguarded remap' {
        Invoke-OpencvArmVerificationCase -Index 1 -ValidText @('no remap', "#if !defined(__clang__)`nneon_fmaxv`n#endif") `
            -InvalidText 'neon_fmaxv' -MessagePattern 'was not guarded for clang'
    }
}
