#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# A one-element array an if/else returns unrolls to a string, and a splat then hands a native command one character per argument.

Describe 'no array assigned from an if/else is splatted unwrapped' {

    It 'finds every $x = if (...) with a one-element @(...) branch that an @x splats' {
        # This file's own demonstration; the vswhere selector it waited for was fixed with the 2026-10-14 base re-key (CON89).
        $known = @('windows/scripts/tests/Lint.ScalarSplat.Tests.ps1|bare')
        $root = Get-RepoRoot
        $hits = foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'windows\scripts') -Recurse -File -Include '*.ps1', '*.psm1') {
            $text = [IO.File]::ReadAllText($file.FullName)
            foreach ($m in [regex]::Matches($text, '(?m)^\s*\$(?<name>\w+)\s*=\s*if\s*\(.*\{\s*@\(')) {
                $name = $m.Groups['name'].Value
                if ($text -notmatch "(?<![\w@])@$name\b") { continue }
                # Several elements stay an array and an empty one splats nothing; one element is what unrolls.
                $statement = (($text.Substring($m.Index) -split "`n") | Select-Object -First 6) -join "`n"
                if ($statement -notmatch "@\(\s*(?:'[^',]*'|`"[^`",]*`"|\$[\w:]+)\s*\)") { continue }
                $rel = $file.FullName.Substring($root.Length + 1) -replace '\\', '/'
                if ("$rel|$name" -notin $known) { "$rel`: `$$name" }
            }
        }
        Assert-Equal '' (@($hits) -join '; ') 'wrap the if in @() so the value stays an array'
    }

    It 'the pattern it hunts really cuts a splat into characters, and @() keeps it whole' {
        $bare = if ($true) { @('--no-deps') } else { @('-x') }
        $wrapped = @(if ($true) { '--no-deps' } else { '-x' })
        Assert-Equal '- - n o - d e p s' ((& cmd /c echo @bare) -join '') 'the bug this file guards against'
        Assert-Equal '--no-deps' ((& cmd /c echo @wrapped) -join '') 'the fix'
    }
}
