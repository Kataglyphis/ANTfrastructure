#requires -Version 7.0
# Parsed stage and literal mount checks do not execute containers or validate full engine grammar.

Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking

Describe 'Harness Docker inspection inputs' {
    It 'retains exact mounts and arguments plus caller-selected wider mount exclusivity' {
        $text = "FROM pinned AS built`nRUN --mount=type=bind,source=shared/fix.patch,target=C:\fix.patch & Build-Test.ps1 -Patch 'C:\fix.patch'`n"
        Invoke-InTestDir -Files @{ 'Dockerfile' = $text } -Body {
            param($dir)
            $contract = @{ Path = Join-Path $dir 'Dockerfile'; ScriptLeaf = 'Build-Test.ps1';
                Mount = @(@{ Text = 'source=shared/fix.patch,target=C:\fix.patch'; Exclusive = 'shared/fix.patch' }); ArgumentText = @("-Patch 'C:\fix.patch'") }
            Assert-TestDockerfileBuildMounts @contract
            $contract.Mount[0].Text = 'absent mount'
            Assert-Throws { Assert-TestDockerfileBuildMounts @contract } -MessagePattern 'required build mount absent mount'
            $contract.Mount[0].Text = 'source=shared/fix.patch,target=C:\fix.patch'
            $contract.ArgumentText = @('absent argument')
            Assert-Throws { Assert-TestDockerfileBuildMounts @contract } -MessagePattern 'required build argument absent argument'
            $contract.ArgumentText = @("-Patch 'C:\fix.patch'")
            [IO.File]::AppendAllText($contract.Path, "RUN echo shared/fix.patch`n")
            Assert-Throws { Assert-TestDockerfileBuildMounts @contract } -MessagePattern 'exclusive build mount shared/fix.patch'
        }
    }

    It 'selects RUN instructions only from the requested parsed stage and refuses omitted or malformed selected stages' {
        Invoke-InTestDir -Files @{ 'Dockerfile' = "FROM pinned AS built`nRUN first`nCOPY file target`nFROM built AS selected`nRUN second```n third`n" } -Body {
            param($dir)
            $path = Join-Path $dir 'Dockerfile'
            Assert-Equal 'RUN first' (@(Get-TestDockerfileRun -Path $path) -join '|') 'default stage selection'
            Assert-Equal 'RUN second third' (@(Get-TestDockerfileRun -Path $path -Stage selected) -join '|') 'selected stage and joined continuation'
            $build = Get-TestDockerfileBuildRun -Path $path -Stage selected -ScriptLeaf second
            Assert-Equal 'RUN second third' $build.Command 'selected command'
            Assert-Equal 1 $build.All.Count 'whole selected-stage RUN collection'
            Assert-Throws { Get-TestDockerfileBuildRun -Path $path -ScriptLeaf absent } -MessagePattern 'one build RUN containing absent'
            [IO.File]::AppendAllText($path, "RUN second again`n")
            Assert-Throws { Get-TestDockerfileBuildRun -Path $path -Stage selected -ScriptLeaf second } -MessagePattern 'one build RUN containing second'
            Assert-Throws { Get-TestDockerfileRun -Path $path -Stage missing } -MessagePattern 'stage .missing. is missing'
            [IO.File]::WriteAllText($path, "FROM`nRUN forbidden`n")
            Assert-Throws { Get-TestDockerfileRun -Path $path } -MessagePattern 'stage .built. is missing'
        }
    }

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
