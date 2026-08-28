# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

param(
    [string]$SourceDir = 'C:\temp\ffmpeg-src',
    [string]$InstallDir = 'C:\runtime',
    [string]$FfmpegVersion = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'  # fail-fast when run standalone (Invoke-SourceBuildChain sets this in-scope for the media run)

# #108: container mounts are FLAT (C:\bkmnt, C:\temp\scripts) while the repo is
# scripts/<group>/ -- shared assets sit beside this script or one level up.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$modulePath = Join-Path $scriptAssetRoot 'modules\WindowsSourceBuild.Common.psm1'
if (-not (Get-Module -Name ([IO.Path]::GetFileNameWithoutExtension($modulePath)))) { Import-Module $modulePath }

$InstallDir = Initialize-SourceBuildScript -InstallDir $InstallDir -ScriptRoot $PSScriptRoot

$FfmpegVersion = Get-SourceBuildVersion -Value $FfmpegVersion -EnvironmentVariables @('FFMPEG_VERSION') -DefaultValue 'n9.0'
$prefix = Join-Path $InstallDir 'ffmpeg'
$ffmpegDir = Join-Path $prefix 'bin'

# TARGET arch: the build HOST is always windows/amd64; arm64 is a CROSS target whose output
# cannot run here. On amd64 $ffCross is $false and $ffCcTargetFlag is '', so every flag this
# script emits stays byte-identical to the pre-arm64 script.
# Print the raw inputs: the resolution once fell back to amd64 silently (an ARG that did not
# cross a stage boundary) and the only symptom was "libonnxruntime not found".
Write-Host ("FFmpeg arch inputs: Process='{0}' Machine='{1}' -> resolved '{2}'" -f `
    [Environment]::GetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'Process'),
    [Environment]::GetEnvironmentVariable('WINDOWS_TARGET_ARCH', 'Machine'),
    (Get-WindowsTargetArch))
$ffTargetArch = Get-WindowsTargetArch
$ffCross      = Test-WindowsCrossTarget -Arch $ffTargetArch
# Rides on --cc, not --extra-cflags, and in BOTH places the compiler is named: configure's own
# probe compilations must target the cross arch too.
$ffCcTargetFlag = if ($ffCross) { " --target=$(Get-ClangTargetTriple -Arch $ffTargetArch)" } else { '' }
if ($ffCross) { Write-Host "FFmpeg: CROSS build for $ffTargetArch on an $(Get-WindowsHostArch) host" }

# Every bash-facing path MUST go through this: a half-converted one collapsed to /cruntimeffmpeg
# and make install silently delivered the whole tree into <git-root>\cruntimeffmpeg.
function ConvertTo-MsysPath([string]$Path) {
    return '/' + $Path.Substring(0, 1).ToLower() + ($Path.Substring(2) -replace '\\', '/')
}

function Assert-FfmpegPkgConfig {
    # Gates the .pc files `make install` produced. Both defects it guards stayed silent for
    # MONTHS because the files were PRESENT and looked fine: `Version: ..` (configure found
    # neither a VERSION file nor git tags) and `prefix=/c/runtime` (an MSYS path clang-cl and
    # lld-link cannot resolve). This helper and Remove-MakefileShowIncludes are kept OUT of
    # WindowsSourceBuild.Common.psm1 on purpose -- that module re-keys all three media branches
    # on every edit; the tests reach them by AST extraction instead.
    param(
        [Parameter(Mandatory)][string]$PkgConfigDir,
        # Presence and well-formedness only; gst-libav's version floors are enforced where it
        # is configured (Assert-PkgConfigModule).
        [string[]]$RequiredModule = @('libavcodec', 'libavformat', 'libavutil', 'libavfilter')
    )
    if (-not (Test-Path $PkgConfigDir -PathType Container)) {
        throw ("FFmpeg install produced no pkgconfig directory at $PkgConfigDir. " +
            'Every pkg-config consumer (gst-libav above all) resolves FFmpeg through these files; ' +
            'without them the merge stage silently drops the plugin. Did `make install` run?')
    }
    $versions = [ordered]@{}
    foreach ($required in $RequiredModule) {
        $pcPath = Join-Path $PkgConfigDir "$required.pc"
        if (-not (Test-Path $pcPath)) {
            throw "FFmpeg install produced no $required.pc — consumers resolving it via pkg-config (gst-libav) cannot build."
        }
        $pcText = Get-Content $pcPath -Raw
        $version = ([regex]::Match($pcText, '(?m)^Version:\s*(.+)$')).Groups[1].Value.Trim()
        if ($version -notmatch '^\d+(\.\d+)+$') {
            throw ("$required.pc declares an unusable version '$version'. FFmpeg's configure found neither a VERSION " +
                'file nor git tags, so its version substitutions expanded to nothing. No consumer version constraint ' +
                "can match this — gst-libav would be silently skipped. Check the VERSION file written after extraction.")
        }
        if ($pcText -match '(?m)^prefix=/[a-z]/') {
            throw "$required.pc still carries an MSYS prefix; native Windows consumers cannot use its -I/-L flags."
        }
        $versions[$required] = $version
    }
    $summary = ($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
    Write-Host "FFmpeg .pc gate OK: $summary (real versions, Windows prefixes)"
    return $versions
}

function Remove-MakefileShowIncludes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$StripWildcardInclude
    )
    if (-not (Test-Path $Path)) { return }
    $c = [System.IO.File]::ReadAllText($Path)
    $c = $c -replace '-showIncludes', ''
    # -options:strict is cl.exe-only; clang-cl parses its prefix as the deprecated -o. Bare
    # builds survived by argument ORDER, but sccache reorders -Fo first, the hijack wins, and
    # the object lands in an NTFS alternate data stream at exit 0 -> "failed to zip up compiler
    # outputs". Stripping it is a correctness fix either way, and unblocks the #100 launcher.
    $c = $c -replace '-options:strict\s*', ''
    # The awk dep-file pipelines below parse MSVC -showIncludes output; clang-cl emits GNU-style
    # deps instead, so they both break and are superseded.
    $c = $c -replace '\|.*awk.*including.*>.*\.d["\s]', ''
    $c = $c -replace '\s*\|\s*\$\(AWK\).*', ''
    $c = $c -replace '\s*\|\s*awk.*', ''
    if ($StripWildcardInclude) { $c = $c -replace '-include\s+\$\(wildcard\s+\*\.d\).*', '' }
    [System.IO.File]::WriteAllText($Path, $c)
}

Write-Host "=== FFmpeg source build ($FfmpegVersion, clang-cl+lld-link default; FFMPEG_TOOLCHAIN=msvc to override) ==="

if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    # #68: trust but VERIFY on re-entry. A -ResumeFrom used to take this return and inherit
    # whatever a failed run left -- incl. a prebuilt/source MIX -- with every gate below skipped.
    $null = Assert-FfmpegPkgConfig -PkgConfigDir (Join-Path $prefix 'lib\pkgconfig')
    Write-Host "FFmpeg already installed at $prefix - .pc gate passed, skipping"; return
}

$tarballPath = "$SourceDir\ffmpeg.tar.gz"
if (Test-Path $SourceDir) { Remove-Item $SourceDir -Recurse -Force }
New-Item -Path $SourceDir -ItemType Directory -Force | Out-Null

# #122: phase brackets via trap, not a whole-body try/catch -- the same failure-names-its-phase
# contract as gstreamer/litert-lm (#109) without indenting 570 lines.
trap { Complete-CurrentBuildPhase -ErrorRecord $_; Write-BuildPhaseSummary -Label 'ffmpeg'; break }

Switch-BuildPhase '1. download + extract'
Write-Host "Downloading FFmpeg $FfmpegVersion..."
if ($FfmpegVersion -in @('main', 'master', 'develop')) {
    try {
        Invoke-DownloadWithRetry -Url "https://github.com/FFmpeg/FFmpeg/archive/refs/heads/$FfmpegVersion.tar.gz" -DestinationPath $tarballPath -Description "FFmpeg $FfmpegVersion tarball"
    } catch {
        # FFmpeg GitHub mirror uses 'master' as default branch; fall back if branch not found
        Write-Warning "FFmpeg branch '$FfmpegVersion' not found, trying 'master'..."
        Invoke-DownloadWithRetry -Url 'https://github.com/FFmpeg/FFmpeg/archive/refs/heads/master.tar.gz' -DestinationPath $tarballPath -Description 'FFmpeg master tarball'
        $FfmpegVersion = 'master'
    }
} else {
    Invoke-DownloadWithRetry -Url "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/$FfmpegVersion.tar.gz" -DestinationPath $tarballPath -Description "FFmpeg $FfmpegVersion tarball"
}
Write-Host "Extracting tarball..."
$srcDir = Expand-SourceTarball -Archive $tarballPath -Destination $SourceDir
Write-Host "Source at: $srcDir"

# git-init so Invoke-SourcePatch takes its git-apply fast-path: without a repo its probe writes
# to stderr, which PS 5.1 under EAP=Stop turns into a terminating NativeCommandError.
Initialize-ExtractedGitRepo -Path $srcDir

Switch-BuildPhase '2. VERSION synthesis + lib*.version'
# ── VERSION file: without it every generated .pc says "Version: .." ───────────
# configure derives the version from $source_path/VERSION or `git describe`, and NEITHER exists
# here (GitHub tarballs ship no VERSION; the git-init above leaves no tags). Both probes come up
# empty and every .pc gets a literal `Version: ..`, which alone keeps gst-libav out of the image
# -- it demands libavcodec >= 58.18.100 and three siblings. Strip the pinned tag's leading 'n'.
$ffmpegVersionNumber = ([string]$FfmpegVersion) -replace '^n', ''
if ($ffmpegVersionNumber -match '^\d+(\.\d+)*$') {
    Set-Content -Path (Join-Path $srcDir 'VERSION') -Value $ffmpegVersionNumber -Encoding ascii -NoNewline
    Write-Host "Wrote VERSION=$ffmpegVersionNumber (GitHub tarballs ship none; configure would emit 'Version: ..' in every .pc)"
} else {
    # A branch build has no meaningful release number -- leave it to configure, and say so.
    Write-Warning "FFMPEG_VERSION '$FfmpegVersion' is not a release number; .pc Version fields may come out empty."
}

# ── lib*.version (n9.0): every .pc now takes its Version from a GENERATED libX/libX.version,
# and ffbuild/libversion.sh's awk chain produced empty MAJOR/MINOR/MICRO under this Git-Bash
# port. The values are static facts of the pinned source, so write them ourselves: LF, no BOM
# (make -includes them for LIBVERSION/LIBMAJOR = DLL naming), format mirroring libversion.sh.
$ffLibs = 'avutil', 'avcodec', 'avformat', 'avdevice', 'avfilter', 'swscale', 'swresample', 'postproc'
foreach ($ffLib in $ffLibs) {
    $ffLibDir = Join-Path $srcDir "lib$ffLib"
    if (-not (Test-Path $ffLibDir)) { continue }
    $ffLibText = ''
    foreach ($h in @((Join-Path $ffLibDir 'version_major.h'), (Join-Path $ffLibDir 'version.h'))) {
        if (Test-Path $h) { $ffLibText += [System.IO.File]::ReadAllText($h) + "`n" }
    }
    $ffLibUc = "LIB$($ffLib.ToUpper())"
    $ffMaj = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MAJOR\s+(\d+)") { $Matches[1] } else { '' }
    $ffMin = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MINOR\s+(\d+)") { $Matches[1] } else { '' }
    $ffMic = if ($ffLibText -match "#define\s+${ffLibUc}_VERSION_MICRO\s+(\d+)") { $Matches[1] } else { '' }
    if (-not ($ffMaj -and $ffMin -and $ffMic)) {
        throw "lib$ffLib version macros not found in version(.major).h (upstream layout changed?) - refusing to write a broken .version file"
    }
    $ffVerContent = "lib${ffLib}_VERSION=$ffMaj.$ffMin.$ffMic`nlib${ffLib}_VERSION_MAJOR=$ffMaj`nlib${ffLib}_VERSION_MINOR=$ffMin`n"
    [System.IO.File]::WriteAllText((Join-Path $ffLibDir "lib$ffLib.version"), $ffVerContent)
    Write-Host "Wrote lib$ffLib.version = $ffMaj.$ffMin.$ffMic (bypasses the libversion.sh awk chain)"
}

