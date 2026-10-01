# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# Target-arch facts; dependency-free because host provisioning imports it before the module set is copied.

# The table: adding a target is a table edit, and a missing case throws instead of building x64.
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
        # MSVC and Windows Kits lib\<this>: what clang-cl links against, the only reason the ARM64 VS component is installed.
        MsvcTargetLibDir = 'x64'
        # The x64 Vulkan SDK ships Lib-ARM64/Bin-ARM64 only with the optional com.lunarg.vulkan.arm64 component.
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
        # QAIRT SDK lib\<this>\ holds the per-arch QNN backend DLLs.
        QnnLibDir = 'x86_64-windows-msvc'
        # Package file names, wix build -arch, AppxManifest ProcessorArchitecture and VC\Redist\MSVC\<ver>\<this>.
        PackageArch = 'x64'
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
        PackageArch = 'arm64'
    }
}

# Always amd64: there is no arm64 Windows container base image, so arm64 is a cross build.
$script:WindowsHostArch = 'amd64'

<#
.SYNOPSIS
    The supported Windows target architectures, sorted.
#>
function Get-SupportedWindowsTargetArches {
    return @($script:TargetArchTable.Keys | Sort-Object)
}

<#
.SYNOPSIS
    Resolves the target arch: -Arch, then $env:WINDOWS_TARGET_ARCH, then 'amd64'.
.DESCRIPTION
    Unknown values throw: a typo degraded to amd64 would produce an x64 build labelled arm64.
.PARAMETER Arch
    Explicit override; empty consults the environment.
#>
function Get-WindowsTargetArch {
    param(
        [string]$Arch = ''
    )

    $resolved = $Arch
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = $env:WINDOWS_TARGET_ARCH }
    if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = 'amd64' }

    $resolved = $resolved.Trim().ToLowerInvariant()
    # Accept CMake/Docker spellings; the canonical form is returned.
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
    Returns a copy of the fact record for a target arch, so callers cannot corrupt the table.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
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
    The build host's arch, always 'amd64'.
#>
function Get-WindowsHostArch {
    return $script:WindowsHostArch
}

<#
.SYNOPSIS
    True when building for an architecture other than the build host's.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
#>
function Test-WindowsCrossTarget {
    param(
        [string]$Arch = ''
    )
    return (Get-WindowsTargetArch -Arch $Arch) -ne $script:WindowsHostArch
}

# Per-fact accessors, so a table key rename touches one line here instead of every build script.

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
    Reads IMAGE_FILE_HEADER.Machine from a PE file; compare against Get-PeMachineType.
.DESCRIPTION
    Throws on a non-PE file, so "not a PE" can never pass as "matches nothing".
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

function Read-PeLayout {
    # The bytes, sections and data directories every PE directory reader needs; throws on a non-PE, naming $Caller.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Caller)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "${Caller}: $Path is too small to be a PE file" }
    $peOff = [BitConverter]::ToUInt32($bytes, 0x3C)
    if ($peOff + 24 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $peOff) -ne 0x00004550) {
        throw "${Caller}: $Path is not a PE file"
    }
    $numSections = [BitConverter]::ToUInt16($bytes, $peOff + 6)
    $optSize     = [BitConverter]::ToUInt16($bytes, $peOff + 20)
    $optOff      = $peOff + 24
    $isPlus      = ([BitConverter]::ToUInt16($bytes, $optOff) -eq 0x20B)
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
    return [pscustomobject]@{
        Bytes    = $bytes
        Sections = $sections
        NumDD    = [BitConverter]::ToUInt32($bytes, $optOff + $(if ($isPlus) { 108 } else { 92 }))
        DdOff    = $optOff + $(if ($isPlus) { 112 } else { 96 })
    }
}

function ConvertTo-PeFileOffset {
    # The file offset of an RVA, or -1 when no section holds it.
    param([Parameter(Mandatory)][object]$Pe, [uint32]$Rva)
    foreach ($s in $Pe.Sections) {
        $span = [Math]::Max($s.VSize, $s.RawSize)
        if ($Rva -ge $s.VA -and $Rva -lt ($s.VA + $span)) { return [int]($s.Raw + ($Rva - $s.VA)) }
    }
    return -1
}

function Add-PeName {
    # Adds the NUL-terminated ASCII name at an RVA to $Names; an RVA outside every section adds nothing.
    param([Parameter(Mandatory)][object]$Pe, [System.Collections.Generic.List[string]]$Names, [uint32]$Rva)
    $bytes = $Pe.Bytes
    $start = ConvertTo-PeFileOffset -Pe $Pe -Rva $Rva
    if ($start -lt 0) { return }
    $end = $start
    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
    $Names.Add([System.Text.Encoding]::ASCII.GetString($bytes, $start, $end - $start))
}

