#requires -Version 7.0
# $scriptAssetRoot locates modules\ before any import, so it cannot live in one: each copy must be assigned, canonical, at column 0.

function Assert-ScriptAssetProjection {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Definition,
        [Parameter(Mandatory)][scriptblock]$Finding, [Parameter(Mandatory)][string]$FailureMessage,
        [string]$Separator = ', ')
    Assert-True ($Definition.Count -gt 0) 'expected at least one resolver definition'
    $issues = @(foreach ($site in $Definition) { & $Finding $site })
    Assert-True ($issues.Count -eq 0) ($FailureMessage + ($issues -join $Separator))
}

Describe 'scriptAssetRoot resolver parity' {

    $canonical = "`$scriptAssetRoot = if (Test-Path (Join-Path `$PSScriptRoot 'modules')) { `$PSScriptRoot } else { Split-Path `$PSScriptRoot -Parent }"
    $scriptsDir = Split-Path $PSScriptRoot -Parent
    # tests/ excluded: this suite and the harness talk ABOUT the resolver.
    $files = Get-ChildItem -Path $scriptsDir -Filter '*.ps1' -Recurse -File |
        Where-Object { $_.FullName -notmatch '\\tests\\' } |
        Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match '\$scriptAssetRoot' }

    $definitions = @(Select-String -LiteralPath @($files.FullName) -Pattern ([regex]::Escape('$scriptAssetRoot = ')))

    It 'rejects an empty scan or an emitted finding while preserving caller diagnostics' {
        $projection = { param($value) if ($value -ne 'valid') { 'fixture issue' } }
        Assert-ScriptAssetProjection -Definition valid -Finding $projection -FailureMessage 'fixture rejection: '
        Assert-Throws { Assert-ScriptAssetProjection -Definition @() -Finding $projection -FailureMessage fixture } -MessagePattern 'at least one resolver'
        Assert-Throws { Assert-ScriptAssetProjection -Definition valid, wrong -Finding $projection -FailureMessage 'fixture rejection: ' } -MessagePattern 'fixture rejection: fixture issue'
    }

    It 'finds the resolver population at all (guards the scan itself)' {
        # A convention rename fails loudly here instead of passing on an empty set.
        Assert-True ($files.Count -ge 30) "expected >=30 scripts referencing `$scriptAssetRoot, found $($files.Count) — did the convention change?"
    }

    It 'every consumer also defines it' {
        $missing = @($files | Where-Object {
            (Get-Content -LiteralPath $_.FullName -Raw) -notmatch [regex]::Escape('$scriptAssetRoot = ')
        })
        Assert-True ($missing.Count -eq 0) ("use-without-definition (the repair-windows-componentstore bug class): " + (($missing | ForEach-Object Name) -join ', '))
    }

    It 'every definition is the canonical line, byte-identical' {
        Assert-ScriptAssetProjection -Definition $definitions -FailureMessage "drifted resolver copies:`n" -Separator "`n" -Finding {
            param($definition)
            if ($definition.Line.TrimEnd() -cne $canonical) { "$($definition.Filename): $($definition.Line.Trim())" }
        }
    }

    It 'every definition sits at top level (column 0), never inside a block' {
        Assert-ScriptAssetProjection -Definition $definitions -FailureMessage 'indented (block-scoped) resolver copies (the apply-containerd-config/-SkipCniSync bug class): ' -Finding {
            param($definition)
            if ($definition.Line -notmatch '^\$scriptAssetRoot') { "$($definition.Filename):$($definition.LineNumber)" }
        }
    }
}
