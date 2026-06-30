# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

function Get-SourceBuildVersion {
    param(
        [string]$Value = '',
        [string[]]$EnvironmentVariables = @(),
        [string]$DefaultValue = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) { return $Value }

    foreach ($envVar in $EnvironmentVariables) {
        if (-not [string]::IsNullOrWhiteSpace($envVar)) {
            $envValue = [Environment]::GetEnvironmentVariable($envVar)
            if (-not [string]::IsNullOrWhiteSpace($envValue)) { return $envValue }
        }
    }

    return $DefaultValue
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
    $env:GIT_SSL_NO_VERIFY = '1'
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

    # Auto-detect sccache compiler launcher for max-speed incremental rebuilds
    $sccacheCmd = Get-Command sccache.exe -ErrorAction SilentlyContinue
    if ($sccacheCmd) {
        if (-not $env:SCCACHE_MAX_JOBS) { $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount.ToString() }
        $cmakeArgs += "-DCMAKE_C_COMPILER_LAUNCHER:FILEPATH=$($sccacheCmd.Source)"
        $cmakeArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER:FILEPATH=$($sccacheCmd.Source)"
        Write-Host "sccache enabled at: $($sccacheCmd.Source) (max $env:SCCACHE_MAX_JOBS jobs)"
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

    Write-Host "Building (this may take 15-120 minutes)..."
    if ($LogFile) {
        & cmake --build $BuildDir --config $Config --parallel 2>&1 | Tee-Object -FilePath $LogFile | Out-Null
    } else {
        & cmake --build $BuildDir --config $Config --parallel
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

function Assert-CudaAvailable {
    $root = Get-CudaRoot
    return -not [string]::IsNullOrWhiteSpace($root)
}

function Assert-CudnnInstalled {
    param(
        [string]$CudnnRoot = ''
    )

    if ([string]::IsNullOrWhiteSpace($CudnnRoot)) { $CudnnRoot = $env:CUDNN_ROOT }
    if ([string]::IsNullOrWhiteSpace($CudnnRoot)) { return $false }
    if (-not (Test-Path $CudnnRoot)) { return $false }

    $headers = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn.h' -Recurse -ErrorAction SilentlyContinue
    $libs = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.lib' -Recurse -ErrorAction SilentlyContinue
    $dlls = Get-ChildItem -Path $CudnnRoot -Filter 'cudnn*.dll' -Recurse -ErrorAction SilentlyContinue

    return ($headers.Count -gt 0) -and ($libs.Count -gt 0) -and ($dlls.Count -gt 0)
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

function Get-SccacheLauncher {
    <#
    .SYNOPSIS
        Finds sccache.exe on PATH and sets SCCACHE_MAX_JOBS to the processor count.
    .OUTPUTS
        [string] Full path to sccache.exe, or $null if not found.
    #>
    $cmd = Get-Command sccache.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    $env:SCCACHE_MAX_JOBS = [Environment]::ProcessorCount
    return $cmd.Source
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
        Applies a patch file to source code using git apply.
    .DESCRIPTION
        Uses git apply (available in the container via Git for Windows) to apply a
        unified diff patch file to the source tree. The patch file is a standard git
        diff with a/ b/ prefix (stripped by -p1 default).
    .PARAMETER PatchFile
        Path to the .patch file to apply.
    .PARAMETER SourceDir
        Root directory of the source tree to patch (cwd during apply).
    .PARAMETER Strip
        Number of leading path components to strip (default 1, strips a/).
    .PARAMETER IgnoreWhitespace
        If set, passes --ignore-whitespace to git apply (for whitespace drift).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$PatchFile,
        [Parameter(Mandatory)]
        [string]$SourceDir,
        [int]$Strip = 1,
        [switch]$IgnoreWhitespace
    )

    if (-not (Test-Path $PatchFile)) { throw "Patch file not found: $PatchFile" }
    if (-not (Test-Path $SourceDir)) { throw "Source directory not found: $SourceDir" }

    $gitArgs = @('apply', "-p$Strip", '--verbose')
    if ($IgnoreWhitespace) { $gitArgs += '--ignore-whitespace' }
    $gitArgs += $PatchFile

    Push-Location $SourceDir
    try {
        Write-Host "Applying patch: $(Split-Path $PatchFile -Leaf) to $SourceDir"
        & git @gitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git apply failed (exit $LASTEXITCODE): $PatchFile" }
        Write-Host "  [OK] Patch applied successfully"
    } finally {
        Pop-Location
    }
}

Export-ModuleMember -Function @(
    'Get-SourceBuildVersion',
    'Invoke-GitClone',
    'Invoke-CmakeConfigure',
    'Invoke-CmakeBuild',
    'Get-CudaRoot',
    'Assert-CudaAvailable',
    'Assert-CudnnInstalled',
    'Enter-VsDevCmdEnvironment',
    'Get-VsInstallPath',
    'Get-MsvcToolsRoot',
    'Resolve-LlvmArchiver',
    'Copy-CpythonPyConfigHeader',
    'Get-SourceBuildPython',
    'Replace-CppKeywordAlternatives',
    'Get-SccacheLauncher',
    'Update-NinjaFile',
    'Invoke-SourcePatch'
)