Enter-VsDevCmdEnvironment
$scoopShims = "$env:USERPROFILE\scoop\shims"
# #76 insurance: this provisioning region once sat SILENT for 7200.9 s (a network timeout inside
# a scoop fetch; normal is 11-18 s). Bounded so a recurrence costs minutes and names itself.
function Invoke-BoundedProvisionStep {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Step,
        [int]$TimeoutMinutes = 10
    )
    $stepStart = Get-Date
    $job = Start-Job -ScriptBlock $Step
    try {
        while ($job.State -eq 'Running' -and (Get-Date) -lt $stepStart.AddMinutes($TimeoutMinutes)) {
            $null = Wait-Job -Job $job -Timeout 60
            if ($job.State -eq 'Running') {
                Write-Host ("  [{0}] still running ({1:N0}s) - heartbeat (#76 guard)" -f $Label, ((Get-Date) - $stepStart).TotalSeconds)
            }
        }
        if ($job.State -eq 'Running') {
            Stop-Job -Job $job
            throw "$Label exceeded $TimeoutMinutes min - the #76 stall class (2h-mute network timeout); rerun or check egress."
        }
        # A job that ENDED in failure must fail the step too: the first cut only threw on
        # timeout, deferring a failed scoop install to an unrelated 'make: not found' much later.
        $jobOut = Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErrs
        if ($jobOut) { $jobOut | ForEach-Object { Write-Host "  [$Label] $_" } }
        if ($job.State -ne 'Completed' -or ($jobErrs -and $jobErrs.Count -gt 0)) {
            $reason = if ($jobErrs) { ($jobErrs | Select-Object -First 3) -join '; ' } else { "job state $($job.State)" }
            throw "$Label FAILED: $reason"
        }
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}
Switch-BuildPhase '3. toolchain provisioning (make/gawk/nv-codec)'
if (-not (Get-Command make -ErrorAction SilentlyContinue)) {
    Write-Host "Installing make via scoop..."
    Invoke-BoundedProvisionStep -Label 'scoop install make' -Step { & scoop install main/make 2>&1; if ($LASTEXITCODE) { throw "scoop exit $LASTEXITCODE" } }
}
# Install gawk and replace MSYS2's broken awk
if (-not (Get-Command gawk -ErrorAction SilentlyContinue)) {
    Write-Host "Installing gawk via scoop..."
    Invoke-BoundedProvisionStep -Label 'scoop install gawk' -Step { & scoop install main/gawk 2>&1; if ($LASTEXITCODE) { throw "scoop exit $LASTEXITCODE" } }
}
$gitAwk = 'C:\Program Files\Git\usr\bin\awk.exe'
$gawkExe = Join-Path $scoopShims 'gawk.exe'
if ((Test-Path $gitAwk) -and (Test-Path $gawkExe)) {
    Copy-Item $gawkExe $gitAwk -Force
    Write-Host "Replaced MSYS2 awk with gawk"
}
$gitUsrBin = 'C:\Program Files\Git\usr\bin'
$env:PATH = "$scoopShims;$gitUsrBin;$env:PATH"
$bashExe = Join-Path $gitUsrBin 'bash.exe'

