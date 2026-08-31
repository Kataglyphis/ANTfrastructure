#requires -Version 7.0
# Tests for the lane-shared media helpers in WindowsBuildDriver.Common.psm1
# (Get-MediaBranchVersionArg / Get-MediaMergeVersionArg / Assert-SccacheEndpoint /
# Get-MediaMemoryBudget). These are the ONE canonical definition both drivers
# (build.ps1 classic, build-buildkit.ps1 BK) consume — a drifting key set here
# silently rebuilds hours of cached layers in one lane or starves the merge
# builder of a version pin. Everything runs against a fake version table; no
# versions.env, docker, or network involved (the only endpoint probed is a
# closed localhost port).

# Fake versions.env table: every key any media branch consumes, with values
# that are obviously fake, PLUS two decoys (MEMORY_LIMIT_GB / BASE_IMAGE) that
# must NEVER leak into version build-args — they are lane-shaped, added by the
# callers themselves.
function New-WbtFakeMediaVersionTable {
    return @{
        ONNXRUNTIME_VERSION       = 'ort-1'
        ONNXRUNTIME_GENAI_VERSION = 'genai-2'
        OPENCV_VERSION            = 'cv-3'
        FFMPEG_VERSION            = 'ff-4'
        PYAV_VERSION              = 'av-5'
        NV_CODEC_HEADERS_REF      = 'nv-6'
        CUDA_ARCHITECTURES        = '89-fake'
        QNN_SDK_ZIP_SHA256        = 'qnnsha-13'
        LITERT_VERSION            = 'lrt-7'
        LITERT_LM_VERSION         = 'lm-8'
        TVM_REF                   = 'tvm-9'
        IREE_VERSION              = 'iree-10'
        GSTREAMER_VERSION         = 'gst-11'
        MEMORY_LIMIT_GB           = '999'
        BASE_IMAGE                = 'decoy/image:tag'
        # Added 2026-08-07 with the removal of the media stages' versions.env
        # COPY: these keys now travel as build-args (they used to reach the
        # scripts through the copied file), so the branch maps read them and a
        # fixture without them fails on the WRONG key.
        PYTHON_VERSION            = 'py-12'
        PROTOC_VERSION            = 'protoc-13'
        JRE_VERSION               = 'jre-14'
    }
}

Describe 'Get-MediaBranchVersionArg' {

    It 'returns exactly the pinned key set per branch, values from the version table' {
        $table = New-WbtFakeMediaVersionTable
        # Table-driven: branch -> expected build-arg hashtable. NOTE the
        # deliberate rename OPENCV_VERSION (versions.env) -> OPENCV_SOURCE_VERSION
        # (Dockerfile ARG) on the core branch.
        $cases = @(
            @{ Branch = 'media-core'; Expected = @{
                    ONNXRUNTIME_VERSION       = 'ort-1'
                    ONNXRUNTIME_GENAI_VERSION = 'genai-2'
                    OPENCV_SOURCE_VERSION     = 'cv-3'
                    OPENCV_VERSION            = 'cv-3'
                    FFMPEG_VERSION            = 'ff-4'
                    PYAV_VERSION              = 'av-5'
                    NV_CODEC_HEADERS_REF      = 'nv-6'
                    CUDA_ARCHITECTURES        = '89-fake'
                    PYTHON_VERSION            = 'py-12'
                    QNN_SDK_ZIP_SHA256        = 'qnnsha-13'
                }
            }
            @{ Branch = 'media-litert'; Expected = @{
                    LITERT_VERSION    = 'lrt-7'
                    LITERT_LM_VERSION = 'lm-8'
                    PROTOC_VERSION    = 'protoc-13'
                    JRE_VERSION       = 'jre-14'
                    # #154: this branch MOUNTS windows/qnn-sdk, so it needs the same
                    # integrity pin as media-core or Resolve-QnnSdk extracts unverified.
                    QNN_SDK_ZIP_SHA256 = 'qnnsha-13'
                }
            }
            @{ Branch = 'media-tvm'; Expected = @{
                    TVM_REF      = 'tvm-9'
                    IREE_VERSION = 'iree-10'
                    # #154: mounts windows/qnn-sdk, same integrity pin as the others.
                    QNN_SDK_ZIP_SHA256 = 'qnnsha-13'
                }
            }
        )
        foreach ($case in $cases) {
            $actual = Get-MediaBranchVersionArg -Branch $case.Branch -VersionTable $table
            $expectedKeys = @($case.Expected.Keys | Sort-Object) -join ','
            $actualKeys = @($actual.Keys | Sort-Object) -join ','
            Assert-Equal $expectedKeys $actualKeys "$($case.Branch): exact key set (no extras, no omissions)"
            foreach ($k in $case.Expected.Keys) {
                Assert-Equal $case.Expected[$k] $actual[$k] "$($case.Branch): value of $k pulled from the version table"
            }
        }
    }

    It 'never leaks lane-shaped args (MEMORY_LIMIT_GB / BASE_IMAGE) even though the table has them' {
        $table = New-WbtFakeMediaVersionTable
        foreach ($branch in 'media-core', 'media-litert', 'media-tvm') {
            $actual = Get-MediaBranchVersionArg -Branch $branch -VersionTable $table
            Assert-False ($actual.Contains('MEMORY_LIMIT_GB')) "$branch must not emit MEMORY_LIMIT_GB"
            Assert-False ($actual.Contains('BASE_IMAGE')) "$branch must not emit BASE_IMAGE"
        }
    }

    It 'throws naming the missing versions.env key' {
        $table = New-WbtFakeMediaVersionTable
        $table.Remove('LITERT_VERSION')
        Assert-Throws { Get-MediaBranchVersionArg -Branch 'media-litert' -VersionTable $table } `
            -MessagePattern 'versions\.env has no key LITERT_VERSION' `
            'a missing pin must fail fast, naming the key'
    }
}

