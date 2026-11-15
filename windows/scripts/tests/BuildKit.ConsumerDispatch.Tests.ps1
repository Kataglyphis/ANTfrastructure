#requires -Version 7.0
# A Windows publish must start every consumer's lanes on the new tag, and a failed dispatch must never fail the publish.
Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsBuildKit.Common.psm1') -Force

# Stands in for Git Bash: records its arguments in FAKE_BASH_LOG and exits with FAKE_BASH_EXIT.
function New-BkFakeBash([string]$Dir) {
    $fake = Join-Path $Dir 'fake-bash.ps1'
    Set-Content -LiteralPath $fake -Value @(
        '($args -join " ") | Add-Content -LiteralPath $env:FAKE_BASH_LOG'
        'exit [int]$env:FAKE_BASH_EXIT'
    )
    return $fake
}

Describe 'Get-BkPushTag' {
    It 'takes the tag from the last path segment' {
        $tags = [ordered]@{
            'registry.example/owner/image:winamd64'        = 'winamd64'
            'registry.example/owner/image:winamd64-nvidia' = 'winamd64-nvidia'
            'localhost:5000/kataglyphis:winarm64'          = 'winarm64'
            'localhost:5000/kataglyphis'                   = ''
        }
        foreach ($ref in $tags.Keys) { Assert-Equal $tags[$ref] (Get-BkPushTag -PushRef $ref) "the tag of $ref" }
    }
}

Describe 'Invoke-BkConsumerDispatch' {
    It 'runs the hub dispatch script in a login shell with the pushed tag' {
        Invoke-InTestDir { param($dir)
            $log = Join-Path $dir 'calls.txt'
            Invoke-WithEnv @{ FAKE_BASH_LOG = $log; FAKE_BASH_EXIT = '0' } {
                $ok = Invoke-BkConsumerDispatch -PushRef 'registry.example/owner/image:winamd64' -RepoRoot (Get-RepoRoot) -BashPath (New-BkFakeBash $dir)
                Assert-True $ok 'a dispatch that ran reports success'
                $calls = @(Get-Content -LiteralPath $log)
                $expected = (Join-Path (Get-RepoRoot) 'linux/scripts/dispatch-consumer-lanes.sh').Replace('\', '/')
                Assert-Equal 1 $calls.Count
                Assert-Equal "-l $expected --tag winamd64" $calls[0]
            }
        }
    }

    It 'warns, dispatches nothing more and does not throw when the dispatch fails, Git Bash is missing or the ref names no tag' {
        foreach ($case in @(
                @{ Ref = 'reg/kataglyphis:winarm64'; Code = '1'; Bash = 'fake'; Said = 'exited 1.*--tag winarm64'; Ran = $true },
                @{ Ref = 'reg/kataglyphis:winamd64'; Code = '0'; Bash = 'missing'; Said = 'by hand: bash linux/scripts/dispatch-consumer-lanes.sh --tag winamd64'; Ran = $false },
                @{ Ref = 'reg/kataglyphis'; Code = '0'; Bash = 'fake'; Said = 'names no tag'; Ran = $false }
            )) {
            Invoke-InTestDir { param($dir)
                $log = Join-Path $dir 'calls.txt'
                $bash = if ($case.Bash -eq 'fake') { New-BkFakeBash $dir } else { Join-Path $dir 'no-such-bash.exe' }
                Invoke-WithEnv @{ FAKE_BASH_LOG = $log; FAKE_BASH_EXIT = $case.Code } {
                    $ok = Invoke-BkConsumerDispatch -PushRef $case.Ref -RepoRoot (Get-RepoRoot) -BashPath $bash -WarningVariable warned -WarningAction SilentlyContinue
                    Assert-False $ok "$($case.Ref) reports no dispatch"
                    Assert-Match $case.Said "$warned"
                    Assert-Equal $case.Ran (Test-Path -LiteralPath $log) "whether $($case.Ref) reached bash"
                }
            }
        }
    }
}

Describe 'Build-Buildkit.ps1 publish' {
    It 'dispatches the consumer lanes right after the final push' {
        $driver = Get-Content -Raw -LiteralPath (Join-Path (Get-RepoRoot) 'windows/Build-Buildkit.ps1')
        Assert-Match '(?s)\[bk\] pushed \$PushRef.{0,200}Invoke-BkConsumerDispatch -PushRef \$PushRef -RepoRoot \$repoRoot' $driver
    }
}
