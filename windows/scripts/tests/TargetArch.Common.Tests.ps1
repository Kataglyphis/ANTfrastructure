#requires -Version 7.0
# Tests for WindowsTargetArch.Common - the single source of TARGET-architecture
# facts on the Windows lane (clang triple, PE machine, vcpkg triplet, SIMD flag
# sets, CMake cross args).
#
# Two properties matter most and are asserted hardest:
#   1. The amd64 lane is BYTE-IDENTICAL to what shipped before this module
#      existed. Introducing an arch dimension must not perturb the working lane.
#   2. An unknown/typo'd arch THROWS. Silently degrading to amd64 would emit an
#      x64 build labelled arm64, which no downstream gate would catch.

Describe 'Get-WindowsTargetArch resolution' {

    It 'defaults to amd64 when nothing is set' {
        Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = $null } {
            Assert-Equal 'amd64' (Get-WindowsTargetArch)
        }
    }

    It 'reads WINDOWS_TARGET_ARCH from the environment' {
        Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = 'arm64' } {
            Assert-Equal 'arm64' (Get-WindowsTargetArch)
        }
    }

    It 'prefers an explicit -Arch over the environment' {
        Invoke-WithEnv @{ WINDOWS_TARGET_ARCH = 'arm64' } {
            Assert-Equal 'amd64' (Get-WindowsTargetArch -Arch 'amd64')
        }
    }

    It 'canonicalizes the common spellings of each target' {
        Assert-Equal 'amd64' (Get-WindowsTargetArch -Arch 'x64')
        Assert-Equal 'amd64' (Get-WindowsTargetArch -Arch 'x86_64')
        Assert-Equal 'amd64' (Get-WindowsTargetArch -Arch 'AMD64')
        Assert-Equal 'arm64' (Get-WindowsTargetArch -Arch 'aarch64')
        Assert-Equal 'arm64' (Get-WindowsTargetArch -Arch 'ARM64')
    }

    It 'throws on an unknown arch rather than defaulting' {
        Assert-Throws -Body { Get-WindowsTargetArch -Arch 'ppc64le' } -MessagePattern 'Unsupported Windows target architecture'
    }

    It 'throws on a typo that is close to a real arch' {
        Assert-Throws -Body { Get-WindowsTargetArch -Arch 'arm46' } -MessagePattern 'Unsupported'
    }

    It 'reports exactly the supported set' {
        $a = @(Get-SupportedWindowsTargetArches)
        Assert-Equal 2 $a.Count
        Assert-Equal 'amd64' $a[0]
        Assert-Equal 'arm64' $a[1]
    }
}

Describe 'Host arch and cross detection' {

    It 'always reports amd64 as the build host (no arm64 Windows container base image exists)' {
        Assert-Equal 'amd64' (Get-WindowsHostArch)
    }

    It 'treats arm64 as a cross target and amd64 as native' {
        Assert-True  (Test-WindowsCrossTarget -Arch 'arm64')
        Assert-False (Test-WindowsCrossTarget -Arch 'amd64')
    }
}

