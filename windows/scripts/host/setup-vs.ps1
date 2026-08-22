# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# PSSA suppression, justified: the Test-Connection below is a deliberate
# network-reachability probe against a fixed public host before the multi-GB
# VS Build Tools download — no system information is exposed. (This edit
# rides in a base-layer window: setup-vs.ps1 is COPY'd before the VS layer,
# so touching it re-pays the VS install.)
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'reachability probe against a fixed public host')]
param(
    [string]$TempDir       = 'C:\temp'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference    = 'SilentlyContinue'

# #108: repo layout is scripts/<group>/ while every container mount stays FLAT
# (C:\bkmnt, C:\temp\scripts). Shared assets (modules/patches/shims/...) live
# beside this script in the flat layout and one level up in the repo layout.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$installerModulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force

# For Resolve-VsBuildToolsRoot (shared VsDevCmd probe, also used by the smoke test).
# Allowed here: WindowsContainerImage.Common is one of the three modules COPY'd
# into Dockerfile.base BEFORE the setup-* scripts run.
$containerImageModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $containerImageModulePath)) { throw "Required module not found: $containerImageModulePath" }
Import-Module $containerImageModulePath -Force

# Admin-Check

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # throw, not Write-Error+exit: under EAP=Stop Write-Error is itself terminating,
    # which made the old `exit 1` dead code.
    throw 'Please run PowerShell as Administrator.'
}

# Single source for the VS major: previously computed twice, 100 lines apart,
# with the same '18' fallback — a drift between the two was a live bug waiting.
$script:VsMajor = if ($env:VISUAL_STUDIO_VERSION) { $env:VISUAL_STUDIO_VERSION } else { '18' }

function Write-InstallerLogDump {
    param([string]$TempDir)


    Write-Host "`n=== Installer log files in $TempDir ===`n"
    Get-ChildItem $TempDir -Filter '*vs_installer.log' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "----- $($_.Name) (full) -----"
    Get-Content $_.FullName -Raw
    }


    Get-ChildItem $TempDir -Filter '*_errors.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object {
    Write-Host "----- $($_.Name) (full) -----"
    Get-Content $_.FullName -Raw
    }


    Get-ChildItem $TempDir -Filter 'dd_setup_*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | ForEach-Object {
    Write-Host "----- $($_.Name) (tail 500) -----"
    Get-Content $_.FullName -Tail 500
    }


    Write-Host "`n----- Quick search for common error patterns in dd_* logs -----"
    Get-ChildItem $TempDir -Filter 'dd_*' -ErrorAction SilentlyContinue | Select-String -Pattern 'error|failed|exception|0x[0-9A-Fa-f]+' -CaseSensitive:$false | Select-Object Filename,LineNumber,Line | ForEach-Object {
    Write-Host "[$($_.Filename):$($_.LineNumber)] $($_.Line)"
    }


    Write-Host "`n----- Disk space (C:) -----"
    Get-PSDrive C | Select-Object Used,Free,Root


    Write-Host "`n----- Network quick-check -----"
    try { Test-Connection -ComputerName www.microsoft.com -Count 1 -ErrorAction Stop | Select-Object Address,ResponseTime } catch { Write-Host "Network check failed: $($_.Exception.Message)" }
}

# (TLS 1.2 is set per-attempt by Invoke-DownloadWithRetry -- no separate
# Enable-Tls12ForDownloads needed; nothing else here downloads.)

# Prepare temp directory for installer logs

# ensure we run the installer with the temp dir we control
$env:TEMP = $TempDir
$env:TMP  = $TempDir

Write-Host "Using TEMP=$env:TEMP for installer temporary files and logs."
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
$installer = Join-Path $TempDir 'vs_buildtools.exe'

# Optionale ENV-Variablen analog Dockerfile

# Pre-declare: the finally below reads $proc, and a failure before Start-Process
# (download, arg building) would otherwise leave it unset — under StrictMode the
# finally would then throw and REPLACE the real exception.
$proc = $null

