# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\iree-src',
    [string]$InstallDir = '',
    [string]$IreeVersion = '',
    [string]$BuildType = 'Release',
    [switch]$SkipPython
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$IreeVersion = Get-SourceBuildVersion -Value $IreeVersion -EnvironmentVariables @('IREE_VERSION') -DefaultValue 'v3.11.0'

Write-Host "=== IREE source build ($IreeVersion, Ninja+clang-cl) ==="

# IREE vendors LLVM (and ~15 other projects) as submodules; the release tarball
# ships WITHOUT them, so this must be a git clone. Shallow clone + shallow
# submodules: GitHub serves the exact pinned SHAs (allowReachableSHA1InWant),
# which turns a ~4 GB llvm-project history into a ~600 MB checkout.
# Invoke-GitClone is not used because its -Recursive maps to `--recursive`
# WITHOUT `--shallow-submodules`.
# Mount-safe reset (shared helper): a plain Remove-Item dies with "used by
# another process" when $SourceDir is a BuildKit cache-mount target -- the
# helper falls back to clearing the CONTENTS (git clones into an empty dir fine).
Reset-SourceBuildDirectory -Path $SourceDir
$env:GIT_TERMINAL_PROMPT = '0'
[void](Invoke-ShieldedNative -Label "IREE clone $IreeVersion" -CommandLine "git clone --depth 1 --branch $IreeVersion --shallow-submodules --recurse-submodules --jobs 4 https://github.com/iree-org/iree.git `"$SourceDir`"")
if (-not (Test-Path (Join-Path $SourceDir 'third_party\llvm-project\llvm\CMakeLists.txt'))) {
    throw 'IREE submodules incomplete: third_party/llvm-project missing after clone'
}

# UPSTREAM BUG (arm64 run 8, 2026-08-24): runtime/src/iree/hal/local/elf/CMakeLists.txt
# adds the x86-64 MASM trampoline object (arch/x86_64_msvc.obj) whenever
# `MSVC_C_ARCHITECTURE_ID MATCHES 64` -- and "ARM64" matches "64". An ARM64
# target then gets an x64 object handed to llvm-lib /machine:ARM64: "file
# machine type x64 conflicts with library machine type arm64". Tighten the
# match to the x64 spellings. Applied on BOTH lanes: on amd64 the ID is "x64",
# which the new regex matches exactly as before, so nothing changes there and
# a correctness fix has no business being arch-conditional. Draft issue:
# out/upstream-issue-iree-elf-arch-arm64-msvc.md.
$ireeElfCmake = Join-Path $SourceDir 'runtime\src\iree\hal\local\elf\CMakeLists.txt'
if (Test-Path $ireeElfCmake) {
    # -AssertGone: an ARM64 build with the old test left in place would fail
    # archiving iree_hal_local_elf_arch.lib with an x64 object.
    [void](Invoke-InlineRegexPatch -Path $ireeElfCmake `
            -SkipIfMatch 'MSVC_C_ARCHITECTURE_ID MATCHES "\^\(x64' `
            -Pattern 'MSVC_C_ARCHITECTURE_ID MATCHES 64 OR MSVC_CXX_ARCHITECTURE_ID MATCHES 64' `
            -Replacement 'MSVC_C_ARCHITECTURE_ID MATCHES "^(x64|X64|AMD64|x86_64)$" OR MSVC_CXX_ARCHITECTURE_ID MATCHES "^(x64|X64|AMD64|x86_64)$"' `
            -AssertGone 'MATCHES 64' `
            -Description 'IREE elf loader: x86_64_msvc.obj only for x64 targets (ARM64 matched "64")')
    # #123 (2026-08-25): the x86_64 ELF trampoline is assembled by a literal
    # `ml64` in an add_custom_command -- the last MSVC tool in this build (on
    # the cross lane it still runs, for the HOST tools pass). Point it at the
    # assembler the configure line names (-DIREE_MASM_COMPILER, llvm-ml).
    # `-m64` is load-bearing: llvm-ml assembles for i386 unless told otherwise,
    # and the file's x64 frame directives (.PUSHREG/.SETFRAME -> .seh_*) then
    # fail with ".seh_* directives are not supported on this target" (measured
    # arm64 run 22, the host-tools pass).
    if (-not (Invoke-InlineRegexPatch -Path $ireeElfCmake `
                -SkipIfMatch 'IREE_MASM_COMPILER' `
                -Pattern 'COMMAND ml64 ' `
                -Replacement 'COMMAND ${IREE_MASM_COMPILER} -m64 ' `
                -AssertGone 'COMMAND ml64 ' `
                -Description 'IREE elf loader: x86_64_msvc.asm assembled by ${IREE_MASM_COMPILER} (llvm-ml) instead of a literal ml64 (#123)')) {
        if (-not (Select-String -Path $ireeElfCmake -Pattern 'IREE_MASM_COMPILER' -Quiet)) {
            throw "IREE elf CMakeLists: neither the literal ml64 command nor the IREE_MASM_COMPILER form is present -- upstream layout changed (#123); check $ireeElfCmake"
        }
    }
}
# Resolved once, THROWING when absent (a silent ml64 fallback is the exception
# #123 removes). Forward slashes: consumed inside CMake's own string expansion.
$ireeMasm = Resolve-LlvmMasm
if (-not $ireeMasm) { throw 'llvm-ml not found on PATH -- the pinned LLVM ships it (bin\llvm-ml.exe); IREE''s x86_64 ELF trampoline would fall back to ml64 (#123)' }
$ireeMasm = $ireeMasm -replace '\\', '/'

# C `inline` linkage in ONE arm_64 ukernel (arm64 runs 9-10, 2026-08-24: the
# whole runtime compiled, every tool failed to LINK with "undefined symbol:
# iree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm"). Checked file by file, that
# is upstream's single non-static C `inline` definition in the arm_64 set,
# and the entry point takes its ADDRESS; under C99 inline semantics (clang's
# default in C mode) an `inline` definition without `extern` emits no
# external symbol. Per-TU -fgnu89-inline was tried first (run 10) and did NOT
# produce the symbol under clang-cl, so the definition itself is made a plain
# external function -- `inline` buys nothing for a function used by address.
# The arm_64 dir is not compiled on amd64 (IREE_ARCH x86_64), so this is
# inert there; guarded on the file, verified after applying.
$ireeI8mm = Join-Path $SourceDir 'runtime\src\iree\builtins\ukernel\arch\arm_64\mmt4d_arm_64_i8mm.c'
if (Test-Path $ireeI8mm) {
    # -AssertGone: with the inline definition left in place every ARM64 tool
    # fails to link on that symbol.
    [void](Invoke-InlineRegexPatch -Path $ireeI8mm `
            -SkipIfMatch '(?m)^void\s*\r?\niree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm\(' `
            -Pattern 'IREE_UK_ATTRIBUTE_ALWAYS_INLINE inline void(\s*\r?\n)iree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm\(' `
            -Replacement 'void$1iree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm(' `
            -AssertGone 'ALWAYS_INLINE inline void\s*\r?\niree_uk_mmt4d_tile_s8s4s32_1x8x16_arm_64_i8mm\(' `
            -Description 'IREE ukernel: s8s4s32 1x8x16 i8mm tile is used by address -- plain external definition (C99 inline emitted no symbol)')
}

