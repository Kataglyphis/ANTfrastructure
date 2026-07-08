# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Get-SourceBuildVersion {
    param(
        [string]$Value = '',
        [string[]]$EnvironmentVariables = @(),
        [string]$DefaultValue = '',
        [switch]$StripVPrefix
    )

    $resolved = $DefaultValue
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $resolved = $Value
    } else {
        foreach ($envVar in $EnvironmentVariables) {
            if (-not [string]::IsNullOrWhiteSpace($envVar)) {
                $envValue = [Environment]::GetEnvironmentVariable($envVar)
                if (-not [string]::IsNullOrWhiteSpace($envValue)) { $resolved = $envValue; break }
            }
        }
    }

    # -StripVPrefix drops a leading 'v' (versions.env uses a v-prefix; scripts that build a git
    # tag re-add it themselves) so that strip lives here once instead of duplicated per script.
    if ($StripVPrefix) { $resolved = $resolved -replace '^v', '' }
    return $resolved
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
        Resolves a default InstallDir for build-*-from-source.ps1 scripts.
    .DESCRIPTION
        Returns InstallDir (defaulting to 'C:\runtime').

        WARNING - scope trap: the Set-StrictMode / $ErrorActionPreference below take
        effect ONLY inside this function's scope; PowerShell does NOT propagate them
        back to the calling script. Do NOT route a build script's preamble through
        this helper expecting it to set Stop-on-error there - the caller MUST declare
        its own `$ErrorActionPreference = 'Stop'` (and Set-StrictMode) at top level, as
        every build-*-from-source.ps1 already does. Collapsing that preamble into this
        call silently disables fail-fast and is a real regression, not dedup.
    .PARAMETER InstallDir
        Passed-through InstallDir value (empty -> 'C:\runtime').
    .OUTPUTS
        [string] The resolved InstallDir.
    #>
    param(
        [string]$InstallDir = ''
    )
    # Function-scoped only (see WARNING above) - kept so this helper itself fails fast.
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

