#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Local Git fixtures cover source identity, sparse fallback, patch checks and accounting; recursive source builds and upstream network availability need separate proofs.

Import-TestRepoModule -Name 'WindowsScripts.Shared', 'WindowsSourceBuild.Common'
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.GitFixtures.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'WindowsOrt.SourceFixture.psm1') -ErrorAction Stop

$source = 'windows/scripts/tests/Test-PatchesApplyClean.ps1'
. (Get-ScriptFunctionDefinition -ScriptPath $source -FunctionName Get-PatchRefs, Get-PatchRepoMap, Get-PatchTargetPaths, Get-PatchCheckout, Get-OrtPatchCheckout, Get-PatchClone, Get-PatchApplyStatus, Get-StaticPatchResult, Resolve-GnuPatchExe)

function Invoke-OrtPatchFixtureClone {
    param($Fixture)
    Get-PatchClone -RepoKey onnxruntime -Spec $Fixture.Spec -Clones $Fixture.Cache -WorkDir $Fixture.Work
}

function Invoke-OrtPatchFixture {
    param([Parameter(Mandatory)][scriptblock]$Body)
    $patchExercise = $Body
    Invoke-OrtSourceFixture -PayloadPath 'source/file.txt' -Payload "old`n" -Exercise {
        param($release)
        $spec = @{ Url = [uri]::new($release.Repo).AbsoluteUri; Ref = 'v1.31.1'; ExpectedCommit = $release.Commit; FallbackUrl = [uri]::new($release.Repo).AbsoluteUri }
        & $patchExercise ([pscustomobject]@{ Root = $release.Directory; Repo = $release.Repo; Commit = $release.Commit; Spec = $spec; Cache = @{}; Work = Join-Path $release.Directory 'clones' })
    }.GetNewClosure()
}

