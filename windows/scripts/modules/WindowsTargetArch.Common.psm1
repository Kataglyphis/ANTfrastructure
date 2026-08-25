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
        # Qualcomm AI Engine Direct (QAIRT) SDK: lib\<this>\ holds the per-arch
        # QNN backend DLLs (QnnCpu on x64; QnnHtp/NPU + QnnCpu on arm64). #121.
        QnnLibDir = 'x86_64-windows-msvc'
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
        QnnLibDir = 'aarch64-windows-msvc'
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

<#
.SYNOPSIS
    Reads IMAGE_FILE_HEADER.Machine from a PE file (.exe/.dll/.pyd).
.DESCRIPTION
    The one 12-line read that was inlined in three places (verify-target-arch,
    build-target-cpython, smoke sections 14/15) before 2026-08-24. Lives here
    because this module is dependency-free and every arch decision already
    resolves through it. Returns the raw UInt16 (0x8664 / 0xAA64 / 0x014C);
    compare against Get-PeMachineType. Throws on a non-PE file rather than
    returning 0, so a caller can never mistake "not a PE" for "matches nothing".
#>
function Get-PeFileMachine {
    param([Parameter(Mandatory)][string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        if ($fs.Length -lt 0x40) { throw "Get-PeFileMachine: $Path is too small to be a PE file" }
        $fs.Seek(0x3C, 'Begin') | Out-Null
        $peOff = $br.ReadUInt32()
        if ($peOff + 6 -gt $fs.Length) { throw "Get-PeFileMachine: $Path has no PE header at the e_lfanew offset" }
        $fs.Seek($peOff, 'Begin') | Out-Null
        $sig = $br.ReadUInt32()
        if ($sig -ne 0x00004550) { throw "Get-PeFileMachine: $Path is not a PE file (signature 0x$($sig.ToString('X8')))" }
        return $br.ReadUInt16()
    } finally { $fs.Dispose() }
}

<#
.SYNOPSIS
    Lists the DLL names a PE file imports (import directory, optionally the
    delay-load directory), by parsing the file -- no dumpbin, no admin.
.DESCRIPTION
    Backlog #127 (2026-08-25): the merge arch gate answered "is every byte the
    right machine?" and nothing answered "can the loader resolve this file on
    the target?" -- which is how an arm64 python.exe shipped with its CRT in a
    directory the loader never searches (#124). This is the primitive for a
    whole-tree static import walk; dependency-free like the rest of this
    module so the gate can use it. PE32 and PE32+ (x64/ARM64). Throws on a
    non-PE, like Get-PeFileMachine.
.PARAMETER IncludeDelayLoad
    Also list DataDirectory[13] (delay-load) imports. Delay-loaded DLLs are
    resolved at first call, so a missing one is a runtime failure too.
.OUTPUTS
    [string[]] DLL names as written in the file (case preserved), unique.
#>
function Get-PeImportNames {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeDelayLoad
    )
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "Get-PeImportNames: $Path is too small to be a PE file" }
    $peOff = [BitConverter]::ToUInt32($bytes, 0x3C)
    if ($peOff + 24 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $peOff) -ne 0x00004550) {
        throw "Get-PeImportNames: $Path is not a PE file"
    }
    $numSections = [BitConverter]::ToUInt16($bytes, $peOff + 6)
    $optSize     = [BitConverter]::ToUInt16($bytes, $peOff + 20)
    $optOff      = $peOff + 24
    $isPlus      = ([BitConverter]::ToUInt16($bytes, $optOff) -eq 0x20B)
    $numDD       = [BitConverter]::ToUInt32($bytes, $optOff + $(if ($isPlus) { 108 } else { 92 }))
    $ddOff       = $optOff + $(if ($isPlus) { 112 } else { 96 })
    $secOff      = $optOff + $optSize
    $sections = @(for ($i = 0; $i -lt $numSections; $i++) {
        $s = $secOff + $i * 40
        [pscustomobject]@{
            VA      = [BitConverter]::ToUInt32($bytes, $s + 12)
            VSize   = [BitConverter]::ToUInt32($bytes, $s + 8)
            Raw     = [BitConverter]::ToUInt32($bytes, $s + 20)
            RawSize = [BitConverter]::ToUInt32($bytes, $s + 16)
        }
    })
    $rvaToOffset = {
        param([uint32]$rva)
        foreach ($s in $sections) {
            $span = [Math]::Max($s.VSize, $s.RawSize)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) { return [int]($s.Raw + ($rva - $s.VA)) }
        }
        return -1
    }
    $readAscii = {
        param([int]$off)
        $end = $off
        while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
        return [System.Text.Encoding]::ASCII.GetString($bytes, $off, $end - $off)
    }
    $names = [System.Collections.Generic.List[string]]::new()
    # DataDirectory[1] = imports: IMAGE_IMPORT_DESCRIPTOR is 20 bytes, Name RVA at +12, all-zero terminator.
    if ($numDD -gt 1) {
        $impRva = [BitConverter]::ToUInt32($bytes, $ddOff + 8)
        if ($impRva -ne 0) {
            $off = & $rvaToOffset $impRva
            while ($off -ge 0 -and $off + 20 -le $bytes.Length) {
                $nameRva = [BitConverter]::ToUInt32($bytes, $off + 12)
                if ($nameRva -eq 0) { break }
                $nOff = & $rvaToOffset $nameRva
                if ($nOff -ge 0) { $names.Add((& $readAscii $nOff)) }
                $off += 20
            }
        }
    }
    # DataDirectory[13] = delay-load: IMAGE_DELAYLOAD_DESCRIPTOR is 32 bytes, DllNameRVA at +4.
    if ($IncludeDelayLoad -and $numDD -gt 13) {
        $dRva = [BitConverter]::ToUInt32($bytes, $ddOff + 13 * 8)
        if ($dRva -ne 0) {
            $off = & $rvaToOffset $dRva
            while ($off -ge 0 -and $off + 32 -le $bytes.Length) {
                $nameRva = [BitConverter]::ToUInt32($bytes, $off + 4)
                if ($nameRva -eq 0) { break }
                $nOff = & $rvaToOffset $nameRva
                if ($nOff -ge 0) { $names.Add((& $readAscii $nOff)) }
                $off += 32
            }
        }
    }
    return @($names | Select-Object -Unique)
}

