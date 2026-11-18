#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local fixtures cover failure accounting before any upstream clone or patch application.

Describe 'Patch drift gate accounting' {
    $source = 'windows/scripts/tests/Test-PatchesApplyClean.ps1'
    . (Get-ScriptFunctionDefinition -ScriptPath $source -FunctionName Get-PatchTargetPaths, Test-UpstreamGone, Get-PatchClone, Get-PatchApplyStatus, Get-StaticPatchResult, Get-PatchDriftExitCode)

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
            } },
        @{ Name = 'a clone of an upstream that answers 404 is not checked, not failed (CON280)'; Files = @{ 'mapped/one.patch' = "--- a/file`n+++ b/file`n" }; Exercise = {
                param($root)
                function Test-UpstreamGone { param([string]$Url) return $Url -eq 'https://example.invalid/gone.git' }
                Invoke-WithPatchGit -Code 128 -Body { param($state)
                    $gone = Get-StaticPatchResult -Patch (Get-Item -LiteralPath (Join-Path $root 'mapped/one.patch')) `
                        -RepoMap @{ mapped = @{ Url = 'https://example.invalid/gone.git'; Ref = 'v1' } } -Clones @{} -WorkDir $root -PatchExe 'unused'
                    Assert-Equal 'NOT CHECKED (upstream answers 404)' $gone.Status
                    $there = Get-StaticPatchResult -Patch (Get-Item -LiteralPath (Join-Path $root 'mapped/one.patch')) `
                        -RepoMap @{ mapped = @{ Url = 'https://example.invalid/there.git'; Ref = 'v1' } } -Clones @{} -WorkDir $root -PatchExe 'unused'
                    Assert-Equal 'FAIL (clone)' $there.Status 'a reachable upstream that refuses the clone still fails'
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

    It 'the verdict fails on a FAIL and only warns on a vanished upstream (CON280)' {
        $row = { param($status) [pscustomobject]@{ Patch = 'p.patch'; Repo = 'onnxruntime'; Ref = 'v1'; Status = $status } }
        Assert-Equal 0 (Get-PatchDriftExitCode -Results @((& $row 'OK'), (& $row 'NOT CHECKED (upstream answers 404)'))) 'a 404 upstream warns'
        Assert-Equal 1 (Get-PatchDriftExitCode -Results @((& $row 'NOT CHECKED (upstream answers 404)'), (& $row 'FAIL (clone)'))) 'a FAIL still fails'
        Assert-Equal 0 (Get-PatchDriftExitCode -Results @((& $row 'OK'), (& $row 'SKIP (no +++ b/ headers)'))) 'clean'
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