# ── NVIDIA hardware video (NVENC / NVDEC / CUVID) ────────────────────────────
# Header-only: FFmpeg dlopen()s the encoder/decoder from the NVIDIA driver at runtime, so no nvcc
# and no CUDA libs are needed. --enable-cuda-nvcc (which COMPILES CUDA filters) stays off.
$nvencFlags = @()
$ffGpu = Get-GpuEnvironment
# No cross-lane exclusion: upstream configure has NO arch guard on nvenc/nvdec/cuvid (detection
# is a check_pkg_config on the headers), so the cross lane is gated on the toolkit check alone.
if ($ffGpu.HasCuda -and (Test-Path (Join-Path $ffGpu.CudaRoot 'include\cuda.h'))) {
    Write-Host 'NVIDIA CUDA detected -> enabling FFmpeg NVENC/NVDEC/CUVID via nv-codec-headers'
    # configure needs pkg-config to locate ffnvcodec; not in the media image, so scoop it too.
    if (-not (Get-Command pkg-config -ErrorAction SilentlyContinue)) {
        Write-Host 'Installing pkg-config via scoop...'
        & scoop install main/pkg-config 2>&1 | Out-Null
    }
    # PREFIX is a forward-slash *Windows* path (C:/...), NOT an MSYS /c/... one, so the generated
    # ffnvcodec.pc emits -IC:/.../include cflags that cl.exe consumes directly.
    $nvHdrRef       = if ($env:NV_CODEC_HEADERS_REF) { $env:NV_CODEC_HEADERS_REF } else { 'n13.1.15.0' }
    $nvHdrSrc       = 'C:\temp\nv-codec-headers'
    $nvHdrPrefix    = 'C:\temp\nv-codec-headers-install'
    $nvHdrPrefixFwd = $nvHdrPrefix -replace '\\', '/'
    if (Test-Path $nvHdrSrc)    { Remove-Item $nvHdrSrc -Recurse -Force }
    if (Test-Path $nvHdrPrefix) { Remove-Item $nvHdrPrefix -Recurse -Force }
    # Stderr-shield: git writes "Cloning into..." to stderr, which under the in-container PS 5.1
    # EAP=Stop surfaces as a terminating NativeCommandError (2>&1 alone does NOT prevent it).
    [void](Invoke-ShieldedNative -Label 'nv-codec-headers clone' -CommandLine "git clone --branch $nvHdrRef --depth 1 https://github.com/FFmpeg/nv-codec-headers.git `"$nvHdrSrc`"")
    $nvHdrSrcCyg = ConvertTo-MsysPath $nvHdrSrc
    [void](Invoke-ShieldedNative -Label 'nv-codec-headers make install' -CommandLine "`"$bashExe`" -c `"cd $nvHdrSrcCyg && make install PREFIX=$nvHdrPrefixFwd`"")
    $nvPc = Join-Path $nvHdrPrefix 'lib\pkgconfig\ffnvcodec.pc'
    if (Test-Path $nvPc) {
        # Native (scoop) pkg-config reads a Windows-path PKG_CONFIG_PATH, which the bash configure
        # wrapper inherits from this process env.
        $nvPcDir = Join-Path $nvHdrPrefix 'lib\pkgconfig'
        $env:PKG_CONFIG_PATH = $nvPcDir + $(if ($env:PKG_CONFIG_PATH) { ";$env:PKG_CONFIG_PATH" } else { '' })
        $nvencFlags = @('--enable-ffnvcodec', '--enable-nvenc', '--enable-nvdec', '--enable-cuvid')
        Write-Host "ffnvcodec $nvHdrRef installed -> $nvPc"
    } else {
        Write-Warning 'nv-codec-headers install produced no ffnvcodec.pc -- FFmpeg will build without NVIDIA video accel.'
    }
} elseif ($ffCross) {
    Write-Host "FFmpeg: no nvidia CUDA toolkit -> cross build for $ffTargetArch without NVENC/NVDEC (CPU-only FFmpeg; FFmpeg has no Vulkan hwaccel on either lane)"
} else {
    Write-Host 'FFmpeg: no nvidia CUDA toolkit -> building without NVENC/NVDEC (CPU-only lane)'
}

