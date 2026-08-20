#requires -Version 7.0
# Tests for Get-WarningFamily, the classifier behind Measure-BuildWarnings.ps1.
# The script exists to PROVE the four -Wno- suppressions added on 2026-08-08
# still earn their place; if its classifier miscounts, that proof is worthless
# and a suppression could be dropped (or kept) for the wrong reason.

Describe 'Get-WarningFamily' {
    # AST-extract the function rather than dot-sourcing the script, which would
    # demand a -LogPath and start analysing. Same pattern as the FFmpeg gate.
    $script = Join-Path (Split-Path (Split-Path $PSCommandPath -Parent) -Parent) 'diagnostics\Measure-BuildWarnings.ps1'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
    $fnAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WarningFamily' }, $true) | Select-Object -First 1
    if (-not $fnAst) { throw "Get-WarningFamily not found in $script — did it move? Update this suite." }
    . ([scriptblock]::Create($fnAst.Extent.Text))

    It 'keys a clang warning by its bracketed group — what -Wno- actually switches off' {
        $line = "C:/src/onnx/stream_handles.h(42,7): warning: expression result unused [-Wunused-value]"
        Assert-Equal '-Wunused-value' (Get-WarningFamily -Line $line) 'bracketed group wins'
    }

    It 'keys MSVC STL and C-numbered warnings by their code' {
        Assert-Equal 'STL4037' (Get-WarningFamily -Line "mlir/BuiltinAttributes.h(88): warning STL4037: 'complex' is deprecated") 'STL code'
        Assert-Equal 'C4996'   (Get-WarningFamily -Line "foo.cpp(3): warning C4996: 'strcpy': deprecated")                       'C code'
    }

    It 'returns null for lines that are not warnings' {
        Assert-True ($null -eq (Get-WarningFamily -Line '[2/900] Building CXX object foo.obj')) 'progress line ignored'
        Assert-True ($null -eq (Get-WarningFamily -Line 'error: no such file'))                 'error line is not a warning'
        Assert-True ($null -eq (Get-WarningFamily -Line ''))                                    'empty line ignored'
    }

    It 'does NOT silently drop a bracket-less clang warning' {
        # Otherwise the total under-reports, and a new flood could grow unseen
        # precisely because it carries no group.
        $family = Get-WarningFamily -Line "foo.cpp(1,1): warning: something odd happened"
        Assert-True ($null -ne $family) 'still classified'
        Assert-Match '^\(ungrouped\)' $family 'marked as ungrouped rather than dropped'
    }

    It 'collapses near-identical bracket-less warnings into ONE family' {
        # Quoted identifiers and numbers are what vary between otherwise
        # identical diagnostics; without normalising them, one flood would be
        # reported as thousands of one-line families and rank nowhere.
        $a = Get-WarningFamily -Line "a.cpp(1,1): warning: unused variable 'alpha' at offset 12"
        $b = Get-WarningFamily -Line "b.cpp(9,4): warning: unused variable 'beta' at offset 4567"
        Assert-Equal $a $b 'identifier and number differences normalised away'
    }

    It 'prefers the MSVC code over the clang path when a line could match both' {
        # A path containing the text "warning:" must not steer an STL-coded line
        # into the clang branch.
        Assert-Equal 'STL4037' (Get-WarningFamily -Line "C:/warning:odd/dir/x.h(2): warning STL4037: deprecated") 'code branch wins'
    }
}
