#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local fixtures cover failure accounting before any upstream clone or patch application.

Describe 'Patch drift gate accounting' {
    $source = 'windows/scripts/tests/Test-PatchesApplyClean.ps1'
    . (Get-ScriptFunctionDefinition -ScriptPath $source -FunctionName Get-PatchTargetPaths, Get-PatchClone, Get-PatchApplyStatus, Get-StaticPatchResult)

    function Invoke-WithPatchGit {
        param([int]$Code, [Parameter(Mandatory)][scriptblock]$Body)
        $state = New-TestCallState -Properties @{ Code = $Code }
        Invoke-WithTestNativeCommand -Name git -FixtureState $state -Implementation {} -Body $Body
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
