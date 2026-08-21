#requires -Version 7.0
# Guard for the $scriptAssetRoot bootstrap resolver (#108 dual-layout).
#
# The resolver CANNOT live in a module — its whole job is to locate modules\
# before the first Import-Module (repo layout: one level up from the script's
# group dir; container layout: flat beside it). So it exists as an inline copy
# in every grouped script, and copies rot: the 2026-08-21 audit found one
# script USING the variable without ever defining it (repair-windows-
# componentstore, StrictMode off -> silent $null -> runtime bind error at the
# END of a 40-min elevated repair) and two copies injected INSIDE nested
# blocks (skipped under a switch / swallowed by a catch). This suite pins the
# three invariants that made those bugs possible:
#   1. every file that references $scriptAssetRoot also assigns it,
#   2. the assignment is the one canonical line (byte-identical everywhere),
#   3. the assignment sits at top level (column 0), never inside a block.

Describe 'scriptAssetRoot resolver parity' {

    $canonical = "`$scriptAssetRoot = if (Test-Path (Join-Path `$PSScriptRoot 'modules')) { `$PSScriptRoot } else { Split-Path `$PSScriptRoot -Parent }"
    $scriptsDir = Split-Path $PSScriptRoot -Parent
    # tests/ excluded: this suite and the harness talk ABOUT the resolver.
    $files = Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\tests\\' } |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '\$scriptAssetRoot' }

    It 'finds the resolver population at all (guards the scan itself)' {
        # If a rename ever moves the convention, this fails loudly instead of
        # the three assertions below passing on an empty set.
        Assert-True ($files.Count -ge 30) "expected >=30 scripts referencing `$scriptAssetRoot, found $($files.Count) — did the convention change?"
    }

    It 'every consumer also defines it' {
        $missing = @($files | Where-Object {
            (Get-Content -LiteralPath $_.FullName -Raw) -notmatch [regex]::Escape('$scriptAssetRoot = ')
        })
        Assert-True ($missing.Count -eq 0) ("use-without-definition (the repair-windows-componentstore bug class): " + (($missing | ForEach-Object Name) -join ', '))
    }

    It 'every definition is the canonical line, byte-identical' {
        $drifted = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $files) {
            $defs = @(Get-Content -LiteralPath $f.FullName | Where-Object { $_ -match [regex]::Escape('$scriptAssetRoot = ') })
            foreach ($d in $defs) {
                if ($d.TrimEnd() -cne $canonical) { $drifted.Add("$($f.Name): $($d.Trim())") }
            }
        }
        Assert-True ($drifted.Count -eq 0) ("drifted resolver copies:`n" + ($drifted -join "`n"))
    }

    It 'every definition sits at top level (column 0), never inside a block' {
        $nested = [System.Collections.Generic.List[string]]::new()
        foreach ($f in $files) {
            $lines = Get-Content -LiteralPath $f.FullName
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match [regex]::Escape('$scriptAssetRoot = ') -and $lines[$i] -notmatch '^\$scriptAssetRoot') {
                    $nested.Add("$($f.Name):$($i + 1)")
                }
            }
        }
        Assert-True ($nested.Count -eq 0) ("indented (block-scoped) resolver copies (the apply-containerd-config/-SkipCniSync bug class): " + ($nested -join ', '))
    }
}