$cygPrefix = ConvertTo-MsysPath $prefix
$cygSrc = ConvertTo-MsysPath $srcDir

# Copy the ONNX headers into compat/ so configure's test_cc probes find them without
# --extra-cflags, which is not passed to test compilations under the msvc-preset conventions.
$onnxRuntimeDir = Join-Path $InstallDir 'lib\onnxruntime-source'
$onnxHeaderCopied = $false
if (Test-Path $onnxRuntimeDir) {
    $header = Get-ChildItem "$onnxRuntimeDir" -Recurse -Filter 'onnxruntime_c_api.h' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($header) {
        $ffCompatInc = Join-Path $srcDir 'compat\onnx'
        New-Item -Path $ffCompatInc -ItemType Directory -Force | Out-Null
        # Mirror the WHOLE staged include dir: ORT 1.28 split the C API across new siblings and
        # the old cherry-pick made configure's probe fail with 'file not found'.
        $ortHeaders = @(Get-ChildItem $header.Directory -File)
        $ortHeaders | Copy-Item -Destination $ffCompatInc -Force
        Write-Host "Copied $($ortHeaders.Count) ONNX header(s) to: $ffCompatInc"
        $onnxHeaderCopied = $true
    } else {
        Write-Warning "ONNX Runtime header onnxruntime_c_api.h not found under $onnxRuntimeDir"
    }
}