function Get-CudaArchitectureList {
    <#
    .SYNOPSIS
        Returns the canonical CUDA architecture list (CMAKE_CUDA_ARCHITECTURES form).
    .DESCRIPTION
        Single source of truth is CUDA_ARCHITECTURES in versions.env (surfaced as an
        env var by the Dockerfiles / load-versions.ps1). Consumers decorate per build
        system — Windows clang-cl builds pass -Decoration '-real'.
    .PARAMETER Decoration
        Suffix appended to every architecture (e.g. '-real' -> '80-real;86-real;...').
    #>
    param(
        [string]$Decoration = ''
    )
    $archs = if (-not [string]::IsNullOrWhiteSpace($env:CUDA_ARCHITECTURES)) { $env:CUDA_ARCHITECTURES } else { '80;86;89;90' }
    if ($Decoration) {
        return (($archs -split ';' | Where-Object { $_ } | ForEach-Object { "$_$Decoration" }) -join ';')
    }
    return $archs
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

function Invoke-CpythonPip {
    <#
    .SYNOPSIS
        Run `python -m pip <args>` via cmd.exe so pip's stderr progress doesn't trip EAP=Stop.
    .DESCRIPTION
        The source-build scripts invoke pip through `cmd.exe /c` because pip writes progress
        to stderr, which under $ErrorActionPreference='Stop' would abort the script. This
        centralizes that idiom (and the $LASTEXITCODE check) so callers stop hand-rolling the
        triple-quote cmd string. Throws on a non-zero pip exit unless -Optional is set (then it
        warns and continues, e.g. the non-critical TVM Python wheel). Bootstrap pip first via
        Install-CpythonPip. `.`-relative installs honor the caller's current directory.
    .PARAMETER Python
        Hashtable from Get-SourceBuildPython / Initialize-ToolchainPythonEnvironment (uses .Exe).
    .PARAMETER Arguments
        Tokens after `-m pip`, e.g. @('install','cmake','ninja','--quiet').
    .PARAMETER Optional
        Warn instead of throw on a non-zero exit.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Python,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Optional
    )
    if (-not (Test-Path $Python.Exe)) { throw "Source-built Python not found at $($Python.Exe)" }
    $argLine = $Arguments -join ' '
    cmd.exe /c """$($Python.Exe)"" -m pip $argLine 2>&1"
    $exit = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
    if ($exit -ne 0) {
        $msg = "pip $argLine failed (exit $exit)"
        if ($Optional) { Write-Host "WARNING: $msg -- continuing"; return }
        throw $msg
    }
}

function Copy-BuildArtifact {
    <#
    .SYNOPSIS
        Stage built artifacts by extension into an install layout, for upstreams whose
        `cmake --install` is disabled or incomplete.
    .DESCRIPTION
        For each -Map entry, ensures <InstallDir>\<Dest> exists and copies the files matching
        the entry's Filter(s) from -BuildDir into it, logging the count. Replaces the hand-rolled
        "New-Item dirs + Get-ChildItem -Filter + Copy-Item" install blocks in the
        build-*-from-source scripts. -Recurse searches the whole build tree (deep artifacts);
        omit it to copy only BuildDir's top level (matching a non-recursive wildcard copy).
    .PARAMETER BuildDir
        Directory to source artifacts from.
    .PARAMETER InstallDir
        Install root; each map entry's Dest subdir is created under it.
    .PARAMETER Map
        Array of @{ Filter = '*.dll'; Dest = 'bin' } entries; Filter may be a string or string[].
    .PARAMETER Recurse
        Search BuildDir recursively (default: top level only).
    #>
    param(
        [Parameter(Mandatory)][string]$BuildDir,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][object[]]$Map,
        [switch]$Recurse
    )
    foreach ($entry in $Map) {
        $destDir = Join-Path $InstallDir $entry.Dest
        New-Item -Path $destDir -ItemType Directory -Force | Out-Null
        $count = 0
        foreach ($filter in @($entry.Filter)) {
            Get-ChildItem -Path $BuildDir -Filter $filter -Recurse:$Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item $_.FullName -Destination $destDir -Force -ErrorAction SilentlyContinue
                $count++
            }
        }
        Write-Host ("Staged {0} {1} -> {2}" -f $count, (@($entry.Filter) -join '/'), $destDir)
    }
}

function Remove-MakefileShowIncludes {
    <#
    .SYNOPSIS
        Strip MSVC /showIncludes and its awk dep-file pipeline from a configure-generated
        FFmpeg makefile so clang-cl/nmake don't choke on the GCC-style dependency scanning.
    .DESCRIPTION
        FFmpeg's ./configure writes the same /showIncludes + `| awk ... > *.d` dep-tracking
        into both ffbuild/*.mak and the top-level library.mak/subdir.mak/Makefile. This applies
        the identical invariant `-replace` set in one place (was duplicated across two loops in
        build-ffmpeg-from-source.ps1). No-op if -Path does not exist.
    .PARAMETER Path
        Makefile to rewrite in place.
    .PARAMETER StripWildcardInclude
        Also drop the `-include $(wildcard *.d)` line -- present in the top-level makefiles,
        not in the ffbuild/*.mak fragments.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$StripWildcardInclude
    )
    if (-not (Test-Path $Path)) { return }
    $c = [System.IO.File]::ReadAllText($Path)
    $c = $c -replace '-showIncludes', ''
    $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
    $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
    $c = $c -replace '\s*\|\s*awk.*', ''
    if ($StripWildcardInclude) { $c = $c -replace '-include\s+\$\(wildcard\s+\*\.d\).*', '' }
    [System.IO.File]::WriteAllText($Path, $c)
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

function Invoke-InlineRegexPatch {
    <#
    .SYNOPSIS
        In-place regex substitution on a source file, warning loudly when the pattern didn't match.
    .DESCRIPTION
        Canonical form for the "kept inline, NOT a .patch" edits that target floating
        upstream paths (CMake-fetched dep SHAs, installed MSVC toolset headers) where a
        static .patch would silently rot. Reads the file, applies -replace and:
          * if the (optional) -Guard regex is present and does NOT match, does nothing;
          * if the replace is a no-op, emits -WarnMessage so a silent miss stays visible;
          * otherwise writes the file back and logs the edit.
        Collapses the read-replace-warn-or-write idiom duplicated across build-onnx
        (CUDA PCH strip, cutlass _udiv128) and build-onnx-genai (MSVC coroutine / yvals_core).
    .PARAMETER Path
        File to patch in place. A missing file is skipped (returns $false) unless -Require.
    .PARAMETER Pattern
        Regex passed to -replace.
    .PARAMETER Replacement
        Replacement string (default '' — i.e. strip the match).
    .PARAMETER Guard
        Optional regex; the edit is only attempted when the file content matches it
        (mirrors the `if ($text -match '...') { ... }` guard around the MSVC STL patches).
    .PARAMETER WarnMessage
        Emitted via Write-Warning when the pattern is present-but-unchanged. Defaults to a
        generic "pattern not found" note naming the file.
    .PARAMETER Require
        Throw if the file does not exist (default: skip missing files quietly).
    .PARAMETER Description
        Human label for the success log line (defaults to the file leaf name).
    .OUTPUTS
        [bool] $true if the file was modified, else $false.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Pattern,
        [string]$Replacement = '',
        [string]$Guard = '',
        [string]$WarnMessage = '',
        [switch]$Require,
        [string]$Description = ''
    )
    if (-not (Test-Path $Path)) {
        if ($Require) { throw "Invoke-InlineRegexPatch: file not found: $Path" }
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $Path -Leaf }
    $text = [System.IO.File]::ReadAllText($Path)
    if ($Guard -and ($text -notmatch $Guard)) { return $false }
    $patched = $text -replace $Pattern, $Replacement
    if ($patched -eq $text) {
        if ([string]::IsNullOrWhiteSpace($WarnMessage)) {
            $WarnMessage = "$Description : pattern not found; upstream layout may have changed. Verify $Path."
        }
        Write-Warning $WarnMessage
        return $false
    }
    [System.IO.File]::WriteAllText($Path, $patched)
    Write-Host "Patched $Description ($Path)"
    return $true
}

function Add-FileBlockOnce {
    <#
    .SYNOPSIS
        Idempotently append (or prepend) a text block to a file, guarded by a marker regex.
    .DESCRIPTION
        Canonical form for the "graft a patch block into an upstream .cmake/.cc file exactly
        once" idiom (the protobuf/sentencepiece/tflite/litert *_patcher.cmake appends and the
        rust-syslib #pragma prepend all share it). Collapses the
        `if ((Test-Path $x) -and ((Get-Content -Raw $x) -notmatch 'MARKER')) { Add-Content ...;
        Write-Host ... }` wrapper into one call. Skips the file when it is missing or already
        contains -Marker; otherwise writes the block and logs it.
    .PARAMETER Path
        File to modify. A missing file is skipped (returns $false) unless -Require.
    .PARAMETER Marker
        Regex identifying an already-applied block; when present the file is left untouched.
    .PARAMETER Content
        Text block to add (typically a here-string).
    .PARAMETER Prepend
        Insert -Content BEFORE the existing file content (default: append after).
    .PARAMETER Encoding
        Optional encoding for the append path (e.g. 'ASCII'); default uses Add-Content's default.
        Ignored for -Prepend, which writes UTF-8 (no BOM) via [System.IO.File]::WriteAllText.
    .PARAMETER Require
        Throw if the file does not exist (default: skip missing files quietly).
    .PARAMETER Description
        Human label for the success log line (defaults to the file leaf name).
    .OUTPUTS
        [bool] $true if the file was modified, else $false.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Marker,
        [Parameter(Mandatory)]
        [string]$Content,
        [switch]$Prepend,
        [string]$Encoding = '',
        [switch]$Require,
        [string]$Description = ''
    )
    if (-not (Test-Path $Path)) {
        if ($Require) { throw "Add-FileBlockOnce: file not found: $Path" }
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Description)) { $Description = Split-Path $Path -Leaf }
    if ((Get-Content -Raw $Path) -match $Marker) { return $false }
    if ($Prepend) {
        [System.IO.File]::WriteAllText($Path, $Content + [System.IO.File]::ReadAllText($Path))
    }
    elseif ($Encoding) {
        Add-Content -LiteralPath $Path -Value $Content -Encoding $Encoding
    }
    else {
        Add-Content -LiteralPath $Path -Value $Content
    }
    Write-Host "Patched $Description"
    return $true
}

function Invoke-NinjaBuildWithRetry {
    <#
    .SYNOPSIS
        Runs ninja at a memory-scaled -j, retries at a lower -j on failure, then optionally installs.
    .DESCRIPTION
        Consolidates the "parallel ninja -> incremental low-j retry -> cmake --install"
        idiom hand-rolled in build-onnx (retry -j2) and build-opencv (retry -j1, tee log).
        Ninja is incremental, so the retry only redoes the TUs that died. Sets NINJA_STATUS
        for compact "[done/total]" progress.
    .PARAMETER BuildDir
        Ninja build directory (passed via -C).
    .PARAMETER RetryJobs
        -j for the fallback pass (ONNX uses 2, OpenCV uses 1). Default 1.
    .PARAMETER MemGBPerJob
        Per-job memory estimate handed to Get-BuildJobCount (default 4).
    .PARAMETER LogFile
        If set, tees build output here and prints its last 50 lines on failure.
    .PARAMETER Install
        Run `cmake --install <BuildDir> --config <InstallConfig>` after a successful build.
    .PARAMETER InstallConfig
        Config for cmake --install (default Release).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BuildDir,
        [int]$RetryJobs = 1,
        [int]$MemGBPerJob = 4,
        [string]$LogFile = '',
        [switch]$Install,
        [string]$InstallConfig = 'Release'
    )
    $env:NINJA_STATUS = "[%f/%t] "
    $jobs = Get-BuildJobCount -MemGBPerJob $MemGBPerJob
    Write-Host "Building with ninja -j$jobs..."
    if ($LogFile) {
        ninja -j $jobs -C $BuildDir 2>&1 | Tee-Object -FilePath $LogFile
    } else {
        ninja -j $jobs -C $BuildDir 2>&1
    }
    if ($LASTEXITCODE -ne 0 -and $jobs -gt $RetryJobs) {
        Write-Host "ninja -j$jobs failed (exit $LASTEXITCODE) - retrying incrementally with -j$RetryJobs..."
        if ($LogFile) {
            ninja -j $RetryJobs -C $BuildDir 2>&1 | Tee-Object -FilePath $LogFile -Append
        } else {
            ninja -j $RetryJobs -C $BuildDir 2>&1
        }
    }
    if ($LASTEXITCODE -ne 0) {
        if ($LogFile -and (Test-Path $LogFile)) {
            Write-Host "`n=== BUILD FAILED - last 50 lines ==="
            Get-Content $LogFile -Tail 50 | ForEach-Object { Write-Host $_ }
        }
        throw "Build failed (exit $LASTEXITCODE)"
    }
    if ($Install) {
        Write-Host "Installing..."
        & cmake --install $BuildDir --config $InstallConfig
        if ($LASTEXITCODE -ne 0) { throw "Install failed" }
    }
}

function Expand-SourceTarball {
    <#
    .SYNOPSIS
        Two-pass 7z extract of a .tar.gz/.tar.bz2 into a directory; returns the single extracted source dir.
    .DESCRIPTION
        7z on Windows unwraps a .tar.gz in two passes (gzip layer, then the inner .tar).
        This runs both passes, then returns the sole top-level directory produced (the
        upstream project root). Consolidates the double-7z + "grab the single child dir"
        idiom in build-ffmpeg. Throws if no extracted directory is found.
    .PARAMETER Archive
        Path to the downloaded .tar.gz / .tar archive.
    .PARAMETER Destination
        Directory to extract into.
    .OUTPUTS
        [string] Full path to the extracted source directory.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Archive,
        [Parameter(Mandatory)]
        [string]$Destination
    )
    & 7z x "$Archive" -o"$Destination" -y -bd 2>&1 | Out-Null
    $tarFile = Get-ChildItem -Path $Destination -Filter '*.tar' | Select-Object -First 1 -ExpandProperty FullName
    if ($tarFile) { & 7z x "$tarFile" -o"$Destination" -y -bd 2>&1 | Out-Null }
    $srcDir = Get-ChildItem -Path $Destination -Directory | Select-Object -First 1 -ExpandProperty FullName
    if (-not $srcDir) { throw "Failed to locate extracted source directory under $Destination" }
    return $srcDir
}

function Initialize-ExtractedGitRepo {
    <#
    .SYNOPSIS
        `git init`s an extracted tarball tree so Invoke-SourcePatch takes its git fast-path.
    .DESCRIPTION
        Byte-identical logic previously duplicated in build-ffmpeg and build-gstreamer.
        Runs `git init` via cmd.exe so git's stderr chatter cannot become a terminating
        NativeCommandError under PS 5.1 EAP=Stop.
    .PARAMETER Path
        Root of the extracted source tree.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    cmd.exe /c "git -C ""$Path"" init >nul 2>&1"
}

function Import-CanonicalVersions {
    <#
    .SYNOPSIS
        Sources load-versions.ps1 (canonical versions.env -> env vars) when present.
    .DESCRIPTION
        Replaces the identical "Test-Path load-versions.ps1; if present, invoke it" block
        in build-ffmpeg and build-gstreamer. A no-op when the script is absent (e.g. the
        env was already baked by the Dockerfile).
    .PARAMETER ScriptRoot
        Directory containing load-versions.ps1. Defaults to the scripts\ dir (this module's parent).
    #>
    param(
        [string]$ScriptRoot = ''
    )
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) { $ScriptRoot = Split-Path $PSScriptRoot -Parent }
    $versionsScript = Join-Path $ScriptRoot 'load-versions.ps1'
    if (Test-Path $versionsScript) { & $versionsScript }
}

function Get-CudaToolkitRootArg {
    <#
    .SYNOPSIS
        Returns the -DCUDA_TOOLKIT_ROOT_DIR CMake arg for the detected CUDA root, or @() if none.
    .DESCRIPTION
        Small shared arg-builder for the `if ($gpuEnv.CudaRoot) { ... }` block repeated in
        build-litert and build-tvm. Pass -ForwardSlash to emit forward-slashed paths (TVM's form).
    .PARAMETER GpuEnv
        Hashtable from Get-GpuEnvironment.
    .PARAMETER ForwardSlash
        Convert backslashes to forward slashes in the emitted path.
    .OUTPUTS
        [string[]] Either a one-element array with the -D arg, or an empty array.
    #>
    param(
        [Parameter(Mandatory)]
        [hashtable]$GpuEnv,
        [switch]$ForwardSlash
    )
    if (-not $GpuEnv.CudaRoot) { return @() }
    $root = if ($ForwardSlash) { $GpuEnv.CudaRoot -replace '\\', '/' } else { $GpuEnv.CudaRoot }
    return @("-DCUDA_TOOLKIT_ROOT_DIR=$root")
}

function Get-LlvmArchiverCmakeArg {
    <#
    .SYNOPSIS
        Returns the -DCMAKE_AR:FILEPATH=<llvm-lib> CMake arg, or @() when llvm-lib isn't found.
    .DESCRIPTION
        CMake can resolve CMAKE_AR to a bogus C:\llvm-lib; passing the full path via
        :FILEPATH fixes it. Same three-line block appeared in build-opencv, build-litert
        and build-tvm.
    .OUTPUTS
        [string[]] One-element array with the -D arg, or an empty array.
    #>
    $llvmLib = Resolve-LlvmArchiver
    if ($llvmLib) { return @("-DCMAKE_AR:FILEPATH=$llvmLib") }
    return @()
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

function Invoke-SourceBuildChain {
    <#
    .SYNOPSIS
        Run an ordered chain of source-build scripts in one container (the shared
        *-all.ps1 run+commit payload loop).
    .DESCRIPTION
        The loop behind the media *-all orchestrators (build-media-core-all,
        build-litert-all): for each stage print a timestamped banner, invoke the stage's
        build script with -SourceDir/-InstallDir, then hard-fail on a non-zero NATIVE exit
        (a child that `exit N`s rather than throwing -- a safety net over EAP=Stop, which
        already propagates child throws). Stages stay sequential because each consumes the
        prior stage's install (LiteRT-LM needs LiteRT; ONNX GenAI needs ONNX Runtime).

        Sets EAP=Stop so children that RELY on an inherited Stop (build-onnx-genai / opencv
        / ffmpeg / litert-from-source do NOT set their own) abort exactly as they did under
        the orchestrator's script scope. Verified empirically: a function-local EAP=Stop
        propagates into an &-invoked external .ps1, so moving the loop off script scope into
        this module function does not change child error semantics.
    .PARAMETER Label
        Chain name used in the banners/errors (e.g. 'media-core', 'media-litert').
    .PARAMETER Stages
        Ordered stage descriptors; each a hashtable with keys Name, Script, SourceDir.
    .PARAMETER InstallDir
        Shared install prefix forwarded to every stage script.
    .PARAMETER ScriptDir
        Directory holding the stage scripts (baked into the builder image).
    #>
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][object[]]$Stages,
        [string]$InstallDir = 'C:\runtime',
        [string]$ScriptDir  = 'C:\temp\scripts'
    )
    $ErrorActionPreference = 'Stop'
    foreach ($stage in $Stages) {
        Write-Host "`n=== $Label stage: $($stage.Name) ($([string]::Format('{0:HH:mm:ss}', (Get-Date)))) ==="
        & (Join-Path $ScriptDir $stage.Script) -SourceDir $stage.SourceDir -InstallDir $InstallDir
        # $LASTEXITCODE is unset until the FIRST native command runs; reading it while unset
        # throws under Set-StrictMode. Treat "never set" as success (a child that ran only
        # cmdlets and threw nothing succeeded); a child's `exit N` sets it, which we honor.
        $exitCode = if (Test-Path Variable:\LASTEXITCODE) { $LASTEXITCODE } else { 0 }
        if ($exitCode) { throw "$($stage.Name) build failed (exit $exitCode)" }
    }
}

Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Invoke-SourceBuildChain',
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
    'Invoke-InlineRegexPatch',
    'Add-FileBlockOnce',
    'Invoke-NinjaBuildWithRetry',
    'Expand-SourceTarball',
    'Initialize-ExtractedGitRepo',
    'Import-CanonicalVersions',
    'Get-CudaToolkitRootArg',
    'Get-LlvmArchiverCmakeArg',
    'Initialize-SourceBuildEnvironment',
    'Initialize-ToolchainPythonEnvironment',
    'Remove-SourceBuildTree',
    'Get-BuildJobCount',
    'Install-CpythonPip',
    'Invoke-CpythonPip',
    'Copy-BuildArtifact',
    'Remove-MakefileShowIncludes',
    'Get-CudaArchitectureList',
    'Get-WindowsX86SimdFlags',
    'Get-WindowsX86Avx512Flags',
    'Get-GpuEnvironment',
    'Resolve-TensorRtRoot',
    # Re-exported from WindowsScripts.Shared (imported above) so a caller gets these via a
    # single Import-Module -- no "import Shared last" ordering dance / nested -Force clobber.
    'Resolve-DirectoryPath',
    'New-Timestamp',
    'Resolve-NormalizedPath',
    'ConvertTo-ParameterList',
    'Invoke-DownloadWithRetry'
)
