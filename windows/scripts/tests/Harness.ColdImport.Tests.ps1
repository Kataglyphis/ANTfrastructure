#requires -Version 7.0
# Child-session fixtures check imports and command visibility; they do not execute build entry points.

Invoke-InTestDir { param($dir)
    Describe 'Cold module command checks' {
        It 'resolves actual exports with quoted paths and reports missing exports' {
            $path = Join-Path $dir "fixture's module.psm1"
            [IO.File]::WriteAllText($path, "function Get-ColdFixtureValue { 42 }; Export-ModuleMember -Function Get-ColdFixtureValue")
            foreach ($force in @($false, $true)) {
                $result = Test-ColdModuleCommands -ModulePath $path -CommandName Get-ColdFixtureValue -Force:$force
                Assert-Equal 0 $result.ExitCode $result.Output
                Assert-Equal '' $result.Output
                $result = Test-ColdModuleCommands -ModulePath $path -CommandName Get-MissingColdFixtureValue -Force:$force
                Assert-Equal 1 $result.ExitCode
                Assert-Match 'Get-MissingColdFixtureValue' $result.Output
            }
        }

        It 'refuses failed imports and cannot see functions defined only in the parent' {
            $path = Join-Path $dir 'failed.psm1'
            [IO.File]::WriteAllText($path, "throw 'fixture import failed'")
            $result = Test-ColdModuleCommands -ModulePath $path -CommandName Get-Date
            Assert-True ($result.ExitCode -ne 0)
            Assert-Match 'fixture import failed' $result.Output
            [IO.File]::WriteAllText($path, 'Export-ModuleMember -Function @()')
            function global:Get-ParentOnlyColdFixture { 42 }
            try {
                $result = Test-ColdModuleCommands -ModulePath $path -CommandName Get-ParentOnlyColdFixture
                Assert-Equal 1 $result.ExitCode
                Assert-Match 'Get-ParentOnlyColdFixture' $result.Output
            } finally { Remove-Item Function:\Get-ParentOnlyColdFixture }
        }
        It 'rejects a probe that hides a failed child exit code' {
            $text = (Get-Command Test-ColdModuleCommands).Definition
            $source = "function Test-ColdModuleCommands {`n$text`n}"
            Invoke-WithFunctionModule -Text $source -FunctionName Test-ColdModuleCommands -Find '$code = $LASTEXITCODE' -Replace '$code = 0' -Body {
                $result = Test-MutColdModuleCommands -ModulePath (Join-Path ([IO.Path]::GetTempPath()) 'absent-cold-fixture.psm1') -CommandName Get-Date
                Assert-Throws { Assert-True ($result.ExitCode -ne 0) } -MessagePattern 'Assert-True failed'
            }
        }
    }
}
