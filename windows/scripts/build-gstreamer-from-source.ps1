<#
.SYNOPSIS
    Build GStreamer from source on Windows using Meson with clang-cl.

.DESCRIPTION
    Alternative to the binary BITS installer. Clones the GStreamer monorepo
    and builds everything from source via Meson wraps. Uses clang-cl as the
    compiler (msvc-compatible ABI) with Visual Studio SDK paths.

.PARAMETER GstVersion
    Git tag or branch to build (default: 1.28.3).

.PARAMETER InstallDir
    Target install prefix (default: C:\gstreamer).

.PARAMETER SrcDir
    Temporary directory for the git clone (default: C:\temp\gst-source).

.PARAMETER BuildDir
    Meson build directory (default: C:\temp\gst-builddir).

.PARAMETER LogDir
    Log output directory (default: C:\temp\logs).

.PARAMETER GitRepo
    GStreamer monorepo URL (default: https://github.com/gstreamer/gstreamer.git).

.PARAMETER KeepBuildArtifacts
    If set, do not remove source and build directories after install.

.PARAMETER MesonSetupArgs
    Additional arguments passed through to meson setup.
#>
param(
    [string]$GstVersion        = '',
    [string]$InstallDir        = 'C:\gstreamer',
    [string]$SrcDir            = 'C:\temp\gst-source',
    [string]$BuildDir          = 'C:\temp\gst-builddir',
    [string]$LogDir            = 'C:\temp\logs',
    [string]$GitRepo           = 'https://github.com/gstreamer/gstreamer.git',
    [switch]$KeepBuildArtifacts,
    [string[]]$MesonSetupArgs  = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- helpers (inline, avoids module scope issues) ----
function Ensure-Dir($path) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    return (Resolve-Path $path).Path
}

# ---- module import (logging only) ----
$modulePath = Join-Path $PSScriptRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

# ---- logging ----
$logContext = New-StructuredLogContext -LogDir $LogDir -Prefix 'gst-source-build'
Start-StructuredLogging -Context $logContext

function log($text) {
    Write-StructuredLogEntry -Context $logContext -Text $text
}

# Load canonical versions from linux/scripts/01-core/versions.env if available
$versionsScript = Join-Path $PSScriptRoot 'load-versions.ps1'
if (Test-Path $versionsScript) { & $versionsScript }

if ([string]::IsNullOrWhiteSpace($GstVersion)) {
    $GstVersion = $env:GST_VERSION
}
if ([string]::IsNullOrWhiteSpace($GstVersion)) {
    $GstVersion = $env:GSTREAMER_VERSION
}
if ([string]::IsNullOrWhiteSpace($GstVersion)) {
    $GstVersion = '1.29.1'  # keep in sync with versions.env
}

try {
    log "START - GStreamer source build"
    log "Version:   $GstVersion"
    log "Install:   $InstallDir"
    log "SrcDir:    $SrcDir"
    log "BuildDir:  $BuildDir"
    log "LogDir:    $LogDir"
    log "GitRepo:   $GitRepo"

    # ---- 1. resolve directories ----
    $resolvedInstallDir = Ensure-Dir $InstallDir
    $resolvedSrcDir     = Ensure-Dir $SrcDir
    $resolvedBuildDir   = Ensure-Dir $BuildDir
    $resolvedLogDir     = Ensure-Dir $LogDir

    # ---- 2. install Meson via uv ----
    # uv needs CPython, download embeddable Python manually (uv's built-in
    # Python download can fail on some Windows hosts).  Then use uv pip.
    log 'Downloading embeddable Python for uv...'
    $pythonUrl = 'https://www.python.org/ftp/python/3.14.6/python-3.14.6-embed-amd64.zip'
    $pythonZip = Join-Path $resolvedLogDir 'python-embed.zip'
    $pythonDir = Join-Path $resolvedSrcDir 'cpython'
    & curl.exe -fsSL --retry 3 $pythonUrl -o $pythonZip
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download embedded Python' }
    Expand-Archive -Path $pythonZip -DestinationPath $pythonDir -Force
    $pyExe = Join-Path $pythonDir 'python.exe'
    Remove-Item "$pythonDir\python*._pth" -Force -ErrorAction SilentlyContinue
    # Enable site-packages by importing site (needed after _pth removal)
    & $pyExe -c "import site" 2>&1 | ForEach-Object { if ($_) { log $_ } }

    log 'Installing pip + Meson...'
    & curl.exe -fsSL 'https://bootstrap.pypa.io/get-pip.py' -o "$pythonDir\get-pip.py"
    $pipLog = Join-Path $resolvedLogDir 'pip-install.log'
    & cmd.exe /c """$pyExe"" ""$pythonDir\get-pip.py"" > ""$pipLog"" 2>&1"
    Get-Content $pipLog | ForEach-Object { if ($_) { if ($_) { log $_ } } }
    & cmd.exe /c """$pyExe"" -m pip install meson > ""$pipLog"" 2>&1"
    Get-Content $pipLog | ForEach-Object { if ($_) { if ($_) { log $_ } } }

    # Find meson executable from Scripts dir (embedded Python's -m may not
    # find site-packages even after _pth removal; direct exe is reliable)
    $pythonScripts = Join-Path $pythonDir 'Scripts'
    $mesonExe = Join-Path $pythonScripts 'meson.exe'
    if (-not (Test-Path $mesonExe)) {
        # Fallback: try pip show to locate
        $mesonVer = & $pyExe -m pip show meson 2>&1 | Select-String '^Location:' | ForEach-Object { $_ -replace '^Location: ', '' }
        if ($mesonVer) {
            $mesonExe = Join-Path (Join-Path ($mesonVer.Trim()) '..\Scripts') 'meson.exe'
        }
    }
    if (-not (Test-Path $mesonExe)) { throw 'meson.exe not found after pip install' }
    $env:PATH = "$pythonScripts;$env:PATH"
    $mesonVer = & $mesonExe --version 2>&1 | Select-Object -First 1
    log "Meson version: $mesonVer"
    $script:mesonExe = $mesonExe
    $env:UV_PYTHON = $pyExe

    # ---- 3. set clang-cl as the compiler ----
    log 'Setting CC/CXX to clang-cl...'
    $env:CC  = 'clang-cl'
    $env:CXX = 'clang-cl'
    # Verify clang-cl is on PATH
    $clangCheck = Get-Command 'clang-cl' -ErrorAction SilentlyContinue
    if (-not $clangCheck) {
        throw 'clang-cl not found on PATH. Ensure LLVM/Clang is installed.'
    }
    log "clang-cl found at: $($clangCheck.Source)"

    # Prevent git from hanging/interactive prompts during meson subproject downloads
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_SSL_NO_VERIFY = '1'

    # ---- 4. download GStreamer source tarball ----
    $gstSrcDir = Join-Path $resolvedSrcDir "gstreamer-$GstVersion"
    if (Test-Path $gstSrcDir) {
        log "Removing existing source directory: $gstSrcDir"
        Remove-Item -Path $gstSrcDir -Recurse -Force
    }

    $tarballUrl = "https://github.com/gstreamer/gstreamer/archive/refs/tags/$GstVersion.tar.gz"
    $tarballPath = Join-Path $resolvedLogDir "gstreamer-$GstVersion.tar.gz"
    log "Downloading GStreamer source tarball from $tarballUrl ..."
    & curl.exe -fsSL --retry 3 $tarballUrl -o $tarballPath 2>&1 | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'Failed to download GStreamer source tarball' }
    log 'Tarball downloaded. Extracting...'

    # 7z on Windows handles .tar.gz in two passes: gzip then tar
    & 7z x $tarballPath -o"$resolvedSrcDir" -y 2>&1 | Where-Object { $_ } | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'Failed to decompress GStreamer source tarball' }
    $tarFile = Join-Path $resolvedSrcDir "gstreamer-$GstVersion.tar"
    if (Test-Path $tarFile) {
        log 'Extracting tar archive...'
        & 7z x $tarFile -o"$resolvedSrcDir" -y 2>&1 | Where-Object { $_ } | ForEach-Object { if ($_) { log $_ } }
        Remove-Item $tarFile -Force
    }
    Remove-Item $tarballPath -Force
    # Locate the actual GStreamer source dir (skip cpython/)
    $gstDirs = @(Get-ChildItem -Path $resolvedSrcDir -Directory -Filter 'gstreamer*')
    if ($gstDirs.Count -ge 1) {
        $gstSrcDir = $gstDirs[0].FullName
        log "Source root: $gstSrcDir"
    } elseif ( -not (Test-Path (Join-Path $gstSrcDir 'meson.build'))) {
        throw "Could not find GStreamer source with meson.build in $resolvedSrcDir"
    }
    log 'Extraction complete.'

    # ---- 5. pre-extract all wrap-git subprojects via tarball ----
    $subprojDir = Join-Path $gstSrcDir 'subprojects'
    Get-ChildItem -Path $subprojDir -Filter '*.wrap' | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $fname = $_.Name
        if ($content -match '^\[wrap-git\]') {
            $url = if ($content -match '(?ms)url\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
            $rev = if ($content -match '(?ms)revision\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
            $dir = if ($content -match '(?ms)directory\s*=\s*(.+?)\r?\n') { $matches[1].Trim() } else { return }
            $target = Join-Path $subprojDir $dir
            if (Test-Path $target) { Remove-Item -Path $_.FullName -Force; return }
            # Build tarball URL
            if ($url -match 'github\.com') {
                $base = $url -replace '\.git$', ''
                $tarballUrl = "$base/archive/$rev.tar.gz"
            } else {
                $tarballUrl = "$url/-/archive/$rev/$dir-$rev.tar.bz2"
            }
            $tmp = Join-Path $resolvedLogDir "$dir-$rev.tar"
            $tmpFile = "$tmp.gz"; if ($tarballUrl -match '\.bz2$') { $tmpFile = "$tmp.bz2" }
            log "Pre-extracting $fname..."
            cmd.exe /c "curl.exe -fsSL --retry 3 ""$tarballUrl"" -o ""$tmpFile"" 2>nul"
            if ($LASTEXITCODE -eq 0 -and (Test-Path $tmpFile)) {
                $extractDir = Join-Path $subprojDir "_ext_$dir"
                New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                cmd.exe /c "7z.exe x ""$tmpFile"" -o""$extractDir"" -y >nul 2>&1"
                $tarFile = @(Get-ChildItem -Path $extractDir -Filter '*.tar' | Sort-Object Length -Descending | Select-Object -First 1)
                if ($tarFile) {
                    cmd.exe /c "7z.exe x ""$($tarFile[0].FullName)"" -o""$extractDir"" -y >nul 2>&1"
                    Remove-Item $tarFile[0].FullName -Force -ErrorAction SilentlyContinue
                }
                $extracted = @(Get-ChildItem -Path $extractDir -Directory)
                if ($extracted.Count -ge 1) {
                    Move-Item -Path $extracted[0].FullName -Destination $target -Force
                    Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
                    log "Pre-extracted $fname to $target"
                }
                Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                log "WARNING: Failed to download $fname, features may be disabled"
            }
            Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue
        }
    }
    # Force-download libffi via PowerShell's & (bypasses cmd.exe path issues)
    $libffiTarget = Join-Path $subprojDir 'libffi'
    if (-not (Test-Path $libffiTarget)) {
        log 'Force-downloading libffi...'
        $libffiUrl = 'https://gitlab.freedesktop.org/gstreamer/meson-ports/libffi/-/archive/meson-3.2.9999.4/libffi-meson-3.2.9999.4.tar.bz2'
        $libffiTmp = Join-Path $resolvedLogDir 'libffi.tar.bz2'
        & curl.exe -fsSL --retry 3 $libffiUrl -o $libffiTmp 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $libffiTmp)) {
            $extractDir = Join-Path $subprojDir '_ext_libffi'
            New-Item -Path $extractDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            cmd.exe /c "7z.exe x ""$libffiTmp"" -o""$extractDir"" -y >nul 2>&1"
            $tarFile = @(Get-ChildItem -Path $extractDir -Filter '*.tar' | Sort-Object Length -Descending | Select-Object -First 1)
            if ($tarFile) {
                cmd.exe /c "7z.exe x ""$($tarFile[0].FullName)"" -o""$extractDir"" -y >nul 2>&1"
                Remove-Item $tarFile[0].FullName -Force -ErrorAction SilentlyContinue
            }
            $extracted = @(Get-ChildItem -Path $extractDir -Directory)
            if ($extracted.Count -ge 1) {
                Move-Item -Path $extracted[0].FullName -Destination $libffiTarget -Force
                log "Force-pre-extracted libffi"
            }
            Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            log "WARNING: Force-download of libffi failed (exit $LASTEXITCODE)"
        }
        Remove-Item -Path $libffiTmp -Force -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $subprojDir 'libffi.wrap') -Force -ErrorAction SilentlyContinue
    }

    # Recursively delete ALL [wrap-git] wraps across the entire source tree.
    # Any subproject can bundle its own wraps (e.g. GLib bundles libffi.wrap,
    # gst-plugins-base may bundle gl-headers.wrap). Git clone fails inside
    # Windows containers, so we remove them all to prevent FATAL ERRORs from
    # Meson.  Pre-extracted wraps (both top-level and bundled) are handled
    # above; anything remaining will fail if git-cloned.
    Get-ChildItem -Path $gstSrcDir -Filter '*.wrap' -Recurse | Where-Object {
        $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        $c -match '^\[wrap-git\]'
    } | ForEach-Object {
        $p = $_.FullName
        Remove-Item -Path $p -Force -ErrorAction SilentlyContinue
        $rel = $p.Substring($gstSrcDir.Length + 1)
        log "Removed bundled [wrap-git]: $rel"
    }

    # ---- 5b. create stub unistd.h + fixed intrin.h for platform compat ----
    $stubDir = 'C:\temp\includes'
    if (-not (Test-Path $stubDir)) { New-Item -Path $stubDir -ItemType Directory -Force | Out-Null }
    # unistd.h: flex/bison generated files + POSIX compat on Windows
    $stubFile = Join-Path $stubDir 'unistd.h'
    if (-not (Test-Path $stubFile)) {
        '#pragma once
int _isatty(int);
#define isatty _isatty
#define fileno _fileno' | Out-File -FilePath $stubFile -Encoding ASCII
        log "Created stub unistd.h at $stubFile"
    }
    # (LLVM 22 mmintrin.h bug: cairo Win32 backend disabled via -Dcairo:win32=disabled)
    # (Cairo Win32 stubs handled in retry loop after meson downloads cairo)

    # ---- 5c. detect CUDA (available from Dockerfile.ai layer) ----
    $cudaDetected = $false
    $cudaRoot = if ($env:CUDA_ROOT) { $env:CUDA_ROOT } elseif ($env:CUDA_PATH) { $env:CUDA_PATH } else { $null }
    if ($cudaRoot -and (Test-Path $cudaRoot)) {
        $cudaDetected = $true
        log "CUDA detected at: $cudaRoot"
        $env:CUDA_PATH = $cudaRoot
        $env:CUDA_HOME = $cudaRoot
        # Add CUDA bins to PATH for nvcc detection by Meson
        $cudaBin = Join-Path $cudaRoot 'bin'
        if (Test-Path $cudaBin) { $env:PATH = "$cudaBin;$env:PATH" }
    } else {
        log 'CUDA not detected — nvcodec/cuda plugins will be auto-detected by Meson'
    }

    # ---- 5d. find compiler-rt for lld-link (__udivti3, etc.) ----
    $compilerRtLib = @(Get-ChildItem -Path "$env:USERPROFILE\scoop\apps\llvm\current\lib\clang" -Recurse -Filter '*builtins*.lib' -ErrorAction SilentlyContinue | Select-Object -First 1)
    $rtFullPath = ''
    if ($compilerRtLib) {
        $rtFullPath = $compilerRtLib.FullName -replace '\\', '/'
        log "Found compiler-rt: $rtFullPath"
    }

    # ---- 6. meson setup (retry with wrap cleanup) ----
    $setupArgs = @(
        'setup', '--vsenv',
        $resolvedBuildDir, $gstSrcDir,
        "--prefix=$resolvedInstallDir",
        '-Dwrap_mode=forcefallback',
        '-Ddoc=disabled',
        '-Dgtk_doc=disabled',
        '-Dintrospection=disabled',
        '-Dtests=disabled',
        '-Dexamples=disabled',
        # Provide stub unistd.h; disable cairo Win32 (avoids LLVM 22 mmintrin.h bug)
        '-Dc_args=-IC:\temp\includes -FIio.h -Disatty=_isatty -Dfileno=_fileno -Dclose=_close -Dwrite=_write -DSTDOUT_FILENO=1 -Wno-cast-function-type-mismatch -Wno-incompatible-function-pointer-types',
        '-Dcairo:win32=disabled',
        '-Dopus:intrinsics=disabled',
        # nvcodec disabled: D3D11 interop code in gstnvdecoder.cpp uses
        # GST_CAPS_FEATURE_MEMORY_D3D11_MEMORY which is undeclared with
        # clang-cl (gst-d3d11 library's headers aren't found). CUDA gst-lib
        # is auto-detected separately and works fine.
        '-Dgst-plugins-bad:nvcodec=disabled',
        # wasapi disabled: IID_* COM GUID symbols not resolved by lld-link
        # (uuid.lib doesn't provide them in clang-cl's linking model)
        '-Dgst-plugins-bad:wasapi=disabled',
        # dots-viewer disabled: cargo crates.io index fetch fails in
        # containers behind proxies
        '-Dgst-devtools:dots-viewer=disabled',
        # /FORCE:MULTIPLE for libffi dups; compiler-rt for lld-link (__udivti3 etc.)
        "-Dc_link_args=['/FORCE:MULTIPLE','$rtFullPath']"
    ) + $MesonSetupArgs

    $setupArgsString = "meson $($setupArgs -join ' ')"
    $mesonSucceeded = $false
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        log "Running meson setup (attempt $attempt/2)..."
        log $setupArgsString
        # Redirect ONLY stdout to file to avoid PowerShell's ErrorRecord trap
        # from native stderr when $ErrorActionPreference='Stop'.
        $outFile = Join-Path $resolvedLogDir "meson-setup-$attempt-out.txt"
        & $mesonExe @setupArgs > $outFile
        $mesonExitCode = $LASTEXITCODE
        if (Test-Path $outFile) { Get-Content $outFile | ForEach-Object { if ($_) { log $_ } } }
        Remove-Item $outFile -Force -ErrorAction SilentlyContinue
        if ($mesonExitCode -eq 0) { $mesonSucceeded = $true; break }

        if ($attempt -eq 1) {
            # Delete known-problematic [wrap-git] wraps inside downloaded subprojects
            Get-ChildItem -Path $gstSrcDir -Filter 'gi-docgen.wrap' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -Path $gstSrcDir -Filter 'gtk-doc.wrap' -Recurse | Remove-Item -Force -ErrorAction SilentlyContinue
            if (Test-Path $resolvedBuildDir) { Remove-Item -Path $resolvedBuildDir -Recurse -Force }
        }
    }
    if (-not $mesonSucceeded) { throw 'meson setup failed after 2 attempts' }
    log 'meson setup completed.'

    # ---- 6. compile (retry once to work around LLVM 22 mmintrin.h bug in Cairo) ----
    $compileSucceeded = $false
    for ($cAttempt = 1; $cAttempt -le 2; $cAttempt++) {
        log "Compiling GStreamer (attempt $cAttempt/2, may take 30-60 min)..."
        & $mesonExe compile -C $resolvedBuildDir 2>&1 | ForEach-Object { if ($_) { log $_ } }
        if ($LASTEXITCODE -eq 0) { $compileSucceeded = $true; break }
        if ($cAttempt -eq 1) {
            log 'Compile attempt 1 failed; patching _commit conflict in GES and retrying...'
            # The -FIio.h conflicts with ges-validate.c's _commit function;
            # rename it locally via a #define before the macro invocation.
            $gesValidate = Join-Path $gstSrcDir 'subprojects/gst-editing-services/ges/ges-validate.c'
            if (Test-Path $gesValidate) {
                $content = Get-Content $gesValidate -Raw
                $patch = '#define _commit ges__commit
'
                if (-not ($content -match '#define _commit ges__commit')) {
                    Set-Content -Path $gesValidate -Value ($patch + $content) -NoNewline
                    log "Patched: ges-validate.c (_commit -> ges__commit)"
                }
            }
        }
    }
    if (-not $compileSucceeded) { throw 'meson compile failed after 2 attempts' }
    log 'Compilation complete.'

    # ---- 7. install ----
    log 'Installing GStreamer...'
    & $mesonExe install -C $resolvedBuildDir 2>&1 | ForEach-Object { if ($_) { log $_ } }
    if ($LASTEXITCODE -ne 0) { throw 'meson install failed' }
    log 'Installation complete.'

    # ---- 8. verify ----
    $gstLaunch = Join-Path $resolvedInstallDir 'bin\gst-launch-1.0.exe'
    if (Test-Path $gstLaunch) {
        log "Verification OK: $gstLaunch"
    } else {
        log "WARNING: gst-launch-1.0.exe not found at expected path: $gstLaunch"
        log 'Build may have completed but binaries may be elsewhere. Check logs.'
    }

    # ---- 9. cleanup ----
    if (-not $KeepBuildArtifacts.IsPresent) {
        log 'Cleaning up source and build directories...'
        if (Test-Path $gstSrcDir) {
            Remove-Item -Path $gstSrcDir -Recurse -Force
            log "Removed: $gstSrcDir"
        }
        if (Test-Path $resolvedBuildDir) {
            Remove-Item -Path $resolvedBuildDir -Recurse -Force
            log "Removed: $resolvedBuildDir"
        }
    }

    log 'END - GStreamer source build completed successfully.'
    exit 0

} catch {
    log "FATAL ERROR: $($_.Exception.Message)"
    if ($_.Exception.InnerException) {
        log "Inner: $($_.Exception.InnerException.Message)"
    }
    log "See structured log: $($logContext.StructuredLogFile)"
    exit 2
} finally {
    Stop-StructuredLogging -Context $logContext
}
