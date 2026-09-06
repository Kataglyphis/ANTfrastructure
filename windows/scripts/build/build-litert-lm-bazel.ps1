#requires -Version 7.0

# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Build LiteRT-LM the OFFICIAL, Google-maintained way:
#   bazelisk build //runtime/engine:litert_lm_main --config=windows
# and install litert_lm_main.exe (+ co-located runtime DLLs) into
# $InstallDir\lib\litert-lm\bin for the media-litert branch export.
#
# WHY BAZEL (2026-08-12): the CMake port (build-litert-lm-from-source.ps1)
# is an unmaintained upstream second-path - one v0.15.0 bump peeled FIVE
# breakage shells (missing protos, stale absl pin, stale litert pin, always-
# on example subprojects, ruy -isystem), each ~2.5 h. The bazel path is
# Google's CI-tested one: PROVEN here to build a working 19 MB
# litert_lm_main.exe in ~9 min / 5094 actions with ZERO code patches. The
# CMake port stays as the frozen fallback (build-litert-lm-from-source.ps1);
# this replaces its litert_lm_main output only. The LiteRT C++ SDK export
# (C:\runtime\lib\litert) is a SEPARATE stage (build-litert-from-source.ps1)
# and is untouched.
#
# The only non-obvious work is neutralizing the toolchain image's Android env
# pollution (baked ANDROID_* for other lanes) so TF's bazel rules don't fire:
#   - TF android_configure.bzl does int($ANDROID_NDK_VERSION) on the dotted
#     revision "29.0.14206865" -> clear ANDROID_NDK_VERSION only;
#   - LiteRT-LM WORKSPACE unconditionally calls android_{ndk,sdk}_repository
#     -> comment both out (no android targets). Do NOT empty ANDROID_HOME
#     (empty -> android_sdk_repository resolves workspace-relative -> the
#     "Expected directory at <ws>/platforms" failure).
#
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\runtime',
    # A bazel repository cache dir (mount it for cross-run reuse). The bazel
    # OUTPUT_BASE deliberately stays container-local (C:\bzl): it is
    # rename-heavy and the BuildKit cache mount is wcifs rename-hostile (same
    # hazard family as the sccache write errors).
    [string]$RepositoryCache = '',
    [string]$LitertLmVersion = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($LitertLmVersion)) {
    $LitertLmVersion = if ($env:LITERT_LM_VERSION) { $env:LITERT_LM_VERSION } else { '0.16.1' }
}
$tag = if ($LitertLmVersion -match '^v') { $LitertLmVersion } else { "v$LitertLmVersion" }

# Self-contained download retry (the script runs both standalone and in the
# chain, so it does not depend on the build modules). A transient
# "response ended prematurely" on the JDK fetch killed run 24 - fetches
# over the public internet MUST retry.
function Get-UrlWithRetry {
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$OutFile, [int]$Retries = 4)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
            if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0) { return }
            throw 'downloaded file is missing or empty'
        } catch {
            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
            if ($i -eq $Retries) { throw "download failed after $Retries attempts [$Uri]: $($_.Exception.Message)" }
            Write-Host ("  download attempt {0}/{1} failed [{2}]: {3} - retrying in {4}s" -f $i, $Retries, $Uri, $_.Exception.Message, ($i * 5))
            Start-Sleep -Seconds ($i * 5)
        }
    }
}

Write-Host "=== [1/6] prerequisites: long paths + bazelisk + JDK (LiteRT-LM $tag) ==="
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f | Out-Null
New-Item -ItemType Directory -Force -Path C:\bzl-tools | Out-Null

# Tool CACHE on the persistent bazel mount (run 26: api.adoptium.net was
# unreachable for all 4 retries - a per-build live download of the JDK is a
# reliability liability). Download bazelisk + JDK ONCE, reuse thereafter;
# only fetch over the network on a cold cache. -RepositoryCache is the mount.
$toolCache = if ($RepositoryCache) { Join-Path $RepositoryCache 'toolcache' } else { 'C:\bzl-tools' }
New-Item -ItemType Directory -Force -Path $toolCache | Out-Null
$cachedBazelisk = Join-Path $toolCache 'bazelisk.exe'
$cachedJdkZip = Join-Path $toolCache 'jdk.zip'
if (-not (Test-Path $cachedBazelisk) -or (Get-Item $cachedBazelisk).Length -eq 0) {
    Get-UrlWithRetry -Uri 'https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-windows-amd64.exe' -OutFile $cachedBazelisk
} else { Write-Host '  bazelisk: cache hit' }
if (-not (Test-Path $cachedJdkZip) -or (Get-Item $cachedJdkZip).Length -eq 0) {
    # Prefer the Adoptium GitHub release asset (github is this repo's reliable
    # download host) over the flaky api.adoptium.net redirect.
    try {
        Get-UrlWithRetry -Uri 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.5%2B11/OpenJDK21U-jdk_x64_windows_hotspot_21.0.5_11.zip' -OutFile $cachedJdkZip
    } catch {
        Write-Host '  github JDK asset failed - falling back to api.adoptium.net'
        Get-UrlWithRetry -Uri 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse?project=jdk' -OutFile $cachedJdkZip
    }
} else { Write-Host '  JDK: cache hit' }
Copy-Item $cachedBazelisk C:\bzl-tools\bazelisk.exe -Force
& 7z x $cachedJdkZip -oC:\bzl-tools\jdk -y -bd | Out-Null
$env:JAVA_HOME = (Get-ChildItem C:\bzl-tools\jdk -Directory | Select-Object -First 1).FullName

