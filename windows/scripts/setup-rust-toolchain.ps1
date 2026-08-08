# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$modulePath = Join-Path $PSScriptRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $modulePath)) {
    throw "Required module not found: $modulePath"
}
Import-Module $modulePath -Force

# rustup WITH a default toolchain -- NOT scoop rust, NOT toolchain-less rustup.
# Flutter's Cargokit (flutter_rust_bridge-style plugins, e.g. rust_builder/cargokit
# in Kataglyphis-Inference-Engine) hard-requires rustup: its build_tool enumerates
# toolchains/targets via rustup and aborts with "rustup not found in PATH."
# otherwise, so scoop-only Rust broke every Flutter+Rust consumer build.
# The old "never rustup" rule targeted a NARROWER failure than the rule: a
# toolchain-less rustup (--default-toolchain none) leaves proxy shims in CARGO_BIN
# that resolve no toolchain. Installed WITH a default toolchain the proxies resolve
# a real one, and because CARGO_BIN sits ahead of scoop's shims on PATH they now
# correctly win. See docs/windows-builds.md, "Rust toolchain".
#
# DELIBERATELY UNPINNED: `stable` resolves to the latest stable at build time
# (versions.env's RUST_VERSION pins only the Linux lane). The smoke test asserts a
# well-formed rustc version + a compile/link/run probe, NOT the versions.env value
# -- keep it that way, or the install fails its own smoke test on the next release.

# PS 5.1 trap: rustup-init and cargo write progress to STDERR; with 2>&1 under
# EAP=Stop the first stderr line would throw. Run native rust steps under
# EAP=Continue and gate on $LASTEXITCODE explicitly instead. Use this ONLY for
# short commands -- long-running ones go through Invoke-RustProcessWithHeartbeat.
function Invoke-NativeRustStep {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Command
    )
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # A CommandNotFoundException under this local EAP=Continue does NOT abort
        # the step but leaves $LASTEXITCODE stale from an earlier native call --
        # null it first and treat "still null" as failure, so a missing binary can
        # never ride a stale 0 into a green step.
        $global:LASTEXITCODE = $null
        & $Command 2>&1 | ForEach-Object { "$_" } | Out-Host
        if ($null -eq $LASTEXITCODE) { throw "$Description failed: command missing or produced no exit code" }
        if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit $LASTEXITCODE)" }
    } finally {
        $ErrorActionPreference = $previousEap
    }
}

