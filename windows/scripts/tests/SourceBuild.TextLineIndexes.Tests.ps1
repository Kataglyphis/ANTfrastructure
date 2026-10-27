#requires -Version 7.0
# Harness-style so the Linux mutation shards, which carry no Pester, can prove the shared line scan.

. (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\modules\WindowsSourceBuild.Common.psm1' -FunctionName 'Find-TextLineIndexes')

Describe 'Find-TextLineIndexes' {
    It 'returns matching zero-based indexes in source order and accepts empty input' {
        $indexes = @(Find-TextLineIndexes -Lines @('Name: codec', 'Libs: -lx265', 'Libs.private: -lc++', 'Libs: -lfoo') -Pattern '^Libs:')
        Assert-Equal '1,3' ($indexes -join ',') 'both matching rows, in file order'
        Assert-Equal 0 @(Find-TextLineIndexes -Lines @() -Pattern '^Libs:').Count 'an empty file has no matches'
    }

    It 'accepts blank lines, which a real .pc carries between its variables and fields' {
        Assert-Equal '3' (@(Find-TextLineIndexes -Lines @('prefix=C:/x', '', 'Name: x265', 'Libs: -lx265', '') -Pattern '^Libs:') -join ',') 'the Libs: row past a blank line'
    }
}