function Add-PeDescriptorName {
    # Walks a descriptor table at $Rva ($Size bytes each, the DLL-name RVA at +$NameAt, ended by a zero name).
    param([Parameter(Mandatory)][object]$Pe, [System.Collections.Generic.List[string]]$Names, [uint32]$Rva, [int]$Size, [int]$NameAt)
    $off = ConvertTo-PeFileOffset -Pe $Pe -Rva $Rva
    while ($Rva -ne 0 -and $off -ge 0 -and $off + $Size -le $Pe.Bytes.Length) {
        $nameRva = [BitConverter]::ToUInt32($Pe.Bytes, $off + $NameAt)
        if ($nameRva -eq 0) { break }
        Add-PeName -Pe $Pe -Names $Names -Rva $nameRva
        $off += $Size
    }
}

<#
.SYNOPSIS
    Lists the unique DLL names a PE file imports, by parsing the file (no dumpbin, no admin).
.PARAMETER IncludeDelayLoad
    Also list delay-load imports: a missing one is a runtime failure too.
#>
function Get-PeImportNames {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeDelayLoad
    )
    $pe = Read-PeLayout -Path $Path -Caller 'Get-PeImportNames'
    $names = [System.Collections.Generic.List[string]]::new()
    # DataDirectory[1] = imports: IMAGE_IMPORT_DESCRIPTOR is 20 bytes, Name RVA at +12, all-zero terminator.
    if ($pe.NumDD -gt 1) {
        Add-PeDescriptorName -Pe $pe -Names $names -Rva ([BitConverter]::ToUInt32($pe.Bytes, $pe.DdOff + 8)) -Size 20 -NameAt 12
    }
    # DataDirectory[13] = delay-load: IMAGE_DELAYLOAD_DESCRIPTOR is 32 bytes, DllNameRVA at +4.
    if ($IncludeDelayLoad -and $pe.NumDD -gt 13) {
        Add-PeDescriptorName -Pe $pe -Names $names -Rva ([BitConverter]::ToUInt32($pe.Bytes, $pe.DdOff + 13 * 8)) -Size 32 -NameAt 4
    }
    return @($names | Select-Object -Unique)
}

<#
.SYNOPSIS
    Lists the names a PE file exports, by parsing the file.
.DESCRIPTION
    A forwarded export is another DLL's code, so it is left out unless -IncludeForwarded.
#>
function Get-PeExportNames {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IncludeForwarded
    )
    $pe = Read-PeLayout -Path $Path -Caller 'Get-PeExportNames'
    $bytes = $pe.Bytes
    if ($pe.NumDD -lt 1) { return @() }
    # DataDirectory[0] = IMAGE_EXPORT_DIRECTORY: NumberOfNames at +24, then the function, name and ordinal table RVAs.
    $dirRva = [BitConverter]::ToUInt32($bytes, $pe.DdOff)
    $dirEnd = $dirRva + [BitConverter]::ToUInt32($bytes, $pe.DdOff + 4)
    $dir = ConvertTo-PeFileOffset -Pe $pe -Rva $dirRva
    if ($dirRva -eq 0 -or $dir -lt 0 -or $dir + 40 -gt $bytes.Length) { return @() }
    $tables = @(28, 32, 36 | ForEach-Object { ConvertTo-PeFileOffset -Pe $pe -Rva ([BitConverter]::ToUInt32($bytes, $dir + $_)) })
    if (@($tables | Where-Object { $_ -lt 0 }).Count -gt 0) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    $count = [BitConverter]::ToUInt32($bytes, $dir + 24)
    for ($i = 0; $i -lt $count; $i++) {
        $fn = [BitConverter]::ToUInt32($bytes, $tables[0] + 4 * [BitConverter]::ToUInt16($bytes, $tables[2] + 2 * $i))
        if (-not $IncludeForwarded -and $fn -ge $dirRva -and $fn -lt $dirEnd) { continue }
        Add-PeName -Pe $pe -Names $names -Rva ([BitConverter]::ToUInt32($bytes, $tables[1] + 4 * $i))
    }
    return $names.ToArray()
}

<#
.SYNOPSIS
    Asserts every given PE file is the target machine; throws naming the first offender, returns the count.
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
    Asserts every PE under a directory is the target machine and at least -MinCount exist; returns the count.
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
    Asserts a tagged extension module name carries the target's EXT_SUFFIX tag; a bare `<mod>.pyd` passes.
