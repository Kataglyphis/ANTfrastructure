# Tests for the source-patch helpers that decide whether every upstream patch lands.
# A silent regression here mis-patches a source tree and blows up mid-build, so these
# are the highest-value units in the suite.

Describe 'Invoke-InlineRegexPatch' {

    It 'replaces a match, writes the file, and returns $true' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'link ${DIR}/libfoo.a here' -NoNewline
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'lib([a-z]+)\.a' -Replacement '$1.lib' -Description 'c'
            Assert-True $r 'should report a modification'
            Assert-Equal 'link ${DIR}/foo.lib here' (Get-Content $f -Raw)
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'does nothing and returns $false when -Guard does not match' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'libfoo.a' -NoNewline
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'libfoo\.a' -Replacement 'foo.lib' -Guard 'THIS_IS_ABSENT' -Description 'c'
            Assert-False $r 'guard miss must skip'
            Assert-Equal 'libfoo.a' (Get-Content $f -Raw) 'file must be untouched'
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'applies when -Guard matches' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'MARKER libfoo.a' -NoNewline
            $r = Invoke-InlineRegexPatch -Path $f -Pattern 'libfoo\.a' -Replacement 'foo.lib' -Guard 'MARKER' -Description 'c'
            Assert-True $r
            Assert-Equal 'MARKER foo.lib' (Get-Content $f -Raw)
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'warns and returns $false when the pattern is present-but-unchanged (no-op)' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'hello world' -NoNewline
            $captured = & { Invoke-InlineRegexPatch -Path $f -Pattern 'no-such-token' -Replacement 'x' -Description 'c' } 3>&1
            $warns = @($captured | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            Assert-True ($warns.Count -ge 1) 'a silent miss must surface a warning'
            Assert-Equal 'hello world' (Get-Content $f -Raw) 'file must be unchanged on no-op'
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'returns $false for a missing file (no -Require)' {
        $dir = New-TestDir
        try {
            $r = Invoke-InlineRegexPatch -Path (Join-Path $dir 'ghost.cmake') -Pattern 'a' -Replacement 'b'
            Assert-False $r
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'throws for a missing file with -Require' {
        $dir = New-TestDir
        try {
            Assert-Throws { Invoke-InlineRegexPatch -Path (Join-Path $dir 'ghost.cmake') -Pattern 'a' -Replacement 'b' -Require }
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'replaces ALL occurrences, not just the first' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'c.cmake'
            Set-Content -Path $f -Value 'liba.a libb.a libc.a' -NoNewline
            [void](Invoke-InlineRegexPatch -Path $f -Pattern 'lib([a-z])\.a' -Replacement '$1.lib')
            Assert-Equal 'a.lib b.lib c.lib' (Get-Content $f -Raw)
        } finally { Remove-Item $dir -Recurse -Force }
    }
}

Describe 'Add-FileBlockOnce' {

    It 'appends the block and returns $true on first application' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'patcher.cmake'
            Set-Content -Path $f -Value 'original' -NoNewline
            $r = Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block" -Description 'p'
            Assert-True $r
            Assert-Match 'original' (Get-Content $f -Raw)
            Assert-Match 'WINFIX-A block' (Get-Content $f -Raw)
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'is idempotent: a second call with the marker present is a no-op' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'patcher.cmake'
            Set-Content -Path $f -Value 'original' -NoNewline
            [void](Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block")
            $lenAfterFirst = (Get-Content $f -Raw).Length
            $r2 = Add-FileBlockOnce -Path $f -Marker 'WINFIX-A' -Content "`n# WINFIX-A block"
            Assert-False $r2 'second application must be skipped'
            Assert-Equal $lenAfterFirst (Get-Content $f -Raw).Length 'content must not grow on re-run'
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It '-Prepend inserts the block before existing content' {
        $dir = New-TestDir
        try {
            $f = Join-Path $dir 'src.cc'
            Set-Content -Path $f -Value 'int main(){}' -NoNewline
            [void](Add-FileBlockOnce -Path $f -Marker 'PRAGMA-X' -Content "// PRAGMA-X`n" -Prepend)
            $raw = Get-Content $f -Raw
            Assert-True ($raw.IndexOf('PRAGMA-X') -lt $raw.IndexOf('int main')) 'prepended block must come first'
        } finally { Remove-Item $dir -Recurse -Force }
    }

    It 'returns $false for a missing file, throws with -Require' {
        $dir = New-TestDir
        try {
            Assert-False (Add-FileBlockOnce -Path (Join-Path $dir 'ghost') -Marker 'M' -Content 'x')
            Assert-Throws { Add-FileBlockOnce -Path (Join-Path $dir 'ghost') -Marker 'M' -Content 'x' -Require }
        } finally { Remove-Item $dir -Recurse -Force }
    }
}
