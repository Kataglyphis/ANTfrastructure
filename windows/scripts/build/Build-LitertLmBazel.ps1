#requires -Version 7.0

# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
# litert_lm_main via upstream's CI-tested bazel path; the CMake port (Build-LitertLmFromSource.ps1) is the frozen fallback.
#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\runtime',
    # A mounted cache dir for the tool cache; bazel's own caches rename files, which the wcifs mount breaks.
    [string]$RepositoryCache = '',
    [string]$LitertLmVersion = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

if ([string]::IsNullOrWhiteSpace($LitertLmVersion)) {
    $LitertLmVersion = if ($env:LITERT_LM_VERSION) { $env:LITERT_LM_VERSION } else { '0.17.1' }
}
$tag = if ($LitertLmVersion -match '^v') { $LitertLmVersion } else { "v$LitertLmVersion" }

# Self-contained retry: this script also runs standalone, without the build modules.
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

# rocm adds the WebGPU (Dawn -> D3D12) backend; `$GpuType -eq 'rocm'` stands in for HasRocm. See docs/windows-builds.md § ROCm layer

function Get-LitertLmBazelArg {
    # The bazel command after the startup options. cpu/nvidia get exactly the pre-rocm command.
    param([string]$GpuType)
    $targets = @('//runtime/engine:litert_lm_main')
    if ($GpuType -eq 'rocm') { $targets += '@directx_shader_compiler//:dxc_dlls' }
    return @('build') + $targets + @('--config=windows', '--repo_env=ANDROID_NDK_VERSION=')
}