<#
.SYNOPSIS
    Asserts every given PE file is the TARGET machine; throws naming the first
    offender with both machine values. Returns the number checked.
.DESCRIPTION
    The static gate that used to be re-inlined per script (TVM/IREE installs,
    cv2, cpython staging, smoke sections 14/15) -- #131, 2026-08-25.
#>
function Assert-PeTargetMachine {
    param(
        [Parameter(Mandatory)][string[]]$Path,
        [string]$Arch = '',
        [string]$Context = ''
    )
    $want = Get-PeMachineType -Arch $Arch
    $label = if ($Context) { "$Context`: " } else { '' }
    foreach ($p in $Path) {
        $got = Get-PeFileMachine -Path $p
        if ($got -ne $want) {
            throw ('{0}{1} is PE machine 0x{2:X4}, expected 0x{3:X4}' -f $label, $p, $got, $want)
        }
    }
    return $Path.Count
}

<#
.SYNOPSIS
    Asserts every PE under a directory is the TARGET machine and that at least
    -MinCount files were found (an empty tree is a failure, never a pass).
    Returns the count.
#>
function Assert-DirectoryTargetArch {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Include = @('*.dll', '*.exe', '*.pyd'),
        [int]$MinCount = 1,
        [string]$Arch = '',
        [string]$Context = ''
    )
    $label = if ($Context) { $Context } else { $Path }
    if (-not (Test-Path -LiteralPath $Path)) { throw "$label`: directory not found: $Path" }
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Include $Include)
    if ($files.Count -lt $MinCount) {
        throw "$label`: found $($files.Count) native file(s) under $Path, expected at least $MinCount -- nothing (or too little) was staged"
    }
    [void](Assert-PeTargetMachine -Path @($files.FullName) -Arch $Arch -Context $label)
    return $files.Count
}

<#
.SYNOPSIS
    Asserts a python extension module NAME carries the target's EXT_SUFFIX tag
    when it carries one at all (`<mod>.cp314-win_arm64.pyd`); bare `<mod>.pyd`
    passes. A host-tagged name is unloadable on the target however correct the
    machine field is (measured 2026-08-24: cv2.cp314-win_amd64.pyd, 0xAA64).
#>
function Assert-PythonExtensionTag {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Arch = '',
        [string]$Context = ''
    )
    $leaf = [System.IO.Path]::GetFileName($Name)
    if ($leaf -notmatch '\.cp\d+-win_(amd64|arm64)\.pyd$') { return $true }
    $want = Get-PythonWheelTag -Arch $Arch
    if ($leaf -notmatch [regex]::Escape($want)) {
        $label = if ($Context) { "$Context`: " } else { '' }
        throw "$label$leaf carries a host EXT_SUFFIX tag, expected '$want' -- the target interpreter would never import it"
    }
    return $true
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

