#requires -Version 7.0
# See docs/windows-cross-builds.md § Where arch facts live

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

    It 'maps the package arch that file names, wix -arch and the AppxManifest share' {
        Assert-Equal 'x64'   (Get-WindowsPackageArch -Arch 'amd64')
        Assert-Equal 'arm64' (Get-WindowsPackageArch -Arch 'arm64')
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
        # A caller mutating the result must not corrupt the table for the session.
        $a = Get-WindowsTargetArchInfo -Arch 'arm64'
        $a.ClangTriple = 'MUTATED'
        Assert-Equal 'aarch64-pc-windows-msvc' (Get-WindowsTargetArchInfo -Arch 'arm64').ClangTriple
    }

    It 'every accessor throws for an unsupported arch' {
        foreach ($fn in @('Get-ClangTargetTriple', 'Get-PeMachineType', 'Get-VcpkgTriplet',
                'Get-VulkanLibDirName', 'Get-PythonWheelTag', 'Get-CpythonBuildPlatform',
                'Get-WindowsRuntimeIdentifier', 'Get-WindowsTargetTagSuffix', 'Get-WindowsPackageArch')) {
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

    It 'arm64 adds NO global optional features' {
        # A global optional AArch64 feature SIGILLs on hardware without it; those belong on dispatched kernels only.
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
        # An unparameterized pattern matches nothing on arm64 and the patch succeeds silently.
        $p = Get-MlasKernelTuPattern -Arch 'amd64'
        Assert-False ('build/x/mlas/lib/sqnbitgemm_kernel_neon.cpp.obj' -match $p)
    }

    It 'the arm64 pattern matches every aarch64 kernel TU that needs per-TU features' {
        # Verbatim from ONNX Runtime v1.29.0's aarch64 MLAS build, not invented names.
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
        # Dispatchers built with the optional features would fault before choosing a kernel.
        $p = Get-MlasKernelTuPattern -Arch 'arm64'
        foreach ($tu in @('cast.cpp', 'halfconv.cpp', 'halfgemm.cpp', 'platform.cpp')) {
            Assert-False ("build/x/mlas/lib/$tu.obj" -match $p) "arm64 pattern must NOT match the dispatcher $tu"
        }
        Assert-False ('build/x/mlas/lib/qgemm_kernel_amx.cpp.obj' -match $p)
    }

    It 'the arm64 floor would have caught the incomplete first pattern' {
        # The first pattern matched 10 of 16 TUs; the floor must reject that state.
        Assert-True ((Get-MlasKernelTuMinimum -Arch 'arm64') -gt 10) 'the floor must reject a 10-TU match'
    }

    It 'declares a nonzero minimum match count per arch' {
        # The floor turns "patch matched nothing" into a build failure.
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
        # A VS generator would ignore -DCMAKE_CXX_COMPILER; the lane is Ninja + clang-cl.
        $a = (@(Get-CMakeCrossArgs -Arch 'arm64')) -join ' '
        Assert-False ($a -match 'CMAKE_GENERATOR_PLATFORM') 'cross args leaked a VS generator platform'
    }
}

Describe 'versions.env parity' {

    # A mirrored key with no reader drifts silently, so WINDOWS_TARGET_ARCHES is read and asserted here.
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
        # See docs/windows-cross-builds.md § Cache discipline: the base image is shared
        $envPath = Join-Path (Get-RepoRoot) 'linux\scripts\01-core\versions.env'
        $v = ConvertFrom-VersionsEnv -Path $envPath
        Assert-False ($v.Contains('WINDOWS_TARGET_ARCH')) `
            'versions.env must NOT define WINDOWS_TARGET_ARCH - Import-Versions.ps1 would overwrite the build-arg in inherited stages'
    }
}

Describe 'COFF machine decoding (byte-shift trap)' {

    # -shl keeps the left operand's type: [byte]0xAA -shl 8 is 0, so an uncast decode reads ARM64 as 0x0064.
    It 'demonstrates why the [int] casts are load-bearing' {
        $b = [byte[]](0x64, 0xAA)
        Assert-Equal 0x0064 ($b[0] -bor ($b[1] -shl 8))            # the trap
        Assert-Equal 0xAA64 ([int]$b[0] -bor ([int]$b[1] -shl 8))  # the fix
    }

    It 'no shipped script decodes a machine word without an [int] cast' {
        # Shipped code only: this file contains the broken form on purpose.
        $shipped = @('build', 'host', 'modules', 'diagnostics') |
            ForEach-Object { Join-Path (Get-RepoRoot) "windows\scripts\$_" } |
            Where-Object { Test-Path $_ }
        $offenders = @()
        foreach ($f in (Get-ChildItem $shipped -Recurse -Include '*.ps1', '*.psm1' -File)) {
            foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
                # Comments explain the trap; only real code can fall into it.
                if ($line.TrimStart().StartsWith('#')) { continue }
                # The machine-word idiom (-shl 8 with -bor) needs an [int] cast on the shifted operand.
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

    # See docs/windows-cross-builds.md § Cache discipline: the base image is shared
    It 'every stage built FROM an external image reference redeclares the ARG' {
        # Only a `${...}` FROM starts from a separate solve; an in-file parent passes its ENV down.
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
