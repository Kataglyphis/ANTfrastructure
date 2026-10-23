#requires -Version 7.0
# Local byte checks cover Set-Content-compatible text fixtures; binary samples and native program execution stay separately gated.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.TextFixtures.psm1') -DisableNameChecking

Describe 'Harness line-based text fixtures' {
    It 'matches native UTF-8 Set-Content bytes for absent, empty, blank and populated line collections' {
        $lineFiles = [ordered]@{
                'absent.txt' = $null; 'empty.txt' = @(); 'blank.txt' = @('')
                'mixed.txt' = @('MiXeD', '', 'last'); 'unicode.txt' = @('caf?', '?'); 'nested [dir]/embedded.txt' = @("embedded`r`nline", 'tail')
            }
        $record = [pscustomobject]@{ Path = '' }
        Invoke-InTestLineDir -LineFiles $lineFiles -Body { param($dir)
            $record.Path = $dir
            $native = Join-Path $dir native.txt
            $files = ConvertTo-TestFileMap -LineFiles $lineFiles
            Assert-Equal 'absent.txt|empty.txt|blank.txt|mixed.txt|unicode.txt|nested [dir]/embedded.txt' ($files.Keys -join '|') 'literal mapping keys retain their order'
            foreach ($entry in $lineFiles.GetEnumerator()) {
                Set-Content -LiteralPath $native -Value $entry.Value -Encoding utf8
                $tree = Join-Path $dir $entry.Key
                Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals([IO.File]::ReadAllBytes($native), [IO.File]::ReadAllBytes($tree))) 'native line serialization bytes'
            }
            Assert-Equal '' (ConvertTo-TestFileText) 'an omitted collection is empty text'
            Assert-Equal 0 (ConvertTo-TestFileMap -LineFiles @{}).Count 'an empty mapping stays empty'
            Assert-Equal "MiXeD||last" ($lineFiles['mixed.txt'] -join '|') 'serialization cannot replace caller line arrays'
        }
        Assert-False (Test-Path -LiteralPath $record.Path) 'the line fixture directory is cleaned after the body'
    }

    It 'retains exact line order, case and the final platform newline, with a fault control' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/WindowsHarness.TextFixtures.psm1' -FunctionName ConvertTo-TestFileText `
            -Find '+ [Environment]::NewLine' -Replace '' -Expected 'final newline must be retained' -IncludeControl -Body {
                $want = "First$([Environment]::NewLine)MiXeD$([Environment]::NewLine)"
                Assert-Equal $want (ConvertTo-MutTestFileText -Line @('First', 'MiXeD')) 'final newline must be retained'
            }
    }
    It 'retains every input mapping entry, with a dropped-entry fault control' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/WindowsHarness.TextFixtures.psm1' -FunctionName ConvertTo-TestFileMap `
            -Find 'foreach ($entry in $LineFiles.GetEnumerator())' -Replace 'foreach ($entry in @($LineFiles.GetEnumerator() | Select-Object -First 1))' -Expected 'all fixture files must be retained' -IncludeControl -Body {
                $files = ConvertTo-MutTestFileMap -LineFiles ([ordered]@{ 'first.txt' = @('one'); 'second [literal].txt' = @('two') })
                Assert-Equal 2 $files.Count 'all fixture files must be retained'
                Assert-Equal 'first.txt|second [literal].txt' ($files.Keys -join '|')
            }
    }

}