function Get-QnnSdkLibDirName {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).QnnLibDir
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
        # MEASURED against ONNX Runtime v1.29.0's x86 MLAS tree (2026-08-24), not
        # guessed -- and the previous value was WRONG, which broke the amd64 lane.
        #
        # The old pattern was 'qgemm_kernel_amx|intrinsics[\\/]avx512'. It matched
        # exactly 5 ninja lines: qgemm_kernel_amx.cpp plus the four files under
        # lib/intrinsics/avx512/. That was complete for an older ORT, but v1.29.0
        # keeps six more AVX-512 kernel TUs directly in lib/, outside the
        # intrinsics/ subtree:
        #     q4gemm_avx512.cpp                      sqnbitgemm_kernel_avx512.cpp
        #     qkv_quant_kernel_avx512vnni.cpp        sqnbitgemm_kernel_avx512_2bit.cpp
        #     sqnbitgemm_kernel_avx512vnni.cpp       sqnbitgemm_kernel_avx512vnni_2bit.cpp
        # Five of those failed to COMPILE ("always_inline function '_mm512_set1_ps'
        # requires target feature 'avx512f'"), and the floor of 4 did not catch it
        # because 5 >= 4. Same failure shape the arm64 branch below already
        # documents: the pattern silently under-matches, the floor rubber-stamps it,
        # and the compiler is what tells you 30 seconds later.
        #
        # The third alternative is deliberately anchored to \.cpp. lib/amd64/ holds
        # MASM kernels with names like QgemmU8X8KernelAvx512Core.asm, and -match is
        # case-INSENSITIVE in PowerShell; anchoring on .cpp makes it structurally
        # impossible to tag an ASM_MASM FLAGS line and hand ml64 a /clang: flag,
        # rather than relying on none of those names happening to contain an
        # underscore before "Avx512".
        'amd64' { return 'qgemm_kernel_amx|intrinsics[\\/]avx512|_avx512[a-z0-9_]*\.cpp' }
        # MEASURED against ONNX Runtime v1.29.0's aarch64 MLAS tree (2026-08-23),
        # not guessed. Three families need per-TU features:
        #   *_fp16.cpp          -> FEAT_FP16 intrinsics (vaddq_f16, vfmaq_f16, ...)
        #                          which clang gates behind target feature 'fullfp16'
        #   *_kernel_neon*.cpp  -> the NEON kernel family (qgemm, qnbitgemm,
        #                          sqnbitgemm, halfgemm, cast, qkv_quant,
        #                          rotary_embedding)
        #   qgemm_kernel_{udot,sdot,smmla,ummla} -> dotprod / i8mm kernels
        #
        # The first version of this pattern listed individual kernel names and
        # matched 10 of 16, silently missing every *_fp16 TU. That did not fail
        # the floor (then 2), it failed the COMPILE: activate_fp16.cpp and
        # pooling_fp16.cpp died with "always_inline function 'vaddq_f16' requires
        # target feature 'fullfp16'". Deliberately NOT matched: cast.cpp,
        # halfconv.cpp, halfgemm.cpp -- those are the runtime DISPATCHERS and must
        # stay feature-free, or the dispatch decision itself becomes unrunnable
        # on hardware lacking the feature.
        'arm64' { return '_fp16|_kernel_neon|qgemm_kernel_(udot|sdot|smmla|ummla)' }
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
        # 11 x86 kernel TUs matched in ONNX Runtime v1.29.0 (measured 2026-08-24):
        # 4 under lib/intrinsics/avx512/, qgemm_kernel_amx.cpp, and 6 *_avx512*.cpp
        # in lib/ itself. The floor is 8, leaving room for ordinary upstream churn.
        #
        # RAISED FROM 4 on 2026-08-24, and the old value is why this exists. With a
        # floor of 4 the stale pattern's 5 matches sailed through, and the amd64
        # build then died compiling sqnbitgemm_kernel_avx512.cpp. A floor only earns
        # its keep if it is high enough that the PREVIOUS broken state would trip
        # it: 5 < 8, so this specific regression can no longer pass silently.
        'amd64' { return 8 }
        # 16 aarch64 kernel TUs matched in ONNX Runtime v1.29.0 (measured
        # 2026-08-23). The floor is 12, not 16, so ordinary upstream churn does
        # not fail the build -- but the 10 that the first, incomplete pattern
        # matched WOULD now fail here instead of surfacing as a compile error
        # 30 seconds later, which is the entire point of having a floor.
        'arm64' { return 12 }
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
        "-DCMAKE_CXX_FLAGS_INIT=--target=$triple",
        # ASM too (added 2026-08-24, found by LiteRT/XNNPACK's .S kernels): a
        # project that enables the ASM language gets a clang-cl whose DEFAULT
        # target is the x64 host, and every aarch64 assembly file then dies in
        # the X86 assembler ("brackets expression not supported on this
        # target") -- with the extra trap that an -march=armv8.2-a+... handed
        # to that x86 driver is misread as a CPU name ("unknown target CPU"),
        # which pointed the first diagnosis at a nonexistent driver gap.
        # Projects that never enable ASM simply ignore these.
        "-DCMAKE_ASM_COMPILER_TARGET=$triple",
        "-DCMAKE_ASM_FLAGS_INIT=--target=$triple"
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
    'Get-PeFileMachine',
    'Get-PeImportNames',
    'Assert-PeTargetMachine',
    'Assert-DirectoryTargetArch',
    'Assert-PythonExtensionTag',
    'Get-VcpkgTriplet',
    'Get-MsvcTargetBinDir',
    'Get-MsvcTargetLibDir',
    'Get-VulkanLibDirName',
    'Get-VulkanBinDirName',
    'Get-PythonWheelTag',
    'Get-QnnSdkLibDirName',
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
