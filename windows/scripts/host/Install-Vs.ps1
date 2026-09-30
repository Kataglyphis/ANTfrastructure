# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingComputerNameHardcoded', '', Justification = 'reachability probe against a fixed public host')]
param(
    [string]$TempDir       = 'C:\temp'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference    = 'SilentlyContinue'

# Shared assets sit beside this script in a flat container mount, one level up in the repo.
$scriptAssetRoot = if (Test-Path (Join-Path $PSScriptRoot 'modules')) { $PSScriptRoot } else { Split-Path $PSScriptRoot -Parent }
$installerModulePath = Join-Path $scriptAssetRoot 'modules\WindowsInstaller.Common.psm1'
if (-not (Test-Path $installerModulePath)) { throw "Required module not found: $installerModulePath" }
Import-Module $installerModulePath -Force

# Dockerfile.base copies only this script's three modules into the VS layer; import no other.
$sharedModulePath = Join-Path $scriptAssetRoot 'modules\WindowsScripts.Shared.psm1'
if (-not (Test-Path $sharedModulePath)) { throw "Required module not found: $sharedModulePath" }
Import-Module $sharedModulePath -Force

$containerImageModulePath = Join-Path $scriptAssetRoot 'modules\WindowsContainerImage.Common.psm1'
if (-not (Test-Path $containerImageModulePath)) { throw "Required module not found: $containerImageModulePath" }
Import-Module $containerImageModulePath -Force

Assert-Elevated -Reason 'the VS Build Tools installer needs it'

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

# The installer writes its logs to TEMP, where Write-InstallerLogDump reads them.
$env:TEMP = $TempDir
$env:TMP  = $TempDir

Write-Host "Using TEMP=$env:TEMP for installer temporary files and logs."
New-Item -Path $TempDir -ItemType Directory -Force | Out-Null
$installer = Join-Path $TempDir 'vs_buildtools.exe'

# The finally reads $proc; unset under StrictMode it would throw and replace the real exception.
$proc = $null

try {
    Write-Host 'Downloading Visual Studio Build Tools Installer...'
    # The major-pinned alias is published late for new majors, so stable is the fallback; no SHA pin, the bootstrapper refreshes in-channel.
        $vsUrls = @(
        "https://aka.ms/vs/$script:VsMajor/release/vs_buildtools.exe",
        'https://aka.ms/vs/stable/vs_buildtools.exe'
    )
    $vsDownloaded = $false
    foreach ($vsUrl in $vsUrls) {
        try {
            # MZ rejects an HTML page served in place of the binary; 3 pinned attempts ride out a transient aka.ms hiccup.
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

        # Core Build Components

        '--add', 'Microsoft.Component.MSBuild',                              # MSBuild compiler
        '--add', 'Microsoft.VisualStudio.Component.CoreBuildTools',          # Core build utilities

        # Windows SDK & Native Desktop

        '--add', "Microsoft.VisualStudio.Component.Windows11SDK.$(if ($env:WINDOWS_SDK_BUILD) { $env:WINDOWS_SDK_BUILD } else { '26100' })", # Windows 11 SDK

        # LLVM/Clang

        '--add', 'Microsoft.VisualStudio.Component.VC.Llvm.Clang',           # Clang compiler for Windows
        '--add', 'Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset',    # Clang-cl toolset

        # ARM64 target: installed for its CRT and import libs, which clang-cl's MSVC-ABI cross links need; its cl.exe is never run
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64',          # MSVC ARM64 CRT + import libs (cross target)

        # VC++ Analysis & Tools
        
        '--add', 'Microsoft.VisualStudio.Component.VC.ASAN',                 # AddressSanitizer (memory debugging)
        '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project',        # CMake tools for Windows
        
        # VC++ Core
        
        '--add', 'Microsoft.VisualStudio.Component.VC.CoreBuildTools',       # C++ core build tools
        '--add', 'Microsoft.VisualStudio.Component.VC.CoreIde',              # C++ core IDE features
        # Explicit: the VCTools workload alone may not register it, and CPython's find_msbuild.bat asks vswhere for it
        '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64'         # MSVC v143 compiler (x86/x64)


        # .NET
        '--add','Microsoft.NetCore.Component.SDK',                            # .NET SDK (dotnet tools)
        '--add','Microsoft.VisualStudio.Component.NuGet.BuildTools'           # NuGet Package Manager / restore tools

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

    # The smoke test probes through the same resolver, so both accept the same Program Files roots.
    $vsBuildToolsRoot = Resolve-VsBuildToolsRoot -VsMajor $script:VsMajor
    if ($vsBuildToolsRoot) {
        Write-Host "VsDevCmd found ($vsBuildToolsRoot)."

        # Assert the vswhere registration, not the files: they can stay on disk unregistered, and CPython needs x64 on both lanes.
        $vswhereExe = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        $x64Registered = ''
        if (Test-Path $vswhereExe) {
            $x64Registered = @(& $vswhereExe -property installationPath -latest -prerelease -products * `
                    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 2>$null | Select-Object -First 1)
        }
        if (-not $x64Registered) {
            Write-InstallerLogDump -TempDir $TempDir
            throw ('Microsoft.VisualStudio.Component.VC.Tools.x86.x64 is not registered in the VS installation ' +
                "($vsBuildToolsRoot), so CPython's find_msbuild.bat cannot locate MSBuild. Re-add the component " +
                'explicitly in this script''s --add list.')
        }
        Write-Host "MSVC x64 component registered ($x64Registered)."

        # Checks lib\arm64, not the arm64 cl.exe: the libraries are what a clang-cl cross link needs.
        $msvcLibArm64 = Get-ChildItem -Path (Join-Path $vsBuildToolsRoot 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'lib\arm64\libcmt.lib' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if (-not $msvcLibArm64) {
            # Warn, not throw: the base image is shared, so an arm64-only prerequisite must not block amd64.
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
        # Only the success path scrubs the logs; failure paths keep them as evidence.
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
    Get-Process -Name '*vs_installer*', '*vs_buildtools*', '*vs_setup*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Host 'Cleaned up lingering VS installer processes'

    # Kept on failure for analysis, removed on success so it does not ride in the base layer.
    if ($proc -and ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010)) {
        Write-Host "Installer was not deleted (left for analysis at $installer)."
    } elseif (Test-Path $installer) {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
}