$confFlags = @()
$confFlags += "--prefix=$cygPrefix"
$confFlags += '--enable-shared', '--disable-static'
$confFlags += '--disable-debug', '--disable-doc'
# No --enable-nonfree: the images are published and nonfree builds are not redistributable.
# gpl/version3 cover FFmpeg's OWN GPL components only -- no external GPL codec is enabled here.
$confFlags += '--enable-gpl', '--enable-version3'
$confFlags += '--enable-ffmpeg', '--enable-ffprobe'
if ($onnxHeaderCopied) {
    $confFlags += '--enable-libonnxruntime'
    $confFlags += "--extra-cflags=-I$cygSrc/compat/onnx"
    $confFlags += "--extra-ldflags=-libpath:$($onnxRuntimeDir -replace '\\', '/')/lib"
}
# clang-cl + lld-link by default (FFMPEG_TOOLCHAIN=msvc falls back). FFmpeg has no clang-cl
# preset, so keep the msvc one for its MSVC-style flag conventions + inherited VsDevCmd SDK env,
# both of which clang-cl mimics, and override only the compiler/linker.
$ffToolchain = if ($env:FFMPEG_TOOLCHAIN) { $env:FFMPEG_TOOLCHAIN } else { 'clang-cl' }
if ($ffToolchain -eq 'clang-cl') {
    # #100: FFmpeg is not CMake, so the module's COMPILER_LAUNCHER wiring never reached it --
    # ZERO compile requests in every build. The launcher must NOT go into configure's --cc: its
    # own compiler tests produce objects lld-link rejects as "unknown file type" through sccache.
    # It is injected at MAKE time instead (make CC=... beats config.mak); opt out FFMPEG_SCCACHE=0.
    # Acceptance criterion is `Compile requests` > 0, NOT the hit rate. Remote backend only, as
    # on the cmake side -- a container-local cache would only bloat layers.
    $ffSccache = Get-Command sccache.exe -ErrorAction SilentlyContinue
    $ffUseLauncher = [bool]($ffSccache -and (Test-SccacheRemoteConfigured) -and $env:FFMPEG_SCCACHE -ne '0')
    Write-Host "FFmpeg toolchain: clang-cl + lld-link (overriding the msvc preset's cc/ld; make-time sccache launcher: $ffUseLauncher)"
    $confFlags += '--toolchain=msvc', "--cc=clang-cl$ffCcTargetFlag", '--ld=lld-link'
} else {
    Write-Host 'FFmpeg toolchain: msvc (cl.exe + link.exe)'
    $confFlags += '--toolchain=msvc'
}
if ($ffCross) {
    # --enable-cross-compile stops configure RUNNING its probe binaries (they are aarch64);
    # --arch selects the target's asm/optimisation tree.
    # --target-os is DELIBERATELY NOT SET: configure runs through Git-bash/MSYS here, so the
    # amd64 lane's own TARGET_OS is the reference value and guessing can select a different code
    # path. Read the amd64 line from the config.mak dump below first: measured cross runs print
    # only ARCH= and AS=, never TARGET_OS, so the cross dump alone cannot answer this.
    $confFlags += '--enable-cross-compile', "--arch=$(Get-FfmpegTargetArch -Arch $ffTargetArch)"
    # /machine on the LINKER is separate from --target on the compiler and BOTH are required:
    # with only --cc carrying the triple, configure's link probes ran as x64 and every check
    # against a cross-built library surfaced as "ERROR: libonnxruntime not found".
    $confFlags += "--extra-ldflags=/machine:$(Get-LibMachineArg -Arch $ffTargetArch)"
    # HOST compiler for the build-time tools that must RUN here: under --enable-cross-compile
    # configure stops assuming cc==host_cc and falls back to plain `gcc`, absent from a Windows
    # container. `clang`, not `clang-cl`, because configure drives host_cc with GNU-style flags,
    # and with no --target so it builds for the host.
    # Host tools must LINK against the HOST CRT: VsDevCmd has put the target's arm64 lib dirs on
    # %LIB%, so a host tool otherwise picks up the arm64 libcmt.lib ("machine type arm64
    # conflicts with x64"). Point host_ldflags at the x64 lib dirs so they win the search order.
    $hostArchDir = Get-MsvcTargetLibDir -Arch (Get-WindowsHostArch)
    $hostLibDirs = @()
    if ($env:VCToolsInstallDir) { $hostLibDirs += (Join-Path $env:VCToolsInstallDir "lib\$hostArchDir") }
    $sdkLibRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
    $sdkVerDir = Get-ChildItem $sdkLibRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "ucrt\$hostArchDir") } |
        Sort-Object Name | Select-Object -Last 1
    if ($sdkVerDir) {
        $hostLibDirs += (Join-Path $sdkVerDir.FullName "ucrt\$hostArchDir")
        $hostLibDirs += (Join-Path $sdkVerDir.FullName "um\$hostArchDir")
    }
    $hostLibDirs = @($hostLibDirs | Where-Object { Test-Path $_ })
    if ($hostLibDirs.Count -eq 0) {
        throw ("cross build: could not locate any $hostArchDir (host) lib directory for FFmpeg's host tools. " +
               'VCToolsInstallDir=' + $env:VCToolsInstallDir + "; SDK root=$sdkLibRoot")
    }
    # FFmpeg pastes host_ldflags verbatim into a make recipe run by MSYS sh, and the real
    # directories contain BOTH spaces and parentheses. 8.3 short paths sidestep the whole quoting
    # chain -- but 8.3 name generation is DISABLED on the container's volume, so ShortPath can
    # return the long path unchanged. Hence quoting as the fallback, with forward slashes to
    # avoid backslash interpretation through MSYS (clang accepts either).
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $hostLibArgs = foreach ($d in $hostLibDirs) {
        $short = try { $fso.GetFolder($d).ShortPath } catch { $d }
        if ($short -notmatch '[ ()]') {
            "-Wl,-libpath:$short"
        } else {
            # DOUBLE quotes, not single: $confStr below already wraps a spaced flag in SINGLE
            # quotes, and a nested single quote would terminate that wrapper early.
            '-Wl,-libpath:"' + ($d -replace '\\', '/') + '"'
        }
    }
    # TWO quoting levels, because a shell parses this value TWICE: $confStr below single-quotes
    # the whole flag so ./configure sees ONE word (do NOT add quotes here as well), and the
    # double quotes above keep each path one word when make re-parses it through sh. Both
    # failures print the same "syntax error near unexpected token `('" -- read the FILENAME in
    # the error to tell them apart.
    $confFlags += '--host-cc=clang'
    $confFlags += ('--host-ldflags=' + ($hostLibArgs -join ' '))
    Write-Host ("FFmpeg: host tools link against {0} libs -> {1}" -f $hostArchDir, ($hostLibArgs -join ' '))
    # aarch64 asm is ENABLED (#112) via clang's INTEGRATED assembler, which understands GAS
    # syntax directly -- no gas-preprocessor.pl driving armasm64, which stays the fallback if a
    # single file ever needs it. Safe because --enable-cross-compile makes configure decide asm
    # support by ASSEMBLING test fragments, never by running them. The contained fallback if a
    # future .S file breaks is --disable-asm, NOT a different toolchain (upstream recommends
    # llvm-mingw, incompatible with this repo's MSVC ABI).
    # --as, not --x86asmexe (FFmpeg's nasm/yasm knob, x86-only). $ffCcTargetFlag carries a
    # leading space, which $confStr's single-quoting handles -- as --cc already relies on.
    $confFlags += "--as=clang$ffCcTargetFlag"
    Write-Host "FFmpeg: aarch64 asm ENABLED via clang's integrated assembler (--as=clang$ffCcTargetFlag); configure assembles test fragments but never runs them"
    Write-Host ("FFmpeg: cross flags -> --enable-cross-compile --arch={0} --extra-ldflags=/machine:{1}" -f `
        (Get-FfmpegTargetArch -Arch $ffTargetArch), (Get-LibMachineArg -Arch $ffTargetArch))
}
# #119: x86asm is ENABLED on the amd64 lane -- archaeology on --disable-x86asm (bd6adca4) found
# NO recorded reason for it, and the pinned nasm is on PATH in every build container. The cross
# lane states the flag EXPLICITLY (x86-only, so configure would ignore it) to keep the two lanes'
# intent readable side by side.
if ($ffCross) {
    $confFlags += '--disable-x86asm'
} else {
    $nasmCmd = Get-Command nasm.exe -ErrorAction SilentlyContinue
    if (-not $nasmCmd) { throw 'FFmpeg: x86asm is enabled on the amd64 lane (backlog #119) but nasm.exe is not on PATH -- verify-toolchain.ps1 asserts it; the toolchain layer is incomplete' }
    $confFlags += "--x86asmexe=$($nasmCmd.Source -replace '\\', '/')"
    Write-Host "FFmpeg: x86asm ENABLED (nasm $($nasmCmd.Source); backlog #119 -- --disable-x86asm had no recorded reason)"
}
# vfwcap links vfw32.lib -> imports AVICAP32.dll, absent from Server Core: every process loading
# avdevice would die with STATUS_DLL_NOT_FOUND. DirectShow capture remains available.
$confFlags += '--disable-indev=vfwcap'
# NVIDIA hardware video accel: empty on the CPU-only lane, populated above when CUDA is present.
$confFlags += $nvencFlags

# Shell-quote flags carrying spaces: the wrapper line is parsed by bash, and an unquoted space
# would split the flag in two.
$confStr = ($confFlags | ForEach-Object { if ($_ -match ' ') { "'$_'" } else { $_ } }) -join ' '

# Patch configure to allow MSYS2 builds (official docs say MSYS is discouraged)
Invoke-SourcePatch -PatchFile (Join-Path $scriptAssetRoot 'patches\ffmpeg\001-allow-msys-builds.patch') -SourceDir $srcDir -IgnoreWhitespace

# VsDevCmd INCLUDE/LIB are inherited from PowerShell, so the MSVC SDK paths are available.
$wrapperLines = @()
$wrapperLines += '#!/usr/bin/env bash'
$wrapperLines += "cd $cygSrc"
$wrapperLines += 'export MSYS=winsymlinks:lnk'
$wrapperLines += 'export TMPDIR=tmpdir'
$wrapperLines += 'rm -rf tmpdir; mkdir -p tmpdir'
Switch-BuildPhase '4. configure'
$wrapperLines += "./configure $confStr"

$wrapperPath = Join-Path $srcDir 'ffmpeg-configure-wrapper.sh'
[System.IO.File]::WriteAllLines($wrapperPath, $wrapperLines)

Write-Host "Configuring FFmpeg (toolchain: $ffToolchain)..."
& $bashExe $wrapperPath 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    $logFile = Join-Path $srcDir 'ffbuild\config.log'
    if (Test-Path $logFile) { Write-Host "=== config.log (last 50 lines) ==="; Get-Content $logFile -Tail 50 }
    throw "FFmpeg configure failed (exit $LASTEXITCODE)"
}
# #100: CC in config.mak is the BARE compiler by design; the launcher rides in as a make-time
# override. Echoed so a cache regression is diagnosable from the build output alone.
$configMak = Join-Path $srcDir 'ffbuild\config.mak'
if (Test-Path $configMak) {
    $ccLine = (Select-String -Path $configMak -Pattern '^CC=' | Select-Object -First 1).Line
    Write-Host "config.mak: $ccLine (make-time sccache launcher: $ffUseLauncher)"
    # configure's own verdict on arch/OS/cpu/assembler: the authoritative "did the cross flags
    # take?", and the amd64 lane's reference TARGET_OS. Array-wrapped so a non-matching pattern
    # is an empty loop, not a $null property under StrictMode. Log-only.
    foreach ($m in @(Select-String -Path $configMak -Pattern '^(TARGET_OS|ARCH|CPU|AS)=' -ErrorAction SilentlyContinue)) {
        Write-Host "config.mak: $($m.Line)"
    }
}

Write-Host 'Building FFmpeg (this may take 30-60 minutes)...'
# Inline, NOT .patch files: these targets are GENERATED by ./configure, so their content differs
# per invocation and no static diff matches reliably. The -replace form targets invariant
# sub-sequences configure writes the same way. See docs/windows-builds.md "Source Patch Policy".
$ffbuildDir = Join-Path $srcDir 'ffbuild'
Get-ChildItem -Path $ffbuildDir -Filter '*.mak' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-MakefileShowIncludes -Path $_.FullName
}
foreach ($fn in @('library.mak', 'subdir.mak', 'Makefile')) {
    Remove-MakefileShowIncludes -Path (Join-Path $srcDir $fn) -StripWildcardInclude
}
# Inter-library import-lib deps (configure may emit no EXTRALIBS at all under the msvc preset).
# ONE map drives both the in-place replace and the append fallback.
$configMakPath = Join-Path $srcDir 'ffbuild/config.mak'
if (Test-Path $configMakPath) {
    $extraLibs = [ordered]@{
        'libswresample' = 'avutil.lib'
        'libswscale'    = 'avutil.lib'
        'libavcodec'    = 'avutil.lib'
        'libavfilter'   = 'avutil.lib'
        'libavformat'   = 'avutil.lib avcodec.lib'
        'libavdevice'   = 'avformat.lib avcodec.lib avutil.lib'
    }
    $cm = [System.IO.File]::ReadAllText($configMakPath)
    foreach ($lib in $extraLibs.Keys) {
        $line = "EXTRALIBS-$lib=$($extraLibs[$lib])"
        if ($cm -match "(?m)^EXTRALIBS-$lib\s*=") {
            $cm = $cm -replace "(?m)^EXTRALIBS-$lib\s*=.*", $line
        } else {
            $cm += "`n$line"
        }
    }
    [System.IO.File]::WriteAllText($configMakPath, $cm)
}