# Canonical preamble: VsDevCmd + pyconfig.h into Include\ (in-tree Windows
# CPython keeps it at PC\pyconfig.h, which CMake's FindPython cannot see —
# configure died there on the first spike) + platform-tag shim + python handle.
$py = Initialize-ToolchainPythonEnvironment

$buildDir = Join-Path $SourceDir 'build'
$ireeInstallDir = Join-Path $InstallDir 'iree'

# #116 (2026-08-24): RUNTIME-ONLY on the cross lane. IREE's build EXECUTES
# host tools (iree-flatcc-cli, generate_embed_data) while compiling the
# runtime, and the compiler would need target-arch LLVM libs as well. Upstream
# supports exactly this split: build the host tools natively, then point the
# TARGET configure at them with IREE_HOST_BIN_DIR. The bundle ships the
# runtime tools + libs (iree-run-module & co.); iree-compile and the python
# packages stay amd64-only and are named ABSENT next to the install.
$ireeCross = Test-WindowsCrossTarget
$pythonBindings = 'OFF'
# Cross lane (#133, 2026-08-26): the RUNTIME python package (iree.runtime, a
# nanobind extension over the runtime this pass cross-builds anyway) follows
# the #120 pattern -- the HOST interpreter runs the build and nanobind's
# probes, the TARGET python314.lib is what _runtime.pyd links, the wheel is
# stamped win_arm64 and PE-checked, never imported here. The compiler package
# stays ABSENT (it needs a target-arch LLVM). Same .Available guard as ORT.
$ireeTargetPy = $null
$ireeNumpyInc = ''
if ($ireeCross -and -not $SkipPython) {
    $ireeTargetPy = Get-TargetBuildPython
    if ($ireeTargetPy.Available) {
        $pythonBindings = 'ON'
        Install-CpythonPip -Python $py
        Initialize-PythonPlatformTag | Out-Null   # EXT_SUFFIX -> target tag for the .pyd name
        Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'wheel', 'setuptools', 'numpy')
        $ireeNumpyInc = (Invoke-ShieldedNative -Label 'numpy include probe' -CommandLine """$($py.Exe)"" -c ""import numpy; print(numpy.get_include())""" | Select-Object -Last 1)
        if (-not $ireeNumpyInc -or -not (Test-Path (Join-Path $ireeNumpyInc 'numpy\arrayobject.h'))) {
            throw "IREE: numpy include dir not usable ('$ireeNumpyInc') -- numpy must be importable by the build interpreter $($py.Exe) before configure"
        }
        Write-Host "IREE cross: RUNTIME build + iree.runtime python bindings for the target (#133) -- host interpreter $($py.Exe), TARGET import lib $($ireeTargetPy.Lib); compiler + iree.compiler stay ABSENT"
    } else {
        Write-Host "IREE cross: RUNTIME-ONLY build, python OFF -- no target CPython import lib at $($ireeTargetPy.Lib) (build-target-cpython.ps1 did not run?)"
    }
} elseif ($ireeCross) {
    Write-Host 'IREE cross: RUNTIME-ONLY build (compiler OFF, python OFF by -SkipPython); host tools first, then the target runtime via IREE_HOST_BIN_DIR (#116)'
} elseif (-not $SkipPython) {
    # Python bindings are EXPECTED on this lane: a missing interpreter must fail
    # loudly, not silently ship an image without iree.compiler/iree.runtime
    # (only an explicit -SkipPython legitimately turns the bindings off).
    if (-not (Test-Path $py.Exe)) {
        throw "IREE python bindings expected but source-built CPython is missing at $($py.Exe) (toolchain layer incomplete? pass -SkipPython for a deliberate no-python build)"
    }
    $pythonBindings = 'ON'
    Install-CpythonPip -Python $py
    # numpy: required by the runtime bindings at import; nanobind is vendored.
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'wheel', 'setuptools', 'numpy')
}