# HOST QUIRK (diagnosed across 5 base builds, 2026-07-15): rustup-init's own
# (parallel) component download/install deadlocks in this host's 2-CPU Hyper-V
# docker-build containers -- 4/5 runs froze at "downloading 3 components" with
# ~5 s of CPU used, an unkillable kernel-stuck process, and a half-installed
# toolchain ("Missing manifest in toolchain"). It froze identically with output
# on the console AND redirected to files, so it is NOT output plumbing; the
# real fix is bypassing rustup's downloader entirely (see the local dist mirror
# below). This wrapper stays as defense in depth for anything long-running:
# (1) the child's output goes to FILES (keeps the docker log readable and the
# child independent of the console relay); (2) a 30 s heartbeat shows liveness
# in the docker log; (3) a hard timeout turns a residual wedge into a clean
# step failure instead of an infinite hang.
function Invoke-RustProcessWithHeartbeat {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [int]$TimeoutSec = 1800
    )
    $logBase = Join-Path $env:TEMP ("rust-{0}" -f ($Description -replace '[^A-Za-z0-9]', '-'))
    $outLog = "$logBase.out.log"; $errLog = "$logBase.err.log"
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru `
        -RedirectStandardOutput "$outLog" -RedirectStandardError "$errLog"
    # PS 5.1 trap: without touching .Handle, the Process object never acquires a
    # handle and $p.ExitCode stays $null after exit (a completed rustup-init then
    # "fails (exit )"). Cache it now; argless WaitForExit() after the loop flushes
    # the exit state for the same reason.
    $null = $p.Handle
    $elapsed = 0
    while (-not $p.WaitForExit(30000)) {
        $elapsed += 30
        Write-Host ("[{0}] running... {1}s elapsed" -f $Description, $elapsed)
        if ($elapsed -ge $TimeoutSec) {
            # Kill the wedged child BEFORE throwing: the HOST QUIRK above is exactly
            # a kernel-stuck child, and leaving it alive keeps its handles (and the
            # RUN step) wedged long after this step has nominally failed. Guarded:
            # a kernel-stuck process may refuse Kill, and that must not mask the
            # timeout diagnostic below.
            try {
                $p.Kill($true)
                $p.Dispose()
            } catch {
                Write-Host ("[{0}] could not kill/dispose timed-out process: {1}" -f $Description, $_.Exception.Message)
            }
            throw ("{0} timed out after {1}s (see {2} / {3})" -f $Description, $TimeoutSec, $outLog, $errLog)
        }
    }
    $p.WaitForExit()
    foreach ($f in @($outLog, $errLog)) {
        if ((Test-Path $f) -and ((Get-Item $f).Length -gt 0)) {
            Write-Host ("--- {0} (last 40 lines) ---" -f (Split-Path $f -Leaf))
            Get-Content $f -Tail 40 | Out-Host
        }
    }
    if ($p.ExitCode -ne 0) { throw ("{0} failed (exit {1})" -f $Description, $p.ExitCode) }
    # Success: the logs were only diagnostics (their tails are already echoed above)
    # -- drop them so they do not ride into the layer. On failure they are kept and
    # referenced by the throw messages.
    Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue
}

Write-Host 'Installing Rust via rustup (stable default toolchain; single provider)...'
$rustupInit = Join-Path $env:TEMP 'rustup-init.exe'
Invoke-DownloadWithRetry -Url 'https://win.rustup.rs/x86_64' -DestinationPath $rustupInit `
    -Description 'rustup-init' -ExpectSignature MZ