# Full-file overwrite, deliberately NOT a .patch: the file is completely rewritten and a context
# diff broke twice on upstream drift. The replacement expands version-script globs against
# per-object llvm-nm dumps via xargs, avoiding a lib.exe call that exceeds the length limit.
$makedefSrc = Join-Path $scriptAssetRoot 'patches\ffmpeg\makedef'
$makedefDst = Join-Path $srcDir 'compat\windows\makedef'
Copy-Item $makedefSrc $makedefDst -Force
Write-Host "Replaced compat/windows/makedef (glob-expanding, response-file-aware)"

# Parallel first; make is incremental, so the -j1 retry redoes only what failed. -jN can hit
# spurious LNK1120 races when a library dependency is not fully linked before its consumer.
$makeJobs = Get-BuildJobCount -MemGBPerJob 2
# #100: the launcher is safe at make time now that -options:strict is stripped from the generated
# maks (see Remove-MakefileShowIncludes); configure stays bare -- its own tests break through it.
Switch-BuildPhase '5. make + install'
$makeCc = if ($ffUseLauncher) { " CC='sccache clang-cl$ffCcTargetFlag'" } else { '' }
# All three make calls are -Optional by design: a parallel-link race falls through to the -j1
# retry, and an incomplete build/install to the artifact verification + fallback below.
[void](Invoke-ShieldedNative -Optional -Label "ffmpeg make -j$makeJobs" -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make -j$makeJobs$makeCc`"")
$builtFfmpeg = Join-Path $srcDir 'ffmpeg.exe'
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Retrying with single job (resolves MSVC link races)...'
    [void](Invoke-ShieldedNative -Optional -Label 'ffmpeg make -j1' -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make -j1$makeCc`"")
}
# The source build can fail at the link stage; fall through to the prebuilt gate below.
if (-not (Test-Path $builtFfmpeg)) {
    Write-Host 'Source build of FFmpeg did not produce ffmpeg.exe (link stage incomplete).'
}
Write-Host 'Attempting install from source if built...'
[void](Invoke-ShieldedNative -Optional -Label 'ffmpeg make install (verify below)' -CommandLine "`"$bashExe`" -c `"cd $cygSrc && make install`"")

# STAGE stats where the #100 acceptance criterion lives: the chain-aggregate dump cannot
# attribute per-stage, so this stage emitted its criterion nowhere.
if ($ffUseLauncher) { Write-SccacheStatsToStderr -Advanced -RequireRemote }

# A --enable-shared build is unusable without its av*.dll next to the exes (STATUS_DLL_NOT_FOUND).
# Treat an incomplete install as a failed source build rather than shipping a broken ffmpeg.
$installedDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
if ((Test-Path "$ffmpegDir\ffmpeg.exe") -and $installedDlls.Count -eq 0) {
    Write-Warning 'Source install produced exes but no av*.dll runtime libraries - discarding as incomplete.'
    Remove-Item "$ffmpegDir\ffmpeg.exe", "$ffmpegDir\ffplay.exe", "$ffmpegDir\ffprobe.exe" -Force -ErrorAction SilentlyContinue
}

# Prebuilt fallback: FAIL-CLOSED since #68. The chain promise is OUR FFmpeg (avcodec 63,
# --enable-libonnxruntime, the one OpenCV links against), and a silent BtbN substitute used to
# land as a MIX over whatever a partial `make install` left. FFMPEG_ALLOW_PREBUILT=1 opts in and
# SCRUBS the whole prefix first so the result is at least self-consistent.
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) {
    if ($env:FFMPEG_ALLOW_PREBUILT -ne '1') {
        throw ('FFmpeg source build did not produce ffmpeg.exe and the prebuilt fallback is fail-closed (#68) - ' +
            'fix the source build (see the make output above) or opt in explicitly with FFMPEG_ALLOW_PREBUILT=1.')
    }
    # No prebuilt on the cross lane -- provenance, NOT availability (winarm64 BtbN assets do
    # exist): a foreign binary breaks the source-chain promise on ANY lane.
    if ($ffCross) {
        throw ("FFmpeg source build did not produce ffmpeg.exe -- and the cross lane has no prebuilt escape hatch: " +
            "a foreign BtbN binary would break the source-chain promise (a winarm64 asset exists; availability is " +
            "not the reason). Fix the cross build (see the make output above).")
    }
    Write-Warning 'FFmpeg source build failed -- falling back to pre-built BtbN MSVC FFmpeg (FFMPEG_ALLOW_PREBUILT=1). DNN/ONNX integration will NOT be available in the fallback binary.'
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '0', 'Process')
    # No MIXED installs: wipe the partial source install before the foreign binaries land.
    Reset-SourceBuildDirectory -Path $prefix
    if (-not (Test-Path $prefix)) { New-Item -Path $prefix -ItemType Directory -Force | Out-Null }
    $dlUrl = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'
    $zipPath = "$env:TEMP\ffmpeg.zip"
    Invoke-DownloadWithRetry -Url $dlUrl -DestinationPath $zipPath -Description 'BtbN prebuilt FFmpeg'
    & 7z x "$zipPath" -o"$env:TEMP\ffmpeg-extract" -y -bd 2>&1 | Out-Null
    $binDir = Get-ChildItem -Path "$env:TEMP\ffmpeg-extract" -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty DirectoryName
    if ($binDir) {
        if (-not (Test-Path $ffmpegDir)) { New-Item -Path $ffmpegDir -ItemType Directory -Force | Out-Null }
        Copy-Item "$binDir\*.exe" "$ffmpegDir\" -Force
        Copy-Item "$binDir\*.dll" "$ffmpegDir\" -Force
    }
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:TEMP\ffmpeg-extract" -Recurse -Force -ErrorAction SilentlyContinue
} else {
    [Environment]::SetEnvironmentVariable('FFMPEG_SOURCE_BUILD', '1', 'Process')
}

