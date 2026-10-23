#requires -Version 7.0
# Local files cover requirements transactions and manifest serialization; real wheel builds and installer execution remain integration coverage.

Import-Module (Join-Path $PSScriptRoot 'WindowsTest.MutationCases.psm1') -ErrorAction Stop

function Assert-PythonRequirementTransaction {
    param($Root)
    $path = Join-Path $Root 'requirements.txt'
    $wheel = Join-Path $Root 'pkg-1-cp315-cp315t-win_arm64.whl'
    Set-Content -LiteralPath $wheel -Value 'wheel bytes'
    $text = "pkg==1 \`n    --hash=sha256:original`nother==2 \`n    --hash=sha256:other"
    [IO.File]::WriteAllText($path, $text)
    $before = [Convert]::ToHexString([IO.File]::ReadAllBytes($path))
    Assert-Equal 0 @(Invoke-MutPythonAppWheelRequirementUpdate -Requirements $path -Action {}).Count
    Assert-Equal $before ([Convert]::ToHexString([IO.File]::ReadAllBytes($path))) 'no selections must not rewrite the requirements'
    $names = Invoke-MutPythonAppWheelRequirementUpdate -Requirements $path -Action {
        param($update)
        Add-MutPythonAppRequirementWheelHash -Update $update -Name pkg -Path $wheel
    }
    Assert-Equal pkg ($names -join '|')
    $sha = (Get-FileHash -LiteralPath $wheel -Algorithm SHA256).Hash.ToLowerInvariant()
    $updated = [IO.File]::ReadAllText($path)
    Assert-True ($updated.Contains("--hash=sha256:$sha")) 'selected wheel hash must be written in lowercase'
    Assert-True ($updated.Contains('other==2')) 'unrelated requirements remain'
    Assert-False ([Convert]::ToHexString([IO.File]::ReadAllBytes($path)).StartsWith('EFBBBF')) 'requirements remain UTF8 without BOM'
    $beforeFailure = [IO.File]::ReadAllText($path)
    Assert-Throws {
        Invoke-MutPythonAppWheelRequirementUpdate -Requirements $path -Action {
            param($update)
            Add-MutPythonAppRequirementWheelHash -Update $update -Name pkg -Path $wheel
            throw 'selection failed after first wheel'
        }
    } -MessagePattern 'selection failed after first wheel'
    Assert-Equal $beforeFailure ([IO.File]::ReadAllText($path)) 'failed selection must not persist partial hash updates'
}

Describe 'Consumer module operation policies' {
    Invoke-TestMutationChecks -Check @(

        @{ Name = 'shares conditional writes, hashing and failure atomicity, with a lost-write fault control'; Arguments = @{
            Find = 'if ($update.Names.Count -gt 0)'; Replace = 'if ($false)'; Expected = 'selected wheel hash must be written'
            ModuleArgumentsFactory = {
                param($dir)
                @{ ScriptPath = 'windows/scripts/modules/WindowsPythonApp.Common.psm1'
                    FunctionName = @('Invoke-PythonAppWheelRequirementUpdate', 'Add-PythonAppRequirementWheelHash', 'Add-RequirementHash', 'Get-RequirementLineGroup')
                    BodyArgumentList = @($dir) }
            }; Body = ${function:Assert-PythonRequirementTransaction} } }
        @{ Name = 'writes generated manifests as UTF8 without BOM and returns the literal destination, with an encoding fault control'; Arguments = @{
            Find = '-Encoding utf8NoBOM'; Replace = '-Encoding utf8BOM'; Expected = 'manifest encoding'
            ModuleArgumentsFactory = {
                param($dir)
                @{ ScriptPath = 'windows/scripts/modules/WindowsPythonApp.Common.psm1'; FunctionName = @('Save-PythonAppManifest'); BodyArgumentList = @($dir) }
            }; Body = {
                param($dir)
                $path = Join-Path $dir 'manifest[1].xml'
                $text = '<root>λ &amp; literal</root>'
                Assert-Equal $path (Save-MutPythonAppManifest -Destination $path -Text $text)
                $actual = [IO.File]::ReadAllBytes($path)
                Assert-False ([Convert]::ToHexString($actual).StartsWith('EFBBBF')) 'manifest encoding must omit BOM'
                Assert-Equal ($text + [Environment]::NewLine) ([Text.Encoding]::UTF8.GetString($actual)) 'manifest encoding preserves Unicode and newline policy'
            } } }
@{ Name = 'reuses ActiveOnly on the already materialized hazards, with a disabled-device fault control'; Arguments = @{
        Find = '-Pattern $HazardPattern -ActiveOnly'; Replace = '-Pattern $HazardPattern'; Expected = 'REFUSING to start'
        ModuleArgumentsFactory = {
                param($dir)
                @{ ScriptPath = 'windows/scripts/modules/WindowsBuildDriver.Common.psm1'
                    FunctionName = @('Get-Rdna4HazardDevice', 'Assert-NoActiveRdna4Gpu')
                    FixtureState = [pscustomobject]@{ Directory = $dir; Probes = 0; Devices = @() }
                    Prelude = @'
function Get-PnpDevice { $State.Probes++; return $State.Devices }
'@ }
            }; Body = {
                param($state)
                $state.Devices = @([pscustomobject]@{ FriendlyName = 'fixture hazard disabled'; Status = 'Error' })
                Assert-MutNoActiveRdna4Gpu -HazardPattern 'fixture hazard'
                Assert-Equal 1 $state.Probes 'refusal checks must not enumerate live devices twice'
                $state.Devices += [pscustomobject]@{ FriendlyName = 'fixture hazard active'; Status = 'ok' }
                Assert-Throws { Assert-MutNoActiveRdna4Gpu -HazardPattern 'fixture hazard' } -MessagePattern "REFUSING to start: 'fixture hazard active' is ENABLED"
                Assert-Equal 2 $state.Probes
                $warnings = @(Assert-MutNoActiveRdna4Gpu -HazardPattern 'fixture hazard' -Force 3>&1)
                Assert-Equal 1 $warnings.Count 'explicit override remains advisory'
                Assert-Match 'fixture hazard active' $warnings[0]
                $prior = $state.Probes
                Assert-MutNoActiveRdna4Gpu -Devices @() -HazardPattern 'fixture hazard'
                Assert-Equal $prior $state.Probes 'an explicitly empty snapshot must not become a live probe'
            }
    } }
    )
}
