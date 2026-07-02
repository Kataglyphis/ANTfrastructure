# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Get-SourceBuildVersion {
    param(
        [string]$Value = '',
        [string[]]$EnvironmentVariables = @(),
        [string]$DefaultValue = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }

    foreach ($envVar in $EnvironmentVariables) {
        if (-not [string]::IsNullOrWhiteSpace($envVar)) {
            $envValue = [Environment]::GetEnvironmentVariable($envVar)
            if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
        }
    }

    return $DefaultValue
}

function Invoke-GitClone {
    param(
        [Parameter(Mandatory)]
        [string]$RepoUrl,
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [string]$Branch = '',
        [string]$Tag = '',
        [switch]$Recursive,
        [switch]$SkipOnFailure,
        [int]$Depth = 1
    )

    if (Test-Path $SourceDir) { Remove-Item $SourceDir -Recurse -Force }

    $ref = if ($Tag) { $Tag } else { $Branch }
    if ([string]::IsNullOrWhiteSpace($ref)) { throw 'Either -Branch or -Tag is required' }

    $gitArgs = @('clone')
    if ($Recursive) { $gitArgs += '--recursive' }
    $gitArgs += '--branch', $ref
    $gitArgs += '--depth', $Depth
    $gitArgs += $RepoUrl, $SourceDir

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # GIT_SSL_NO_VERIFY is honored if set by the caller's environment (e.g. behind a
    # TLS-intercepting proxy) but is no longer forced on for every clone.
    $env:GIT_TERMINAL_PROMPT = '0'

    $null = & git @gitArgs 2>&1
    $cloneExit = $LASTEXITCODE

    $ErrorActionPreference = $oldEAP

    if ($cloneExit -ne 0) {
        if ($SkipOnFailure) {
            Write-Host "WARNING: git clone failed (exit $cloneExit) - skipped"
            return $false
        }
        throw "git clone failed (exit $cloneExit): $RepoUrl $ref"
    }
    return $true
}

function Invoke-CmakeConfigure {
    param(
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [Parameter(Mandatory)]
        [string]$InstallPrefix,
        [string]$Generator = 'Ninja',
        [string]$Platform = '',
        [string]$Toolset = '',
        [string]$BuildType = 'Release',
        [string]$CCompiler = 'clang-cl',
        [string]$CxxCompiler = 'clang-cl',
        [string]$Linker = 'lld-link',
        [string]$Archiver = 'llvm-lib',
        [string[]]$ExtraArgs = @(),
        [switch]$SkipOnFailure
    )

    New-Item -Path $BuildDir -ItemType Directory -Force | Out-Null
    New-Item -Path $InstallPrefix -ItemType Directory -Force | Out-Null

    $cmakeArgs = @('-S', $SourceDir, '-B', $BuildDir, "-DCMAKE_INSTALL_PREFIX=$InstallPrefix")

    if ($Generator) {
        $cmakeArgs += '-G', $Generator
        if ($Platform) { $cmakeArgs += '-A', $Platform }
        if ($Toolset) { $cmakeArgs += '-T', $Toolset }
    }

    if ($BuildType) { $cmakeArgs += "-DCMAKE_BUILD_TYPE=$BuildType" }
    if ($CCompiler) { $cmakeArgs += "-DCMAKE_C_COMPILER=$CCompiler" }
    if ($CxxCompiler) { $cmakeArgs += "-DCMAKE_CXX_COMPILER=$CxxCompiler" }
    if ($Linker) { $cmakeArgs += "-DCMAKE_LINKER=$Linker" }
    if ($Archiver) { $cmakeArgs += "-DCMAKE_AR=$Archiver" }

    # sccache only pays off with a REMOTE backend: without BuildKit cache mounts a
    # container-local disk cache dies with the layer (zero cross-build hits) while
    # bloating the image. Enable the launcher only when a remote is configured
    # (pass -SccacheEndpoint to windows/build.ps1 / see docs/windows-builds.md).
    $sccacheRemoteConfigured = -not [string]::IsNullOrWhiteSpace($env:SCCACHE_WEBDAV_ENDPOINT) -or
        -not [string]::IsNullOrWhiteSpace($env:SCCACHE_BUCKET) -or
        -not [string]::IsNullOrWhiteSpace($env:SCCACHE_REDIS_ENDPOINT)
    if ($sccacheRemoteConfigured) {
        $sccacheCmd = Get-Command sccache.exe -ErrorAction SilentlyContinue
        if ($sccacheCmd) {
            if (-not $env:SCCACHE_MAX_JOBS) { $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString() }
            $cmakeArgs += "-DCMAKE_C_COMPILER_LAUNCHER:FILEPATH=$($sccacheCmd.Source)"
            $cmakeArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER:FILEPATH=$($sccacheCmd.Source)"
            Write-Host "sccache enabled at: $($sccacheCmd.Source) (remote backend, max $env:SCCACHE_MAX_JOBS jobs)"
        }
    } else {
        Write-Host 'sccache disabled (no remote backend configured; a container-local cache would only bloat layers)'
    }

    if ($ExtraArgs.Count -gt 0) { $cmakeArgs += $ExtraArgs }

    Write-Host "CMake configure: $($cmakeArgs -join ' ')"
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) {
        if ($SkipOnFailure) {
            Write-Host "WARNING: CMake configuration failed - skipped"
            return $false
        }
        throw "CMake configuration failed"
    }
    return $true
}

