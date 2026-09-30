#requires -Version 7.0
# Scripts run before pwsh exists must stay 5.1-parseable; #requires only gates the minimum version, PSParser checks syntax.

Describe 'Dockerfile.base WPS-5.1 bootstrap scripts stay 5.1-parseable (#106)' {
    $repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
    # Only what runs before Dockerfile.base's SHELL switches to pwsh; keep in step with that SHELL order.
    $bootstrapScripts = @(
        'windows\scripts\host\Initialize-Pwsh.ps1'    # first RUN of Dockerfile.base, WPS 5.1 SHELL
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
            # PSParser does not flag `?.`, so it is named here.
            Assert-True ($content -notmatch '\$\w+\?\.') "$rel uses PS7 null-conditional member access (`?.`), which 5.1 cannot parse."
        }
    }
}
