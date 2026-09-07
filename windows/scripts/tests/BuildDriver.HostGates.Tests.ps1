#requires -Version 7.0
# Tests for the two host preflight gates in WindowsBuildDriver.Common.psm1 that
# were hardened on 2026-08-07: Assert-DiskHeadroom (now multi-drive) and
# Assert-ShimPatch (now SHA256-based, size only as a fallback).
#
# Both gates only ever run at the start of a multi-hour build, so a regression
# in either is invisible until it costs a run: a disk gate that watches the
# wrong volume passes a build straight into the "hcsshim fails weirdly" band,
# and a shim gate that waves the stock binary through hands you ExportLayer 0x3
# after the compile is already paid for.

Describe 'Assert-DiskHeadroom (multi-drive)' {

    It 'passes when every checked drive clears the floor' {
        # MinFreeGb 0: no real drive can be below it, so this exercises the
        # success path without depending on the machine's actual free space.
        Assert-DiskHeadroom -MinFreeGb 0
        Assert-DiskHeadroom -Drive @('C') -MinFreeGb 0
    }

    It 'accepts letter, colon and full-path forms for the same drive' {
        # The drivers pass $repoRoot (a path); humans pass 'D:'. Both must
        # normalize to one letter rather than blowing up in Get-PSDrive.
        foreach ($form in @('C', 'C:', 'C:\', "$env:SystemRoot")) {
            Assert-DiskHeadroom -Drive @($form) -MinFreeGb 0
        }
    }

    It 'ignores a drive letter that does not exist on this host' {
        # A repo checked out on C: collapses the list to one entry; a bogus
        # letter must not be an error (the gate is about space, not topology).
        Assert-DiskHeadroom -Drive @('Q', 'Z') -MinFreeGb 0
    }

    It 'throws below the floor and names the short drive' {
        # 100 PB: below the floor on any host, so the failure path is testable.
        Assert-Throws -MessagePattern 'C: has .* GB free' -Body {
            Assert-DiskHeadroom -Drive @('C') -MinFreeGb 100000000
        } -Message 'must fail loudly and say which drive is short'
    }

    It 'reports EVERY short drive, not just the first' {
        # The whole point of the change: a full context drive next to a healthy
        # store drive used to be invisible. Both must appear in one message.
        $repoDrive = (Get-Item $PSScriptRoot).PSDrive.Name
        $threw = $null
        try { Assert-DiskHeadroom -Drive @($repoDrive) -MinFreeGb 100000000 } catch { $threw = $_.Exception.Message }
        Assert-NotNull $threw 'must throw'
        Assert-Match 'C:' $threw 'store drive must be reported'
        Assert-Match "${repoDrive}:" $threw 'repo drive must be reported'
    }

    It '-Force downgrades the failure to a warning' {
        Assert-DiskHeadroom -Drive @('C') -MinFreeGb 100000000 -Force -WarningAction SilentlyContinue
    }
}

Describe 'Write-ShimPatchState / Get-ShimPatchStatePath' {

    It 'records the hash, size and variant of the deployed binary' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'patched-shim-bytes' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            $written = Write-ShimPatchState -ShimPath $shim -StatePath $statePath -Variant 'local-constant'
            Assert-Equal $statePath $written 'returns the path it wrote'
            $state = Get-Content $statePath -Raw | ConvertFrom-Json
            Assert-Equal (Get-FileHash -Algorithm SHA256 -Path $shim).Hash $state.sha256 'records the live hash'
            Assert-Equal 'local-constant' $state.variant 'records the variant'
            Assert-Equal (Get-Item $shim).Length $state.sizeBytes 'records the size'
        }
    }

    It 'records the stock backup hash when one is supplied' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            $stock = Join-Path $dir 'shim.exe.orig'
            Set-Content -Path $shim -Value 'patched' -NoNewline
            Set-Content -Path $stock -Value 'stock' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            Write-ShimPatchState -ShimPath $shim -StatePath $statePath -StockBackupPath $stock | Out-Null
            $state = Get-Content $statePath -Raw | ConvertFrom-Json
            Assert-Equal (Get-FileHash -Algorithm SHA256 -Path $stock).Hash $state.stockSha256 'records the stock hash'
        }
    }

    It 'prefers an explicit path, then the env override, then ProgramData' {
        Assert-Equal 'C:\explicit.json' (Get-ShimPatchStatePath -StatePath 'C:\explicit.json')
        Invoke-WithEnv @{ KATAGLYPHIS_SHIM_STATE = 'C:\from-env.json' } {
            Assert-Equal 'C:\from-env.json' (Get-ShimPatchStatePath)
        }
        Invoke-WithEnv @{ KATAGLYPHIS_SHIM_STATE = '' } {
            Assert-Match 'kataglyphis[\\/]shim-patch\.json$' (Get-ShimPatchStatePath) 'default lands under ProgramData'
        }
    }
}