# Local dist mirror: pre-fetch the stable channel manifest + the three msvc
# component tarballs with Invoke-DownloadWithRetry (single-stream, retrying,
# proven reliable in these containers -- unlike rustup's own downloader, see the
# HOST QUIRK note above), rewrite the manifest's URLs to file:// paths, regenerate
# the manifest .sha256 to match, and point RUSTUP_DIST_SERVER at the mirror.
# rustup-init then installs via plain file copies -- no network, no deadlock.
$targetTriple = 'x86_64-pc-windows-msvc'
$mirrorRoot = Join-Path $env:TEMP 'rustup-dist'
$distDir = Join-Path $mirrorRoot 'dist'
New-Item -Path $distDir -ItemType Directory -Force | Out-Null
$manifestPath = Join-Path $distDir 'channel-rust-stable.toml'
Invoke-DownloadWithRetry -Url 'https://static.rust-lang.org/dist/channel-rust-stable.toml' `
    -DestinationPath $manifestPath -Description 'rust stable channel manifest'

$manifest = Get-Content -Path $manifestPath -Raw
$componentUrls = @([regex]::Matches($manifest, 'xz_url\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -match "/(rustc|rust-std|cargo|rustfmt|clippy)-\d[^/]*-$([regex]::Escape($targetTriple))\.tar\.xz$" } |
    Sort-Object -Unique)
if ($componentUrls.Count -lt 3) {
    throw "expected at least the rustc/rust-std/cargo $targetTriple tarball URLs in the channel manifest, found $($componentUrls.Count)"
}
foreach ($url in $componentUrls) {
    $relative = ($url -replace '^https://static\.rust-lang\.org/dist/', '') -replace '/', '\'
    $destination = Join-Path $distDir $relative
    Invoke-DownloadWithRetry -Url $url -DestinationPath $destination -Description (Split-Path $relative -Leaf)
}

# file:///C:/... form; forward slashes. The manifest hash file must be regenerated
# because the URL rewrite changed the manifest bytes (rustup verifies it).
$mirrorUrl = 'file:///' + ($mirrorRoot -replace '\\', '/')
$manifest = $manifest -replace 'https://static\.rust-lang\.org', $mirrorUrl
Set-Content -Path $manifestPath -Value $manifest -Encoding ASCII -NoNewline
$manifestHash = (Get-FileHash -Path $manifestPath -Algorithm SHA256).Hash.ToLower()
Set-Content -Path "$manifestPath.sha256" -Value "$manifestHash  channel-rust-stable.toml" -Encoding ASCII

$env:RUSTUP_DIST_SERVER = $mirrorUrl
# Single-threaded unpack: the deadlock class this guards against is thread-pool
# contention in a 2-CPU container; determinism beats a minute of unpack speed.
$env:RUSTUP_IO_THREADS = '1'

# --no-modify-path: we don't need rustup's PATH edit (Dockerfile.base already puts
# CARGO_BIN on the baked PATH).
# try/finally: the multi-GB mirror, the installer and the env override must go away
# on the FAILURE path too (previously success-path-only, so a failed install left
# them behind for the layer / the next diagnostic run).
try {
    # -c rustfmt -c clippy: install them HERE, while the local mirror still
    # exists. The component tarballs are already fetched above (the URL regex
    # includes both), but `--profile minimal` does not install them and the
    # finally block then deletes the mirror. What survives is a cached channel
    # manifest whose URLs were rewritten to file:///...\rustup-dist - a path
    # that no longer exists - so a later `rustup component add rustfmt` fails
    # with "could not download file from file:///... : file not found", offline
    # and unfixable at runtime.
    #
    # That is not hypothetical: a consumer's Build-Windows.ps1 catches exactly
    # that failure and logs "rustfmt unavailable in this image (offline
    # rustup); skipping the format check", then reports the step as COMPLETED.
    # Its format and clippy gates have therefore never run against this image -
    # each finished in ~0.1s (measured 2026-08-07). Installing the components
    # at image-build time is what makes those gates real.
    Invoke-RustProcessWithHeartbeat -Description 'rustup-init' -FilePath $rustupInit `
        -ArgumentList @('-y', '--no-modify-path', '--default-toolchain', 'stable', '--profile', 'minimal',
                        '-c', 'rustfmt', '-c', 'clippy') `
        -TimeoutSec 900
} finally {
    Remove-Item $rustupInit -Force -ErrorAction SilentlyContinue
    Remove-Item $mirrorRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\RUSTUP_DIST_SERVER -ErrorAction SilentlyContinue
}

# CARGO_HOME (Dockerfile.base) already points at C:\Users\ContainerAdministrator\.cargo,
# so the rustup proxies land in CARGO_BIN, which the persistent PATH already carries
# for later build stages. Prepend it to THIS process's PATH so the asserts below
# resolve immediately.
$cargoBin = if ($env:CARGO_BIN) { $env:CARGO_BIN } else { Join-Path $env:USERPROFILE '.cargo\bin' }
if (Test-Path (Join-Path $cargoBin 'cargo.exe')) {
    $env:PATH = "$cargoBin;$env:PATH"
    Write-Host "Using rustup-managed Rust binaries at $cargoBin"
}

Assert-ContainerCommandAvailable -Name 'rustup' | Out-Null
Assert-ContainerCommandAvailable -Name 'cargo' | Out-Null
Assert-ContainerCommandAvailable -Name 'rustc' | Out-Null

# Idempotent re-assert of the default: rustup-init sets it, but if its tail ever
# stalls again this keeps the proxies resolving a toolchain deterministically.
Invoke-NativeRustStep -Description 'rustup default stable' -Command { rustup default stable }
Invoke-NativeRustStep -Description 'cargo --version' -Command { cargo --version }
Invoke-NativeRustStep -Description 'rustc --version' -Command { rustc --version }

# Assert the lint components at BUILD time. They cannot be added later: the dist
# mirror is deleted a few lines up and the cached manifest points at file:///
# paths that no longer resolve. A consumer that finds them missing degrades to
# "skipping the format check" and still reports success, so the only place this
# can be caught is here, while it is still fixable.
Invoke-NativeRustStep -Description 'cargo fmt --version' -Command { cargo fmt --version }
Invoke-NativeRustStep -Description 'cargo clippy --version' -Command { cargo clippy --version }

# Cargokit-shaped asserts: these two calls are exactly what flutter_rust_bridge's
# build_tool runs; failing here is cheaper than failing in every consumer build.
Invoke-NativeRustStep -Description 'rustup show active-toolchain' -Command { rustup show active-toolchain }
Invoke-NativeRustStep -Description 'rustup which cargo' -Command { rustup which cargo }

# Bake flutter_rust_bridge_codegen: consumer builds otherwise cargo-install it on
# first run, costing minutes of cold cargo time per fresh container. Long-running
# compile -> heartbeat wrapper (same relay-wedge defense as rustup-init).
Write-Host 'Baking flutter_rust_bridge_codegen (cargo install)...'
Invoke-RustProcessWithHeartbeat -Description 'cargo-install-frb-codegen' `
    -FilePath (Join-Path $cargoBin 'cargo.exe') `
    -ArgumentList @('install', 'flutter_rust_bridge_codegen', '--locked') `
    -TimeoutSec 2400