function Invoke-CmakeBuild {
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [string]$Config = 'Release',
        [switch]$Install,
        [switch]$SkipOnFailure,
        [string]$LogFile = ''
    )

    # Bounded parallelism: bare `--parallel` lets ninja run cores+2 jobs, which can
    # OOM a memory-capped container (MEMORY_LIMIT_GB / BUILD_JOBS scale this down).
    $jobs = Get-BuildJobCount -MemGBPerJob 2
    Write-Host "Building with $jobs parallel jobs (this may take 15-120 minutes)..."
    if ($LogFile) {
        & cmake --build $BuildDir --config $Config --parallel $jobs 2>&1 | Tee-Object -FilePath $LogFile | Out-Null
    } else {
        & cmake --build $BuildDir --config $Config --parallel $jobs
    }
    if ($LASTEXITCODE -ne 0) {
        if ($LogFile -and (Test-Path $LogFile)) {
            Write-Host "`n=== BUILD LOG ERRORS ==="
            Select-String -Path $LogFile -Pattern 'FAILED:|error:' -SimpleMatch | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
            Write-Host "--- last 20 lines ---"
            Get-Content $LogFile -Tail 20 | ForEach-Object { Write-Host $_ }
        }
        if ($SkipOnFailure) {
            Write-Host "WARNING: Build failed - skipped"
            return $false
        }
        throw "Build failed"
    }

    if ($Install) {
        Write-Host "Installing..."
        & cmake --install $BuildDir --config $Config
        if ($LASTEXITCODE -ne 0) { throw "Install failed" }
    }
    return $true
}

function Get-CudaRoot {
    <#
    .SYNOPSIS
        Returns the CUDA root directory from environment variables.
    .DESCRIPTION
        Checks $env:CUDA_ROOT first, then $env:CUDA_PATH, returns $null if neither is set.
        This is the SINGLE source of truth for CUDA detection across all build scripts.
    #>
    if ($env:CUDA_ROOT -and (Test-Path $env:CUDA_ROOT)) { return $env:CUDA_ROOT }
    if ($env:CUDA_PATH -and (Test-Path $env:CUDA_PATH)) { return $env:CUDA_PATH }
    return $null
}

