#requires -Version 7.0
# Logical text preserves raw inspection inputs; it does not validate Docker grammar, mounts or stage policies.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking

Describe 'Harness Docker inspection inputs' {
    It 'loads a literal file and folds LF and CRLF continuations without executing or expanding its content' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'Dockerfile [literal]'
            $text = 'FROM pinned AS base' + "`n" + 'RUN first `' + "`n" + '  second `' + "`r`n" + 'third' + "`n" + 'COPY $env:UNSET_LITERAL C:\literal' + "`n"
            [IO.File]::WriteAllText($path, $text)
            $want = 'FROM pinned AS base' + "`n" + 'RUN first    second  third' + "`n" + 'COPY $env:UNSET_LITERAL C:\literal' + "`n"
            Assert-Equal $want (Get-TestDockerLogicalText -LiteralPath $path) 'only escaped newlines are replaced'
            $instructions = @(Get-TestDockerLogicalLine -LiteralPath $path | Where-Object { $_ -match '^(FROM|RUN|COPY) ' })
            Assert-Equal 3 $instructions.Count 'caller instruction selection sees the folded RUN once'
            Assert-Equal 'FROM|RUN|COPY' (($instructions | ForEach-Object { ($_ -split ' ')[0] }) -join '|')
            Assert-Equal $text ([IO.File]::ReadAllText($path)) 'inspection does not rewrite its source'
        }
    }

    It 'retains source order, empty lines and ordinary CR bytes through both file and text inputs' {
        Invoke-InTestDir -Files @{ 'Dockerfile' = "FROM first`r`n`r`nRUN command`r`n"; 'empty' = '' } -Body { param($dir)
            $path = Join-Path $dir Dockerfile
            $lines = @(Get-TestDockerLogicalLine -LiteralPath $path)
            Assert-Equal 4 $lines.Count 'blank and trailing lines remain inspectable'
            Assert-Equal "FROM first`r|`r|RUN command`r|" ($lines -join '|') 'ordinary CRLF bytes are not silently normalized'
            Assert-Equal ($lines -join '|') ((ConvertTo-TestDockerLogicalLine -Text ([IO.File]::ReadAllText($path))) -join '|')
            Assert-Equal 1 @(Get-TestDockerLogicalLine -LiteralPath (Join-Path $dir empty)).Count
            Assert-Equal '' (Get-TestDockerLogicalText -LiteralPath (Join-Path $dir empty))
        }
    }

    It 'fails missing files rather than returning an empty successful inspection' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir never-existed.Dockerfile
            Assert-Throws { Get-TestDockerLogicalText -LiteralPath $path } -MessagePattern 'never-existed.Dockerfile'
            Assert-Throws { Get-TestDockerLogicalLine -LiteralPath $path } -MessagePattern 'never-existed.Dockerfile'
        }
    }

    It 'detects losing continuation folding before a caller parses logical instructions' {
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/tests/WindowsHarness.DockerFixtures.psm1' -FunctionName ConvertTo-TestDockerLogicalText `
            -Find '$Text -replace ''`\r?\n'', '' ''' -Replace '$Text' -Expected 'continued RUN must be one logical instruction' -IncludeControl -Body {
                $text = 'RUN first `' + "`n" + 'second `' + "`r`n" + 'third'
                Assert-Equal 'RUN first  second  third' (ConvertTo-MutTestDockerLogicalText -Text $text) 'continued RUN must be one logical instruction'
            }
    }
}
