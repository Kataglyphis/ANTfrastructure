#requires -Version 7.0
# A miscounting classifier would make Measure-BuildWarnings.ps1's case for the -Wno- suppressions worthless.

Describe 'Get-WarningFamily' {
    # AST-extracted: dot-sourcing the script would demand a -LogPath and start analysing.
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\diagnostics\Measure-BuildWarnings.ps1' -FunctionName 'Get-WarningFamily')

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
        # Otherwise a new flood could grow unseen precisely because it carries no group.
        $family = Get-WarningFamily -Line "foo.cpp(1,1): warning: something odd happened"
        Assert-True ($null -ne $family) 'still classified'
        Assert-Match '^\(ungrouped\)' $family 'marked as ungrouped rather than dropped'
    }

    It 'collapses near-identical bracket-less warnings into ONE family' {
        # Unnormalised identifiers and numbers would split one flood into thousands of one-line families.
        $a = Get-WarningFamily -Line "a.cpp(1,1): warning: unused variable 'alpha' at offset 12"
        $b = Get-WarningFamily -Line "b.cpp(9,4): warning: unused variable 'beta' at offset 4567"
        Assert-Equal $a $b 'identifier and number differences normalised away'
    }

    It 'prefers the MSVC code over the clang path when a line could match both' {
        # A path containing "warning:" must not steer an STL-coded line into the clang branch.
        Assert-Equal 'STL4037' (Get-WarningFamily -Line "C:/warning:odd/dir/x.h(2): warning STL4037: deprecated") 'code branch wins'
    }
}
