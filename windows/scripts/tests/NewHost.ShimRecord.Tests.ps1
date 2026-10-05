#requires -Version 7.0
# A Stevedore update overwrote the patched shim and left its record on 2026-09-21; Install-NewHost then skipped the redeploy.

Describe 'Install-NewHost: the shim record proves the patch only while its hash matches' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-NewHost.ps1' -FunctionName 'Test-RecordedShimLive')

    # -Record live names the shim's own hash, lower the same in lowercase, none writes no record.
    function New-ShimCase {
        param([string]$Dir, [ValidateSet('live', 'lower', 'none')][string]$Record = 'live')
        $shim = Join-Path $Dir 'containerd-shim-runhcs-v1.exe'
        $json = Join-Path $Dir 'shim-patch.json'
        [System.IO.File]::WriteAllText($shim, 'patched')
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $shim).Hash
        if ($Record -eq 'lower') { $hash = $hash.ToLowerInvariant() }
        if ($Record -ne 'none') { Set-Content -LiteralPath $json -Value (@{ sha256 = $hash } | ConvertTo-Json) }
        @{ Shim = $shim; Record = $json }
    }
    function Test-Case { param($Case, [string]$Shim = $Case.Shim) Test-RecordedShimLive -RecordPath $Case.Record -ShimExe $Shim }

    It 'accepts the shim the record names' {
        Invoke-InTestDir { param($dir)
            Assert-True (Test-Case (New-ShimCase -Dir $dir)) 'hash match'
        }
    }

    It 'rejects a shim an update replaced, record left behind' {
        Invoke-InTestDir { param($dir)
            $c = New-ShimCase -Dir $dir
            Set-Content -LiteralPath $c.Shim -Value 'stock from the update'
            Assert-False (Test-Case $c) 'the live bytes changed'
        }
    }

    It 'reads the recorded hash case-insensitively' {
        Invoke-InTestDir { param($dir)
            Assert-True (Test-Case (New-ShimCase -Dir $dir -Record lower)) 'lowercase record'
        }
    }

    It 'rejects a missing record, a missing shim, an unreadable record and one with no hash' {
        Invoke-InTestDir { param($dir)
            $none = New-ShimCase -Dir $dir -Record none
            Assert-False (Test-Case $none) 'no record'
            Assert-False (Test-Case (New-ShimCase -Dir $dir) -Shim (Join-Path $dir 'absent.exe')) 'no shim'
            foreach ($bad in '{ not json', '{ "schema": "kataglyphis/shim-patch-state@1" }') {
                Set-Content -LiteralPath $none.Record -Value $bad
                Assert-False (Test-Case $none) "record: $bad"
            }
        }
    }
}
