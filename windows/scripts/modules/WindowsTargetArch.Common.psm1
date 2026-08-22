# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Single source of truth for TARGET-architecture facts on the Windows lane.
#
# The Windows BUILD HOST is always windows/amd64 -- there is no arm64 Windows
# container base image (servercore/nanoserver are amd64-only and Windows Server
# has no arm64 release), so the arm64 lane is a CROSS build: an x64 container
# emitting aarch64 binaries. Only the compile TARGET varies; the toolchain that
# runs is always x64.
#
# This module is the Windows twin of linux/scripts/01-core/arch-mapping.sh. Every
# arch-dependent literal in the build scripts should resolve through here rather
# than being spelled inline, so that adding a target is a table edit and a
# missing case is a loud throw instead of a silently x64-shaped build.
#
# DELIBERATELY DEPENDENCY-FREE: no Import-Module of Shared/SourceBuild. It is
# imported very early (including by host provisioning scripts that run before
# the full module set is COPY'd) and must never drag the module graph in.

# ---------------------------------------------------------------------------
# The table. Every accessor below reads from this; nothing hardcodes an arch.
# ---------------------------------------------------------------------------
$script:TargetArchTable = @{
    amd64 = @{
        Arch = 'amd64'
        # clang-cl target triple. Both lanes target the MSVC ABI.
        ClangTriple = 'x86_64-pc-windows-msvc'
        # VsDevCmd.bat -arch= value. -host_arch is ALWAYS amd64 (see header).
        VsDevCmdArch = 'amd64'
        # COFF/PE IMAGE_FILE_HEADER.Machine. IMAGE_FILE_MACHINE_AMD64.
        PeMachine = 0x8664
        PeMachineName = 'AMD64'
        # vcpkg triplet (classic mode).
        VcpkgTriplet = 'x64-windows'
        # VC\Tools\MSVC\<ver>\bin\Hostx64\<this>  -- the cross toolset directory.
        MsvcTargetBinDir = 'x64'
        # VC\Tools\MSVC\<ver>\lib\<this> and Windows Kits\10\Lib\<ver>\um\<this>.
        # These are what clang-cl LINKS against and are the reason the ARM64 VS
        # component is installed at all (we never invoke its cl.exe).
        MsvcTargetLibDir = 'x64'
        # Vulkan SDK subdirectories. The x64 SDK ships Lib-ARM64/Bin-ARM64 only
        # when the OPTIONAL com.lunarg.vulkan.arm64 component is selected.
        VulkanLibDir = 'Lib'
        VulkanBinDir = 'Bin'
        # PEP 425 platform tag / sysconfig.get_platform().
        PythonWheelTag = 'win_amd64'
        PythonPlatform = 'win-amd64'
        # CPython PCbuild: build.bat -p <BuildPlatform>, output in PCbuild\<OutDir>.
        CpythonBuildPlatform = 'x64'
        CpythonOutputDir = 'amd64'
        # Rust target triple.
        RustTarget = 'x86_64-pc-windows-msvc'
        # OpenCV's installed layout (opencv5\<this>\vc18\lib).
        OpenCvArchDir = 'x64'
        # .NET/NuGet runtime identifier -- runtimes\<this>\native.
        RuntimeIdentifier = 'win-x64'
        # Image/artifact tag component.
        TagSuffix = 'winamd64'
        # ffmpeg configure --arch=
        FfmpegArch = 'x86_64'
        # lib.exe / llvm-lib /machine:
        LibMachine = 'x64'
        # CMAKE_SYSTEM_PROCESSOR
        CMakeSystemProcessor = 'AMD64'
    }
    arm64 = @{
        Arch = 'arm64'
        ClangTriple = 'aarch64-pc-windows-msvc'
        VsDevCmdArch = 'arm64'
        # IMAGE_FILE_MACHINE_ARM64.
        PeMachine = 0xAA64
        PeMachineName = 'ARM64'
        VcpkgTriplet = 'arm64-windows'
        MsvcTargetBinDir = 'arm64'
        MsvcTargetLibDir = 'arm64'
        VulkanLibDir = 'Lib-ARM64'
        VulkanBinDir = 'Bin-ARM64'
        PythonWheelTag = 'win_arm64'
        PythonPlatform = 'win-arm64'
        CpythonBuildPlatform = 'ARM64'
        CpythonOutputDir = 'arm64'
        RustTarget = 'aarch64-pc-windows-msvc'
        OpenCvArchDir = 'arm64'
        RuntimeIdentifier = 'win-arm64'
        TagSuffix = 'winarm64'
        FfmpegArch = 'aarch64'
        LibMachine = 'arm64'
        CMakeSystemProcessor = 'ARM64'
    }
}