Describe 'Get-MediaMergeVersionArg' {

    It 'is the branch union minus the core compile-only inputs plus the GStreamer pin' {
        $table = New-WbtFakeMediaVersionTable
        $merge = Get-MediaMergeVersionArg -VersionTable $table
        $expectedKeys = @(
            'FFMPEG_VERSION', 'GSTREAMER_VERSION', 'IREE_VERSION', 'LITERT_LM_VERSION',
            'LITERT_VERSION', 'ONNXRUNTIME_GENAI_VERSION', 'ONNXRUNTIME_VERSION',
            'OPENCV_SOURCE_VERSION', 'PYAV_VERSION', 'TVM_REF'
        ) -join ','
        Assert-Equal $expectedKeys (@($merge.Keys | Sort-Object) -join ',') 'exact merge key set'
        # Compile-only core inputs the merge Dockerfile declares no ARG for:
        Assert-False ($merge.Contains('NV_CODEC_HEADERS_REF')) 'NV_CODEC_HEADERS_REF is excluded from the merge env'
        Assert-False ($merge.Contains('CUDA_ARCHITECTURES')) 'CUDA_ARCHITECTURES is excluded from the merge env'
        # No lane-shaped leakage:
        Assert-False ($merge.Contains('MEMORY_LIMIT_GB')) 'MEMORY_LIMIT_GB must not leak into the merge env'
        Assert-False ($merge.Contains('BASE_IMAGE')) 'BASE_IMAGE must not leak into the merge env'
        # Values survive the union untouched, and the merge-own pin is present:
        Assert-Equal 'gst-11' $merge['GSTREAMER_VERSION'] 'merge adds its own GStreamer pin'
        Assert-Equal 'ort-1' $merge['ONNXRUNTIME_VERSION'] 'core branch value carried through'
        Assert-Equal 'lm-8' $merge['LITERT_LM_VERSION'] 'litert branch value carried through'
        Assert-Equal 'tvm-9' $merge['TVM_REF'] 'tvm branch value carried through'
    }

    It 'throws when the GStreamer pin is missing (merge-only key)' {
        $table = New-WbtFakeMediaVersionTable
        $table.Remove('GSTREAMER_VERSION')
        Assert-Throws { Get-MediaMergeVersionArg -VersionTable $table } `
            -MessagePattern 'versions\.env has no key GSTREAMER_VERSION' `
            'the merge env must fail fast on a missing GStreamer pin'
    }
}

Describe 'Assert-SccacheEndpoint' {

    It 'returns without probing when no compile stage is requested (endpoint absent)' {
        Assert-SccacheEndpoint -Stages @('base', 'toolchain', 'merge') -SccacheEndpoint ''
        Assert-True $true 'non-media stages never require the endpoint'
    }

    It '-NoSccache bypasses the gate even for the media stage' {
        Assert-SccacheEndpoint -Stages @('media') -SccacheEndpoint '' -NoSccache
        Assert-True $true 'a deliberate cache-less build passes without an endpoint'
    }

    It 'media without an endpoint throws with the one-time host setup hint' {
        Assert-Throws { Assert-SccacheEndpoint -Stages @('media') -SccacheEndpoint '' } `
            -MessagePattern 'scoop install dufs' `
            'the failure must carry the dufs setup recipe, not just "missing endpoint"'
    }

    It 'media with an unreachable endpoint throws naming the endpoint (closed localhost port)' {
        # Offline-safe reachability probe: nothing listens on 127.0.0.1:1, so the
        # HEAD request is refused locally without touching the network.
        Assert-Throws { Assert-SccacheEndpoint -Stages @('media') -SccacheEndpoint 'http://127.0.0.1:1' } `
            -MessagePattern 'not reachable' `
            'a dead endpoint must fail the gate before hours of uncached compiling'
    }
}

Describe 'Get-MediaMemoryBudget' {

    # SEAM GAP: total host RAM is read straight from Win32_ComputerSystem inside
    # the function (no parameter to inject it), so the subtraction cases below
    # read the SAME CIM value themselves and compare — deterministic on a given
    # host, but not a true fake. -RequestedGb and -HostReserveGb are the only
    # injectable seams.

    It 'an explicit -RequestedGb always wins' {
        Assert-Equal 12 (Get-MediaMemoryBudget -RequestedGb 12) 'explicit request bypasses auto-detect'
        Assert-Equal 2 (Get-MediaMemoryBudget -RequestedGb 2 -HostReserveGb 0) 'explicit request wins even below the auto-detect floor'
    }

    It 'auto-detect never goes below the 8 GB floor (absurd host reserve)' {
        Assert-Equal 8 (Get-MediaMemoryBudget -HostReserveGb 100000) 'floor of 8 GB when reserve exceeds host RAM'
    }

    It 'auto-detect subtracts the host reserve from total physical RAM' {
        $totalGb = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        Assert-Equal ([math]::Max(8, $totalGb)) (Get-MediaMemoryBudget -HostReserveGb 0) 'reserve 0: full host RAM (floored at 8)'
        Assert-Equal ([math]::Max(8, $totalGb - 5)) (Get-MediaMemoryBudget -HostReserveGb 5) 'reserve 5: total minus reserve (floored at 8)'
    }
}
