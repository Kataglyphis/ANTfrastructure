#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local fixtures cover pin selection, catalogue mapping and failure accounting; real upstream application needs the network gate.

Describe 'Patch drift gate accounting' {
    $source = 'windows/scripts/tests/Test-PatchesApplyClean.ps1'
    . (Get-ScriptFunctionDefinition -ScriptPath $source -FunctionName Get-PatchRefs, Get-PatchRepoMap, Get-PatchTargetPaths, Get-PatchClone, Get-PatchApplyStatus, Get-StaticPatchResult)

    function Invoke-WithPatchGit {
        param([int]$Code, [Parameter(Mandatory)][scriptblock]$Body)
        $state = New-TestCallState -Properties @{ Code = $Code }
        Invoke-WithTestNativeCommand -Name git -FixtureState $state -Implementation {} -Body $Body
    }

    It 'maps every current static patch before attempting an upstream clone' {
        $map = Get-PatchRepoMap -Refs (Get-PatchRefs)
        $patches = @(Get-ChildItem -LiteralPath (Join-Path (Get-RepoRoot) 'windows/scripts/patches') -Recurse -Filter '*.patch')
        Assert-True ($patches.Count -gt 0) 'the real catalogue is nonempty'
        Invoke-InTestDir { param($root)
            Invoke-WithPatchGit -Code 7 -Body { param($state)
                foreach ($patch in $patches) {
                    $result = Get-StaticPatchResult -Patch $patch -RepoMap $map -Clones @{} -WorkDir $root -PatchExe 'unused'
                    Assert-False ($result.Status -like 'FAIL (no repo mapping*') "mapped upstream for $($patch.FullName)"
                }
            }
        }
    }

    It 'uses the PyTorch source pin for the torchvision host compiler adapter' {
        $refs = Get-PatchRefs -FileVersions @{ PYTORCH_VERSION = 'v9.8.7'; TORCHVISION_VERSION = 'v1.2.3' }
        $map = Get-PatchRepoMap -Refs $refs
        Assert-Equal 'https://github.com/pytorch/pytorch.git' $map.pytorch.Url 'cpp_extension belongs to PyTorch'
        Assert-Equal 'v9.8.7' $map.pytorch.Ref 'the source pin wins over the fallback and torchvision pin'
        $overridden = Get-PatchRefs -FileVersions @{ PYTORCH_VERSION = 'v9.8.7' } -Versions @{ PYTORCH = 'v8.7.6' }
        Assert-Equal 'v8.7.6' $overridden.PYTORCH 'explicit diagnostic overrides retain precedence'
    }

    It 'uses both checked pin and repository selectors at the entry point' {
        $ast = Get-TestScriptAst -ScriptPath $source
        $refs = @(Get-TestAstCommands -Ast $ast -Name Get-PatchRefs)
        $map = @(Get-TestAstCommands -Ast $ast -Name Get-PatchRepoMap)
        Assert-TestAstCommand -Command $refs -Text 'Get-PatchRefs -FileVersions $fileVersions -Versions $Versions' -Unconditional
        Assert-TestAstCommand -Command $map -Text 'Get-PatchRepoMap -Refs $defaultRefs' -Unconditional
        Assert-TestAstOrder -Before $refs[0] -After $map[0]
    }

    $fileCases = @(
        @{ Name = 'fails an unmapped patch and skips only a patch with no existing target header'; Files = @{ 'unknown/one.patch' = "--- a/file`n+++ b/file`n"; 'mapped/two.patch' = "--- /dev/null`n+++ b/new-file`n" }; Exercise = {
                param($root)
                $unknown = Join-Path $root 'unknown/one.patch'
                $unmapped = Get-StaticPatchResult -Patch (Get-Item -LiteralPath $unknown) -RepoMap @{} -Clones @{} -WorkDir $root -PatchExe 'unused'
                Assert-Match '^FAIL \(no repo mapping' $unmapped.Status
                $created = Get-StaticPatchResult -Patch (Get-Item -LiteralPath (Join-Path $root 'mapped/two.patch')) `
                    -RepoMap @{ mapped = @{ Url = 'unused'; Ref = 'v1' } } -Clones @{} -WorkDir $root -PatchExe 'unused'
                Assert-Equal 'SKIP (no +++ b/ headers)' $created.Status
            } },
        @{ Name = 'checks a patch against the repo that claims it, not its directory'; Files = @{ 'consumer/port.patch' = "--- /dev/null`n+++ b/new-file`n" }; Exercise = {
                param($root)
                $map = @{ consumer = @{ Url = 'unused'; Ref = 'c1' }; port = @{ Url = 'unused'; Ref = 'p1'; Patches = @('port.patch') } }
                $claimed = Get-StaticPatchResult -Patch (Get-Item -LiteralPath (Join-Path $root 'consumer/port.patch')) -RepoMap $map -Clones @{} -WorkDir $root -PatchExe 'unused'
                Assert-Equal 'port' $claimed.Repo
                Assert-Equal 'p1' $claimed.Ref
            } },
        @{ Name = 'reports clone failure and leaves its cache empty'; Files = @{ 'mapped/one.patch' = "--- a/file`n+++ b/file`n" }; Exercise = {
                param($root)
                $cache = @{}
                Invoke-WithPatchGit -Code 7 -Body { param($state)
                    $result = Get-StaticPatchResult -Patch (Get-Item -LiteralPath (Join-Path $root 'mapped/one.patch')) `
                        -RepoMap @{ mapped = @{ Url = 'unused'; Ref = 'v1' } } -Clones $cache -WorkDir $root -PatchExe 'unused'
                    Assert-Equal 'FAIL (clone)' $result.Status
                    Assert-Equal 0 $cache.Count 'a failed clone cannot be reused'
                    Assert-Equal 1 $state.Calls.Count 'one clone attempt'
                }
            } }
    )
    foreach ($case in $fileCases) {
        It $case.Name {
            Invoke-InTestDir { param($root)
                Write-TestFileTree -Root $root -Files $case.Files
                & $case.Exercise $root
            }
        }
    }

    It 'reports a sparse checkout that returned success but omitted its target' {
        Invoke-InTestDir { param($root)
            Invoke-WithPatchGit -Code 0 -Body { param($state)
                $status = Get-PatchApplyStatus -Clone $root -Targets @('missing/file.txt') -PatchFile (Join-Path $root 'one.patch') -PatchExe 'unused'
                Assert-Equal 'FAIL (target not checked out: missing/file.txt)' $status
                Assert-Equal 1 $state.Calls.Count 'the missing file fails before git apply'
            }
        }
    }
}