function Get-LitertLmRocmEnvScrub {
    # rocm lane: name -> value ($null unsets) for env entries into the ROCm tree and HIP_PLATFORM, hiding TheRock from bazel.
    param([string]$GpuType, [Parameter(Mandatory)][System.Collections.IDictionary]$Environment)
    $scrub = @{}
    if ($GpuType -ne 'rocm') { return $scrub }
    $norm = { param([string]$p) $p.Trim().Replace('/', '\').TrimEnd('\') }
    $roots = @(foreach ($name in @($Environment.Keys)) {
            $value = [string]$Environment[$name]
            if ($name -in 'ROCM_PATH', 'HIP_PATH' -and $value.Trim()) { & $norm $value }
        })
    $inRocm = { param([string]$entry)
        $e = & $norm $entry
        foreach ($r in $roots) { if ($e -ieq $r -or $e.StartsWith("$r\", [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    foreach ($name in @($Environment.Keys)) {
        if ($name -ieq 'HIP_PLATFORM') { $scrub[$name] = $null; continue }
        $entries = @(([string]$Environment[$name]) -split ';')
        $kept = @($entries | Where-Object { -not (& $inRocm $_) })
        if ($kept.Count -eq $entries.Count) { continue }
        $scrub[$name] = if (@($kept | Where-Object { $_.Trim() }).Count -eq 0) { $null } else { $kept -join ';' }
    }
    return $scrub
}

function Set-LitertLmProcessEnv {
    # Sets name -> value in this process ($null removes it) and returns the previous values for the restore.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $previous = @{}
    foreach ($name in @($Values.Keys)) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        if ($null -eq $Values[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath "Env:$name" -Value $Values[$name] }
    }
    return $previous
}

function Assert-LitertLmDxcPin {
    # Bazel verifies the DXC zip against upstream's WORKSPACE sha256; this ties that sha to versions.env.
    param([Parameter(Mandatory)][string]$Workspace, [string]$Expected)
    if (-not $Expected) { throw 'LITERT_LM_DXC_ZIP_SHA256 is not set: refusing an unpinned DirectX Shader Compiler download' }
    $m = [regex]::Match($Workspace, 'name\s*=\s*"directx_shader_compiler"[^)]*?sha256\s*=\s*"([0-9a-fA-F]{64})"')
    if (-not $m.Success) { throw 'LiteRT-LM WORKSPACE has no sha256-pinned directx_shader_compiler http_archive' }
    if ($m.Groups[1].Value -ne $Expected) {
        throw "LiteRT-LM WORKSPACE pins the DXC zip at $($m.Groups[1].Value), versions.env LITERT_LM_DXC_ZIP_SHA256 says $Expected"
    }
}

function Get-LitertLmGpuPayload {
    # rocm lane: what --backend=gpu loads by bare name from the exe's dir, each with its versions.env pin key.
    param([string]$GpuType, [Parameter(Mandatory)][string]$PrebuiltDir, [Parameter(Mandatory)][string]$DxcDir)
    if ($GpuType -ne 'rocm') { return @() }
    $dxcLicenses = 'licenses\directx-shader-compiler'
    return @(
        @{ Source = Join-Path $PrebuiltDir 'libLiteRtWebGpuAccelerator.dll'; Dir = 'bin'; PinKey = 'LITERT_LM_WEBGPU_ACCELERATOR_SHA256' }
        @{ Source = Join-Path $PrebuiltDir 'libLiteRtTopKWebGpuSampler.dll'; Dir = 'bin'; PinKey = 'LITERT_LM_WEBGPU_SAMPLER_SHA256' }
        @{ Source = Join-Path $PrebuiltDir 'libwebgpu_dawn.dll'; Dir = 'bin'; PinKey = 'LITERT_LM_WEBGPU_DAWN_SHA256' }
        @{ Source = Join-Path $DxcDir 'bin\x64\dxcompiler.dll'; Dir = 'bin'; PinKey = '' }
        @{ Source = Join-Path $DxcDir 'bin\x64\dxil.dll'; Dir = 'bin'; PinKey = '' }
        @{ Source = Join-Path $DxcDir 'LICENSE-MS.txt'; Dir = $dxcLicenses; PinKey = '' }
        @{ Source = Join-Path $DxcDir 'LICENSE-LLVM.txt'; Dir = $dxcLicenses; PinKey = '' }
        @{ Source = Join-Path $DxcDir 'LICENSE-MIT.txt'; Dir = $dxcLicenses; PinKey = '' }
    )
}

function Install-LitertLmGpuPayload {
    # Copies each payload file under $Root\<Dir>; a pinned file must match its versions.env SHA256 first.
    param([Parameter(Mandatory)][object[]]$Payload, [Parameter(Mandatory)][string]$Root)
    foreach ($item in $Payload) {
        $name = Split-Path -Leaf $item.Source
        if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) { throw "LiteRT-LM GPU payload missing: $($item.Source)" }
        if ($item.PinKey) {
            $want = [Environment]::GetEnvironmentVariable($item.PinKey)
            if ($want -notmatch '^[0-9a-fA-F]{64}$') { throw "$($item.PinKey) is not a SHA256 ('$want'): refusing an unpinned $name" }
            $got = (Get-FileHash -LiteralPath $item.Source -Algorithm SHA256).Hash
            if ($got -ne $want) { throw "$name has SHA256 $got, versions.env $($item.PinKey) pins $want" }
        }
        $dest = Join-Path $Root $item.Dir
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -LiteralPath $item.Source -Destination $dest -Force
    }
}

$gpuType = [string]$env:GPU_TYPE

Write-Host "=== [1/6] prerequisites: long paths + bazelisk + JDK (LiteRT-LM $tag) ==="
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f | Out-Null
New-Item -ItemType Directory -Force -Path C:\bzl-tools | Out-Null

# bazelisk and the JDK are cached on the mount: a live JDK download per build is unreliable.
$toolCache = if ($RepositoryCache) { Join-Path $RepositoryCache 'toolcache' } else { 'C:\bzl-tools' }
New-Item -ItemType Directory -Force -Path $toolCache | Out-Null
$cachedBazelisk = Join-Path $toolCache 'bazelisk.exe'
$cachedJdkZip = Join-Path $toolCache 'jdk.zip'
if (-not (Test-Path $cachedBazelisk) -or (Get-Item $cachedBazelisk).Length -eq 0) {
    Get-UrlWithRetry -Uri 'https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-windows-amd64.exe' -OutFile $cachedBazelisk
} else { Write-Host '  bazelisk: cache hit' }
if (-not (Test-Path $cachedJdkZip) -or (Get-Item $cachedJdkZip).Length -eq 0) {
    # The GitHub release asset first; the api.adoptium.net redirect is flaky.
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
$restoreEnv = $null
try {
    & git lfs pull 2>&1 | Select-Object -Last 2

    Write-Host '=== [3/6] neutralize the WORKSPACE Android repository rules ==='
    $ws = Get-Content C:\llm\WORKSPACE -Raw
    if ($gpuType -eq 'rocm') { Assert-LitertLmDxcPin -Workspace $ws -Expected $env:LITERT_LM_DXC_ZIP_SHA256 }
    # Commented out, not an emptied ANDROID_HOME, which makes android_sdk_repository resolve workspace-relative.
    $ws = $ws.Replace('android_ndk_repository(name = "androidndk")', '# [bazel-port] android_ndk_repository disabled (no android targets)')
    $ws = $ws.Replace('android_sdk_repository(name = "androidsdk")', '# [bazel-port] android_sdk_repository disabled (no android targets)')
    # zlib.net/fossils is flaky and @minizip re-fetches it every run; GitHub's release is the same tarball.
    $ws = $ws.Replace('https://zlib.net/fossils/zlib-1.3.1.tar.gz', 'https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz')
    Set-Content -Path C:\llm\WORKSPACE -Value $ws -NoNewline

    Write-Host '=== [4/6] bazel env ==='
    # TF's android_configure.bzl int()s ANDROID_NDK_VERSION, which the image sets to a dotted revision.
    [Environment]::SetEnvironmentVariable('ANDROID_NDK_VERSION', $null, 'Machine')
    # Remove-Item: SetEnvironmentVariable($null) leaves it defined-empty for native children.
    Remove-Item -Path Env:ANDROID_NDK_VERSION -ErrorAction SilentlyContinue
    # The bazel server inherits this env at start, so hide the ROCm tree before the first bazelisk call.
    $envScrub = Get-LitertLmRocmEnvScrub -GpuType $gpuType -Environment ([Environment]::GetEnvironmentVariables())
    if ($envScrub.Count -gt 0) {
        $restoreEnv = Set-LitertLmProcessEnv -Values $envScrub
        Write-Host "  rocm lane: ROCm tree hidden from bazel ($(@($envScrub.Keys | Sort-Object) -join ', ')); + DXC target"
    }
    $outputBase = 'C:\bzl'
    $bazelArgs = @("--output_base=$outputBase")
    $bazelCmd = Get-LitertLmBazelArg -GpuType $gpuType
    # No --repository_cache on the mount: bazel renames temp files into it, which the wcifs mount breaks.
    $env:BAZEL_VC = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC'
    $py = 'C:\temp\cpython\PCbuild\amd64'
    if (Test-Path "$py\python.exe") { $env:PATH = "$py;$env:PATH" }
    $env:PATH = "C:\bzl-tools;$env:JAVA_HOME\bin;$env:PATH"

    Write-Host '=== [5/6] bazelisk build //runtime/engine:litert_lm_main --config=windows ==='
    & C:\bzl-tools\bazelisk.exe @bazelArgs @bazelCmd 2>&1 |
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
    # Every .dll from bazel-bin and the runfiles, since the smoke runs the exe with only this bin\ on PATH.
    $dllSources = @('C:\llm\bazel-bin\runtime\engine', 'C:\llm\bazel-bin\runtime\engine\litert_lm_main.exe.runfiles')
    foreach ($s in $dllSources) {
        if (Test-Path $s) {
            Get-ChildItem -Path $s -Filter '*.dll' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                Copy-Item $_.FullName $binOut -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $gpuPayload = @(Get-LitertLmGpuPayload -GpuType $gpuType -PrebuiltDir 'C:\llm\prebuilt\windows_x86_64' `
            -DxcDir (Join-Path $outputBase 'external\directx_shader_compiler'))
    if ($gpuPayload.Count -gt 0) {
        Install-LitertLmGpuPayload -Payload $gpuPayload -Root (Join-Path $InstallDir 'lib\litert-lm')
        Write-Host "  rocm lane: GPU backend staged ($($gpuPayload.Count) files: WebGPU accelerator, sampler, Dawn, DXC + licences)"
    }
    # Count what landed: the runfiles repeat DLL names and the copies are SilentlyContinue.
    $dllCount = @(Get-ChildItem -LiteralPath $binOut -Filter '*.dll' -File -ErrorAction SilentlyContinue).Count
    # Best-effort public headers for downstream apps; the contract guard below catches an empty include\.
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
    # Success is reaching the flag parser: abseil's --help exits 1, so reset LASTEXITCODE for the calling chain.
    if ($help -notmatch 'model_path|input_prompt|Flags from') {
        throw "installed litert_lm_main.exe did not reach its flag parser (missing DLL?). Output: $($help.Substring(0,[Math]::Min(300,$help.Length)))"
    }
    $global:LASTEXITCODE = 0
    Write-Host ("LiteRT-LM (bazel) INSTALLED: {0} ({1:N0} bytes, {2} DLL(s) co-located, --help OK)" -f $installedExe, $sz, $dllCount)

    # The merge image promises this layout (LITERT_LM_*); check it here, not hours later at the smoke gate.
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
    # The caller's later steps (Get-GpuEnvironment) need the rocm env back.
    if ($restoreEnv) { $null = Set-LitertLmProcessEnv -Values $restoreEnv }
    Pop-Location
}
