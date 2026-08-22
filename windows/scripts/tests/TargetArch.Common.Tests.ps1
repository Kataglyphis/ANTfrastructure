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

    It 'the arm64 pattern matches aarch64 kernel TUs and not x86 ones' {
        $p = Get-MlasKernelTuPattern -Arch 'arm64'
        Assert-True  ('build/x/mlas/lib/sqnbitgemm_kernel_neon.cpp.obj' -match $p)
        Assert-True  ('build/x/mlas/lib/qgemm_kernel_udot.cpp.obj' -match $p)
        Assert-True  ('build/x/mlas/lib/qgemm_kernel_smmla.cpp.obj' -match $p)
        Assert-False ('build/x/mlas/lib/qgemm_kernel_amx.cpp.obj' -match $p)
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
