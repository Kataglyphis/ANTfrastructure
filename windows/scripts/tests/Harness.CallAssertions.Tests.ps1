#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Small argument and AST fixtures cover assertion failures, not production compilation or runtime order.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.CallAssertions.psm1') -ErrorAction Stop

Describe 'Shared recorded argument assertions' {
    It 'preserves spaces, empty values, order and caller projection' {
        $calls = @(@('first', 'source with spaces'), @('second', ''))
        Assert-TestRecordedArguments -Calls $calls -Expected @('source with spaces', '') -ArgumentIndex 1
        Assert-TestRecordedArguments -Calls $calls -Expected @('FIRST', 'SECOND') -Project { param($value) $value.ToUpperInvariant() }
        Assert-TestRecordedArguments -Calls @() -Expected @()
        Assert-Throws { Assert-TestRecordedArguments -Calls $calls -Expected @('first') } -MessagePattern 'recorded argument sequence count'
        Assert-Throws { Assert-TestRecordedArguments -Calls $calls -Expected @('second', 'first') } -MessagePattern 'recorded argument sequence at 0'
    }
}

Describe 'Shared source call order assertions' {
    It 'requires unique ordered calls, exact selected wiring and a valid selection' {
        Invoke-InTestDir -Files @{ 'calls.ps1' = "Save-Input`nRepair-Input -Path 'value with spaces'`nConfigure-Output`n" } -Body { param($dir)
            $fixture = @{ ScriptPath = Join-Path $dir 'calls.ps1'; Name = @('Save-Input', 'Repair-Input', 'Configure-Output'); Text = "Repair-Input -Path 'value with spaces'"; RequiredIndex = 1; Unconditional = $true }
            Assert-TestScriptCallOrder @fixture
            $fixture.Name = @('Repair-Input', 'Save-Input', 'Configure-Output')
            Assert-Throws { Assert-TestScriptCallOrder @fixture } -MessagePattern 'source order'
            $fixture.Name = @('Save-Input', 'Repair-Input', 'Configure-Output')
            $fixture.RequiredIndex = 3
            Assert-Throws { Assert-TestScriptCallOrder @fixture } -MessagePattern 'outside the selected sequence'
            $fixture.RequiredIndex = 1
            Add-Content -LiteralPath $fixture.ScriptPath -Value 'Repair-Input'
            Assert-Throws { Assert-TestScriptCallOrder @fixture } -MessagePattern 'one selected call to Repair-Input'
        }
    }
}
