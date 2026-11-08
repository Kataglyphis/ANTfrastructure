#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Parsed inline scripts and workflow inputs prove wiring; Docker metadata, CI provenance and hardware stay external coverage.

Describe 'ARM64 digest acceptance workflow wiring' {
    It 'pins both container actions and runs the real unweakened device gate after checking its receipt' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) '.github/workflows/windows-arm64.yml')).Replace("`r", '')
        $blocks = [regex]::Matches($text, '(?m)^        run: \|\n((?:          [^\n]*\n|\n)+)')
        Assert-Equal 3 $blocks.Count
        $asts = @($blocks | ForEach-Object { ConvertTo-TestScriptAst -Text ([regex]::Replace($_.Groups[1].Value, '(?m)^          ', '')) })
        $resolve = @(Get-TestAstCommands -Ast $asts[0] -Name Resolve-Arm64AcceptanceImage)
        Assert-Equal 1 $resolve.Count
        Assert-Equal '$env:CANDIDATE_DIGEST' (Get-TestCommandArguments -Command $resolve[0] -AsAst).Digest.Extent.Text
        Assert-Equal 2 ([regex]::Matches($text, '(?m)^          image-arm64: \$\{\{ steps\.image\.outputs\.ref \}\}$')).Count
        Assert-Match 'group: windows-arm64-.*github\.run_id' $text
        $read = @(Get-TestAstCommands -Ast $asts[2] -Name Read-Arm64AcceptanceBundle)
        $gate = @(Get-TestAstCommands -Ast $asts[2] -Name Invoke-Arm64AcceptanceGate)
        Assert-TestAstCommand -Command $read -Assignment '$receipt' -Text 'Read-Arm64AcceptanceBundle -ZipPath ./bundle.zip -ReceiptPath ./image-receipt.json -Image $env:ARM64_IMAGE -HubCommit $env:GITHUB_SHA -RunId $env:GITHUB_RUN_ID -RunAttempt $env:GITHUB_RUN_ATTEMPT'
        Assert-TestAstCommand -Command $gate -Text 'Invoke-Arm64AcceptanceGate -Receipt $receipt -OutputPath ./device-acceptance.json -Architecture $env:PROCESSOR_ARCHITECTURE -Gate { & ./Test-Arm64Bundle.ps1 -ZipPath ./bundle.zip }'
        Assert-True ($read[0].Extent.StartOffset -lt $gate[0].Extent.StartOffset)
        Assert-True (Test-TestAstUnconditional -Node $gate[0])
        Assert-Match '(?s)name: Upload the device acceptance receipt\n        if: \$\{\{ always\(\) \}\}.*path: bundle/device-acceptance.json' $text
    }
}