# The build host. Not a table entry: it is a fact about where we run, not a
# target we select. Every cross decision is "target != this".
$script:WindowsHostArch = 'amd64'

<#
.SYNOPSIS
    The list of supported Windows target architectures.
.OUTPUTS
    [string[]] Sorted arch names.
#>
function Get-SupportedWindowsTargetArches {
    return @($script:TargetArchTable.Keys | Sort-Object)
}

<#
.SYNOPSIS
    Resolves the active Windows target architecture.
.DESCRIPTION
    Precedence: explicit -Arch parameter, then $env:WINDOWS_TARGET_ARCH, then
    'amd64'. Defaulting to amd64 keeps every existing caller byte-identical:
    a tree with no WINDOWS_TARGET_ARCH anywhere behaves exactly as before.

    Unknown values THROW rather than falling back. A typo'd arch that silently
    degraded to amd64 would produce an x64 build labelled arm64 -- the single
    worst failure this module exists to prevent.
.PARAMETER Arch
    Explicit override. Empty/whitespace means "consult the environment".
.OUTPUTS
    [string] 'amd64' or 'arm64'.
#>
function Get-WindowsTargetArch {
    param(
        [string]$Arch = ''
    )

    $resolved = $Arch
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = $env:WINDOWS_TARGET_ARCH }
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = 'amd64' }

    $resolved = $resolved.Trim().ToLowerInvariant()
    # Accept the common spellings of each target so a caller passing a CMake or
    # Docker-flavoured name is not silently wrong. The canonical form is returned.
    switch ($resolved) {
        'x64'     { $resolved = 'amd64' }
        'x86_64'  { $resolved = 'amd64' }
        'aarch64' { $resolved = 'arm64' }
    }

    if (-not $script:TargetArchTable.ContainsKey($resolved)) {
        $supported = (Get-SupportedWindowsTargetArches) -join ', '
        throw "Unsupported Windows target architecture '$Arch' (resolved '$resolved'). Supported: $supported"
    }
    return $resolved
}

<#
.SYNOPSIS
    Returns the full fact record for a Windows target architecture.
.DESCRIPTION
    Returns a COPY of the table row, so a caller mutating the result cannot
    corrupt the module-scoped table for every subsequent caller in the session.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
.OUTPUTS
    [hashtable] All arch facts. See the table at the top of this module.
#>
function Get-WindowsTargetArchInfo {
    param(
        [string]$Arch = ''
    )
    $key = Get-WindowsTargetArch -Arch $Arch
    return $script:TargetArchTable[$key].Clone()
}

<#
.SYNOPSIS
    The architecture the Windows build host always runs as.
.OUTPUTS
    [string] Always 'amd64' -- there is no arm64 Windows container base image.
#>
function Get-WindowsHostArch {
    return $script:WindowsHostArch
}

<#
.SYNOPSIS
    True when building for an architecture other than the build host's.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
.OUTPUTS
    [bool]
#>
function Test-WindowsCrossTarget {
    param(
        [string]$Arch = ''
    )
    return (Get-WindowsTargetArch -Arch $Arch) -ne $script:WindowsHostArch
}

# ---------------------------------------------------------------------------
# Thin per-fact accessors. These exist so call sites read as intent
# ("Get-VcpkgTriplet") rather than as table plumbing, and so a rename of a
# table key touches one line here instead of every build script.
# ---------------------------------------------------------------------------

function Get-ClangTargetTriple {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).ClangTriple
}

function Get-VsDevCmdArch {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).VsDevCmdArch
}

function Get-PeMachineType {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).PeMachine
}

function Get-VcpkgTriplet {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).VcpkgTriplet
}

function Get-MsvcTargetBinDir {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).MsvcTargetBinDir
}

function Get-MsvcTargetLibDir {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).MsvcTargetLibDir
}

function Get-VulkanLibDirName {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).VulkanLibDir
}

function Get-VulkanBinDirName {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).VulkanBinDir
}