Invoke-NativeRustStep -Description 'flutter_rust_bridge_codegen --version' -Command {
    flutter_rust_bridge_codegen --version
}

# ── sccache FROM SOURCE, overwriting the scoop baseline on PATH ───────────────
# Released sccache cannot wrap nvcc on CUDA 13.3: it decomposes nvcc by parsing
# `nvcc --dryrun`, and 13.3.33 moved `--simt-only` AFTER the input file, so the
# positional parser took the flag as the input, mis-grouped the cicc/ptxas
# device steps, and the per-arch .cubin files were never produced. The build
# dies at the combine step with
#   fatbinary fatal : Could not open input file '<tu>.compute_80.cubin'
# (measured here 2026-08-08 on ONNX's CUDA provider). Upstream fix:
# mozilla/sccache#2722, merged 2026-08-04 — five days AFTER v0.17.0 shipped, so
# no release carries it yet. SCCACHE_GIT_REV pins that merge commit.
#
# This is what makes CMAKE_CUDA_COMPILER_LAUNCHER usable, i.e. what lets ~1h of
# CUDA/TensorRT kernel compiles be cached instead of re-paid every run.
#
# Lands in CARGO_BIN, which sits BEFORE the scoop shims in Dockerfile.base's
# PATH, so this binary wins. The scoop install stays as the version-pinned
# baseline; verify-toolchain.ps1 asserts that the CARGO_BIN one is what
# resolves, because `sccache --version` CANNOT tell them apart (main still
# reports 0.17.0).
#
# Default features are `all`, which includes `webdav` — the L2 backend must not
# quietly disappear from a source build.
$sccacheRev = [string]$env:SCCACHE_GIT_REV
if ([string]::IsNullOrWhiteSpace($sccacheRev)) {
    throw 'SCCACHE_GIT_REV is not set (versions.env not loaded?) — refusing to build an unpinned sccache.'
}
Write-Host "Building sccache from source at $sccacheRev (CUDA 13.3 nvcc fix, mozilla/sccache#2722)..."
Invoke-RustProcessWithHeartbeat -Description 'cargo-install-sccache' `
    -FilePath (Join-Path $cargoBin 'cargo.exe') `
    -ArgumentList @('install', 'sccache', '--locked', '--git', 'https://github.com/mozilla/sccache', '--rev', $sccacheRev) `
    -TimeoutSec 3600
Invoke-NativeRustStep -Description 'sccache --version (cargo build)' -Command {
    & (Join-Path $cargoBin 'sccache.exe') --version
}

# Drop the registry/build intermediates -- only CARGO_BIN needs to ship in the layer.
foreach ($cacheDir in @('registry', 'git')) {
    $p = Join-Path $env:USERPROFILE ".cargo\$cacheDir"
    if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
}