Describe 'Per-arch fact mapping' {

    It 'maps the clang-cl target triples' {
        Assert-Equal 'x86_64-pc-windows-msvc'  (Get-ClangTargetTriple -Arch 'amd64')
        Assert-Equal 'aarch64-pc-windows-msvc' (Get-ClangTargetTriple -Arch 'arm64')
    }

    It 'maps the PE machine types to the COFF constants' {
        # IMAGE_FILE_MACHINE_AMD64 / IMAGE_FILE_MACHINE_ARM64
        Assert-Equal 0x8664 (Get-PeMachineType -Arch 'amd64')
        Assert-Equal 0xAA64 (Get-PeMachineType -Arch 'arm64')
    }

    It 'maps the vcpkg triplets' {
        Assert-Equal 'x64-windows'   (Get-VcpkgTriplet -Arch 'amd64')
        Assert-Equal 'arm64-windows' (Get-VcpkgTriplet -Arch 'arm64')
    }

    It 'maps the Vulkan SDK subdirectories (arm64 needs the optional LunarG component)' {
        Assert-Equal 'Lib'       (Get-VulkanLibDirName -Arch 'amd64')
        Assert-Equal 'Bin'       (Get-VulkanBinDirName -Arch 'amd64')
        Assert-Equal 'Lib-ARM64' (Get-VulkanLibDirName -Arch 'arm64')
        Assert-Equal 'Bin-ARM64' (Get-VulkanBinDirName -Arch 'arm64')
    }

    It 'maps the CPython PCbuild platform and output directory' {
        # build.bat -p <platform>; artifacts land in PCbuild\<outdir>
        Assert-Equal 'x64'   (Get-CpythonBuildPlatform -Arch 'amd64')
        Assert-Equal 'amd64' (Get-CpythonOutputDir     -Arch 'amd64')
        Assert-Equal 'ARM64' (Get-CpythonBuildPlatform -Arch 'arm64')
        Assert-Equal 'arm64' (Get-CpythonOutputDir     -Arch 'arm64')
    }

    It 'maps the python wheel tags and platform names' {
        Assert-Equal 'win_amd64' (Get-PythonWheelTag     -Arch 'amd64')
        Assert-Equal 'win-amd64' (Get-PythonPlatformName -Arch 'amd64')
        Assert-Equal 'win_arm64' (Get-PythonWheelTag     -Arch 'arm64')
        Assert-Equal 'win-arm64' (Get-PythonPlatformName -Arch 'arm64')
    }

    It 'maps the NuGet runtime identifiers' {
        Assert-Equal 'win-x64'   (Get-WindowsRuntimeIdentifier -Arch 'amd64')
        Assert-Equal 'win-arm64' (Get-WindowsRuntimeIdentifier -Arch 'arm64')
    }

    It 'maps the rust target triples' {
        Assert-Equal 'x86_64-pc-windows-msvc'  (Get-RustTargetTriple -Arch 'amd64')
        Assert-Equal 'aarch64-pc-windows-msvc' (Get-RustTargetTriple -Arch 'arm64')
    }

    It 'maps the image tag suffixes' {
        Assert-Equal 'winamd64' (Get-WindowsTargetTagSuffix -Arch 'amd64')
        Assert-Equal 'winarm64' (Get-WindowsTargetTagSuffix -Arch 'arm64')
    }

    It 'maps ffmpeg --arch and lib /machine values' {
        Assert-Equal 'x86_64'  (Get-FfmpegTargetArch -Arch 'amd64')
        Assert-Equal 'aarch64' (Get-FfmpegTargetArch -Arch 'arm64')
        Assert-Equal 'x64'     (Get-LibMachineArg    -Arch 'amd64')
        Assert-Equal 'arm64'   (Get-LibMachineArg    -Arch 'arm64')
    }

    It 'returns a defensive copy of the fact record' {
        # A caller mutating the result must not corrupt the table for the rest
        # of the session.
        $a = Get-WindowsTargetArchInfo -Arch 'arm64'
        $a.ClangTriple = 'MUTATED'
        Assert-Equal 'aarch64-pc-windows-msvc' (Get-WindowsTargetArchInfo -Arch 'arm64').ClangTriple
    }

    It 'every accessor throws for an unsupported arch' {
        foreach ($fn in @('Get-ClangTargetTriple', 'Get-PeMachineType', 'Get-VcpkgTriplet',
                'Get-VulkanLibDirName', 'Get-PythonWheelTag', 'Get-CpythonBuildPlatform',
                'Get-WindowsRuntimeIdentifier', 'Get-WindowsTargetTagSuffix')) {
            Assert-Throws -Body { & $fn -Arch 'sparc' } -Message "accessor $fn accepted a bogus arch"
        }
    }
}

Describe 'SIMD flag sets' {

    It 'amd64 baseline flags are byte-identical to the historical string' {
        # Regression guard: the pre-module literal from WindowsSourceBuild.Common.
        $expected = '/clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-mssse3 /clang:-msse3 /clang:-msse4.1 /clang:-msse4.2 /clang:-mpopcnt'
        Assert-True ((Get-WindowsTargetSimdFlags -Arch 'amd64') -ceq $expected) 'amd64 SIMD flags drifted'
    }

    It 'amd64 kernel flags are byte-identical to the historical string' {
        $expected = '/clang:-mavx512f /clang:-mavx512cd /clang:-mavx512bw /clang:-mavx512dq /clang:-mavx512vl /clang:-mavx512vnni /clang:-mavx512bf16 /clang:-mavx512fp16 /clang:-mavxvnni /clang:-mamx-int8 /clang:-mamx-tile /clang:-mamx-bf16'
        Assert-True ((Get-WindowsTargetKernelSimdFlags -Arch 'amd64') -ceq $expected) 'amd64 kernel flags drifted'
    }

    It 'the legacy x86 helpers still return the same strings' {
        Assert-True ((Get-WindowsX86SimdFlags)   -ceq (Get-WindowsTargetSimdFlags       -Arch 'amd64'))
        Assert-True ((Get-WindowsX86Avx512Flags) -ceq (Get-WindowsTargetKernelSimdFlags -Arch 'amd64'))
    }

    It 'arm64 adds NO global optional features' {
        # AArch64 baseline already mandates NEON, and a globally-enabled optional
        # feature (dotprod/i8mm/SVE) produces SIGILL on hardware without it -
        # the same class of failure AVX-512 caused on x86. Optional features
        # belong only on runtime-dispatched kernels.
        Assert-Equal '' (Get-WindowsTargetSimdFlags -Arch 'arm64')
    }

    It 'arm64 kernel flags carry the dispatched AArch64 features' {
        $f = Get-WindowsTargetKernelSimdFlags -Arch 'arm64'
        Assert-Match 'armv8\.2-a' $f
        Assert-Match '\+dotprod'  $f
        Assert-Match '\+i8mm'     $f
    }

    It 'arm64 kernel flags contain no x86 features' {
        $f = Get-WindowsTargetKernelSimdFlags -Arch 'arm64'
        Assert-False ($f -match 'avx|sse|amx') 'arm64 kernel flags leaked an x86 feature'
    }
}