# ── Make the installed .pc files usable by NATIVE Windows consumers ───────────
# configure MUST get an MSYS --prefix or `make install` lands in the wrong place, and FFmpeg
# copies that same string into every .pc. clang-cl and lld-link cannot resolve /c/... , so the
# emitted -I/-L flags stay unusable until rewritten here. Same silent class as `Version: ..`.
$ffPkgConfigDir = Join-Path $prefix 'lib\pkgconfig'
if (Test-Path $ffPkgConfigDir) {
    $winPrefix = ($prefix -replace '\\', '/')   # C:/runtime/ffmpeg
    # Reuse the exact string configure was given: a second conversion could drift and then
    # silently match nothing.
    $msysPrefix = $cygPrefix -replace '\\', '/' # /c/runtime/ffmpeg
    $rewritten = 0
    foreach ($pc in Get-ChildItem -Path $ffPkgConfigDir -Filter '*.pc' -File) {
        $text = Get-Content $pc.FullName -Raw
        if ($text -notmatch [regex]::Escape($msysPrefix)) { continue }
        Set-Content -Path $pc.FullName -Value ($text -replace [regex]::Escape($msysPrefix), $winPrefix) -Encoding ascii -NoNewline
        $rewritten++
    }
    Write-Host "Rewrote MSYS prefixes to Windows form in $rewritten .pc file(s) under $ffPkgConfigDir"
}

# OUTSIDE the Test-Path guard on purpose: with the gate inside it, a missing lib\pkgconfig -- the
# most complete failure of all -- skipped every assertion and reported nothing. The opted-in
# prebuilt fallback (#68) ships no .pc BY DESIGN; that is the one legitimate skip.
Switch-BuildPhase '6. pc gate + PyAV wheel'
if ($env:FFMPEG_SOURCE_BUILD -eq '0') {
    Write-Warning 'Prebuilt fallback active (FFMPEG_ALLOW_PREBUILT=1): no .pc files exist by design; downstream consumers (gst-libav, OpenCV chain-link, PyAV) will not find FFmpeg.'
} else {
    $null = Assert-FfmpegPkgConfig -PkgConfigDir $ffPkgConfigDir
}

# ── Import-lib normalization (PyAV and other MSVC-style consumers link these) ──
# `make install` follows configure's SHLIBDIR/LIBDIR split, and ffmpeg master has already moved
# that layout once (lib\ with no .lib at all -> PyAV LNK1181). Normalize instead of chasing:
# harvest every .lib/.def into lib\, then regenerate any still-missing import lib from its .def.
if (Test-Path "$ffmpegDir\ffmpeg.exe") {
    $ffLibDir = Join-Path $prefix 'lib'
    New-Item -Path $ffLibDir -ItemType Directory -Force | Out-Null
    foreach ($pattern in @('*.lib', '*.def')) {
        $harvest = @(Get-ChildItem $prefix -Recurse -Filter $pattern -ErrorAction SilentlyContinue) +
                   @(Get-ChildItem $srcDir -Recurse -Filter $pattern -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match '^(av|sw)' })
        foreach ($f in $harvest) {
            if ($f.DirectoryName -ne $ffLibDir) {
                Write-Host "harvesting $($f.Name) from $($f.DirectoryName)"
                Copy-Item $f.FullName $ffLibDir -Force
                # inside the install prefix this is a relocation, not a copy:
                # bin\ must ship only runtime DLLs + exes
                if ($f.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item $f.FullName -Force
                }
            }
        }
    }
    foreach ($defFile in @(Get-ChildItem $ffLibDir -Filter '*.def' -ErrorAction SilentlyContinue)) {
        # avformat-63.def -> avformat.lib (unversioned, what PyAV's -lavformat resolves)
        $libName = ($defFile.BaseName -replace '-\d+$', '') + '.lib'
        $libPath = Join-Path $ffLibDir $libName
        if (-not (Test-Path $libPath)) {
            Write-Host "regenerating $libName from $($defFile.Name)"
            # /name pins the DLL the import lib binds to (our makedef emits EXPORTS only);
            # /machine follows the TARGET -- an x64 import lib cannot link into an aarch64 binary.
            [void](Invoke-ShieldedNative -Label "lib.exe /def $($defFile.Name)" -CommandLine "lib.exe /nologo /machine:$(Get-LibMachineArg -Arch $ffTargetArch) /def:`"$($defFile.FullName)`" /name:$($defFile.BaseName).dll /out:`"$libPath`"")
        }
    }
    # Fail HERE with data instead of a bare LNK1181 deep inside a setup.py. The BtbN fallback
    # legitimately ships no import libs, so only a SOURCE build asserts.
    $ffImportLibs = @(Get-ChildItem $ffLibDir -Filter '*.lib' -ErrorAction SilentlyContinue | ForEach-Object Name)
    Write-Host ("import libs in ${ffLibDir}: " + (($ffImportLibs | Sort-Object) -join ', '))
    if (([Environment]::GetEnvironmentVariable('FFMPEG_SOURCE_BUILD', 'Process') -eq '1') -and
        ($ffImportLibs -notcontains 'avformat.lib')) {
        Write-Host ("lib dir inventory: " + ((Get-ChildItem $ffLibDir -Name -ErrorAction SilentlyContinue) -join ', '))
        throw "ffmpeg install has no avformat.lib in $ffLibDir -- master drift broke import-lib generation"
    }
}