try {
    Write-Host 'Downloading Visual Studio Build Tools Installer...'
    # Prefer the major-pinned channel (aka.ms/vs/<major>/release) so a VS major bump
    # can never ride in silently — but Microsoft publishes that alias LATE for new
    # majors (for 18 it still bounces to a Bing HTML page, which the MZ guard
    # rejects), so fall back to aka.ms/vs/stable with a loud warning. The VsDevCmd
    # major sanity check below still catches a silent stable->19 flip. A hard SHA256
    # pin is deliberately NOT used (the bootstrapper refreshes within a channel every
    # few weeks); the actual hash is LOGGED for provenance instead.
        $vsUrls = @(
        "https://aka.ms/vs/$script:VsMajor/release/vs_buildtools.exe",
        'https://aka.ms/vs/stable/vs_buildtools.exe'
    )
    $vsDownloaded = $false
    foreach ($vsUrl in $vsUrls) {
        try {
            # -ExpectSignature MZ rejects-and-retries HTML pages served in place of the
            # binary (missing alias / flaky aka.ms redirect — same class as the nuget bug).
            # 3 pinned attempts (#79): budget 2 once lost the pinned alias to a
            # transient aka.ms hiccup and silently degraded to floating stable.
            $attempts = if ($vsUrl -match 'stable') { 4 } else { 3 }
            Invoke-DownloadWithRetry -Url $vsUrl -DestinationPath $installer `
                -Description "VS Build Tools installer ($vsUrl)" -ExpectSignature MZ -MaxAttempts $attempts
            $vsDownloaded = $true
            if ($vsUrl -match 'stable') {
                Write-Warning "major-pinned VS alias unavailable — used floating 'stable' channel (currently VS $script:VsMajor; the VsDevCmd check below fails the build if it ever is not)."
            }
            break
        } catch {
            Write-Warning "VS bootstrapper URL failed: $vsUrl -- $($_.Exception.Message)"
        }
    }
    if (-not $vsDownloaded) { throw 'VS Build Tools bootstrapper unavailable from every candidate URL' }
    Write-Host ("VS Build Tools bootstrapper SHA256 (provenance): {0}" -f (Get-FileHash -Algorithm SHA256 -Path $installer).Hash)

    $installerArgs = @(
        '--quiet',
        '--wait', '--norestart', '--nocache',

        # Workloads

        '--add', 'Microsoft.VisualStudio.Workload.MSBuildTools',              # Core MSBuild toolset
        '--add', 'Microsoft.VisualStudio.Workload.VCTools',                   # C++ desktop build tools
        #'--add', 'Microsoft.VisualStudio.Workload.AzureBuildTools',          # Azure development build tools
        #'--add', 'Microsoft.VisualStudio.Workload.UniversalBuildTools',       # UWP build tools
        #'--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools', # .NET desktop build tools

        # Core Build Components

        '--add', 'Microsoft.Component.MSBuild',                              # MSBuild compiler
        '--add', 'Microsoft.VisualStudio.Component.CoreBuildTools',          # Core build utilities
        # '--add', 'Microsoft.VisualStudio.Component.TextTemplating',        # T4 text template engine
        
        # Windows SDK & Native Desktop

        '--add', "Microsoft.VisualStudio.Component.Windows11SDK.$(if ($env:WINDOWS_SDK_BUILD) { $env:WINDOWS_SDK_BUILD } else { '26100' })", # Windows 11 SDK
        # '--add','Microsoft.VisualStudio.Workload.NativeDesktop',           # only for full GUI functionality 
                                                                             # NOT for CICD

        # LLVM/Clang

        '--add', 'Microsoft.VisualStudio.Component.VC.Llvm.Clang',           # Clang compiler for Windows
        '--add', 'Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset',    # Clang-cl toolset

        # ARM64 target support (2026-08-22)
        #
        # This is installed for its LIBRARIES, not its compiler. Every stage of
        # this chain compiles with clang-cl and links with lld-link; the bundled
        # Hostx64\arm64\cl.exe is never invoked. But clang-cl targets the MSVC
        # ABI, so an aarch64-pc-windows-msvc build links against Microsoft's
        # ARM64 CRT and import libraries (VC\Tools\MSVC\<v>\lib\arm64) -- which
        # ship ONLY with this component. Without it, cross-compiling produces
        # objects that cannot be linked.
        #
        # The Windows SDK component above is architecture-complete and already
        # carries Lib\<ver>\um\arm64, so no SDK change is needed alongside this.
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',          # MSVC ARM64 CRT + import libs (cross target)

        # VC++ Analysis & Tools
        
        '--add', 'Microsoft.VisualStudio.Component.VC.ASAN',                 # AddressSanitizer (memory debugging)
        '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project',        # CMake tools for Windows
        
        # VC++ Core
        
        '--add', 'Microsoft.VisualStudio.Component.VC.CoreBuildTools',       # C++ core build tools
        '--add', 'Microsoft.VisualStudio.Component.VC.CoreIde',              # C++ core IDE features
        # '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'         # MSVC v143 compiler (x86/x64)
        # '--add', 'Microsoft.VisualStudio.Component.VC.Redist.14.Latest',   # C++ redistributable
        
        # VC++ Libraries
        
        # '--add', 'Microsoft.VisualStudio.Component.VC.ATL',                 # Active Template Library
        # '--add', 'Microsoft.VisualStudio.Component.VC.ATLMFC',              # MFC library support
        # '--add', 'Microsoft.VisualStudio.Component.VC.CLI.Support'          # C++/CLI support
        
        
        # .NET
        '--add','Microsoft.NetCore.Component.SDK',                            # .NET SDK (dotnet tools)
        '--add','Microsoft.VisualStudio.Component.NuGet.BuildTools'           # NuGet Package Manager / restore tools
        # '--add', 'Microsoft.VisualStudio.Component.Roslyn.Compiler',        # C#/VB managed compiler
        # '--add', 'Microsoft.VisualStudio.Component.Roslyn.LanguageServices' # C#/VB language services

    )

    Write-Host "Starting Visual Studio Build Tools installation ..."
    try {
        $proc = Start-Process -FilePath $installer -ArgumentList $installerArgs -Wait -NoNewWindow -PassThru
    }
    catch {
        Write-Host "Start-Process Exception: $($_.Exception.Message)"
        Write-InstallerLogDump -TempDir $TempDir
        throw
    }

    Write-Host "Installer ExitCode: $($proc.ExitCode)"

    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        Write-Host 'Installation failed -- printing logs:'
        Write-InstallerLogDump -TempDir $TempDir
        throw "Build Tools Setup failed (ExitCode $($proc.ExitCode))."
    }

    if ($proc.ExitCode -eq 3010) {
        Write-Warning 'Installation complete. A reboot is required (ExitCode 3010).'
    } else {
        Write-Host 'Installation succeeded.'
    }

    # VS major from versions.env's VISUAL_STUDIO_VERSION (reaches this pre-load-versions
    # layer as a --build-arg, same route as WINDOWS_SDK_BUILD above). Probe via the
    # shared Resolve-VsBuildToolsRoot so this check and the smoke test can never
    # diverge on which Program Files roots they accept.
    $vsBuildToolsRoot = Resolve-VsBuildToolsRoot -VsMajor $script:VsMajor
    if ($vsBuildToolsRoot) {
        Write-Host "VsDevCmd found ($vsBuildToolsRoot)."

        # Hard gate on the ARM64 cross-target LIBRARIES (2026-08-22).
        #
        # Asserted here, in the layer that installs them, because a silently
        # dropped VS component otherwise surfaces hours later as an opaque
        # link error deep in a media build -- the failure class every gate in
        # this repo exists to convert into one clear message.
        #
        # NB this deliberately checks lib\arm64, NOT bin\Hostx64\arm64\cl.exe:
        # we never invoke that compiler (the chain is clang-cl + lld-link), and
        # a cl.exe probe would pass even if the libraries -- the part that is
        # actually load-bearing for a cross link -- were missing.
        $msvcLibArm64 = Get-ChildItem -Path (Join-Path $vsBuildToolsRoot 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'lib\arm64\libcmt.lib' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if (-not $msvcLibArm64) {
            # WARN, not throw: this base image is SHARED by both lanes, so an
            # arm64-only prerequisite must never block an amd64 build.
            # WINDOWS_ARM64_STRICT=1 opts into the hard gate (same shape as
            # CUDA_STACK_STRICT). The installer log dump is deliberately kept on
            # the strict path only - it is multi-hundred lines and would drown
            # a routine amd64 build in noise.
            $msg = ('MSVC ARM64 libraries missing (no VC\Tools\MSVC\<ver>\lib\arm64\libcmt.lib under ' +
                    "$vsBuildToolsRoot). The VC.Tools.ARM64 component did not install; " +
                    'clang-cl cannot link an aarch64-pc-windows-msvc target without it.')
            if ($env:WINDOWS_ARM64_STRICT -eq '1') {
                Write-InstallerLogDump -TempDir $TempDir
                throw $msg
            }
            Write-Warning "$msg (amd64 lane unaffected; set WINDOWS_ARM64_STRICT=1 to make this fatal)"
        } else {
            Write-Host "MSVC ARM64 cross libraries present ($msvcLibArm64)."
        }
        # Success-path scrub: the installer leaves dd_setup_* / *vs_installer*.log
        # behind in $TempDir, and they would otherwise ride along in the committed
        # layer. Failure paths deliberately KEEP them — they are the evidence
        # Write-InstallerLogDump prints (same pattern as preserving the installer).
        Get-ChildItem -Path $TempDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'dd_setup_*' -or $_.Name -like '*vs_installer*.log' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host 'Removed VS installer logs (dd_setup_* / *vs_installer*.log) from the success-path layer.'
    } else {
        Write-Host 'VsDevCmd not found -- printing logs.'
        Write-InstallerLogDump -TempDir $TempDir
        throw 'VS Build Tools not installed. Check dd_bootstrapper*.log and dd_setup_*.log under %TEMP%.'
    }
}
finally {
    # Clean up any lingering VS installer processes
    Get-Process -Name '*vs_installer*', '*vs_buildtools*', '*vs_setup*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host 'Cleaned up lingering VS installer processes'

    # On failure keep the installer for analysis; on success remove it so it does
    # not ride along in the base layer.
    if ($proc -and ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010)) {
        Write-Host "Installer was not deleted (left for analysis at $installer)."
    } elseif (Test-Path $installer) {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
}