Describe 'MLAS per-TU patch targeting' {

    It 'the x64 pattern matches the x64 MLAS kernel TUs' {
        $p = Get-MlasKernelTuPattern -Arch 'amd64'
        Assert-True ('build/x/mlas/lib/qgemm_kernel_amx.cpp.obj' -match $p)
        Assert-True ('build/x/mlas/lib/intrinsics/avx512/avx512_core.cpp.obj' -match $p)
        Assert-True ('build\x\mlas\lib\intrinsics\avx512\foo.cpp.obj' -match $p)
    }

    It 'the x64 pattern does NOT match aarch64 kernels - the whole reason this is parameterized' {
        # An unparameterized pattern would match nothing in an arm64 build and
        # SUCCEED silently, shipping dispatched kernels compiled without their
        # features. This assertion is the regression guard for that failure.
        $p = Get-MlasKernelTuPattern -Arch 'amd64'
        Assert-False ('build/x/mlas/lib/sqnbitgemm_kernel_neon.cpp.obj' -match $p)
    }

    It 'the arm64 pattern matches every aarch64 kernel TU that needs per-TU features' {
        # VERBATIM from ONNX Runtime v1.29.0's aarch64 MLAS build (measured
        # 2026-08-23 in a real cross build), not invented names. The *_fp16
        # entries are the ones the first pattern missed, which made
        # activate_fp16.cpp fail to compile with "requires target feature
        # 'fullfp16'".
        $p = Get-MlasKernelTuPattern -Arch 'arm64'
        foreach ($tu in @(
                'activate_fp16.cpp', 'pooling_fp16.cpp',
                'hqnbitgemm_kernel_neon_fp16.cpp', 'hqnbitgemm_kernel_neon_fp16_8bit.cpp',
                'rotary_embedding_kernel_neon_fp16.cpp', 'rotary_embedding_kernel_neon.cpp',
                'sqnbitgemm_kernel_neon_fp32.cpp', 'sqnbitgemm_kernel_neon_int8.cpp',
                'sqnbitgemm_kernel_neon_int8_2bit.cpp', 'qnbitgemm_kernel_neon.cpp',
                'qgemm_kernel_neon.cpp', 'qgemm_kernel_udot.cpp', 'qgemm_kernel_sdot.cpp',
                'halfgemm_kernel_neon.cpp', 'cast_kernel_neon.cpp', 'qkv_quant_kernel_neon.cpp')) {
            Assert-True ("build/x/mlas/lib/$tu.obj" -match $p) "arm64 pattern must match $tu"
        }
    }

    It 'the arm64 pattern leaves the runtime DISPATCHERS alone' {
        # These select a kernel at run time. Compiling them WITH the optional
        # features would make the dispatch decision itself fault on hardware
        # that lacks them - the exact failure the per-TU design prevents.
        $p = Get-MlasKernelTuPattern -Arch 'arm64'
        foreach ($tu in @('cast.cpp', 'halfconv.cpp', 'halfgemm.cpp', 'platform.cpp')) {
            Assert-False ("build/x/mlas/lib/$tu.obj" -match $p) "arm64 pattern must NOT match the dispatcher $tu"
        }
        Assert-False ('build/x/mlas/lib/qgemm_kernel_amx.cpp.obj' -match $p)
    }

    It 'the arm64 floor would have caught the incomplete first pattern' {
        # The original pattern matched 10 of 16 TUs and passed a floor of 2,
        # so the miss surfaced as a compile error instead of a gate failure.
        Assert-True ((Get-MlasKernelTuMinimum -Arch 'arm64') -gt 10) 'the floor must reject a 10-TU match'
    }

    It 'declares a nonzero minimum match count per arch' {
        # The floor is what turns "patch matched nothing" from a silent success
        # into a build failure.
        Assert-True ((Get-MlasKernelTuMinimum -Arch 'amd64') -gt 0)
        Assert-True ((Get-MlasKernelTuMinimum -Arch 'arm64') -gt 0)
    }
}