.DESCRIPTION
    A host-tagged name is unloadable on the target, however correct its PE machine field is.
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

function Get-WindowsPackageArch {
    param([string]$Arch = '')
    return (Get-WindowsTargetArchInfo -Arch $Arch).PackageArch
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

# SIMD

<#
.SYNOPSIS
    Baseline SIMD flags safe for a whole target's compilation; may be empty.
.DESCRIPTION
    arm64 gets none: NEON is baseline, and a globally enabled optional feature (dotprod, i8mm, SVE) is SIGILL on
    hardware without it. Optional features belong on runtime-dispatched kernels only.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
#>
function Get-WindowsTargetSimdFlags {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    switch ($key) {
        'amd64' {
            return '/clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-mssse3 /clang:-msse3 /clang:-msse4.1 /clang:-msse4.2 /clang:-mpopcnt'
        }
        'arm64' {
            # NEON is implied by the target triple.
            return ''
        }
    }
    throw "Get-WindowsTargetSimdFlags: no flag set defined for '$key'"
}

<#
.SYNOPSIS
    Per-TU SIMD flags for runtime-dispatched MLAS kernels; never global CXX flags.
.DESCRIPTION
    See docs/windows-build-invariants.md § AVX-512/AMX flags never go in global CXX flags.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
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
    Regex for the build.ninja lines of the MLAS TUs that need per-TU kernel flags.
.DESCRIPTION
    Arch-specific because a pattern that matches nothing succeeds silently; callers assert Get-MlasKernelTuMinimum.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
#>
function Get-MlasKernelTuPattern {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    switch ($key) {
        # Anchored to \.cpp: -match is case-insensitive and lib/amd64 holds MASM *Avx512*.asm kernels.
        'amd64' { return 'qgemm_kernel_amx|intrinsics[\\/]avx512|_avx512[a-z0-9_]*\.cpp' }
        # Not matched on purpose: the dispatchers (cast.cpp, halfconv.cpp, halfgemm.cpp) must stay feature-free.
        'arm64' { return '_fp16|_kernel_neon|qgemm_kernel_(udot|sdot|smmla|ummla)' }
    }
    throw "Get-MlasKernelTuPattern: no TU pattern defined for '$key'"
}

<#
.SYNOPSIS
    Minimum number of MLAS TUs the kernel-flag patch must match to be trusted.
.DESCRIPTION
    A floor, not an exact count, so ordinary upstream churn passes but the previous broken state trips it.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
#>
function Get-MlasKernelTuMinimum {
    param([string]$Arch = '')

    $key = Get-WindowsTargetArch -Arch $Arch
    switch ($key) {
        # ORT v1.29.0 matches 11; the stale pattern matched 5.
        'amd64' { return 8 }
        # ORT v1.29.0 matches 16; the first, incomplete pattern matched 10.
        'arm64' { return 12 }
    }
    throw "Get-MlasKernelTuMinimum: no minimum defined for '$key'"
}

# CMake

<#
.SYNOPSIS
    The CMake arguments that turn a native configure into a cross configure; empty for the host arch.
.PARAMETER Arch
    Target arch; resolved via Get-WindowsTargetArch.
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
        # See docs/windows-build-invariants.md § CMake cross configures must carry the ASM language target too
        "-DCMAKE_ASM_COMPILER_TARGET=$triple",
        "-DCMAKE_ASM_FLAGS_INIT=--target=$triple"
    )
}

# The build machine's x64-targeting MSVC tool for meson; throws instead of falling back to PATH's ARM64 cl.
function Resolve-BuildMachineMsvcTool {
    param(
        [Parameter(Mandatory)]
        [string]$VcToolsDir,
        [Parameter(Mandatory)]
        [string]$Name
    )
    if ([string]::IsNullOrWhiteSpace($VcToolsDir)) { throw "Resolve-BuildMachineMsvcTool: no VC tools root (LIB carried no VC\Tools\MSVC entry and Get-MsvcToolsRoot found none) -- cannot name the build machine's $Name" }
    $tool = Join-Path $VcToolsDir "bin\HostX64\x64\$Name"
    if (-not (Test-Path $tool -PathType Leaf)) { throw "Resolve-BuildMachineMsvcTool: $tool not found -- the build machine's libffi needs the x64-targeting $Name (VC.Tools.x86.x64 component)" }
    return ($tool -replace '\\', '/')
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
    'Get-PeExportNames',
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
    'Get-WindowsPackageArch',
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
    'Get-CMakeCrossArgs',
    'Resolve-BuildMachineMsvcTool'
)
