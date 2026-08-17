# Backlog #106: the three scripts that run under Windows PowerShell 5.1 — in
# Dockerfile.base BEFORE pwsh exists in the image — must stay 5.1-PARSEABLE.
# A `#requires -Version 5.1` line cannot enforce that (it gates the MINIMUM
# version, not the syntax level), and the constraint otherwise lives only in
# comments. Found live on 2026-08-17: a probe script declared 5.1 while using
# ProcessStartInfo.ArgumentList, which 5.1 does not have — declarations drift,
# parsers do not.
#
# The check parses each script with the legacy-compatible tokenizer
# (System.Management.Automation.PSParser), which rejects PS7-only syntax
# (ternary `? :`, pipeline-chain `&&`/`||`) that pwsh's own parser accepts. It
# cannot catch API-level drift (.NET-Core-only members) — that still needs the
# real 5.1 run in the base build — but it catches the syntax class, which is
# what actually creeps in.

Describe 'Dockerfile.base WPS-5.1 bootstrap scripts stay 5.1-parseable (#106)' {
    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    # EXACTLY ONE script runs under WPS 5.1 — this gate's own first run proved
    # the audit wrong about that. #106 claimed setup-vs.ps1 and
    # setup-scoop-tools.ps1 were 5.1 too; both declare `#requires -Version 7.0`
    # and both run AFTER Dockerfile.base's SHELL switches to pwsh (line ~69),
    # while they execute at lines ~93/~125. Only bootstrap-pwsh.ps1 executes
    # under the initial `powershell` SHELL (line ~30 → RUN at ~45). Keep this
    # list in step with the SHELL ordering in Dockerfile.base, not with lore.
    $bootstrapScripts = @(
        'windows\scripts\bootstrap-pwsh.ps1'    # first RUN of Dockerfile.base, WPS 5.1 SHELL
    )

    foreach ($rel in $bootstrapScripts) {
        $path = Join-Path $repoRoot $rel

        It "exists: $rel" {
            Assert-True (Test-Path $path) "expected 5.1-era bootstrap script missing at $path - if it moved, update this test AND Dockerfile.base together"
        }
        if (-not (Test-Path $path)) { continue }
        $content = Get-Content -LiteralPath $path -Raw

        It "tokenizes with the 5.1-compatible parser: $rel" {
            $parseErrors = $null
            $null = [System.Management.Automation.PSParser]::Tokenize($content, [ref]$parseErrors)
            Assert-True (@($parseErrors).Count -eq 0) ("$rel no longer tokenizes with the 5.1-compatible parser - " +
                "PS7-only syntax crept into a script that runs before pwsh exists in the base image. " +
                "First error: $(@($parseErrors) | Select-Object -First 1 | ForEach-Object { $_.Message })")
        }

        It "does not demand PowerShell 7: $rel" {
            Assert-True ($content -notmatch '#requires\s+-Version\s+7') ("$rel declares #requires -Version 7 but " +
                'Dockerfile.base runs it under Windows PowerShell 5.1 - it would refuse to start at the first RUN.')
        }

        It "avoids PS7 null-conditional member access: $rel" {
            # PSParser does NOT flag `?.` — name it here so the failure points at
            # the construct instead of a generic tokenizer error elsewhere.
            Assert-True ($content -notmatch '\$\w+\?\.') "$rel uses PS7 null-conditional member access (`?.`), which 5.1 cannot parse."
        }
    }
}