Write-Host "=== [2/6] clone $tag + git lfs (prebuilt libs) ==="
if (-not (Get-Command git-lfs -ErrorAction SilentlyContinue)) { & scoop install main/git-lfs 2>&1 | Select-Object -Last 1 }
& git lfs install --skip-repo 2>&1 | Out-Null
& git clone --depth 1 --branch $tag https://github.com/google-ai-edge/LiteRT-LM.git C:\llm 2>&1 | Select-Object -Last 2
Push-Location C:\llm
try {
    & git lfs pull 2>&1 | Select-Object -Last 2

    Write-Host '=== [3/6] neutralize the WORKSPACE Android repository rules ==='
    $ws = Get-Content C:\llm\WORKSPACE -Raw
    $ws = $ws.Replace('android_ndk_repository(name = "androidndk")', '# [bazel-port] android_ndk_repository disabled (no android targets)')
    $ws = $ws.Replace('android_sdk_repository(name = "androidsdk")', '# [bazel-port] android_sdk_repository disabled (no android targets)')
    # zlib.net/fossils is a notoriously flaky host (8/8 bazel download retries
    # timed out mid-build). The @minizip repo pulls zlib-1.3.1.tar.gz from there
    # with NO sha256, so it re-downloads every run. Point it at the official
    # zlib 1.3.1 release asset on GitHub -- byte-identical tarball (same
    # zlib-1.3.1/ layout, so strip_prefix still resolves), reliable host.
    $ws = $ws.Replace('https://zlib.net/fossils/zlib-1.3.1.tar.gz', 'https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz')
    Set-Content -Path C:\llm\WORKSPACE -Value $ws -NoNewline

    Write-Host '=== [4/6] bazel env ==='
    [Environment]::SetEnvironmentVariable('ANDROID_NDK_VERSION', $null, 'Machine')
    # Process scope: Remove-Item, not SetEnvironmentVariable($null) -- the latter
    # leaves the variable defined-empty from PowerShell, which a native child
    # (bazel here) still sees as set.
    Remove-Item -Path Env:ANDROID_NDK_VERSION -ErrorAction SilentlyContinue
    $bazelArgs = @('--output_base=C:\bzl')
    $buildArgs = @('--config=windows', '--repo_env=ANDROID_NDK_VERSION=')
    # DELIBERATELY NO --repository_cache on the mount: bazel's
    # content_addressable cache writes temp files and RENAMES them into place,
    # and the BuildKit cache mount is wcifs rename-hostile - run 27 died
    # exactly there ("FileNotFoundException: ...content_addressable\...\tmp-").
    # This is the same hazard the header notes for output_base (kept
    # container-local at C:\bzl). The mount is used ONLY for the tool cache
    # above (plain Copy-Item, create-only - wcifs-safe). Cross-run caching of
    # bazel's own repo deps is left for a later wcifs-safe transport (e.g. the
    # WebDAV handoff the chain already uses); bazel re-fetches from
    # github/google mirrors each run, which is reliable enough.
    $env:BAZEL_VC = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC'
    $py = 'C:\temp\cpython\PCbuild\amd64'
    if (Test-Path "$py\python.exe") { $env:PATH = "$py;$env:PATH" }
    $env:PATH = "C:\bzl-tools;$env:JAVA_HOME\bin;$env:PATH"

    Write-Host '=== [5/6] bazelisk build //runtime/engine:litert_lm_main --config=windows ==='
    & C:\bzl-tools\bazelisk.exe @bazelArgs build //runtime/engine:litert_lm_main @buildArgs 2>&1 |
        Tee-Object -FilePath C:\bazel-build.log | Select-Object -Last 20
    $bexit = $LASTEXITCODE
    if ($bexit -ne 0) {
        [Console]::Error.WriteLine("--- bazel build failed ($bexit); last 60 log lines ---")
        Get-Content C:\bazel-build.log -Tail 60 | ForEach-Object { [Console]::Error.WriteLine($_) }
        Start-Sleep -Seconds 2
        throw "bazel build failed ($bexit)"
    }

    Write-Host '=== [6/6] install exe + runtime DLLs, smoke-run ==='
    $exe = 'C:\llm\bazel-bin\runtime\engine\litert_lm_main.exe'
    if (-not (Test-Path $exe)) { throw 'bazel green but litert_lm_main.exe missing' }
    $binOut = Join-Path $InstallDir 'lib\litert-lm\bin'
    New-Item -ItemType Directory -Force -Path $binOut | Out-Null
    Copy-Item $exe $binOut -Force
    # Co-located runtime DLLs (kissfft/z/vcruntime and any prebuilt .dll the
    # exe dlopen/loads) live next to it in bazel-bin and/or the runfiles tree;
    # gather every .dll from both so the exe resolves standalone (the final
    # smoke runs it with only this bin\ on PATH).
    $dllSources = @('C:\llm\bazel-bin\runtime\engine', 'C:\llm\bazel-bin\runtime\engine\litert_lm_main.exe.runfiles')
    foreach ($s in $dllSources) {
        if (Test-Path $s) {
            Get-ChildItem -Path $s -Filter '*.dll' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item $_.FullName $binOut -Force -ErrorAction SilentlyContinue
            }
        }
    }
    # Count what LANDED, not what was attempted (2026-08-22). The old counter
    # incremented once per source file found and never looked at the result:
    # the two sources include the bazel RUNFILES tree, a symlink farm carrying
    # the same DLL names repeatedly, and the copies are -ErrorAction
    # SilentlyContinue. It reported "5 DLL(s) co-located" for a directory
    # holding ONE — attempts dressed up as artifacts. The contract guard below
    # counts the directory and disagreed, which is how this surfaced.
    $dllCount = @(Get-ChildItem -LiteralPath $binOut -Filter '*.dll' -File -ErrorAction SilentlyContinue).Count
    # Headers are informational in the smoke (Test-Path-gated); stage the
    # public runtime headers best-effort so downstream apps can include them.
    $incOut = Join-Path $InstallDir 'lib\litert-lm\include'
    New-Item -ItemType Directory -Force -Path $incOut | Out-Null
    if (Test-Path 'C:\llm\runtime\engine') {
        Get-ChildItem 'C:\llm\runtime\engine' -Filter '*.h' -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-Item $_.FullName $incOut -Force -ErrorAction SilentlyContinue }
    }

    $installedExe = Join-Path $binOut 'litert_lm_main.exe'
    $sz = (Get-Item $installedExe).Length
    $prevPath = $env:PATH; $env:PATH = "$binOut;$env:PATH"
    try { $help = (& cmd /c "`"$installedExe`" --help 2>&1" | Out-String) } finally { $env:PATH = $prevPath }
    # SUCCESS is "the exe reached its flag parser" (output match) + files in
    # place - NOT the --help exit code, which is 1 for abseil-style CLIs that
    # treat --help as "no command run". Reset $LASTEXITCODE so the &-caller
    # (build-litert-all.ps1) does not misread that 1 as a build failure
    # (run 25: INSTALLED marker printed, then a false "build failed (exit 1)").
    if ($help -notmatch 'model_path|input_prompt|Flags from') {
        throw "installed litert_lm_main.exe did not reach its flag parser (missing DLL?). Output: $($help.Substring(0,[Math]::Min(300,$help.Length)))"
    }
    $global:LASTEXITCODE = 0
    Write-Host ("LiteRT-LM (bazel) INSTALLED: {0} ({1:N0} bytes, {2} DLL(s) co-located, --help OK)" -f $installedExe, $sz, $dllCount)

    # CONTRACT GUARD (2026-08-22): the merge image declares LITERT_LM_ROOT /
    # _INCLUDE / _BIN as a promise to consumers. Nothing verified that promise
    # in-stage, so a shortfall surfaced only at the smoke gate — HOURS later,
    # at the end of the whole chain — or not at all: LITERT_LM_LIB pointed at a
    # directory that never existed for ELEVEN WEEKS before an assertion caught
    # it (#127). The header copy above is deliberately best-effort
    # (-ErrorAction SilentlyContinue), which is exactly how an EMPTY include\
    # would slip through unnoticed. Assert the declared layout here, where the
    # failure is cheap and names the stage that owns it.
    $contract = @(
        @{ Path = $binOut; Filter = '*.exe'; What = 'LITERT_LM_BIN executable' }
        @{ Path = $binOut; Filter = '*.dll'; What = 'LITERT_LM_BIN runtime DLLs' }
        @{ Path = $incOut; Filter = '*.h'; What = 'LITERT_LM_INCLUDE headers' }
    )
    $shortfall = @()
    foreach ($c in $contract) {
        $n = @(Get-ChildItem -LiteralPath $c.Path -Filter $c.Filter -File -Recurse -ErrorAction SilentlyContinue).Count
        Write-Host ("  contract: {0,-28} {1,4} file(s) in {2}" -f $c.What, $n, $c.Path)
        if ($n -lt 1) { $shortfall += ('{0} — nothing matching {1} in {2}' -f $c.What, $c.Filter, $c.Path) }
    }
    if ($shortfall.Count -gt 0) {
        throw ("LiteRT-LM install does not satisfy the layout the merge image declares:`n  " +
            ($shortfall -join "`n  ") +
            "`nFix the install here, or correct the ENV in windows\Dockerfile.media-merge-builder — " +
            'but never leave the image promising a path it does not ship.')
    }
} finally {
    Pop-Location
}