Remove-SourceBuildTree -Path $SourceDir

Write-Host "=== FFmpeg build completed ==="
Write-Host "Artifacts at: $prefix"
if (Test-Path "$ffmpegDir\ffmpeg.exe") { Write-Host "ffmpeg.exe installed" }
if (Test-Path "$ffmpegDir\ffprobe.exe") { Write-Host "ffprobe.exe installed" }
$finalDlls = @(Get-ChildItem "$ffmpegDir\*.dll" -ErrorAction SilentlyContinue)
Write-Host "runtime DLLs installed: $($finalDlls.Count)"
if (-not (Test-Path "$ffmpegDir\ffmpeg.exe")) { throw 'FFmpeg install incomplete: no ffmpeg.exe (source build and fallback both failed)' }

# ── PyAV wheel built against THIS FFmpeg ─────────────────────────────────────
# The PyPI av wheel is structurally unloadable on Server Core (its bundled avdevice hard-imports
# AVICAP32.dll), so build from sdist against OUR install: --ffmpeg-dir supplies include/lib
# directly (setup.py's pkg-config path never engages here) and python314.lib is reachable only
# via LIB. On cross (#120 step 2) the wheel is BUILT and STAGED, never imported: link inputs come
# from the TARGET CPython, and PyAV is the one consumer in this chain compiled by MSVC cl.exe, so
# `build_ext --plat-name win-arm64` picks the x86_arm64 cross tools and Assert-WheelTargetArch
# PE-checks the staged wheel in place of the import.
$ffTargetPy = Get-TargetBuildPython
if ($ffCross -and -not $ffTargetPy.Available) {
    Write-Host "Skipping the PyAV wheel: cross build without a target CPython import lib ($($ffTargetPy.Lib) missing -- did build-target-cpython.ps1 run?)"
    Complete-CurrentBuildPhase
    Write-BuildPhaseSummary -Label 'ffmpeg'
    Complete-SourceBuild -Banner '=== FFmpeg cross build completed (PyAV skipped: no target CPython) ===' -SourceDir $SourceDir
}
if ([Environment]::GetEnvironmentVariable('FFMPEG_SOURCE_BUILD', 'Process') -ne '1') {
    Write-Warning 'FFmpeg came from the prebuilt fallback (no headers/import libs) -- skipping the PyAV wheel build.'
    return
}
$pyavVersion = Get-SourceBuildVersion -EnvironmentVariables @('PYAV_VERSION') -DefaultValue '18.1.0'
Write-Host "=== PyAV $pyavVersion wheel build (against $prefix) ==="
$py = Get-SourceBuildPython
Install-CpythonPip -Python $py
Initialize-PythonPlatformTag | Out-Null
Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'cython', 'setuptools', 'wheel')
$pyavSrcRoot = 'C:\temp\pyav-src'
New-Item -Path $pyavSrcRoot -ItemType Directory -Force | Out-Null
Invoke-CpythonPip -Python $py -Arguments @('download', "av==$pyavVersion", '--no-binary', ':all:', '--no-deps', '--no-build-isolation', '-d', $pyavSrcRoot)
$pyavSdist = Get-ChildItem $pyavSrcRoot -Filter 'av-*.tar.gz' | Select-Object -First 1
if (-not $pyavSdist) { throw "PyAV sdist not downloaded to $pyavSrcRoot" }
[void](Invoke-ShieldedNative -Label 'PyAV sdist extract' -CommandLine """$($py.Exe)"" -m tarfile -e ""$($pyavSdist.FullName)"" ""$pyavSrcRoot""")
$pyavDir = (Get-ChildItem $pyavSrcRoot -Directory | Select-Object -First 1).FullName
# TARGET import-lib dir on LIB (host == target on amd64; the aarch64 python314.lib on cross).
$env:LIB = "$($ffTargetPy.LibDir);$env:LIB"
$pyavBuildCmd = if ($ffCross) {
    $distutilsPlat = (Get-PythonWheelTag) -replace '_', '-'   # win_arm64 -> win-arm64 (distutils spelling)
    "setup.py --ffmpeg-dir=""$prefix"" build_ext --plat-name $distutilsPlat bdist_wheel --plat-name $(Get-PythonWheelTag)"
} else {
    "setup.py --ffmpeg-dir=""$prefix"" bdist_wheel"
}
# One call for both lanes: -CrossStage stages + PE/name-checks on cross (the --plat-name is
# already in $pyavBuildCmd, so the helper adds no second one), installs + import-asserts natively.
Invoke-PythonWheelBuild -Python $py -WorkingDir $pyavDir -Arguments $pyavBuildCmd -ModuleName 'av' -NoDeps -CrossStage | Out-Null
Complete-CurrentBuildPhase
Write-BuildPhaseSummary -Label 'ffmpeg'
Complete-SourceBuild -Banner '=== PyAV wheel build completed ===' -SourceDir $pyavSrcRoot  # cleanup + banner + exit 0 (see module help)