function Get-PythonWheelTag {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).PythonWheelTag
}

function Get-PythonPlatformName {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).PythonPlatform
}

function Get-CpythonBuildPlatform {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).CpythonBuildPlatform
}

function Get-CpythonOutputDir {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).CpythonOutputDir
}

function Get-RustTargetTriple {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).RustTarget
}

function Get-OpenCvArchDir {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).OpenCvArchDir
}

function Get-WindowsRuntimeIdentifier {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).RuntimeIdentifier
}

function Get-WindowsTargetTagSuffix {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).TagSuffix
}

function Get-FfmpegTargetArch {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).FfmpegArch
}

function Get-LibMachineArg {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).LibMachine
}

# ---------------------------------------------------------------------------
# SIMD / vectorisation
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    Baseline SIMD flags safe to apply to a whole target's compilation.
.DESCRIPTION
    amd64 returns the historical Get-WindowsX86SimdFlags string verbatim, so the
    existing lane's emitted flags are provably unchanged.

    arm64 returns nothing by default. AArch64 already mandates NEON in its
    baseline, and unlike x86 there is no safe "everything modern" set: dotprod /
    i8mm / SVE are optional features and a globally-enabled one produces
    SIGILL on hardware that lacks it -- the exact class of failure documented
    for AVX-512 in Get-WindowsTargetKernelSimdFlags. Optional AArch64 features
    belong ONLY on runtime-dispatched kernels, via that function.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
.OUTPUTS
    [string] Space-separated compiler flags; may be empty.
#>
function Get-WindowsTargetSimdFlags {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    switch ($key) {
        'amd64' {
            return '/clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-mssse3 /clang:-msse3 /clang:-msse4.1 /clang:-msse4.2 /clang:-mpopcnt'
        }
        'arm64' {
            # Baseline armv8-a (NEON) is implied by the target triple. See above
            # for why nothing optional is added globally.
            return ''
        }
    }
    throw "Get-WindowsTargetSimdFlags: no flag set defined for '$key'"
}

<#
.SYNOPSIS
    Per-TU SIMD flags for runtime-dispatched math kernels (MLAS).