Describe 'CMake cross arguments' {

    It 'emits NOTHING for the host arch so the amd64 configure line is unchanged' {
        $a = @(Get-CMakeCrossArgs -Arch 'amd64')
        Assert-Equal 0 $a.Count
    }

    It 'puts CMake into cross mode for arm64' {
        $a = @(Get-CMakeCrossArgs -Arch 'arm64')
        Assert-True ($a -contains '-DCMAKE_SYSTEM_NAME=Windows')
        Assert-True ($a -contains '-DCMAKE_SYSTEM_PROCESSOR=ARM64')
    }

    It 'passes the aarch64 triple to both compilers' {
        $a = (@(Get-CMakeCrossArgs -Arch 'arm64')) -join ' '
        Assert-Match 'CMAKE_C_COMPILER_TARGET=aarch64-pc-windows-msvc' $a
        Assert-Match 'CMAKE_CXX_COMPILER_TARGET=aarch64-pc-windows-msvc' $a
        Assert-Match 'CMAKE_C_FLAGS_INIT=--target=aarch64-pc-windows-msvc' $a
        Assert-Match 'CMAKE_CXX_FLAGS_INIT=--target=aarch64-pc-windows-msvc' $a
    }

    It 'never mentions a Visual Studio generator or -A platform' {
        # The whole lane is Ninja + clang-cl + lld-link; a VS generator would
        # ignore -DCMAKE_CXX_COMPILER entirely.
        $a = (@(Get-CMakeCrossArgs -Arch 'arm64')) -join ' '
        Assert-False ($a -match 'CMAKE_GENERATOR_PLATFORM') 'cross args leaked a VS generator platform'
    }
}