# GPU lane: CUDA HAL driver dlopens nvcuda.dll at runtime and the CUDA compiler
# target emits PTX through IREE's own NVPTX backend -- neither needs nvcc, so
# they are safe to enable whenever the lane is nvidia.
$gpuEnv = Get-GpuEnvironment
$cudaFlag = if ($gpuEnv.HasCuda) { 'ON' } else { 'OFF' }
if ($cudaFlag -eq 'ON') { Write-Host 'NVIDIA lane -> enabling IREE CUDA HAL driver + CUDA target backend (PTX via NVPTX, no nvcc)' }

$ireeEhscInclude = (Join-Path $scriptAssetRoot 'patches\iree\enable-ehsc.cmake') -replace '\\', '/'
$ireeHostBinDir = $null
if ($ireeCross) {
    # Phase A: HOST tools. A native (x64) runtime-only configure of the SAME
    # tree into build-host\, installed to build-host\install -- upstream's
    # documented cross recipe. -TargetArch (Get-WindowsHostArch) is the
    # per-call override that keeps every cross arg out of this configure
    # (same mechanism as LiteRT's host-flatc pass).
    $hostBuildDir   = Join-Path $SourceDir 'build-host'
    $hostInstallDir = Join-Path $hostBuildDir 'install'
    Write-Host 'IREE cross: building HOST tools (native x64, runtime-only) for IREE_HOST_BIN_DIR...'
    $hostArgs = @(
        "-DCMAKE_BUILD_TYPE=$BuildType"
        "-DCMAKE_PROJECT_INCLUDE=$ireeEhscInclude"
        '-DIREE_BUILD_COMPILER=OFF', '-DIREE_BUILD_TESTS=OFF', '-DIREE_BUILD_SAMPLES=OFF'
        '-DIREE_BUILD_PYTHON_BINDINGS=OFF', '-DLLVM_ENABLE_DIA_SDK=OFF'
    )
    $hostArgs += Get-LlvmArchiverCmakeArg
    # The host tools include the x86_64 ELF trampoline (MASM) -- assembled by
    # llvm-ml through the IREE_MASM_COMPILER patch above (#123).
    $hostArgs += "-DIREE_MASM_COMPILER=$ireeMasm"
    # Shared host-tool shape: host target on the choke point AND the host's
    # LIB/LIBPATH for the pass (arm64 run 3: "msvcrtd.lib(exe_main.obj): machine
    # type arm64 conflicts with x64" in the very first try-compile without it).
    $ireeHostBinDir = Invoke-HostToolCmakeBuild -SourceDir $SourceDir -BuildDir $hostBuildDir -InstallPrefix $hostInstallDir `
        -ExtraArgs $hostArgs -Install -InstallConfig $BuildType -LogName 'iree-host-tools-build.log' -Label 'IREE host tools'
    # The two tools the target build executes -- named as IREE 3.x looks them up
    # under IREE_HOST_BIN_DIR (iree_c_embed_data.cmake: "iree-c-embed-data";
    # arm64 run 5 asserted the pre-rename `generate_embed_data` and died). A
    # missing one here is a loud layout-drift signal, not a late "program not
    # found" deep in ninja.
    foreach ($tool in @('iree-flatcc-cli.exe', 'iree-c-embed-data.exe')) {
        $toolPath = Join-Path $ireeHostBinDir $tool
        if (-not (Test-Path $toolPath)) { throw "IREE cross: host tool $tool missing in $ireeHostBinDir after the host install (upstream install layout drift?)" }
        # UPSTREAM GAP (arm64 run 6): IREE composes "${IREE_HOST_BIN_DIR}/<tool>"
        # WITHOUT the .exe suffix (Linux-shaped), and ninja then wants that exact
        # FILE as a dependency: "'.../bin/iree-flatcc-cli', needed by
        # '.../dummy_reader.h', missing and no known rule to make it". A
        # suffix-less twin satisfies the dependency, and CreateProcess appends
        # .exe when it launches an extension-less full path -- both copies are
        # the same bytes, so either resolution runs the same tool.
        Copy-Item -Path $toolPath -Destination (Join-Path $ireeHostBinDir ([IO.Path]::GetFileNameWithoutExtension($tool))) -Force
    }
    Write-Host "IREE cross: host tools ready at $ireeHostBinDir"
}

$cmakeExtra = @(
    "-DCMAKE_BUILD_TYPE=$BuildType"
    # nanobind EH port: see patches\iree\enable-ehsc.cmake (directory-scope
    # /EHsc for every project; the only injection point that survives LLVM's
    # flag stripping without leaking into the ukernel bitcode cross-clang).
    "-DCMAKE_PROJECT_INCLUDE=$ireeEhscInclude"
    '-DLLVM_ENABLE_RTTI=ON'
    "-DIREE_BUILD_COMPILER=$(if ($ireeCross) { 'OFF' } else { 'ON' })"
    '-DIREE_BUILD_TESTS=OFF'
    '-DIREE_BUILD_SAMPLES=OFF'
    # The BuildTools image ships the DIA SDK headers but NOT ATL -- LLVM
    # auto-enables DIA and then dies on atlbase.h. DIA-based PDB reading is
    # irrelevant to IREE; force it off.
    '-DLLVM_ENABLE_DIA_SDK=OFF'
    "-DIREE_BUILD_PYTHON_BINDINGS=$pythonBindings"
    '-DIREE_HAL_DRIVER_VULKAN=ON'
    "-DIREE_HAL_DRIVER_CUDA=$cudaFlag"
    "-DIREE_TARGET_BACKEND_CUDA=$cudaFlag"
)
if ($pythonBindings -eq 'ON' -and $ireeCross) {
    # Both prefixes: IREE bootstraps FindPython3 first and then FindPython
    # (nanobind wants the latter) from the SAME executable; under
    # CMAKE_CROSSCOMPILING neither may probe the target, so every value is
    # handed over -- host exe, arch-neutral include, TARGET import lib, and
    # the numpy headers probed above with the host interpreter.
    $cmakeExtra += Get-PythonCMakeHintArgs -Python $ireeTargetPy -Prefix @('Python3', 'Python') -ForwardSlash -NumPyIncludeDir $ireeNumpyInc
} elseif ($pythonBindings -eq 'ON') {
    $cmakeExtra += "-DPython3_EXECUTABLE=$($py.Exe -replace '\\', '/')"
}
$cmakeExtra += Get-LlvmArchiverCmakeArg
# QNN target backend (#121): IREE's Qualcomm target backend dispatches
# compiled MLIR models to the Snapdragon NPU via the QAIRT SDK.
$qnnSdk = Resolve-QnnSdk -DropDir 'C:\temp\qnn-sdk' -ExpectedSha256 $env:QNN_SDK_ZIP_SHA256
if ($qnnSdk) {
    $cmakeExtra += @('-DIREE_TARGET_BACKEND_QNN=ON', "-DQNN_HOME=$($qnnSdk.Home -replace '\\', '/')")
    Write-Host "IREE: QNN target backend ON (SDK root $($qnnSdk.Home), backends from $($qnnSdk.LibDir)) -- backlog #121"
} else {
    $cmakeExtra += '-DIREE_TARGET_BACKEND_QNN=OFF'
}
# Native lane: the x86_64 trampoline is assembled in THIS configure; cross lane:
# the ARM64 branch never reaches the custom command, the value is merely unused.
$cmakeExtra += "-DIREE_MASM_COMPILER=$ireeMasm"
if ($ireeHostBinDir) { $cmakeExtra += "-DIREE_HOST_BIN_DIR=$($ireeHostBinDir -replace '\\', '/')" }

# Phase B (or the only phase on amd64): the TARGET configure. Cross args come
# from Invoke-CmakeConfigure's choke point.
Invoke-CmakeConfigure -SourceDir $SourceDir -BuildDir $buildDir -InstallPrefix $ireeInstallDir -ExtraArgs $cmakeExtra | Out-Null

if ($ireeCross) {
    # Per-TU feature flags for the arm_64 ukernels (arm64 run 7, 2026-08-24):
    # upstream's CMakeLists hands each feature kernel its -march via
    # iree_select_compiler_opts(CLANG_OR_GCC ...), and clang-cl is classified
    # as MSVC there, so the flags are dropped and the TUs die with "always_inline
    # function 'vfmaq_f16' requires target feature 'fullfp16'". Same remedy and
    # same discipline as LiteRT/XNNPACK and MLAS: append the feature per-TU in
    # build.ninja post-configure -- these are dispatcher-gated microkernels, the
    # only code allowed to assume the feature -- and THROW below a floor, because
    # a pattern that matches nothing succeeds silently. Second clang-cl gap in
    # the same files: bare `asm(...)` (GNU keyword, off under MS compat) --
    # -Dasm=__asm__ on every arm_64 ukernel TU restores it without touching
    # the tree.
    $ireeUkFeatureMap = [ordered]@{
        'mmt4d_arm_64_fullfp16' = 'fp16'
        'mmt4d_arm_64_fp16fml'  = 'fp16fml'
        'mmt4d_arm_64_bf16'     = 'bf16'
        'mmt4d_arm_64_dotprod'  = 'dotprod'
        'mmt4d_arm_64_i8mm'     = 'i8mm'
    }
    # Two passes over the same file, each with its own floor: every arm_64
    # ukernel C TU gets -Dasm=__asm__ (15 measured; floor 10), the five feature
    # kernels upstream lists (fullfp16/fp16fml/bf16/dotprod/i8mm) get their
    # -march (floor 5 -- the pre-fix state tags 0, exactly what must trip).
    $ireeNinja = Join-Path $buildDir 'build.ninja'
    $isArm64Uk = { param($line) $line -match 'ukernel[\\/]arch[\\/]arm_64[\\/]' -and $line -match '\.c\.obj' }
    [void](Add-NinjaPerTuFlags -NinjaFile $ireeNinja -Label 'IREE arm_64 ukernel (asm keyword)' -Floor 10 -AlreadyTaggedPattern '-Dasm=__asm__' -Select {
        param($line) if (& $isArm64Uk $line) { '-Dasm=__asm__' } else { '' }
    })
    [void](Add-NinjaPerTuFlags -NinjaFile $ireeNinja -Label 'IREE arm_64 ukernel feature' -Floor 5 -AlreadyTaggedPattern 'armv8\.2-a' -Select {
        param($line)
        if (& $isArm64Uk $line) {
            foreach ($tok in $ireeUkFeatureMap.Keys) { if ($line -match "$tok\.c\.obj") { return "/clang:-march=armv8.2-a+$($ireeUkFeatureMap[$tok])" } }
        }
        return ''
    })
}

Write-Host 'Building IREE (LLVM in-tree -- this may take 60-120 minutes)...'
# Persistent log (backlog #43): a 60-120 min build whose log used to die with
# the failed solve, leaving only a 50-line tail as the entire diagnosis.
$buildLog = Get-PersistentBuildLogPath -Name 'iree-build.log' -FallbackDir $buildDir
Invoke-NinjaBuildWithRetry -BuildDir $buildDir -RetryJobs 1 -MemGBPerJob 2 -LogFile $buildLog -Install -InstallConfig $BuildType
# Hit-rate evidence on STDERR - survives the 2MiB step-log clip (backlog #3).
Write-SccacheStatsToStderr -Advanced -RequireRemote

# Native gate: a REAL compile+run through the installed tools, not an
# existence check (Server Core taught us binaries can exist and still not run).
$ireeCompile = Join-Path $ireeInstallDir 'bin\iree-compile.exe'
$ireeRun     = Join-Path $ireeInstallDir 'bin\iree-run-module.exe'
# Cross lane: the compiler is OFF by design, so only the runtime tool is required.
$ireeRequiredTools = if ($ireeCross) { @($ireeRun) } else { @($ireeCompile, $ireeRun) }
foreach ($tool in $ireeRequiredTools) {
    if (-not (Test-Path $tool)) { throw "IREE install incomplete: $tool missing" }
}
# ONE test module for both gates (native + python); MLIR is whitespace-
# insensitive, so the python gate embeds the same text collapsed to one line.
$gateMlir = @'
func.func @abs(%input : tensor<f32>) -> (tensor<f32>) {
  %result = math.absf %input : tensor<f32>
  return %result : tensor<f32>
}
'@
if ($ireeCross) {
    # Static gate: nothing installed here can execute on this host, but the
    # failure this gate exists for ("a host tool leaked into the target
    # install", or "nothing was installed at all") is fully detectable from
    # the PE headers. The functional compile+run proof is deferred to the
    # native arm64 validation job (docs/windows-cross-builds.md).
    $ireeBinCount = Assert-DirectoryTargetArch -Path (Join-Path $ireeInstallDir 'bin') -Include @('*.exe', '*.dll') -MinCount 1 -Context 'IREE cross (a host tool leaked into the target install?)'
    $absentComponent = if ($pythonBindings -eq 'ON') { 'iree-compile.exe and the iree.compiler python package' } else { 'iree-compile.exe and the iree.compiler / iree.runtime python packages' }
    [void](Write-AbsentOnCrossMarker -Root $ireeInstallDir -Component $absentComponent -FileName 'COMPILER-ABSENT-ON-ARM64.txt' -Reason @(
        'The compiler needs TARGET-arch LLVM libraries (an LLVM cross-built for aarch64-windows; backlog #116/#133) -- not attempted.',
        $(if ($pythonBindings -eq 'ON') { 'The iree.runtime python package IS built for the target (#133) and staged as a win_arm64 wheel in C:\runtime\wheels; only iree.compiler is missing.' } else { 'The python packages were not built on this pass (no target CPython import lib or -SkipPython).' }),
        'bin\ carries the runtime tools (iree-run-module & co.), lib\ the runtime libraries, include\ the headers.'
    ))
    Write-Host ('iree static gate OK (cross lane): {0} target binaries under bin\, all PE machine 0x{1:X4}; iree-compile + python ABSENT by design (#116)' -f $ireeBinCount, (Get-PeMachineType))
} else {
$mlirPath = Join-Path $env:TEMP 'iree-gate.mlir'
$vmfbPath = Join-Path $env:TEMP 'iree-gate.vmfb'
$gateMlir | Set-Content -Path $mlirPath -Encoding ascii
[void](Invoke-ShieldedNative -Label 'iree-compile gate' -CommandLine """$ireeCompile"" --iree-hal-target-backends=llvm-cpu ""$mlirPath"" -o ""$vmfbPath""")
$runOut = (Invoke-ShieldedNative -Label 'iree-run-module gate' -CommandLine """$ireeRun"" --module=""$vmfbPath"" --device=local-task --function=abs --input=f32=-5") | Out-String
if ($runOut -notmatch 'f32=5') { throw 'iree-run-module gate failed (abs(-5) != 5)' }
Write-Host 'iree native gate OK (llvm-cpu compile + local-task run, abs(-5)=5)'
Remove-Item $mlirPath, $vmfbPath -Force -ErrorAction SilentlyContinue
}

# Python wheels: with IREE_BUILD_PYTHON_BINDINGS=ON the build tree synthesizes
# pip-installable packages at <build>/compiler and <build>/runtime that reuse
# the ninja-built artifacts (the documented dev-install path). --no-build-isolation
# keeps pip inside this env so the wheel packs existing objects instead of
# re-running the whole LLVM build in an isolated tree.
if ($pythonBindings -eq 'ON') {
    # IREE's CleanEggInfo cmdclass deletes the egg-info dir that the SAME
    # wheel build just created (its stale-metadata guard misfires on the
    # Windows path layout) and setuptools then dies with 'Cannot update time
    # stamp of directory ... egg-info' (spike round 8). The guard only
    # protects REUSED trees; this tree is pristine every build, so neutralize
    # the rmtree. Generated-file edit by policy (like ffmpeg's config.mak):
    # these setup.py files are synthesized into the build tree at configure.
    foreach ($setupPy in @((Join-Path $buildDir 'compiler\setup.py'), (Join-Path $buildDir 'runtime\setup.py'))) {
        if (Test-Path $setupPy) {
            $content = [System.IO.File]::ReadAllText($setupPy)
            $patched = $content -replace 'shutil\.rmtree\(d, ignore_errors=True\)', 'print(f"kataglyphis: keeping fresh egg-info {d}")'
            if ($patched -ne $content) {
                [System.IO.File]::WriteAllText($setupPy, $patched)
                Write-Host "Neutralized CleanEggInfo rmtree in $setupPy"
            }
        }
    }
    if ($ireeCross) {
        # Cross lane (#133): ONLY the runtime package exists (compiler OFF), and
        # it is built + STAGED, never installed or imported here. The build tree's
        # synthesized runtime/setup.py is IS_CONFIGURED (source/binary dirs baked
        # in): its build_py step runs `cmake --build` (a no-op on the finished
        # tree) and installs the IreePythonPackage-runtime component, then
        # bdist_wheel zips it -- --plat-name via -CrossStage stamps win_arm64 and
        # Assert-WheelTargetArch PE-checks _runtime*.pyd and the runtime DLLs.
        $pkgDir = Join-Path $buildDir 'runtime'
        if (-not (Test-Path (Join-Path $pkgDir 'setup.py'))) { throw "IREE python package dir missing setup.py: $pkgDir" }
        Write-Host 'Building IREE runtime wheel for the target (cross lane; compiler package ABSENT by design)...'
        Invoke-PythonWheelBuild -Python $py -WorkingDir $pkgDir -Arguments 'setup.py bdist_wheel' -ModuleName 'iree.runtime' -NoDeps -CrossStage | Out-Null
    } else {
    foreach ($pkg in @(
        @{ Dir = 'compiler'; Module = 'iree.compiler' },
        @{ Dir = 'runtime';  Module = 'iree.runtime' }
    )) {
        $pkgDir = Join-Path $buildDir $pkg.Dir
        if (-not (Test-Path (Join-Path $pkgDir 'setup.py'))) {
            throw "IREE python package dir missing setup.py: $pkgDir"
        }
        $wheelOut = Join-Path $SourceDir "dist-$($pkg.Dir)"
        Write-Host "Building IREE $($pkg.Dir) wheel (reusing the ninja build tree)..."
        Invoke-CpythonPip -Python $py -Arguments @('wheel', $pkgDir, '--no-deps', '--no-build-isolation', '-w', $wheelOut)
        Install-StagedPythonWheel -Python $py -SourceDir $wheelOut -ModuleName $pkg.Module | Out-Null
    }
    }
    # End-to-end binding gate: compile MLIR through the python compiler API and
    # execute it on the python runtime -- proves the two wheels interoperate.
    # Native lane only: on the cross lane there is no compiler package and the
    # runtime .pyd is aarch64 -- nothing here could import it (the staged wheel
    # was PE- and name-checked instead).
    if (-not $ireeCross) {
    $pyGate = Join-Path $env:TEMP 'iree-py-gate.py'
    @"
import numpy as np
import iree.compiler.tools as tools
import iree.runtime as rt
MLIR = '$($gateMlir -replace '\s+', ' ')'
vmfb = tools.compile_str(MLIR, target_backends=["llvm-cpu"])
module = rt.load_vm_flatbuffer(vmfb, driver="local-task")
# tensor<f32> inputs must be numpy arrays -- a bare python float dies in the
# VM marshaling layer with FAILED_PRECONDITION (list.c), spike round 10.
value = float(module.abs(np.asarray(-5.0, dtype=np.float32)).to_host())
assert value == 5.0, value
print("iree python gate OK: abs(-5) =", value)
"@ | Set-Content -Path $pyGate -Encoding ascii
    [void](Invoke-ShieldedNative -Label 'IREE python end-to-end gate' -CommandLine """$($py.Exe)"" ""$pyGate""")
    Remove-Item $pyGate -Force -ErrorAction SilentlyContinue
    }
}

Remove-SourceBuildTree -Path $SourceDir

# QNN runtime staging (#121): stage the backend DLLs beside the IREE install.
if ($qnnSdk) { [void](Copy-QnnRuntime -Sdk $qnnSdk -OrtInstallDir $ireeInstallDir) }

Write-Host '=== IREE source build completed ==='
Write-Host "Artifacts at: $ireeInstallDir"

# Explicit success -- see Complete-SourceBuild in WindowsSourceBuild.Common.psm1 for why.
exit 0