function Enter-VsDevCmdEnvironment {
    param(
        [string]$Arch = 'amd64',
        [string]$HostArch = 'amd64',
        [string]$VsDevCmdPath = ''
    )

    # Resolve VsDevCmd.bat via vswhere (robust across VS versions, not hardcoded to VS 18).
    if ([string]::IsNullOrWhiteSpace($VsDevCmdPath)) {
        $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at $vswhere - Visual Studio Installer missing" }
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ([string]::IsNullOrWhiteSpace($vsPath)) { throw 'No Visual Studio installation with VC Tools x86/x64 found via vswhere' }
        $VsDevCmdPath = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
    }
    if (-not (Test-Path $VsDevCmdPath)) { throw "VsDevCmd.bat not found at: $VsDevCmdPath" }

    cmd /c """$VsDevCmdPath"" -arch=$Arch -host_arch=$HostArch && set" | ForEach-Object {
        if ($_ -match '^(.*?)=(.*)$') {
            Set-Item -Path "Env:$($Matches[1])" -Value $Matches[2] -ErrorAction SilentlyContinue
        }
    }
}

function Get-VsInstallPath {
    <#
    .SYNOPSIS
        Resolves the latest Visual Studio installation path via vswhere.
    .OUTPUTS
        [string] The VS installation path (e.g. C:\Program Files\Microsoft Visual Studio\18\BuildTools).
    #>
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at $vswhere - Visual Studio Installer missing" }
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ([string]::IsNullOrWhiteSpace($vsPath)) { throw 'No Visual Studio installation with VC Tools x86/x64 found via vswhere' }
    return $vsPath
}

function Get-MsvcToolsRoot {
    <#
    .SYNOPSIS
        Resolves the latest MSVC tools directory (include/lib headers) via vswhere.
    .OUTPUTS
        [string] Full path to the MSVC tools version directory (e.g. ...\VC\Tools\MSVC\14.51.32910).
    #>
    $vsPath = Get-VsInstallPath
    $msvcRoot = Join-Path $vsPath 'VC\Tools\MSVC'
    $dirs = Get-ChildItem -Path $msvcRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    if (-not $dirs) { throw "No MSVC toolchain found under $msvcRoot" }
    return $dirs[0].FullName
}

function Resolve-LlvmArchiver {
    <#
    .SYNOPSIS
        Resolves the full path to llvm-lib.exe for use as CMAKE_AR in clang-cl builds.
    .DESCRIPTION
        CMake's default CMAKE_AR resolution can find llvm-lib incorrectly (e.g. C:\llvm-lib).
        This returns the full path so it can be passed via -DCMAKE_AR:FILEPATH=...
    .OUTPUTS
        [string] Full path to llvm-lib.exe, or $null if not found.
    #>
    $llvmLib = (Get-Command 'llvm-lib' -ErrorAction SilentlyContinue).Source
    if (-not $llvmLib) { $llvmLib = (Get-Command 'llvm-lib.exe' -ErrorAction SilentlyContinue).Source }
    return $llvmLib
}

function Copy-CpythonPyConfigHeader {
    <#
    .SYNOPSIS
        Copies CPython's PC\pyconfig.h to Include\pyconfig.h (source build puts it in PC/, not Include/).
    .DESCRIPTION
        The source-built CPython generates pyconfig.h under PC\ but many build systems
        expect it under Include\. This copies it if the destination is missing.
    .PARAMETER CpythonDir
        Path to the CPython source checkout (default: $env:TEMP_DIR\cpython).
    #>
    param(
        [string]$CpythonDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $src = Join-Path $CpythonDir 'PC\pyconfig.h'
    $dst = Join-Path $CpythonDir 'Include\pyconfig.h'
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
        Copy-Item $src $dst -Force
        Write-Host "Copied pyconfig.h to Include/ (from $src)"
    }
}

function Get-SourceBuildPython {
    <#
    .SYNOPSIS
        Returns paths for the source-built CPython interpreter (built in the toolchain layer).
    .OUTPUTS
        [hashtable] @{ Exe=...; Include=...; LibDir=...; Lib=... }
    .PARAMETER CpythonDir
        Path to the CPython source checkout (default: $env:TEMP_DIR\cpython).
    #>
    param(
        [string]$CpythonDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($CpythonDir)) { $CpythonDir = Join-Path $env:TEMP_DIR 'cpython' }
    $exe = Join-Path $CpythonDir 'PCbuild\amd64\python.exe'
    $include = Join-Path $CpythonDir 'Include'
    $libDir = Join-Path $CpythonDir 'PCbuild\amd64'
    $lib = if (Test-Path (Join-Path $libDir 'python314.lib')) { Join-Path $libDir 'python314.lib' } else { Join-Path $libDir 'python3.lib' }
    return @{ Exe = $exe; Include = $include; LibDir = $libDir; Lib = $lib }
}

function Replace-CppKeywordAlternatives {
    <#
    .SYNOPSIS
        Replaces C++ keyword alternatives (and/or/not) with symbolic operators (&&/||/!) for clang-cl.
    .DESCRIPTION
        clang-cl does not support the ISO-C++ keyword alternatives `and`, `or`, `not`
        (they require including <iso646.h> on MSVC). This in-place patches a source file
        to replace all word-boundary occurrences with symbolic operators.
    .PARAMETER Path
        File to patch in-place.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    if (-not (Test-Path $Path)) { return }
    $content = [System.IO.File]::ReadAllText($Path)
    $patched = $content -replace '\bor\b', '||' -replace '\band\b', '&&' -replace '\bnot\b', '!'
    if ($content -ne $patched) {
        [System.IO.File]::WriteAllText($Path, $patched)
        Write-Host "Patched keyword alternatives in: $Path"
    }
}

function Update-NinjaFile {
    <#
    .SYNOPSIS
        Strips MSVC-only flags from a build.ninja file that clang-cl errors on.
    .DESCRIPTION
        clang-cl doesn't understand several MSVC-only flags (/experimental:external,
        /arch:, /bigobj, -WX, /Qspectre). This patches the generated build.ninja in-place
        after CMake configure but before ninja build.
    .PARAMETER NinjaFile
        Path to the build.ninja file.
    .PARAMETER StripPatterns
        Array of regex patterns to remove from build.ninja.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$NinjaFile,
        [string[]]$StripPatterns = @()
    )
    if (-not (Test-Path $NinjaFile)) { return }
    $text = [System.IO.File]::ReadAllText($NinjaFile)
    $original = $text
    foreach ($pattern in $StripPatterns) {
        $text = $text -replace $pattern, ''
    }
    $text = $text -replace '  +', ' '
    if ($text -ne $original) {
        [System.IO.File]::WriteAllText($NinjaFile, $text)
        Write-Host "Patched build.ninja for clang-cl compatibility: $NinjaFile"
    }
}

function Invoke-SourcePatch {
    <#
    .SYNOPSIS
        Idempotently applies a patch file to source code using git apply / patch.exe.
    .DESCRIPTION
        Mirrors linux/scripts/01-core/apply-patch.sh behaviour:
          1. If the patch is already applied (reverse-apply check passes), SKIP.
          2. If the patch applies cleanly (forward check passes), APPLY.
          3. Otherwise, throw a loud error.

        Prefers `git apply` when SourceDir is a git working tree; falls back to
        `patch.exe -p1` for extracted tarballs (Patch.exe ships with Git for Windows).
        The patch file is a standard unified diff with a/ b/ prefix.
    .PARAMETER PatchFile
        Path to the .patch file to apply.
    .PARAMETER SourceDir
        Root directory of the source tree to patch (cwd during apply).
    .PARAMETER Strip
        Number of leading path components to strip (default 1, strips a/).
    .PARAMETER IgnoreWhitespace
        If set, passes --ignore-whitespace to git apply (for whitespace drift).
    .PARAMETER Description
        Optional human-friendly label for log output (defaults to patch file name).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PatchFile,
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [int]$Strip = 1,
        [switch]$IgnoreWhitespace,
        [string]$Description = ''
    )

    if (-not (Test-Path $PatchFile)) { throw "Patch file not found: $PatchFile" }
    if (-not (Test-Path $SourceDir)) { throw "Source directory not found: $SourceDir" }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $PatchFile -Leaf }

    $pFlag = "-p$Strip"
    $wsFlag = @()
    if ($IgnoreWhitespace) { $wsFlag += '--ignore-whitespace' }

    # Detect git repo: check .git directory first, then try git rev-parse with
    # suppressed stderr (fatal: not a git repository) that PS 5.1 treats as an
    # ErrorRecord even under $ErrorActionPreference = 'Continue'.
    $isGitRepo = $false
    if (Test-Path (Join-Path $SourceDir '.git')) {
        $isGitRepo = $true
    } else {
        $gitErr = $null
        $null = & git -C $SourceDir rev-parse --git-dir 2>$null
        if ($LASTEXITCODE -eq 0) { $isGitRepo = $true }
    }

    Push-Location $SourceDir
    try {
        # Suppress $ErrorActionPreference for git/patch native commands: in PS 5.1,
        # stderr output from git apply (e.g. "patch failed: softmax.h:41") is treated
        # as a PowerShell ErrorRecord that triggers `$ErrorActionPreference = 'Stop'`
        # even when `2>$null` is used. We rely on `$LASTEXITCODE` instead.
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        Write-Host "Applying patch: $Description to $SourceDir"

        if ($isGitRepo) {
            # 1. Already applied? (reverse-check)
            $null = & git apply --reverse --check $pFlag $wsFlag $PatchFile 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  SKIP: $Description (already applied)"
                return
            }
            # 2. Forward apply
            $null = & git apply --check $pFlag $wsFlag $PatchFile 2>&1
            if ($LASTEXITCODE -eq 0) {
                $null = & git apply $pFlag --verbose $wsFlag $PatchFile 2>&1
                if ($LASTEXITCODE -ne 0) { throw "git apply failed (exit $LASTEXITCODE): $PatchFile" }
                Write-Host "  [OK] $Description applied via git"
                return
            }
        } else {
            # Fallback: patch.exe (ships with Git for Windows at $GIT_USRBIN\patch.exe)
            $patchExe = (Get-Command patch.exe -ErrorAction SilentlyContinue).Source
            if (-not $patchExe) { throw "patch.exe not found and source is not a git repo -- cannot apply $PatchFile" }

            # 1. Already applied? (reverse dry-run)
            $null = & $patchExe $pFlag --dry-run --reverse $PatchFile 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  SKIP: $Description (already applied)"
                return
            }
            # 2. Forward dry-run
            $null = & $patchExe $pFlag --dry-run $PatchFile 2>&1
            if ($LASTEXITCODE -eq 0) {
                $null = & $patchExe $pFlag $PatchFile 2>&1
                if ($LASTEXITCODE -ne 0) { throw "patch.exe failed (exit $LASTEXITCODE): $PatchFile" }
                Write-Host "  [OK] $Description applied via patch.exe"
                return
            }
        }

        $ErrorActionPreference = $oldEAP

        # 3. Patch does not apply cleanly
        $msg = "ERROR: $Description -- patch does not apply cleanly to $SourceDir"
        Write-Host $msg
        Write-Host "       The upstream source may have changed. Regenerate the .patch file."
        Write-Host "--- patch file: $PatchFile ---"
        Get-Content $PatchFile -TotalCount 40 | ForEach-Object { Write-Host "       $_" }
        Write-Host '       ...'
        throw $msg
    } finally {
        $ErrorActionPreference = $oldEAP
        Pop-Location
    }
}

function Initialize-SourceBuildEnvironment {
    <#
    .SYNOPSIS
        Standard preamble for every build-*-from-source.ps1 script.
    .DESCRIPTION
        Sets StrictMode + Stop error action, imports this module, and resolves
        a default InstallDir. Call at the top of each build script instead of
        duplicating the 4-line boilerplate.
    .PARAMETER InstallDir
        Passed-through InstallDir value (empty -> 'C:\runtime').
    .OUTPUTS
        [string] The resolved InstallDir.
    #>
    param(
        [string]$InstallDir = ''
    )
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = 'C:\runtime' }
    return $InstallDir
}

function Get-WindowsX86SimdFlags {
    <#
    .SYNOPSIS
        Returns the canonical x86 SIMD /feature flag string for clang-cl on Windows.
    .DESCRIPTION
        Single source of truth for the SIMD flag set used by both OpenCV and ONNX
        Runtime Windows builds. AVX2 baseline + AVX-512 + AMX + popcnt/aes/pclmul.
    .OUTPUTS
        [string] Space-separated /clang:... flags (no leading space).
    #>
    return '/clang:-mavx2 /clang:-mavx /clang:-mfma /clang:-mssse3 /clang:-msse3 /clang:-msse4.1 /clang:-msse4.2 /clang:-mpopcnt'
}

function Get-WindowsX86Avx512Flags {
    <#
    .SYNOPSIS
        Returns the AVX-512 + AMX sub-flag string used by ONNX Runtime.
    .OUTPUTS
        [string] Space-separated /clang:... flags covering AVX-512 + AMX.
    #>
    return '/clang:-mavx512f /clang:-mavx512cd /clang:-mavx512bw /clang:-mavx512dq /clang:-mavx512vl /clang:-mavx512vnni /clang:-mavx512bf16 /clang:-mavx512fp16 /clang:-mavxvnni /clang:-mamx-int8 /clang:-mamx-tile /clang:-mamx-bf16'
}

function Resolve-TensorRtRoot {
    <#
    .SYNOPSIS
        Resolves the canonical TensorRT install root from $env:TENSORRT_ROOT.
    .DESCRIPTION
        Looks for a `TensorRT-*` versioned subdirectory below the env var; falls
        back to the env value itself when only a flat layout is present. Returns
        $null if TENSORRT_ROOT is unset or doesn't exist on disk.
    .OUTPUTS
        [string] Resolved TensorRT root path (or $null).
    #>
    $trtRoot = $env:TENSORRT_ROOT
    if (-not $trtRoot) { return $null }
    if (-not (Test-Path $trtRoot)) { return $null }
    # An empty root means the extract stage ran without a TensorRT zip (graceful
    # skip) — treat as not installed so builds don't enable a hollow TensorRT EP.
    if (-not (Get-ChildItem $trtRoot -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $null }
    $trtVerDir = Get-ChildItem "$trtRoot\TensorRT-*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($trtVerDir) { return $trtVerDir.FullName }
    return $trtRoot
}

function Get-GpuEnvironment {
    <#
    .SYNOPSIS
        Detect GPU/CUDA/cuDNN/TensorRT/ROCm environment once for all GPU-aware build scripts.
    .DESCRIPTION
        Single source of truth for GPU detection across onnx, opencv, litert,
        litert-lm, tvm, gstreamer. Returns a hashtable of resolved paths + a
        GpuType discriminator ('nvidia' / 'amd' / 'cpu'). Per-script CMake args
        remain in the build scripts (each library has its own flag names like
        `Donnxruntime_USE_TENSORRT` vs `DUSE_CUDA`) -- the helper only resolves
        *environment paths*, not project-specific flags.
    .OUTPUTS
        [hashtable] @{ GpuType='nvidia'|'amd'|'cpu'; CudaRoot=$string|null;
                       CudnnRoot=$string|null; TensorRtRoot=$string|null;
                       CudaBin=$string|null }
    #>
    $gpuType = if ($env:GPU_TYPE) { $env:GPU_TYPE.ToLowerInvariant() } else { 'cpu' }
    $cudaRoot = Get-CudaRoot
    $cudnnRoot = $env:CUDNN_ROOT
    $trtRoot = Resolve-TensorRtRoot
    $cudaBin = if ($cudaRoot) { Join-Path $cudaRoot 'bin' } else { $null }

    if ($gpuType -eq 'nvidia' -and $cudaRoot -and (Test-Path $cudaRoot)) {
        # Prepend CUDA bin to PATH so nvcc / cudnn DLLs are discoverable by the
        # single build script that needs PATH-based lookup (FFmpeg auto-detect).
        if ($cudaBin -and (Test-Path $cudaBin) -and ($env:PATH -notlike "*$cudaBin*")) {
            $env:PATH = "$cudaBin;$env:PATH"
        }
        if ($env:CUDA_PATH -eq $null -or $env:CUDA_PATH -ne $cudaRoot) { $env:CUDA_PATH = $cudaRoot }
        if ($env:CUDA_HOME -eq $null -or $env:CUDA_HOME -ne $cudaRoot) { $env:CUDA_HOME = $cudaRoot }
    }

    return @{
        GpuType       = $gpuType
        CudaRoot      = $cudaRoot
        CudnnRoot     = $cudnnRoot
        TensorRtRoot  = $trtRoot
        CudaBin       = $cudaBin
    }
}

function Install-CpythonPip {
    <#
    .SYNOPSIS
        Idempotently bootstraps pip into the source-built CPython (toolchain layer).
    .DESCRIPTION
        The source-built interpreter ships without pip. With the media build split
        into parallel branches, every script that needs pip (GenAI, TVM wheel,
        GStreamer's meson install) must be able to bootstrap it independently —
        no ordering assumption between branches. Skips instantly if pip is present.
    .PARAMETER Python
        Hashtable from Get-SourceBuildPython (resolved automatically if omitted).
    #>
    param(
        [hashtable]$Python = $null
    )
    if (-not $Python) { $Python = Get-SourceBuildPython }
    if (-not (Test-Path $Python.Exe)) { throw "Source-built Python not found at $($Python.Exe)" }
    # cmd.exe avoids PowerShell treating pip's stderr chatter as errors
    cmd.exe /c """$($Python.Exe)"" -m pip --version >nul 2>&1"
    if ($LASTEXITCODE -eq 0) { Write-Host 'pip already installed'; return }
    Write-Host 'Bootstrapping pip via get-pip.py...'
    $pipScript = Join-Path $env:TEMP 'get-pip.py'
    Invoke-WebRequest -Uri 'https://bootstrap.pypa.io/get-pip.py' -OutFile $pipScript -UseBasicParsing
    cmd.exe /c """$($Python.Exe)"" ""$pipScript"" --quiet 2>&1"
    if ($LASTEXITCODE -ne 0) { throw 'get-pip.py failed' }
    Remove-Item $pipScript -Force -ErrorAction SilentlyContinue
}

function Remove-SourceBuildTree {
    <#
    .SYNOPSIS
        Removes source/build trees after install so they don't bloat the Docker layer.
    .DESCRIPTION
        Each build-*-from-source.ps1 script clones + builds under C:\temp and installs
        to C:\runtime. Without cleanup the clone/build tree (often several GB) is
        committed into the image layer. Call this after a successful install.
        Set KEEP_BUILD_ARTIFACTS=1 to keep the trees for debugging.
    .PARAMETER Path
        One or more directories to remove.
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )
    if ($env:KEEP_BUILD_ARTIFACTS -eq '1') {
        Write-Host "KEEP_BUILD_ARTIFACTS=1 - keeping: $($Path -join ', ')"
        return
    }
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path $p)) { continue }
        # Never delete from inside the tree being removed
        if ((Get-Location).Path -like "$p*") { Set-Location (Split-Path $p -Parent) }
        Write-Host "Removing build tree: $p"
        # rd handles long paths and read-only .git objects more reliably than Remove-Item
        & cmd.exe /c "rd /s /q ""$p""" 2>$null
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BuildJobCount {
    <#
    .SYNOPSIS
        Returns a parallel job count scaled to available memory (min 2, max core count).
    .DESCRIPTION
        Heavy TUs (CUDA kernels, AVX-512 templates under clang-cl) can OOM a container
        at full -j<cores>. jobs = min(cores, memGB / MemGBPerJob), floor 2.
        Override explicitly with the BUILD_JOBS environment variable.
    .PARAMETER MemGBPerJob
        Estimated peak memory per compile job in GB (default 4; use 8 for
        CUDA/AVX-512-heavy builds like ONNX Runtime).
    #>
    param(
        [int]$MemGBPerJob = 4
    )
    if ($env:BUILD_JOBS -match '^\d+$') { return [int]$env:BUILD_JOBS }
    $cores = [Environment]::ProcessorCount
    $memGB = 0
    # Under process isolation Win32_OperatingSystem reports HOST memory, not the
    # container's --memory cap. The driver passes the cap as MEMORY_LIMIT_GB so
    # parallel branch builds don't collectively oversubscribe the host.
    if ($env:MEMORY_LIMIT_GB -match '^\d+$') {
        $memGB = [int]$env:MEMORY_LIMIT_GB
    } else {
        try {
            $memGB = [int][Math]::Floor((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize / 1MB)
        } catch { }
    }
    if ($memGB -le 0) { return $cores }
    return [Math]::Max(2, [Math]::Min($cores, [int][Math]::Floor($memGB / $MemGBPerJob)))
}

function Initialize-ToolchainPythonEnvironment {
    <#
    .SYNOPSIS
        Load VsDevCmd (MSVC tools), copy CPython pyconfig.h, resolve source-built CPython.
    .DESCRIPTION
        Canonical preamble for any build script that needs MSVC STL headers +
        the source-built CPython interpreter (built in the toolchain layer).
        Replaces the 3-line boilerplate duplicated (in different orders!) across
        build-onnx, build-onnx-genai, build-tvm.
    .PARAMETER Arch
        Target architecture passed to VsDevCmd (default 'amd64').
    .PARAMETER HostArch
        Host architecture passed to VsDevCmd (default 'amd64').
    .OUTPUTS
        [hashtable] Same as Get-SourceBuildPython: @{ Exe; Include; LibDir; Lib }.
    #>
    param(
        [string]$Arch = 'amd64',
        [string]$HostArch = 'amd64'
    )
    Enter-VsDevCmdEnvironment -Arch $Arch -HostArch $HostArch
    Copy-CpythonPyConfigHeader
    return Get-SourceBuildPython
}

Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Invoke-GitClone',
    'Invoke-CmakeConfigure',
    'Invoke-CmakeBuild',
    'Get-CudaRoot',
    'Enter-VsDevCmdEnvironment',
    'Get-MsvcToolsRoot',
    'Resolve-LlvmArchiver',
    'Copy-CpythonPyConfigHeader',
    'Get-SourceBuildPython',
    'Replace-CppKeywordAlternatives',
    'Update-NinjaFile',
    'Invoke-SourcePatch',
    'Initialize-SourceBuildEnvironment',
    'Initialize-ToolchainPythonEnvironment',
    'Remove-SourceBuildTree',
    'Get-BuildJobCount',
    'Install-CpythonPip',
    'Get-WindowsX86SimdFlags',
    'Get-WindowsX86Avx512Flags',
    'Get-GpuEnvironment',
    'Resolve-TensorRtRoot'
)
