# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# dav1d/x264/x265 as static libs linked into FFmpeg's DLLs, so none collides with GStreamer's; run by Build-FfmpegFromSource.ps1.

param(
    [Parameter(Mandatory)][string]$Prefix,
    [string]$WorkDir = 'C:\temp\ffmpeg-codecs-src',
    [string]$TargetArch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# arm64 first needs GStreamer's meson cross file and aarch64 asm shim reproduced here.
if (Test-WindowsCrossTarget -Arch $TargetArch) {
    Write-Host "FFmpeg codecs: none on the $(Get-WindowsTargetArch -Arch $TargetArch) cross lane yet (dav1d/x264/x265 are amd64-only; GStreamer's own dav1d/x264 plugins still ship there)"
    return [pscustomobject]@{ ConfigureFlags = @(); PkgConfigDir = $null; ConfigSymbols = @() }
}

# dav1d and x264 pin the sources GStreamer's wraps build, so the image carries one version of each.
$dav1dVersion = Get-SourceBuildVersion -EnvironmentVariables @('DAV1D_VERSION') -DefaultValue '1.4.1'
$dav1dSha256 = Get-SourceBuildVersion -EnvironmentVariables @('DAV1D_SHA256') -DefaultValue '8d407dd5fe7986413c937b14e67f36aebd06e1fa5cfec679d10e548476f2d5f8'
$x264Branch = Get-SourceBuildVersion -EnvironmentVariables @('X264_MESON_BRANCH') -DefaultValue '164.3108-meson'
$x264Commit = Get-SourceBuildVersion -EnvironmentVariables @('X264_MESON_COMMIT') -DefaultValue 'ecc833a37945073a779b42b1a9f20c4454a62fbb'
$x265Version = Get-SourceBuildVersion -EnvironmentVariables @('X265_VERSION') -DefaultValue '4.1'
$x265Sha256 = Get-SourceBuildVersion -EnvironmentVariables @('X265_SHA256') -DefaultValue 'a31699c6a89806b74b0151e5e6a7df65de4b49050482fe5ebf8a4379d7af8f29'

Reset-SourceBuildDirectory -Path $WorkDir
Reset-SourceBuildDirectory -Path $Prefix
$null = [System.IO.Directory]::CreateDirectory($WorkDir)
$libDir = Join-Path $Prefix 'lib'

# FFmpeg's msvc toolchain wants the .pc's -l<name> as <name>.lib, but meson installs lib<name>.a: read the name from the .pc.
function Copy-CodecStaticLib([string]$From, [string]$PcName) {
    $src = Join-Path $libDir $From
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "codec build installed no $src" }
    $pc = Join-Path $libDir "pkgconfig\$PcName"
    if (-not (Test-Path -LiteralPath $pc -PathType Leaf)) { throw "codec build installed no $pc" }
    $libsLine = @(Get-Content -LiteralPath $pc | Where-Object { $_ -match '^Libs:' }) | Select-Object -First 1
    $names = @([regex]::Matches("$libsLine", '(?:^|\s)-l(\S+)') | ForEach-Object { $_.Groups[1].Value })
    if ($names.Count -ne 1) { throw "$pc names $($names.Count) -l librar(ies) in '$libsLine', expected exactly one" }
    # The two exceptions in FFmpeg n9.0.2's msvc flag filter: -lz -> zlib.lib, -lx264 -> libx264.lib.
    $libName = switch ($names[0]) { 'z' { 'zlib.lib' } 'x264' { 'libx264.lib' } default { "$($names[0]).lib" } }
    Copy-Item -LiteralPath $src -Destination (Join-Path $libDir $libName) -Force
    Write-Host "FFmpeg codecs: $From -> $libName (from $PcName)"
}

# This runs before GStreamer's stage, which is where meson normally arrives.
function Initialize-CodecMeson {
    if (Get-Command meson -ErrorAction SilentlyContinue) { return }
    $py = Initialize-ToolchainPythonEnvironment
    Install-CpythonPip -Python $py | Out-Host
    Invoke-CpythonPip -Python $py -Arguments @('install', '--quiet', 'meson') | Out-Host
    $scripts = (& $py.Exe -c "import sysconfig; print(sysconfig.get_path('scripts'))" | Select-Object -First 1)
    $scripts = @("$scripts".Trim(), (Join-Path (Split-Path $py.Exe -Parent) 'Scripts')) |
        Where-Object { $_ -and (Test-Path (Join-Path $_ 'meson.exe')) } | Select-Object -First 1
    if (-not $scripts) { throw 'meson.exe not found after pip install meson' }
    $env:PATH = "$scripts;$env:PATH"
    Write-Host "FFmpeg codecs: meson $(& meson --version) from $scripts"
}