Describe 'versions.env parity' {

    # WINDOWS_TARGET_ARCHES mirrors the module's arch table. A mirrored key with
    # no reader is a second source of truth that drifts silently, so it is read
    # HERE and asserted against the table - the same shape as the versions.env
    # parity assertions in Shared.VersionsEnv.Tests.ps1.
    It 'WINDOWS_TARGET_ARCHES matches the module arch table' {
        $envPath = Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'
        $v = ConvertFrom-VersionsEnv -Path $envPath
        # OrderedDictionary exposes Contains(), not ContainsKey().
        Assert-True ($v.Contains('WINDOWS_TARGET_ARCHES')) 'versions.env must declare WINDOWS_TARGET_ARCHES'
        $declared = @(($v['WINDOWS_TARGET_ARCHES'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object)
        $supported = @(Get-SupportedWindowsTargetArches)
        Assert-Equal ($supported -join ',') ($declared -join ',') 'versions.env WINDOWS_TARGET_ARCHES drifted from the module table'
    }

    It 'WINDOWS_TARGET_ARCH is NOT a versions.env key' {
        # It is a per-BUILD switch, not a pin. Keeping it here made
        # load-versions.ps1 rewrite the value in any stage where process and
        # machine env agreed -- which is exactly what happens in a stage built
        # FROM a previous arm64 stage, and it silently reverted the lane to
        # amd64 (measured 2026-08-23; FFmpeg then failed as "libonnxruntime not
        # found"). The Dockerfile ARG defaults supply the default instead.
        $envPath = Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'
        $v = ConvertFrom-VersionsEnv -Path $envPath
        Assert-False ($v.Contains('WINDOWS_TARGET_ARCH')) `
            'versions.env must NOT define WINDOWS_TARGET_ARCH - load-versions.ps1 would overwrite the build-arg in inherited stages'
    }
}

Describe 'COFF machine decoding (byte-shift trap)' {

    # PowerShell's -shl keeps the LEFT operand's TYPE. [byte]0xAA -shl 8 is 0,
    # not 0xAA00, so `$bytes[0] -bor ($bytes[1] -shl 8)` silently reads only the
    # low byte and reports 0x0064 for a genuine ARM64 object.
    #
    # That is the most damaging way an arch check can be wrong: a false FAIL on
    # the very probe that decides whether the cross toolchain works at all. It
    # was live in verify-toolchain.ps1 and the arm64 prereq probe on 2026-08-23.
    It 'demonstrates why the [int] casts are load-bearing' {
        $b = [byte[]](0x64, 0xAA)
        Assert-Equal 0x0064 ($b[0] -bor ($b[1] -shl 8))            # the trap
        Assert-Equal 0xAA64 ([int]$b[0] -bor ([int]$b[1] -shl 8))  # the fix
    }

    It 'no shipped script decodes a machine word without an [int] cast' {
        # SHIPPED code only. This test file itself deliberately contains the
        # broken form above to demonstrate the trap, and scanning tests/ would
        # make the guard flag its own documentation.
        $shipped = @('build', 'host', 'modules', 'diagnostics') |
            ForEach-Object { Join-Path (Get-RepoRoot) "windows\scripts\$_" } |
            Where-Object { Test-Path $_ }
        $offenders = @()
        foreach ($f in (Get-ChildItem $shipped -Recurse -Include '*.ps1', '*.psm1' -File)) {
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                # Comments explain the trap; only real code can fall into it.
                if ($line.TrimStart().StartsWith('#')) { continue }
                # A shift-by-8 combined with -bor is the machine-word idiom.
                # Require an [int] cast on the shifted operand; anything else
                # silently truncates to the low byte.
                if ($line -match '-bor' -and $line -match '-shl\s+8') {
                    if ($line -notmatch '\[int\][^-]*-shl\s+8') {
                        $offenders += ('{0}: {1}' -f $f.Name, $line.Trim())
                    }
                }
            }
        }
        Assert-Equal 0 $offenders.Count ("machine-word decode without [int] cast: " + ($offenders -join ' // '))
    }
}

Describe 'WINDOWS_TARGET_ARCH crosses stage boundaries' {

    # ARGs do NOT cross a FROM boundary. Every stage that RUNs a build script has
    # to redeclare WINDOWS_TARGET_ARCH, or it silently falls back to the amd64
    # default while its parent image was built for arm64.
    #
    # Measured 2026-08-23: media-core-built-ffmpeg was FROM the arm64 onnx image
    # but did not redeclare, so the FFmpeg cross block never ran, configure
    # link-probed as x64, and lld-link rejected the arm64 onnxruntime.lib. The
    # symptom configure prints -- "libonnxruntime not found" -- points nowhere
    # near the cause, which is exactly why this needs a static gate.
    It 'every stage built FROM an external image reference redeclares the ARG' {
        # Derived, not listed: a stage whose FROM is `${SOMETHING}` starts from an
        # image built by a SEPARATE solve, so nothing in this file's ENV chain
        # reaches it. A stage whose FROM names an in-file stage (e.g. `FROM common`)
        # inherits ENV normally and must NOT be required to redeclare -- requiring
        # it there would be cargo cult.
        $repo = Get-RepoRoot
        $missing = @()
        foreach ($rel in @('windows\Dockerfile.media-builder', 'windows\Dockerfile.media-merge-builder')) {
            $path = Join-Path $repo $rel
            Assert-True (Test-Path $path) "missing Dockerfile: $rel"
            $lines = @(Get-Content -LiteralPath $path)
            # Index every stage header so a body can be bounded by the next one.
            $headers = @()
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^FROM\s+(\S+)(?:\s+AS\s+(\S+))?\s*$') {
                    $headers += [pscustomobject]@{ Index = $i; Parent = $Matches[1]; Name = $Matches[2] }
                }
            }
            for ($h = 0; $h -lt $headers.Count; $h++) {
                $stage = $headers[$h]
                if (-not $stage.Name) { continue }
                # Only stages pulled from a build-arg image reference are at risk.
                if ($stage.Parent -notmatch '^\$\{') { continue }
                $end = if ($h + 1 -lt $headers.Count) { $headers[$h + 1].Index - 1 } else { $lines.Count - 1 }
                $body = $lines[$stage.Index..$end]
                # Only stages that actually RUN something can be affected.
                if (-not ($body | Select-String -Pattern '^RUN ')) { continue }
                if (-not ($body | Select-String -Pattern '^ARG\s+WINDOWS_TARGET_ARCH')) {
                    $missing += "${rel}: stage '$($stage.Name)' is FROM $($stage.Parent) and RUNs, but does not redeclare ARG WINDOWS_TARGET_ARCH"
                }
            }
        }
        Assert-Equal 0 $missing.Count ($missing -join ' // ')
    }
}
