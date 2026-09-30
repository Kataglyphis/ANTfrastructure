#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# Cache-bust lever: any content change re-keys this layer past poisoned snapshotter debris; see docs/failure-modes.md.


param(
    [string]$TempDir = 'C:\temp',
    # Derived from GIT_VERSION by default; pass a URL only for a git-for-windows respin (.windows.2).
    [string]$GitInstallerUrl = '',
    [string]$CMakeVersion = '',
    [string]$VulkanVersion = '',
    # Compiled-output pins; empty falls through to scoop's manifest for a standalone run.
    [string]$LlvmVersion = '',
    [string]$NinjaVersion = '',
    [string]$NasmVersion = '',
    # '1' hard-gates the arm64 checks; a parameter, since a bare $env: read is unreachable from docker build.
    [string]$WindowsArm64Strict = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

# Local wrappers, not module exports: only the three modules COPY'd before this script exist in Dockerfile.base.

# Throws on a non-zero native exit, which $ErrorActionPreference never sees.
function Invoke-ScoopStep {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Command
    )
    Write-Host "==> $Description"
    $global:LASTEXITCODE = 0    # clear stale exit codes from earlier native calls
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed (exit code $LASTEXITCODE)" }
}

# Retries, since scoop has none; a dropped transfer leaves a partial file, hence the cache purge.
function Install-ScoopPackage {
    param(
        [Parameter(Mandatory)][string]$Package,
        [string]$Version = '',
        [switch]$Global,
        [int]$MaxAttempts = 3
    )
    $spec = if ([string]::IsNullOrWhiteSpace($Version)) { $Package } else { "$Package@$Version" }
    $flags = @(if ($Global) { '--global' })
    $desc = "scoop install $($flags -join ' ') $spec".Replace('  ', ' ')
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Invoke-ScoopStep -Description $desc -Command {
                scoop install @flags $spec
            }.GetNewClosure()
            return
        } catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning "$desc failed (attempt $attempt/$MaxAttempts) - purging the app's scoop cache and retrying in 15s"
            $app = ($Package -split '/')[-1]
            scoop cache rm $app 2>$null | Out-Null
            $global:LASTEXITCODE = 0
            Start-Sleep -Seconds 15
        }
    }
}

# Shared assets sit one level up in the repo layout and beside the script in the flat container mounts.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $sharedModulePath)) {
    throw "Required module not found: $sharedModulePath"
}

Import-Module $sharedModulePath -Force

$installerModulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force

# For Assert-FileSha256 and Get-PreferredToolPath, which the other modules do not re-export.
$sharedHelpersPath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Get-Module -Name 'WindowsScripts.Shared')) { Import-Module $sharedHelpersPath }

# Shared helpers (Invoke-DownloadWithRetry, etc.) come through the Common modules' re-export.

# Param wins, then the baked env; empty falls through to scoop's current manifest.
$CMakeVersion = Resolve-ContainerImageValue -Value $CMakeVersion -EnvironmentVariable 'CMAKE_VERSION'
$VulkanVersion = Resolve-ContainerImageValue -Value $VulkanVersion -EnvironmentVariable 'VULKAN_VERSION'
# Same resolution route for the compiled-output pins (param wins, then baked env).
$LlvmVersion  = Resolve-ContainerImageValue -Value $LlvmVersion  -EnvironmentVariable 'LLVM_WINDOWS_VERSION'
$NinjaVersion = Resolve-ContainerImageValue -Value $NinjaVersion -EnvironmentVariable 'NINJA_WINDOWS_VERSION'
$NasmVersion  = Resolve-ContainerImageValue -Value $NasmVersion  -EnvironmentVariable 'NASM_WINDOWS_VERSION'

$TempDir = Initialize-ContainerImageTempDirectory -TempDir $TempDir

