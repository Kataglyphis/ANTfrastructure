#requires -Version 7.0
# NOT covered: real containerd access, protected task execution, concurrent image changes or reclaimed bytes.

Describe 'Delegated immutable image inventory' {
    Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop

    It 'refuses incomplete malformed and repeated raw image identities' {
        $exercise = {
            $good = New-DelegationFixtureImageListing
            $line = $good | ConvertTo-Json -Compress
            $tags = @(ConvertTo-MutDelegatedImageTags @($line))
            Assert-Equal 1 $tags.Count
            $details = @([pscustomobject]@{ Manifest = $good.ID; Config = $good.ID })
            Assert-Equal $good.ID @(ConvertTo-MutDelegatedImageInventory $tags $details)[0].Config
            $untagged = New-DelegationFixtureImageListing -Untagged | ConvertTo-Json -Compress
            Assert-Throws { ConvertTo-MutDelegatedImageTags @($untagged) } -MessagePattern 'Untagged'
            Assert-Throws { ConvertTo-MutDelegatedImageInventory $tags @() } -MessagePattern 'identity is unknown'
            Assert-Throws { ConvertTo-MutDelegatedImageTags @($line, $line) } -MessagePattern 'duplicate tags'
            Assert-DelegationPropertyRefusals -Prototype $good -Fault @(@{ Name = 'two names' }, @{ ID = 'short' }, @{ ID = @($good.ID, $good.ID) }) -MessagePattern 'identity is unknown' -Body {
                param($changed)
                ConvertTo-MutDelegatedImageTags @($changed | ConvertTo-Json -Compress)
            }
            Assert-Throws { ConvertTo-MutDelegatedImageTags @('{"Name":"example/store:current"}') } -MessagePattern 'identity is unknown'
        }
        Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsStevedoreDelegation.Inventory.psm1' -FunctionName 'ConvertTo-DelegatedImageTags', 'ConvertTo-DelegatedImageInventory' -Body $exercise
    }

    It 'resolves raw digest-qualified aliases through one immutable manifest lookup' {
        $manifest = 'sha256:' + ('a' * 64)
        $config = 'sha256:' + ('b' * 64)
        $names = @(
            ('example/store:current@' + $manifest)
            ('local/kataglyphis:arm64-acceptance-fixture@' + $manifest)
        )
        $state = [pscustomobject]@{ Manifest = $manifest; Config = $config; Names = $names;
            Details = @([pscustomobject]@{ Id = $config; RepoTags = @(); RepoDigests = @('example/store@' + $manifest) }) }
        $exercise = {
            param($State)
            $problem = ''
            $actual = @()
            try { $actual = @(Get-MutDelegatedContainerdInventory @{} fixture aliases -Kind image) }
            catch { $problem = $_.Exception.Message }
            Assert-Equal '' $problem 'immutable manifest selectors must resolve digest-qualified aliases'
            Assert-Equal 2 $actual.Count
            Assert-Equal ($State.Names -join '|') (($actual | ForEach-Object Tag) -join '|')
            foreach ($row in $actual) {
                Assert-Equal $State.Manifest $row.Manifest
                Assert-Equal $State.Config $row.Config
            }
        }
        $cases = @(
            New-DelegationFixtureMutation 'ForEach-Object Manifest | Sort-Object -Unique' 'ForEach-Object Tag | Sort-Object -Unique' 'immutable manifest selectors'
            New-DelegationFixtureMutation 'ForEach-Object Manifest | Sort-Object -Unique' 'ForEach-Object Manifest' 'immutable manifest selectors'
        )
        Invoke-TestFunctionMutations -ModuleArguments (Get-DelegationModuleArguments ImageInventory $state) -Case $cases -IncludeControl -Body $exercise
        $refusal = {
            param($State)
            Assert-Throws { Get-MutDelegatedContainerdInventory @{} fixture aliases -Kind image } -MessagePattern 'identity is unknown'
        }
        $valid = $state.Details[0]
        foreach ($case in (Get-DelegationFixtureIdentityCases $valid ([pscustomobject]@{ Id = 'short' }))) {
            $state.Details = $case.Entries
            Invoke-DelegationModuleFixture -Kind ImageInventory -State $state -Body $refusal
        }
    }

    It 'records empty successful output and refuses successful commands with diagnostics' {
        $exercise = {
            $tool = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
            Invoke-InTestDir {
                param($dir)
                Assert-Equal 0 @(Invoke-MutDelegatedStoreCommand $tool @('-NoProfile', '-Command', 'exit 0') $dir quiet).Count
                Assert-Equal '' ([IO.File]::ReadAllText((Join-Path $dir 'quiet.stdout.log')).Trim())
                Assert-Equal '0' ([IO.File]::ReadAllText((Join-Path $dir 'quiet.exitcode.log')).Trim())
                Assert-Throws {
                    Invoke-MutDelegatedStoreCommand $tool @('-NoProfile', '-Command', '[Console]::Error.WriteLine(''inventory incomplete''); exit 0') $dir noisy
                } -MessagePattern 'probe diagnostics'
                Assert-Match 'inventory incomplete' ([IO.File]::ReadAllText((Join-Path $dir 'noisy.stderr.log')))
            }
        }
        Invoke-TestFunctionMutations -ScriptPath 'windows/scripts/modules/WindowsStevedoreDelegation.Inventory.psm1' -FunctionName 'Invoke-DelegatedStoreCommand' -Body $exercise `
            -Find '[IO.File]::ReadAllText((Join-Path $LogRoot "$Name.stderr.log")).Trim()' -Replace '$false' -Expected 'expected an exception' -IncludeControl
    }
}
