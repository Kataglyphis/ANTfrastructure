#requires -Version 7.0
# Install-NewHost.ps1 Sync-ShimForkCheckout: the hcsshim fork is built from a PINNED commit, and a
# work dir left by an older pin must not rebuild the old tree. NOT covered: clone, go build, deploy.

Describe 'Install-NewHost: shim fork checkout follows the pin' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\scripts\host\Install-NewHost.ps1' -FunctionName 'Sync-ShimForkCheckout')
    $script:Git = (Get-Command git -ErrorAction Stop).Source

    # Runs $Case with an upstream of two commits and a work clone left at the OLDER one. GIT_* removed:
    # a hook exports GIT_DIR, and `git -C <dir>` would then act on the hook's repo.
    function Invoke-ForkCase {
        param([scriptblock]$Case)
        Invoke-WithEnv @{ GIT_DIR = $null; GIT_WORK_TREE = $null; GIT_INDEX_FILE = $null } { Invoke-InTestDir { param($dir)
            $src = Join-Path $dir 'src'; $work = Join-Path $dir 'work'
            $null = & $script:Git init -q $src 2>&1
            $null = & $script:Git -C $src config uploadpack.allowAnySHA1InWant true
            foreach ($n in 'old', 'new') {
                [System.IO.File]::WriteAllText((Join-Path $src 'f.txt'), $n)
                $null = & $script:Git -C $src add f.txt
                $null = & $script:Git -C $src -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m $n
            }
            $f = @{ Dir = $dir; Work = $work; New = (& $script:Git -C $src rev-parse HEAD).Trim(); Old = (& $script:Git -C $src rev-parse HEAD~1).Trim() }
            $null = & $script:Git clone -q $src $work 2>&1
            $null = & $script:Git -C $work checkout -q --detach $f.Old 2>&1
            & $Case $f
        } }
    }
    function Get-WorkHead { param($f) (& $script:Git -C $f.Work rev-parse HEAD).Trim() }

    It 're-pins a work dir left at an older pin' {
        Invoke-ForkCase { param($f)
            Assert-True (Sync-ShimForkCheckout -Git $script:Git -Work $f.Work -Pin $f.New) 'reports that it moved HEAD'
            Assert-Equal $f.New (Get-WorkHead $f) 'HEAD is the new pin'
        }
    }

    It 'leaves a tree already at the pin alone, without touching the network' {
        Invoke-ForkCase { param($f)
            # An unreachable origin: any fetch attempt would throw.
            $null = & $script:Git -C $f.Work remote set-url origin (Join-Path $f.Dir 'no-such-remote')
            Assert-False (Sync-ShimForkCheckout -Git $script:Git -Work $f.Work -Pin $f.Old) 'nothing to do'
            Assert-Equal $f.Old (Get-WorkHead $f) 'HEAD unchanged'
        }
    }

    It 'fails naming the pin when the pinned commit cannot be fetched' {
        Invoke-ForkCase { param($f)
            $missing = 'f' * 40
            Assert-Throws { Sync-ShimForkCheckout -Git $script:Git -Work $f.Work -Pin $missing } 'unfetchable pin' -MessagePattern "cannot fetch the pinned fork commit $missing"
            Assert-Equal $f.Old (Get-WorkHead $f) 'HEAD left where it was'
        }
    }
}
