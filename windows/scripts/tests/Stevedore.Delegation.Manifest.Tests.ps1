#requires -Version 7.0
# NOT covered: real file ACLs, signed runtime loading, live task registration or an actual administrator token.

function New-DelegationManifestState {
    $root = Join-Path ([IO.Path]::GetTempPath()) 'ant-delegation-manifest-fixture'
    $files = @(Get-DelegatedMaintenancePayload | ForEach-Object { [pscustomobject]@{ path = $_; sha256 = 'a' * 64 } })
    $files += [pscustomobject]@{ path = 'runtime\pwsh.exe'; sha256 = 'a' * 64 }
    $toolsRoot = Join-Path $root 'tools'
    $tools = @('buildctl.exe', 'nerdctl.exe' | ForEach-Object { [pscustomobject]@{ name = $_; path = Join-Path $toolsRoot $_; sha256 = 'a' * 64 } })
    $manifest = [pscustomobject]@{ schema = 1; keep_gib = 100; namespace = 'buildkit'; buildkit = 'npipe:////./pipe/buildkitd';
        containerd = '\\.\pipe\containerd-containerd'; reader_sid = 'S-1-5-21-1-2-3-1001'; files = $files; tools = $tools }
    [pscustomobject]@{ Root = $root; ToolsRoot = $toolsRoot; Manifest = $manifest }
}

function Invoke-DelegationManifestFixture {
    param($State, [scriptblock]$Body, [string]$Find = '', [string]$Replace = '')
    $prelude = @'
function Get-DelegatedMaintenanceLayout { [pscustomobject]@{Root=$State.Root;Tools=$State.ToolsRoot} }
function Assert-DelegatedMaintenancePath { param($Path,[switch]$Trusted) }
function Get-Content { param($LiteralPath,[switch]$Raw) $State.Manifest | ConvertTo-Json -Depth 12 }
function Get-FileHash { param($LiteralPath,$Algorithm) [pscustomobject]@{Hash=('a'*64)} }
'@
    Invoke-WithFunctionModule -ScriptPath 'windows/scripts/modules/WindowsStevedoreDelegation.Security.psm1' `
        -FunctionName 'Read-DelegatedMaintenanceManifest', 'Get-DelegatedMaintenancePayload', 'Get-DelegatedMaintenanceSddl' `
        -FixtureState $State -Prelude $prelude -Body $Body -Find $Find -Replace $Replace
}

function Get-DelegationManifestCases {
    return @(
            @{Find='if ($manifest.schema -ne 1 -or $manifest.keep_gib -ne 100 -or $manifest.namespace -cne ''buildkit'')';Change={param($x) $x.Manifest.keep_gib=1}},
            @{Find='if ($manifest.buildkit -cne ''npipe:////./pipe/buildkitd'' -or $manifest.containerd -cne ''\\.\pipe\containerd-containerd'')';Change={param($x) $x.Manifest.buildkit='npipe://other'}},
            @{Find='if ($manifest.files.Count -lt 9 -or $manifest.tools.Count -ne 2)';Change={param($x) $x.Manifest.files=@($x.Manifest.files|Where-Object path -NE 'runtime\pwsh.exe')}},
            @{Find='if (@($paths | Sort-Object -Unique).Count -ne $paths.Count)';Change={param($x) $x.Manifest.files+=$x.Manifest.files[0]}},
            @{Find='if ($required -cnotin $paths)';Change={param($x) $x.Manifest.files[0].path='runtime\replacement.exe'}},
            @{Find='if (-not $target.StartsWith($Root.TrimEnd(''\'') + ''\'', [StringComparison]::OrdinalIgnoreCase))';Change={param($x) $x.Manifest.files+=[pscustomobject]@{path='..\escape';sha256=('a'*64)}}},
            @{Find='if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256)';Change={param($x) $x.Manifest.files[0].sha256='b'*64}},
            @{Find='if ($tool.path -cne (Join-Path $layout.Tools $tool.name))';Change={param($x) $x.Manifest.tools[0].path=Join-Path $x.Root 'other.exe'}},
            @{Find='if ((Get-FileHash -LiteralPath $tool.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $tool.sha256)';Change={param($x) $x.Manifest.tools[0].sha256='b'*64}}
        )
}

function Assert-DelegationManifestRefusal {
    param($State)
    Assert-Throws { Read-MutDelegatedMaintenanceManifest $State.Root } -MessagePattern 'differs|differ|incomplete|duplicates|missing|escapes|changed'
}

Describe 'Delegated maintenance closure and policy manifest' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Stevedore.Delegation.Fixture.psm1') -ErrorAction Stop
        . (Get-DelegationFixtureFunctions Manifest)
    }

    It 'loads the complete fixed policy through the same production reader' {
        Invoke-DelegationManifestFixture -State (New-DelegationManifestState) -Body {
            param($State)
            $manifest = Read-MutDelegatedMaintenanceManifest $State.Root
            Assert-Equal 100 $manifest.keep_gib
            Assert-Equal 9 $manifest.files.Count
            Assert-Equal 2 $manifest.tools.Count
        }
    }

    It 'refuses widened policy endpoints omitted files duplicates traversal and hash drift' {
        foreach ($recipe in Get-DelegationManifestCases) {
            $state = New-DelegationManifestState
            & $recipe.Change $state
            Invoke-DelegationManifestFixture -State $state -Body { param($State) Assert-DelegationManifestRefusal $State }
        }
    }

    It 'mutation-tests that policy endpoint and mandatory-closure guards can fail' {
        $recipes = @(Get-DelegationManifestCases)
        foreach ($recipe in $recipes) {
            $state=New-DelegationManifestState
            & $recipe.Change $state
            Assert-Throws {
                Invoke-DelegationManifestFixture -State $state -Find $recipe.Find -Replace 'if ($false)' -Body {
                    param($State)
                    Assert-DelegationManifestRefusal $State
                }
            } -MessagePattern 'expected an exception'
        }
    }
}