.DESCRIPTION
    NEVER put these in global CXX flags -- see the x86 history below.

    x86 field history (2026-08-03, ORT v1.28, AVX2-only 5950X): globally, clang
    may emit AVX-512 anywhere, and the in-tree protoc AND onnxruntime.dll's
    static initializers both crashed at RUN/LOAD time with
    STATUS_ILLEGAL_INSTRUCTION. But entirely without them MLAS's arch TUs
    (qgemm_kernel_amx, intrinsics/avx512/*) fail to COMPILE: clang-cl gates
    intrinsics behind target features and ORT's mlas.cmake adds no per-file -m
    flags on its MSVC branch. The settled design: build-onnx-from-source.ps1
    appends this string per-TU to exactly the MLAS FLAGS lines matched by
    Get-MlasKernelTuPattern in build.ninja post-configure -- the only place the
    features may be assumed, because those kernels are runtime-dispatched.

    AArch64 is the same shape of problem with different features: dotprod, i8mm
    and bf16 are optional extensions that MLAS dispatches on at runtime, so the
    kernels that implement them must be compiled with the feature enabled while
    the rest of the library must not be.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
.OUTPUTS
    [string] Space-separated compiler flags.
#>
function Get-WindowsTargetKernelSimdFlags {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    switch ($key) {
        'amd64' {
            return '/clang:-mavx512f /clang:-mavx512cd /clang:-mavx512bw /clang:-mavx512dq /clang:-mavx512vl /clang:-mavx512vnni /clang:-mavx512bf16 /clang:-mavx512fp16 /clang:-mavxvnni /clang:-mamx-int8 /clang:-mamx-tile /clang:-mamx-bf16'
        }
        'arm64' {
            # armv8.2-a is the floor that makes dotprod/i8mm/bf16 expressible.
            return '/clang:-march=armv8.2-a+dotprod+i8mm+bf16+fp16'
        }
    }
    throw "Get-WindowsTargetKernelSimdFlags: no kernel flag set defined for '$key'"
}

<#
.SYNOPSIS
    Regex matching the MLAS translation units that need per-TU kernel flags.
.DESCRIPTION
    Consumed by build-onnx-from-source.ps1's post-configure build.ninja patch.

    This is arch-specific and MUST be, because the x86 pattern
    (qgemm_kernel_amx / intrinsics/avx512) matches NOTHING in an aarch64 build.
    A patch that matches nothing SUCCEEDS silently, so an unparameterized
    pattern would yield a green arm64 build whose dispatched kernels were
    compiled without their features -- unoptimised at best, absent at worst.
    Callers must assert a minimum match count; see Get-MlasKernelTuMinimum.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
.OUTPUTS
    [string] A regex suitable for -match against a build.ninja FLAGS line.
#>
function Get-MlasKernelTuPattern {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    switch ($key) {
        'amd64' { return 'qgemm_kernel_amx|intrinsics[\\/]avx512' }
        'arm64' { return 'sqnbitgemm_kernel_neon|hgemm_kernel_neon|qgemm_kernel_(udot|sdot|smmla|ummla)|halfgemm_kernel_neon|cast_kernel_neon' }
    }
    throw "Get-MlasKernelTuPattern: no TU pattern defined for '$key'"
}

<#
.SYNOPSIS
    Minimum number of MLAS TUs the kernel-flag patch must match to be trusted.
.DESCRIPTION
    The guard against a silently no-op patch. Deliberately conservative: it is
    a floor that proves the pattern still matches the upstream tree, not an
    exact count that would break on every ORT bump.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
.OUTPUTS
    [int]
#>
function Get-MlasKernelTuMinimum {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    switch ($key) {
        'amd64' { return 4 }
        'arm64' { return 2 }
    }
    throw "Get-MlasKernelTuMinimum: no minimum defined for '$key'"
}

# ---------------------------------------------------------------------------
# CMake
# ---------------------------------------------------------------------------

<#
.SYNOPSIS
    The CMake arguments that turn a native configure into a cross configure.
.DESCRIPTION
    Returns an EMPTY array for the host arch, so the amd64 lane's configure
    command line is provably unchanged by this module's introduction.

    For a cross target it returns CMAKE_SYSTEM_NAME/PROCESSOR (which is what
    puts CMake into CMAKE_CROSSCOMPILING mode) plus the clang-cl target triple
    on the compiler and linker flag variables. The triple is passed through
    /clang: on the compilers and directly to lld-link, because clang-cl only
    forwards --target to the compiler driver.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
.OUTPUTS
    [string[]] CMake -D arguments; empty when not cross-compiling.
#>
function Get-CMakeCrossArgs {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    if ($key -eq $script:WindowsHostArch) { return @() }

    $info = Get-WindowsTargetArchInfo -Arch $key
    $triple = $info.ClangTriple

    return @(
        '-DCMAKE_SYSTEM_NAME=Windows',
        "-DCMAKE_SYSTEM_PROCESSOR=$($info.CMakeSystemProcessor)",
        "-DCMAKE_C_COMPILER_TARGET=$triple",
        "-DCMAKE_CXX_COMPILER_TARGET=$triple",
        "-DCMAKE_C_FLAGS_INIT=--target=$triple",
        "-DCMAKE_CXX_FLAGS_INIT=--target=$triple"
    )
}

Export-ModuleMember -Function @(
    'Get-SupportedWindowsTargetArches',
    'Get-WindowsTargetArch',
    'Get-WindowsTargetArchInfo',
    'Get-WindowsHostArch',
    'Test-WindowsCrossTarget',
    'Get-ClangTargetTriple',
    'Get-VsDevCmdArch',
    'Get-PeMachineType',
    'Get-VcpkgTriplet',
    'Get-MsvcTargetBinDir',
    'Get-MsvcTargetLibDir',
    'Get-VulkanLibDirName',
    'Get-VulkanBinDirName',
    'Get-PythonWheelTag',
    'Get-PythonPlatformName',
    'Get-CpythonBuildPlatform',
    'Get-CpythonOutputDir',
    'Get-RustTargetTriple',
    'Get-OpenCvArchDir',
    'Get-WindowsRuntimeIdentifier',
    'Get-WindowsTargetTagSuffix',
    'Get-FfmpegTargetArch',
    'Get-LibMachineArg',
    'Get-WindowsTargetSimdFlags',
    'Get-WindowsTargetKernelSimdFlags',
    'Get-MlasKernelTuPattern',
    'Get-MlasKernelTuMinimum',
    'Get-CMakeCrossArgs'
)