Describe 'Patch drift gate accounting' {

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

    $identityExercise = {
        param($root, $identity)
        Invoke-OrtPatchFixture {
            param($fixture)
            $fixture.Spec.ExpectedCommit = Add-TestGitCommit -Path $fixture.Repo -Files $identity.Change -Message 'different source identity' -PassThru
            if ($identity.MissingPrimary) { $fixture.Spec.Url = Join-Path $fixture.Root 'missing primary' }
            $checkout = Invoke-OrtPatchFixtureClone -Fixture $fixture
            Assert-Match $identity.Pattern $checkout.Error
            Assert-Equal 0 $fixture.Cache.Count
        }
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
        @{ Name = 'refuses a successful primary tag that names a different commit'; Files = @{}; Change = @{ 'next.txt' = 'next' }; MissingPrimary = $false; Pattern = 'FAIL.*source commit mismatch'; Exercise = $identityExercise },
        @{ Name = 'refuses a matching commit with a different declared release version'; Files = @{}; Change = @{ VERSION_NUMBER = '1.29.0' }; MissingPrimary = $true; Pattern = 'FAIL.*source version mismatch'; Exercise = $identityExercise }
    )
    foreach ($case in $fileCases) {
        It $case.Name {
            Invoke-InTestDir { param($root)
                Write-TestFileTree -Root $root -Files $case.Files
                & $case.Exercise $root $case
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

Describe 'Verified sparse ONNX patch sources' {
    It 'imports the shared identity checks unconditionally at the real entry point' {
        $ast = Get-TestScriptAst -ScriptPath $source
        $imports = @(Get-TestAstCommands -Ast $ast -Name Import-Module | Where-Object { $_.Extent.Text.Contains('WindowsSourceBuild.Common.psm1') })
        Assert-TestAstCommand -Command $imports -Text 'Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) ''modules\WindowsSourceBuild.Common.psm1'') -ErrorAction Stop' -Unconditional
    }

    It 'preserves LF patch inputs despite an inherited autocrlf setting' {
        Invoke-OrtPatchFixture {
            param($fixture)
            $config = Join-Path $fixture.Root 'git-user.config'
            Write-TestFileTree -Root $fixture.Root -Files @{ 'git-user.config' = "[core]`nautocrlf=true`n" }
            Invoke-WithEnv @{ GIT_CONFIG_GLOBAL = $config } {
                $checkout = Invoke-OrtPatchFixtureClone -Fixture $fixture
                Assert-Equal '' $checkout.Error
                Assert-Equal 'false' (@(Invoke-TestGitCommand -Path $checkout.Path -ArgumentList @('config', '--local', 'core.autocrlf'))[-1])
                $null = Invoke-TestGitCommand -Path $checkout.Path -ArgumentList @('sparse-checkout', 'set', '--no-cone', '--', 'source/file.txt')
                Assert-Equal "old`n" ([IO.File]::ReadAllText((Join-Path $checkout.Path 'source/file.txt')))
            }
        }
    }

    It 'reads the original commit pin and retains explicit paired overrides' {
        $refs = Get-PatchRefs -FileVersions @{ ONNXRUNTIME_VERSION = 'v1.31.1'; ONNXRUNTIME_WINDOWS_SOURCE_COMMIT = 'a' * 40 }
        $map = Get-PatchRepoMap -Refs $refs
        Assert-Equal ('a' * 40) $map.onnxruntime.ExpectedCommit
        Assert-Equal 'https://github.com/ROCm/onnxruntime.git' $map.onnxruntime.FallbackUrl
        $refs = Get-PatchRefs -FileVersions @{ ONNXRUNTIME_WINDOWS_SOURCE_COMMIT = 'a' * 40 } -Versions @{ ONNXRUNTIME = 'v1.29.0'; ONNXRUNTIME_SOURCE_COMMIT = 'b' * 40 }
        Assert-Equal 'v1.29.0' $refs.ONNXRUNTIME
        Assert-Equal ('b' * 40) $refs.ONNXRUNTIME_SOURCE_COMMIT
    }

    It 'uses the exact primary release and caches only a checked source' {
        Invoke-OrtPatchFixture {
            param($fixture)
            $fixture.Spec.FallbackUrl = Join-Path $fixture.Root 'missing fallback'
            $first = Invoke-OrtPatchFixtureClone -Fixture $fixture
            Assert-Equal '' $first.Error
            Assert-False (Test-Path -LiteralPath (Join-Path $first.Path 'source/file.txt')) 'the checkout stays sparse'
            $fixture.Spec.Url = Join-Path $fixture.Root 'missing primary'
            $second = Invoke-OrtPatchFixtureClone -Fixture $fixture
            Assert-Equal $first.Path $second.Path
            Assert-Equal 1 $fixture.Cache.Count
        }
    }

    It 'recovers a tagless mirror by full original commit and checks the actual patch' {
        Invoke-OrtPatchFixture {
            param($fixture)
            $fixture.Spec.Url = Join-Path $fixture.Root 'missing primary'
            $null = Invoke-TestGitCommand -Path $fixture.Repo -ArgumentList @('tag', '-d', 'v1.31.1')
            $checkout = Invoke-OrtPatchFixtureClone -Fixture $fixture
            Assert-Equal '' $checkout.Error
            $patch = Join-Path $fixture.Root 'one.patch'
            [IO.File]::WriteAllText($patch, "--- a/source/file.txt`n+++ b/source/file.txt`n@@ -1 +1 @@`n-old`n+new`n")
            $patchExe = if ($IsWindows) { Resolve-GnuPatchExe } else { (Get-Command patch).Source }
            Assert-Equal 'OK' (Get-PatchApplyStatus -Clone $checkout.Path -Targets @('source/file.txt') -PatchFile $patch -PatchExe $patchExe)
            Assert-Equal "old`n" ([IO.File]::ReadAllText((Join-Path $checkout.Path 'source/file.txt'))) 'dry runs preserve original source'
        }
    }

    It 'refuses missing or malformed pins before creating a checkout' {
        Invoke-OrtPatchFixture {
            param($fixture)
            foreach ($bad in @('', 'abcdef0', ('A' * 40))) {
                $fixture.Spec.ExpectedCommit = $bad
                $checkout = Invoke-OrtPatchFixtureClone -Fixture $fixture
                Assert-Match 'FAIL.*full lowercase Git commit' $checkout.Error
                Assert-False (Test-Path -LiteralPath $fixture.Work)
                Assert-Equal 0 $fixture.Cache.Count
            }
        }
    }

    It 'keeps a failed fallback out of the clone cache' {
        Invoke-OrtPatchFixture {
            param($fixture)
            $fixture.Spec.Url = $fixture.Spec.FallbackUrl = Join-Path $fixture.Root 'missing source'
            $checkout = Invoke-OrtPatchFixtureClone -Fixture $fixture
            Assert-Equal 'FAIL (clone)' $checkout.Error
            Assert-Equal '' $checkout.Path
            Assert-Equal 0 $fixture.Cache.Count
        }
    }
}