Describe 'Assert-ShimPatch (hash gate)' {

    It 'passes when the live binary matches the recorded hash' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'patched-shim-bytes' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            Write-ShimPatchState -ShimPath $shim -StatePath $statePath -Variant 'local-constant' | Out-Null
            # No -Force, no size in either table: the hash alone must satisfy it.
            Assert-ShimPatch -ShimPath $shim -StatePath $statePath
        }
    }

    It 'throws when the binary changed after deployment' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'patched-shim-bytes' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            Write-ShimPatchState -ShimPath $shim -StatePath $statePath | Out-Null
            # Simulate a Stevedore update overwriting the patched shim.
            Set-Content -Path $shim -Value 'something-else-entirely' -NoNewline
            Assert-Throws -MessagePattern 'CHANGED since the patch was deployed' -Body {
                Assert-ShimPatch -ShimPath $shim -StatePath $statePath
            }
        }
    }

    It 'names a revert to stock specifically when the stock hash is known' {
        # The operator-facing difference that matters: "reverted to stock" tells
        # you a Stevedore update did it; "changed" leaves you guessing.
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            $stock = Join-Path $dir 'shim.exe.orig'
            Set-Content -Path $shim -Value 'patched' -NoNewline
            Set-Content -Path $stock -Value 'stock' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            Write-ShimPatchState -ShimPath $shim -StatePath $statePath -StockBackupPath $stock | Out-Null
            Copy-Item $stock $shim -Force
            Assert-Throws -MessagePattern 'REVERTED TO THE STOCK BINARY' -Body {
                Assert-ShimPatch -ShimPath $shim -StatePath $statePath
            }
        }
    }

    It '-Force downgrades a hash mismatch to a warning' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'patched' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            Write-ShimPatchState -ShimPath $shim -StatePath $statePath | Out-Null
            Set-Content -Path $shim -Value 'other' -NoNewline
            Assert-ShimPatch -ShimPath $shim -StatePath $statePath -Force -WarningAction SilentlyContinue
        }
    }

    It 'ignores a state file recorded for a DIFFERENT install path' {
        # Comparing hashes across two unrelated binaries would be worse than no
        # check at all, so the gate must fall back instead.
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            $other = Join-Path $dir 'elsewhere.exe'
            Set-Content -Path $shim -Value 'patched' -NoNewline
            Set-Content -Path $other -Value 'unrelated' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            Write-ShimPatchState -ShimPath $other -StatePath $statePath | Out-Null
            # Falls back to size: declare this file's size as patched -> passes.
            Assert-ShimPatch -ShimPath $shim -StatePath $statePath `
                -PatchedSize @((Get-Item $shim).Length) -WarningAction SilentlyContinue
        }
    }
}

Describe 'Assert-ShimPatch (size fallback, no recorded hash)' {

    It 'accepts a known patched size and asks to record the hash' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'x' -NoNewline
            Assert-ShimPatch -ShimPath $shim -StatePath (Join-Path $dir 'absent.json') `
                -PatchedSize @((Get-Item $shim).Length) -WarningAction SilentlyContinue
        }
    }

    It 'still fails hard on a known stock size' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'x' -NoNewline
            # The patched sentinel must not collide with the fixture's real size
            # (1 byte), or the patched branch wins and the stock check never runs.
            Assert-Throws -MessagePattern 'STOCK binary' -Body {
                Assert-ShimPatch -ShimPath $shim -StatePath (Join-Path $dir 'absent.json') `
                    -PatchedSize @(999999) -StockSize @((Get-Item $shim).Length)
            }
        }
    }

    It 'warns (never throws) on an unrecognised size' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'x' -NoNewline
            Assert-ShimPatch -ShimPath $shim -StatePath (Join-Path $dir 'absent.json') `
                -PatchedSize @(999999) -StockSize @(999998) -WarningAction SilentlyContinue
        }
    }

    It 'throws when no shim is installed and -Force is not passed (fail-closed, backlog #48)' {
        Invoke-InTestDir { param($dir)
            Assert-Throws -MessagePattern 'shim not found' -Body {
                # -AlternateRoot @(): a build host HAS a real shim, which the fallback
                # probe would find, and the not-found path would never run.
                Assert-ShimPatch -ShimPath (Join-Path $dir 'missing.exe') -AlternateRoot @() -WarningAction SilentlyContinue
            }
        }
    }

    It 'skips with a warning when no shim is installed and -Force is passed' {
        Invoke-InTestDir { param($dir)
            Assert-ShimPatch -ShimPath (Join-Path $dir 'missing.exe') -AlternateRoot @() -Force -WarningAction SilentlyContinue
        }
    }

    It 'falls back to the size check when the state file is corrupt' {
        Invoke-InTestDir { param($dir)
            $shim = Join-Path $dir 'shim.exe'
            Set-Content -Path $shim -Value 'x' -NoNewline
            $statePath = Join-Path $dir 'state.json'
            Set-Content -Path $statePath -Value 'not json at all {{{' -NoNewline
            Assert-ShimPatch -ShimPath $shim -StatePath $statePath `
                -PatchedSize @((Get-Item $shim).Length) -WarningAction SilentlyContinue
        }
    }
}

Describe 'Get-StageDiskFloorGb / Assert-StageDiskHeadroom (shared by both lanes)' {

    # The floors were calibrated against a measured run after an estimated 80 GB
    # media floor refused a legitimate rebuild at 72.3 GB free. They now live in
    # the module so the classic lane — which had NO per-stage check at all —
    # enforces the same numbers instead of a second copy that drifts.

    It 'gives heavy stages a higher floor than trimmings' {
        Assert-True ((Get-StageDiskFloorGb -Label 'Dockerfile.nvidia') -gt (Get-StageDiskFloorGb -Label 'Dockerfile.torch')) `
            'CUDA must demand more headroom than the app stage'
        Assert-True ((Get-StageDiskFloorGb -Label 'media-core') -gt (Get-StageDiskFloorGb -Label 'toolchain-builder')) `
            'a media branch must demand more than the toolchain'
    }

    It 'matches BOTH lanes label shapes for the same stage' {
        # BK labels look like 'Dockerfile.media-builder:media-core-built-onnx';
        # classic ones like 'Dockerfile.media-builder-media-core'. A floor that
        # only matched one shape would silently fall back to the default.
        Assert-Equal (Get-StageDiskFloorGb -Label 'Dockerfile.media-builder:media-core-built-onnx') `
                     (Get-StageDiskFloorGb -Label 'Dockerfile.media-builder-media-core') `
                     'the same stage must get the same floor in either lane'
        Assert-Equal (Get-StageDiskFloorGb -Label 'Dockerfile.media-merge-builder:built') `
                     (Get-StageDiskFloorGb -Label 'Dockerfile.media-merge-builder-merge') `
                     'merge floors must agree across lanes'
    }

    It 'falls back to a sane default for an unknown label' {
        Assert-Equal 40 (Get-StageDiskFloorGb -Label 'something-new') 'unknown stages still get a floor'
        Assert-Equal 40 (Get-StageDiskFloorGb -Label '') 'an empty label must not throw'
    }

    It 'passes when the floor is clearable and throws when it is not' {
        # The pass case derives its floor from the ACTUAL free space instead of
        # `-FloorGb 0`. That form looked up the 40 GB table default and assumed
        # the runner clears it - "real disk clears 40" was written right here -
        # which made the test a property of the host. On 2026-08-12 a
        # windows-2025 runner had 32.5 GB free on C: and this was the single red
        # test in an otherwise green 480-test suite, failing with a message about
        # buildkit store GC that had nothing to do with the code under test.
        #
        # The table-lookup path is not lost: the preceding test already asserts
        # Get-StageDiskFloorGb returns 40 for an unknown label, which is the same
        # code `-FloorGb 0` reaches.
        $freeGb = [math]::Floor((Get-PSDrive C).Free / 1GB)
        $clearable = [math]::Max(1, $freeGb - 1)
        Assert-StageDiskHeadroom -Label 'test' -FloorGb $clearable

        Assert-Throws -MessagePattern 'REFUSING to start' -Body {
            Assert-StageDiskHeadroom -Label 'test' -FloorGb 100000000
        }
    }

    It '-Force downgrades the refusal to a warning' {
        Assert-StageDiskHeadroom -Label 'test' -FloorGb 100000000 -Force -WarningAction SilentlyContinue
    }
}

Describe 'Get-StageDiskFloorGb per SUB-stage (refined after a 1.5 GB false refusal)' {

    # The first table lumped every media-* label at one floor, which applies
    # ONNX's appetite to sub-stages an order of magnitude lighter — it refused
    # the FFmpeg sub-stage at 53.5 GB free over a 55 GB floor. Blocking correct
    # work is the same class of failure as waving danger through.

    It 'gives ONNX the highest media floor and FFmpeg a lower one' {
        $onnx = Get-StageDiskFloorGb -Label 'Dockerfile.media-builder:media-core-built-onnx'
        $ffm  = Get-StageDiskFloorGb -Label 'Dockerfile.media-builder:media-core-built-ffmpeg'
        Assert-True ($onnx -gt $ffm) 'the 25 GB ONNX image must demand more than the FFmpeg sub-stage'
    }

    It 'does not let the generic media rule swallow the specific sub-stages' {
        # Ordering bug guard: a generic 'media-core' rule placed first would
        # catch 'media-core-built-onnx' and silently under-protect it.
        Assert-Equal 55 (Get-StageDiskFloorGb -Label 'Dockerfile.media-builder:media-core-built-onnx')
        Assert-Equal 45 (Get-StageDiskFloorGb -Label 'Dockerfile.media-builder:media-core-built-opencv')
    }

    It 'still covers the branches and the merge' {
        Assert-Equal 45 (Get-StageDiskFloorGb -Label 'media-litert-built')
        Assert-Equal 40 (Get-StageDiskFloorGb -Label 'media-tvm-built')
        Assert-Equal 45 (Get-StageDiskFloorGb -Label 'Dockerfile.media-merge-builder:built')
    }
}

Describe 'Assert-NoActiveRdna4Gpu (RDNA4 layer-lock gate, 2026-08-10)' {

    # Fake PnP device rows: the gate must judge from FriendlyName + Status
    # alone, so tests never depend on this host's real GPUs.
    $rdna4On   = [pscustomobject]@{ FriendlyName = 'AMD Radeon RX 9070 XT'; Status = 'OK' }
    $rdna4Off  = [pscustomobject]@{ FriendlyName = 'AMD Radeon RX 9070 XT'; Status = 'Error' }
    $igpu      = [pscustomobject]@{ FriendlyName = 'AMD Radeon(TM) Graphics'; Status = 'OK' }
    $nvidia    = [pscustomobject]@{ FriendlyName = 'NVIDIA GeForce RTX 4090'; Status = 'OK' }

    It 'refuses to start when an RDNA4 dGPU is enabled' {
        Assert-Throws -MessagePattern 'ActivateLayer 0x20' -Body {
            Assert-NoActiveRdna4Gpu -Devices @($rdna4On, $igpu)
        } -Message 'an enabled RX 9070 XT must fail the preflight loudly'
    }

    It 'names the toggle recipe in the refusal' {
        # Set-Rdna4Gpu, not toggle-rdna4-gpu: the script was renamed in the
        # approved-verb sweep (Toggle is not an approved PowerShell verb) and
        # this pattern was left behind, so the test has been red ever since
        # while the gate itself was fine. The assertion's intent is unchanged --
        # the refusal must still name the script that gets you out of it.
        Assert-Throws -MessagePattern 'Set-Rdna4Gpu' -Body {
            Assert-NoActiveRdna4Gpu -Devices @($rdna4On)
        }
    }

    It 'interpolates the device name into the refusal (no literal {0})' {
        # Regression pin: -f binds tighter than +, so an unparenthesized
        # string concat left a literal {0} in the user-facing message.
        Assert-Throws -MessagePattern 'RX 9070 XT' -Body {
            Assert-NoActiveRdna4Gpu -Devices @($rdna4On)
        } -Message 'the refusal must name the actual device'
    }

    It 'passes when the RDNA4 dGPU is disabled (the build window)' {
        Assert-NoActiveRdna4Gpu -Devices @($rdna4Off, $igpu)
    }

    It 'ignores hosts with no RDNA4 hardware (iGPU / NVIDIA / none)' {
        Assert-NoActiveRdna4Gpu -Devices @($igpu, $nvidia)
        Assert-NoActiveRdna4Gpu -Devices @()
    }

    It '-Force downgrades the refusal to a warning (SkipHostChecks path)' {
        Assert-NoActiveRdna4Gpu -Devices @($rdna4On) -Force -WarningAction SilentlyContinue
    }

    It 'catches other RDNA4 SKUs via the pattern (RX 9060, AI PRO R9700)' {
        foreach ($name in @('AMD Radeon RX 9060 XT', 'AMD Radeon AI PRO R9700')) {
            Assert-Throws -Body {
                Assert-NoActiveRdna4Gpu -Devices @([pscustomobject]@{ FriendlyName = $name; Status = 'OK' })
            } -Message "$name must be treated as a hazard"
        }
    }

    It 'survives Adrenalin (TM)-style renames of the FriendlyName' {
        # Drivers have shipped 'Radeon (TM)' / 'Radeon(TM)' spellings before; a
        # rename must not silently disarm the gate (review sweep, 2026-08-10).
        foreach ($name in @('AMD Radeon(TM) RX 9070 XT', 'AMD Radeon (TM) RX 9070 XT')) {
            Assert-Throws -Body {
                Assert-NoActiveRdna4Gpu -Devices @([pscustomobject]@{ FriendlyName = $name; Status = 'OK' })
            } -Message "$name must still be treated as a hazard"
        }
    }
}

Describe 'Assert-BuildkitdStepLogEnv (step-log clip preflight, backlog 0a)' {

    It 'passes when BUILDKIT_STEP_LOG_MAX_SIZE=-1 is present' {
        Assert-BuildkitdStepLogEnv -EnvironmentOverride @('BUILDKIT_STEP_LOG_MAX_SIZE=-1', 'BUILDKIT_STEP_LOG_MAX_SPEED=-1')
    }

    It 'refuses when the env was wiped (the 2026-08-10 Stevedore-repair drift)' {
        Assert-Throws -MessagePattern 'BUILDKIT_STEP_LOG_MAX_SIZE' -Body {
            Assert-BuildkitdStepLogEnv -EnvironmentOverride @()
        } -Message 'a wiped service env must refuse before a multi-hour build loses its logs'
    }

    It 'names the elevated remediation in the refusal' {
        Assert-Throws -MessagePattern 'Restart-Service buildkitd' -Body {
            Assert-BuildkitdStepLogEnv -EnvironmentOverride @('SOME_OTHER=1')
        }
    }

    It '-Force downgrades to a warning (SkipHostChecks path)' {
        Assert-BuildkitdStepLogEnv -EnvironmentOverride @() -Force -WarningAction SilentlyContinue
    }

    It 'survives the REAL registry read on a key with no Environment value (run-13 regression)' {
        # Winmgmt exists on every Windows host and carries no Environment
        # value - the exact shape of the wiped-env case. The gate must reach
        # its own refusal (or -Force warning), never a StrictMode
        # PropertyNotFound from the raw `.Environment` access.
        Assert-Throws -MessagePattern 'BUILDKIT_STEP_LOG_MAX_SIZE' -Body {
            Assert-BuildkitdStepLogEnv -ServiceName 'Winmgmt'
        } -Message 'missing value must produce the gate refusal, not a property error'
        Assert-BuildkitdStepLogEnv -ServiceName 'Winmgmt' -Force -WarningAction SilentlyContinue
    }

    It 'returns silently when the service does not exist at all' {
        Assert-BuildkitdStepLogEnv -ServiceName 'NoSuchServiceKataglyphis'
    }
}

Describe 'Get-Rdna4HazardDevice (single-source hazard set, backlog #1)' {

    $rdna4On   = [pscustomobject]@{ FriendlyName = 'AMD Radeon RX 9070 XT'; Status = 'OK' }
    $rdna4Off  = [pscustomobject]@{ FriendlyName = 'AMD Radeon RX 9060 XT'; Status = 'Error' }
    $aipro     = [pscustomobject]@{ FriendlyName = 'AMD Radeon AI PRO R9700'; Status = 'OK' }
    $igpu      = [pscustomobject]@{ FriendlyName = 'AMD Radeon(TM) Graphics'; Status = 'OK' }

    It 'returns every hazard SKU and nothing else' {
        $r = @(Get-Rdna4HazardDevice -Devices @($rdna4On, $rdna4Off, $aipro, $igpu))
        Assert-Equal 3 $r.Count 'RX 9070 XT + RX 9060 XT + AI PRO R9700, but never the iGPU'
    }

    It '-ActiveOnly filters to enabled devices' {
        $r = @(Get-Rdna4HazardDevice -Devices @($rdna4On, $rdna4Off, $aipro, $igpu) -ActiveOnly)
        Assert-Equal 2 $r.Count 'only the Status=OK hazards'
    }

    It 'returns empty for a hazard-free host' {
        Assert-Equal 0 @(Get-Rdna4HazardDevice -Devices @($igpu)).Count
    }
}