#region 1. Git (pinned installer)
# Derived from GIT_VERSION so the pin cannot drift in a default; .windows.1 covers normal releases.
$gitVer = Resolve-ContainerImageValue -EnvironmentVariable 'GIT_VERSION' -DefaultValue '2.55.0'
$GitInstallerUrl = Resolve-ContainerImageValue -Value $GitInstallerUrl -EnvironmentVariable 'GIT_INSTALLER_URL' `
    -DefaultValue "https://github.com/git-for-windows/git/releases/download/v$gitVer.windows.1/Git-$gitVer-64-bit.exe"

$gitInstaller = Join-Path $TempDir 'Git-64-bit.exe'
# An empty pin (a respun-release URL override) skips the hash check.
$gitSha = Resolve-ContainerImageValue -EnvironmentVariable 'GIT_WINDOWS_INSTALLER_SHA256' -DefaultValue ''
Invoke-DownloadWithRetry -Url $GitInstallerUrl -DestinationPath $gitInstaller -Description 'Git for Windows installer' -ExpectSignature MZ -ExpectedSha256 $gitSha
# Without the exit-code gate a failed install surfaces only as "git not recognized" in a media build.
$gitProc = Start-Process -FilePath $gitInstaller -ArgumentList '/SILENT', '/NORESTART' -Wait -NoNewWindow -PassThru
if ($gitProc.ExitCode -ne 0) { throw "Git for Windows installer failed (exit $($gitProc.ExitCode))" }
Remove-Item $gitInstaller -Force
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Program Files\Git\cmd',
    'C:\Program Files\Git\bin',
    'C:\Program Files\Git\usr\bin'
) | Out-Null

#endregion
#region 2. WiX toolset (dotnet tool, pinned)
# Shared with Test-Toolchain.ps1's assert; the defaults keep a standalone run working.
$WixVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_VERSION' -DefaultValue '4.0.6'
$WixUiExtVersion = Resolve-ContainerImageValue -EnvironmentVariable 'WIX_UI_EXT_VERSION' -DefaultValue '4.0.6'
Invoke-ScoopStep -Description "dotnet tool install wix $WixVersion" -Command {
    dotnet tool install --tool-path C:\WiX wix --version $WixVersion
}
Invoke-ScoopStep -Description "wix extension add WixToolset.UI.wixext/$WixUiExtVersion" -Command {
    & 'C:\WiX\wix.exe' extension add --global "WixToolset.UI.wixext/$WixUiExtVersion"
}

Enable-Tls12ForDownloads
$scoopInstallScript = Join-Path $TempDir 'install-scoop.ps1'
#endregion
#region 3. scoop bootstrap + shims
# Hash-pinned because it is executed: a mismatch means scoop revved it, so re-review before bumping.
$scoopSha = Resolve-ContainerImageValue -EnvironmentVariable 'SCOOP_INSTALLER_SHA256' -DefaultValue ''
Invoke-DownloadWithRetry -Url 'https://get.scoop.sh' -DestinationPath $scoopInstallScript -Description 'scoop installer script' -ExpectedSha256 $scoopSha
& $scoopInstallScript -RunAsAdmin
Sync-ContainerProcessPath -AdditionalPaths @(
    'C:\Users\ContainerAdministrator\scoop\shims',
    'C:\ProgramData\scoop\shims'
) | Out-Null
Assert-ContainerCommandAvailable -Name 'git' | Out-Null
Assert-ContainerCommandAvailable -Name 'scoop' | Out-Null
# Test the bucket directory: `scoop bucket add` exits 2 for an existing one, and the installer pre-adds main.
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
foreach ($bucket in @('main', 'extras', 'versions')) {
    if (Test-Path (Join-Path $scoopRoot "buckets\$bucket")) {
        Write-Host "==> scoop bucket add $bucket -- already present, skipped"
        continue
    }
    Invoke-ScoopStep -Description "scoop bucket add $bucket" -Command { scoop bucket add $bucket }.GetNewClosure()
}
Install-ScoopPackage -Package 'main/7zip'
Invoke-ScoopStep -Description 'scoop config use_external_7zip true' -Command { scoop config use_external_7zip true }

# No rust here: Install-RustToolchain.ps1's rustup is the single provider.

#endregion
#region 4. Vulkan LAN preseed + pinned installs (cmake/vulkan/flutter)
# Preseeded from the LAN under scoop's cache name, since sdk.lunarg.com stalls in containers; scoop still checks the hash.
if ($env:VULKAN_PRESEED_ENDPOINT -and $VulkanVersion) {
    try {
        $vkVendorUrl = "https://sdk.lunarg.com/sdk/download/$VulkanVersion/windows/vulkansdk-windows-X64-$VulkanVersion.exe"
        $vkUrlSha = [System.Security.Cryptography.SHA256]::Create()
        $vkTok = ([BitConverter]::ToString($vkUrlSha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($vkVendorUrl))) -replace '-', '').ToLower().Substring(0, 7)
        $vkCacheDir = Join-Path $env:USERPROFILE 'scoop\cache'
        $null = New-Item -ItemType Directory -Force -Path $vkCacheDir
        $vkDest = Join-Path $vkCacheDir "vulkan#$VulkanVersion#$vkTok.exe"
        $vkSrc = "$($env:VULKAN_PRESEED_ENDPOINT)/preseed/vulkansdk-windows-X64-$VulkanVersion.exe"
        & (Join-Path $env:SystemRoot 'System32\curl.exe') -sf --retry 3 --retry-delay 5 --retry-all-errors -o $vkDest $vkSrc
        if ($LASTEXITCODE -eq 0) {
            Write-Host "vulkan preseed: $vkDest ($([math]::Round((Get-Item $vkDest).Length / 1MB)) MB) from $vkSrc"
        } else {
            Remove-Item $vkDest -Force -ErrorAction SilentlyContinue
            Write-Warning "vulkan preseed fetch failed (exit $LASTEXITCODE) - falling back to the direct download"
        }
        $global:LASTEXITCODE = 0
    } catch {
        Write-Warning "vulkan preseed skipped: $($_.Exception.Message)"
    }
}
Install-ScoopPackage -Package 'main/vulkan' -Version $VulkanVersion

# The aarch64 libs are an optional SDK component; warn-only since this layer is shared with amd64 (docs/windows-cross-builds.md).
$armStrict = if (-not [string]::IsNullOrWhiteSpace($WindowsArm64Strict)) { $WindowsArm64Strict } else { $env:WINDOWS_ARM64_STRICT }
$vkRoot = Join-Path $env:USERPROFILE 'scoop\apps\vulkan\current'
$vkArm64Lib = Join-Path $vkRoot 'Lib-ARM64'
if (Test-Path $vkArm64Lib) {
    Write-Host "Vulkan ARM64 cross libraries already present ($vkArm64Lib)."
} else {
    $maintenanceTool = Join-Path $vkRoot 'maintenancetool.exe'
    if (Test-Path $maintenanceTool) {
        # Current Qt IFW long options first, the older short forms as a fallback.
        $argSets = @(
            @('--accept-licenses', '--default-answer', '--confirm-command', 'install', 'com.lunarg.vulkan.arm64'),
            @('--al', '--am', '-c', 'install', 'com.lunarg.vulkan.arm64')
        )
        foreach ($argSet in $argSets) {
            Write-Host "Adding Vulkan ARM64 component: maintenancetool $($argSet -join ' ')"
            & $maintenanceTool @argSet 2>&1 | ForEach-Object { Write-Host "  $_" }
            $global:LASTEXITCODE = 0
            if (Test-Path $vkArm64Lib) { break }
        }
    } else {
        Write-Warning "Vulkan maintenancetool.exe not found at $maintenanceTool - cannot add the ARM64 component."
    }

    if (Test-Path $vkArm64Lib) {
        Write-Host "Vulkan ARM64 cross libraries installed ($vkArm64Lib)."
    } elseif ($armStrict -eq '1') {
        throw ("Vulkan ARM64 component (com.lunarg.vulkan.arm64) is not installed: $vkArm64Lib is missing. " +
               'It is an optional component of the x64 SDK and is required to link an aarch64 target. ' +
               'WINDOWS_ARM64_STRICT=1 made this a hard gate.')
    } else {
        Write-Warning ("Vulkan ARM64 component (com.lunarg.vulkan.arm64) not installed: $vkArm64Lib is missing. " +
                       'The amd64 lane is unaffected; an arm64 target cannot link Vulkan until this is resolved. ' +
                       'Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
}

# Pinned so the Windows image cannot silently diverge from the Linux lane.
Install-ScoopPackage -Package 'extras/flutter' -Version ([string]$env:FLUTTER_VERSION) -Global
#endregion
#region 5. PINNED compiled-output packages + floating toolset + cache scrub
# Pinned: they shape compiled output, and patches are written against one clang-cl (independent of Linux's LLVM_RELEASE).
Install-ScoopPackage -Package 'main/llvm'  -Version $LlvmVersion
Install-ScoopPackage -Package 'main/ninja' -Version $NinjaVersion
Install-ScoopPackage -Package 'main/nasm'  -Version $NasmVersion

# aarch64 compiler-rt builtins, unconditionally; see docs/windows-cross-builds.md § aarch64 compiler-rt is a base prerequisite.
$llvmAppRoot = Join-Path $env:USERPROFILE 'scoop\apps\llvm\current'
$rtHost = @(Get-ChildItem -Path (Join-Path $llvmAppRoot 'lib\clang') -Recurse -Filter 'clang_rt.builtins-x86_64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
$rtTarget = @(Get-ChildItem -Path (Join-Path $llvmAppRoot 'lib\clang') -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($rtTarget.Count -gt 0) {
    Write-Host "compiler-rt builtins for aarch64 already present ($($rtTarget[0].FullName))."
} elseif ($rtHost.Count -eq 0) {
    Write-Warning ("clang_rt.builtins-x86_64.lib not found under $llvmAppRoot\lib\clang - cannot determine where to " +
                   'place the aarch64 counterpart. The LLVM layout changed; arm64 links needing __udivti3 will fail.')
} else {
    # Beside the host library, the directory clang and every consumer already search.
    $rtDestDir = $rtHost[0].Directory.FullName
    $rtArchive = Join-Path $env:TEMP "clang+llvm-$LlvmVersion-aarch64-pc-windows-msvc.tar.xz"
    # %2B, not '+', which 404s; probe with a ranged GET, since GitHub refuses HEAD here.
    $rtUrl = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/clang%2Bllvm-$LlvmVersion-aarch64-pc-windows-msvc.tar.xz"
    $rtExtractDir = Join-Path $env:TEMP 'llvm-aarch64-rt'
    try {
        Write-Host "Fetching aarch64 compiler-rt from $rtUrl (large, one-time; only clang_rt.builtins-aarch64.lib is kept)"
        Invoke-DownloadWithRetry -Url $rtUrl -DestinationPath $rtArchive
        # Verified-or-warn: the key is empty here, since base runs before versions.env is baked.
        $rtSha = Resolve-ContainerImageValue -EnvironmentVariable 'LLVM_WINDOWS_AARCH64_RT_SHA256' -DefaultValue ''
        Assert-FileSha256 -Path $rtArchive -Expected $rtSha -Label 'aarch64 compiler-rt archive' -PinName 'LLVM_WINDOWS_AARCH64_RT_SHA256'
        New-Item -Path $rtExtractDir -ItemType Directory -Force | Out-Null
        # System32 bsdtar: GNU tar reads C:\... as a remote host and does not match member patterns.
        $rtTar = Get-PreferredToolPath -CommandName 'tar' -CandidatePaths @("$env:SystemRoot\System32\tar.exe")
        if (-not $rtTar) { throw 'No tar.exe found to extract the aarch64 compiler-rt archive.' }
        & $rtTar -xf $rtArchive -C $rtExtractDir '*clang_rt.builtins-aarch64.lib'
        $global:LASTEXITCODE = 0
        $rtFound = @(Get-ChildItem -Path $rtExtractDir -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($rtFound.Count -gt 0) {
            Copy-Item -Path $rtFound[0].FullName -Destination $rtDestDir -Force
            Write-Host "compiler-rt builtins for aarch64 installed -> $(Join-Path $rtDestDir 'clang_rt.builtins-aarch64.lib')"
        } else {
            Write-Warning "clang_rt.builtins-aarch64.lib was not found inside $rtArchive - the upstream archive layout changed."
        }
    } catch {
        Write-Warning "aarch64 compiler-rt fetch failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -Path $rtArchive -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $rtExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $rtTarget = @(Get-ChildItem -Path (Join-Path $llvmAppRoot 'lib\clang') -Recurse -Filter 'clang_rt.builtins-aarch64.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($rtTarget.Count -eq 0) {
        # Warn by default: an arm64-only prerequisite in a shared layer must not break amd64.
        $msg = ('compiler-rt builtins for aarch64 are NOT installed under ' + $llvmAppRoot + '\lib\clang. ' +
                'An arm64 target cannot link 128-bit integer arithmetic (__udivti3 / __umodti3 & co); ' +
                'GStreamer is known to need it. The amd64 lane is unaffected.')
        if ($armStrict -eq '1') { throw ($msg + ' WINDOWS_ARM64_STRICT=1 made this a hard gate.') }
        Write-Warning ($msg + ' Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
}
# aarch64 OpenSSL beside the host one, warn-only; see docs/windows-cross-builds.md § aarch64 OpenSSL is a base prerequisite too.
$sslArm64Root = 'C:\opt\openssl-arm64'
$sslArm64Lib = @(Get-ChildItem -Path $sslArm64Root -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($sslArm64Lib.Count -gt 0) {
    Write-Host "OpenSSL (aarch64) already present ($($sslArm64Lib[0].FullName))."
} else {
    $sslUrl  = 'https://slproweb.com/download/Win64ARMOpenSSL-4_0_2.exe'
    $sslSha  = '5d2653ef3045a4090d448b5b9d4b85ca5277cc2d410aade9523e9bc0275b7e51'
    $sslExe  = Join-Path $env:TEMP 'Win64ARMOpenSSL.exe'
    try {
        Write-Host "Fetching aarch64 OpenSSL from $sslUrl (installed beside the x64 build, never replacing it)"
        Invoke-DownloadWithRetry -Url $sslUrl -DestinationPath $sslExe
        $got = (Get-FileHash -LiteralPath $sslExe -Algorithm SHA256).Hash
        if ($got -ine $sslSha) { throw "sha256 mismatch: got $got, expected $sslSha (this is the hash scoop's own openssl manifest pins for the arm64 asset)" }
        # Extract with innounp, never run the installer (a silent run exits 0 and installs nothing); declared, not order-dependent.
        Install-ScoopPackage -Package 'main/innounp'

        # @() and .Count: (Get-Command ...).Source on a null result throws under StrictMode.
        $innounp = $null
        $innounpCmd = @(Get-Command 'innounp' -CommandType Application -ErrorAction SilentlyContinue)
        if ($innounpCmd.Count -gt 0) { $innounp = $innounpCmd[0].Source }
        if (-not $innounp) {
            $cand = Join-Path $env:USERPROFILE 'scoop\apps\innounp\current\innounp.exe'
            if (Test-Path $cand) { $innounp = $cand }
        }
        if (-not $innounp) { throw 'innounp not found (scoop installs it for innosetup manifests such as openssl) - cannot extract the aarch64 OpenSSL package.' }
        New-Item -Path $sslArm64Root -ItemType Directory -Force | Out-Null
        # Output logged, never swallowed: a silent failure here looks like success.
        $unpOut = & $innounp -x -y "-d$sslArm64Root" $sslExe 2>&1
        $unpCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        Write-Host "innounp exit=$unpCode; last lines:"
        @($unpOut) | Select-Object -Last 6 | ForEach-Object { Write-Host "    $_" }
    } catch {
        Write-Warning "aarch64 OpenSSL fetch/install failed: $($_.Exception.Message)"
    } finally {
        Remove-Item -Path $sslExe -Force -ErrorAction SilentlyContinue
    }

    # Found by search, never by assuming slproweb's layout.
    $sslArm64Lib = @(Get-ChildItem -Path $sslArm64Root -Recurse -Filter 'libcrypto.lib' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($sslArm64Lib.Count -gt 0) {
        Write-Host "OpenSSL (aarch64) installed -> $($sslArm64Lib[0].FullName)"
        # Log the shape once so the consumer side can be written against FACT.
        @('include', 'lib') | ForEach-Object {
            $d = Join-Path $sslArm64Root $_
            if (Test-Path $d) { Write-Host "  openssl-arm64/${_}: $((Get-ChildItem $d -Force | Select-Object -First 8 | ForEach-Object { $_.Name }) -join ', ')" }
        }
        $pcFound = @(Get-ChildItem -Path $sslArm64Root -Recurse -Filter '*.pc' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        Write-Host "  openssl-arm64 pkgconfig files: $(if ($pcFound) { $pcFound -join ', ' } else { 'NONE (the consumer authors its own .pc)' })"
    } elseif ($armStrict -eq '1') {
        throw "OpenSSL for aarch64 is not installed under $sslArm64Root. gst-plugins-bad's hls/dtls/aes and glib-networking's openssl backend cannot link on the cross lane. WINDOWS_ARM64_STRICT=1 made this a hard gate."
    } else {
        Write-Warning ("OpenSSL for aarch64 is not installed under $sslArm64Root. The amd64 lane is unaffected; on arm64, " +
                       "gst-plugins-bad's hls/dtls/aes and glib-networking's openssl TLS backend will fail to link. " +
                       'Set WINDOWS_ARM64_STRICT=1 to make this a hard failure.')
    }
}

# Floating: tools the build only invokes; pin one the moment it links into shipped binaries. One call each keeps the retry.
foreach ($floatingPkg in @('nano', 'cppcheck', 'extras/nsis', 'main/uv', 'main/nuget', 'extras/zlib', 'main/openssl', 'main/pkg-config')) {
    Install-ScoopPackage -Package $floatingPkg
}

Install-ScoopPackage -Package 'main/cmake' -Version $CMakeVersion

# Baked here: their SourceForge downloads flake, and a cached base pays that once instead of every ffmpeg stage.
Install-ScoopPackage -Package 'main/make'
Install-ScoopPackage -Package 'main/gawk'

# The installers are already unpacked into the apps dir; the cache would only bloat this layer.
Write-Host 'Clearing scoop download cache...'
scoop cache rm * 2>&1 | Out-Null

# In this layer, since a committed layer can never be shrunk by a later one.
foreach ($d in @("$env:USERPROFILE\.nuget\packages", "$env:LOCALAPPDATA\Temp")) {
    if (Test-Path $d) {
        Write-Host "Clearing $d ..."
        Remove-Item "$d\*" -Recurse -Force -ErrorAction SilentlyContinue
    }
}
#endregion