# One meson project: release, NDEBUG, static, clang-cl (meson would otherwise pick cl.exe).
function Invoke-CodecMeson([string]$Name, [string]$SourceDir, [string[]]$Options) {
    $buildDir = Join-Path $WorkDir "$Name-build"
    $saved = @{ CC = $env:CC; CXX = $env:CXX }
    # The same launcher rule as GStreamer's meson build: sccache only with a remote backend.
    $cc = if ((Test-SccacheRemoteConfigured) -and (Get-Command sccache.exe -ErrorAction SilentlyContinue)) { 'sccache clang-cl' } else { 'clang-cl' }
    $env:CC = $cc; $env:CXX = $cc
    try {
        $setup = @('setup', $buildDir, $SourceDir, "--prefix=$Prefix", '--libdir=lib',
            '--buildtype=release', '-Db_ndebug=true', '--default-library=static',
            # FFmpeg's DLLs link the static CRT, so meson's /MD default leaves __imp_ refs configure cannot resolve.
            '-Db_vscrt=mt') + $Options
        # Out-Host throughout: the result object must be this script's only pipeline output.
        & meson @setup | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "$Name meson setup failed ($LASTEXITCODE)" }
        & meson install -C $buildDir | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "$Name meson build/install failed ($LASTEXITCODE)" }
    } finally {
        $env:CC = $saved.CC; $env:CXX = $saved.CXX
    }
}

# A SHA256-pinned release tarball, extracted under the work dir; returns the source root.
function Get-CodecTarball([string]$Name, [string]$Url, [string]$Sha256) {
    $archive = Join-Path $WorkDir ([IO.Path]::GetFileName($Url))
    $null = Invoke-DownloadWithRetry -Url $Url -DestinationPath $archive -ExpectedSha256 $Sha256 -Description $Name
    return Expand-SourceTarball -Archive $archive -Destination (Join-Path $WorkDir ($Name -replace '\s.*$', ''))
}

Initialize-CodecMeson

# ── dav1d: AV1 decode (x86 asm through nasm) ─────────────────────────────────
$dav1dSrc = Get-CodecTarball -Name "dav1d $dav1dVersion" -Sha256 $dav1dSha256 `
    -Url "https://download.videolan.org/pub/videolan/dav1d/$dav1dVersion/dav1d-$dav1dVersion.tar.xz"
Invoke-CodecMeson -Name 'dav1d' -SourceDir $dav1dSrc -Options @('-Denable_tools=false', '-Denable_tests=false', '-Denable_asm=true')
Copy-CodecStaticLib -From 'libdav1d.a' -PcName 'dav1d.pc'

# ── x264: H.264 encode (GStreamer's meson port; x86 asm through nasm) ─────────
$x264Src = Join-Path $WorkDir 'x264'
Invoke-GitClone -RepoUrl 'https://gitlab.freedesktop.org/gstreamer/meson-ports/x264.git' -Branch $x264Branch -SourceDir $x264Src -Depth 1 | Out-Null
$x264Head = (& git -C $x264Src rev-parse HEAD).Trim()
if ($x264Head -ne $x264Commit) { throw "x264 meson port branch $x264Branch is at $x264Head, not the pinned $x264Commit -- re-derive X264_MESON_COMMIT from GStreamer's subprojects/x264.wrap" }
Invoke-CodecMeson -Name 'x264' -SourceDir $x264Src -Options @('-Dcli=false')
Copy-CodecStaticLib -From 'libx264.a' -PcName 'x264.pc'

# ── x265: HEVC encode (CMake; x86 asm through nasm) ───────────────────────────
$x265Root = Get-CodecTarball -Name "x265 $x265Version" -Sha256 $x265Sha256 `
    -Url "https://bitbucket.org/multicoreware/x265_git/downloads/x265_$x265Version.tar.gz"
# x265 4.1 sets CMP0025/CMP0054 to OLD, which CMake 4 refuses; a bump that rewrites those lines fails here loudly.
$x265Cml = Join-Path $x265Root 'source\CMakeLists.txt'
$x265Text = [System.IO.File]::ReadAllText($x265Cml)
foreach ($policy in 'CMP0025', 'CMP0054') {
    $old = "cmake_policy(SET $policy OLD)"
    if (-not $x265Text.Contains($old)) { throw "x265 $x265Version CMakeLists.txt no longer says '$old': re-check the CMake 4 policy patch" }
    $x265Text = $x265Text.Replace($old, "cmake_policy(SET $policy NEW)")
}
[System.IO.File]::WriteAllText($x265Cml, $x265Text)
$x265Build = Join-Path $WorkDir 'x265-build'
Invoke-CmakeConfigure -SourceDir (Join-Path $x265Root 'source') -BuildDir $x265Build -InstallPrefix $Prefix -Generator 'Ninja' `
    -ExtraArgs (@('-DENABLE_SHARED=OFF', '-DENABLE_CLI=OFF', '-DENABLE_ASSEMBLY=ON', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
        # The static CRT, like dav1d/x264 above and FFmpeg itself: x265's own switch rewrites /MD to /MT.
        '-DSTATIC_LINK_CRT=ON') + @(Get-LlvmArchiverCmakeArg)) | Out-Host
Invoke-NinjaBuildWithRetry -BuildDir $x265Build -Install -InstallConfig 'Release' | Out-Host
Copy-CodecStaticLib -From 'x265-static.lib' -PcName 'x265.pc'

# Each .pc was read by Copy-CodecStaticLib above, which throws on a missing one.
$pkgConfigDir = Join-Path $libDir 'pkgconfig'
Write-Host "FFmpeg codecs: dav1d $dav1dVersion, x264 $x264Branch@$($x264Commit.Substring(0, 8)), x265 $x265Version -> $Prefix (static)"
return [pscustomobject]@{
    ConfigureFlags = @('--enable-libdav1d', '--enable-libx264', '--enable-libx265')
    PkgConfigDir   = $pkgConfigDir
    ConfigSymbols  = @('CONFIG_LIBDAV1D', 'CONFIG_LIBX264', 'CONFIG_LIBX265')
}
