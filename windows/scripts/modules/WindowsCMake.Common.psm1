# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

Set-StrictMode -Version Latest

# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
$buildCommonPath = Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1'
Import-Module $buildCommonPath -ErrorAction Stop

$sharedCommonPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedCommonPath -ErrorAction Stop

$testingCommonPath = Join-Path $PSScriptRoot 'WindowsTesting.Common.psm1'
Import-Module $testingCommonPath -ErrorAction Stop

# Generates compile_commands.json from the ninja graph when CMake did not emit one.
function Get-CompileCommandsDatabase {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$BuildRoot
  )

  $compileDb = Join-Path $BuildRoot 'compile_commands.json'
  if (Test-Path $compileDb) {
    return $compileDb
  }

  $buildNinja = Join-Path $BuildRoot 'build.ninja'
  if (-not (Test-Path $buildNinja)) {
    throw "compile_commands.json not found at: $compileDb"
  }

  $ninjaCommand = Get-Command 'ninja' -ErrorAction SilentlyContinue
  if (-not $ninjaCommand) {
    throw "compile_commands.json not found at: $compileDb"
  }

  Write-BuildLogWarning -Context $Context -Message 'compile_commands.json missing; generating it from ninja compdb.'

  # The resolved path keeps ninja mockable in tests.
  $compdbOutput = & $ninjaCommand.Source '-C' $BuildRoot '-t' 'compdb' 2>&1
  if ($LASTEXITCODE -ne 0) {
    $compdbError = ($compdbOutput | Out-String).Trim()
    throw "Failed to generate compile_commands.json via ninja -t compdb: $compdbError"
  }

  Set-Content -Path $compileDb -Value $compdbOutput -Encoding utf8

  if (-not (Test-Path $compileDb)) {
    throw "compile_commands.json not found at: $compileDb"
  }

  return $compileDb
}

function Get-SanitizerRuntimeDlls {
  # Microsoft's ASan runtime first: LLVM's shares the DLL name but not the exports (docs/windows-clang-cl-sanitizers.md).
  foreach ($runtimeDir in @(Get-AsanRuntimeDirs)) {
    $sanitizerDlls = @(Get-ChildItem -Path (Join-Path $runtimeDir 'clang_rt.*san*.dll') -ErrorAction SilentlyContinue)
    if ($sanitizerDlls.Count -gt 0) {
      return $sanitizerDlls
    }
  }

  return @()
}

function Copy-SanitizerRuntimeDlls {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [System.IO.FileInfo[]]$SanitizerDlls,
    [string[]]$DestinationDirectories
  )

  foreach ($destinationDirectory in @($DestinationDirectories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    if (-not (Test-Path $destinationDirectory)) {
      continue
    }

    foreach ($dll in $SanitizerDlls) {
      Copy-Item -Path $dll.FullName -Destination $destinationDirectory -Force
      Write-BuildLog -Context $Context -Message "DEBUG: Copied $($dll.Name) to $destinationDirectory"
    }
  }
}

function Remove-BuildRootSafe {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$Path,
    [Parameter(Mandatory)]
    [string]$Label
  )

  if (Remove-BuildRoot -Context $Context -Path $Path) {
    return
  }

  Write-BuildLogWarning -Context $Context -Message "Could not remove build directory ($Label): $Path. Continuing with in-place configure/build."
}

# The -DisableSccache -D flags go last so they beat the preset, a reused CMakeCache.txt and the caller's args.
function Get-CmakeConfigureArgs {
  param(
    [Parameter(Mandatory)]
    [string]$BuildPath,
    [Parameter(Mandatory)]
    [string]$Preset,
    [string[]]$ConfigureExtraArgs = @(),
    [switch]$DisableSccache
  )

  $configureArgs = @('-B', $BuildPath, '--preset', $Preset) + @($ConfigureExtraArgs)
  if ($DisableSccache) {
    $configureArgs += @('-DCOMPILER_CACHE=', '-DCMAKE_C_COMPILER_LAUNCHER=', '-DCMAKE_CXX_COMPILER_LAUNCHER=')
  }
  return , $configureArgs
}

function Write-CmakeEnvironmentDiagnostics {
  param($Context, [string[]]$Name, [switch]$ShowUnset)
  foreach ($variable in $Name) {
    $value = [Environment]::GetEnvironmentVariable($variable)
    if ($value) { Write-BuildLog -Context $Context -Message "DEBUG:   $variable = $value" }
    elseif ($ShowUnset) { Write-BuildLog -Context $Context -Message "DEBUG:   $variable = (not set)" }
  }
}

function Write-CmakeSccacheStats {
  param($Context, [switch]$Advanced)
  foreach ($line in @(Get-SccacheStatsText -Advanced:$Advanced | Where-Object { $null -ne $_ })) {
    Write-BuildLog -Context $Context -Message "DEBUG:   $line"
  }
}

function Invoke-CmakeSccacheServer {
  param($Context, [ValidateSet('Start', 'Stop')][string]$Action)
  if ($Action -eq 'Stop') {
    try {
      & sccache --stop-server 2>&1 | Out-Null
      Write-BuildLog -Context $Context -Message "DEBUG: Stopped sccache server"
    } catch {
      Write-BuildLog -Context $Context -Message "DEBUG: Could not stop sccache server (may not be running)"
    }
    return
  }
  try {
    $result = & sccache --start-server 2>&1
    Write-BuildLog -Context $Context -Message "DEBUG: sccache --start-server: $result"
  } catch {
    Write-BuildLog -Context $Context -Message "DEBUG: sccache server already running or failed to start"
  }
}

function Write-CmakeHostFacts {
  param($Context, [string]$BuildPath, [string]$Preset, [string]$Configuration, [int]$ParallelJobs, [switch]$VerboseOutput, [switch]$DisableSccache)
  $cpuCount = [Environment]::ProcessorCount
  $logicalProcessors = (Get-CimInstance -ClassName Win32_ComputerSystem).NumberOfLogicalProcessors
  Write-BuildLogMessages -Context $Context -Messages @(
    "DEBUG: ========== SYSTEM INFO =========="
    "DEBUG: System CPU count (Environment): $cpuCount"
    "DEBUG: System logical processors (WMI): $logicalProcessors"
    "DEBUG: ParallelJobs parameter: $ParallelJobs"
    "DEBUG: VerboseOutput mode: $VerboseOutput"
    "DEBUG: DisableSccache: $DisableSccache"
    "DEBUG: BuildPath: $BuildPath"
    "DEBUG: Preset: $Preset"
    "DEBUG: Configuration: $Configuration"
  )
  return $cpuCount
}

function Write-CmakeBuildSystemInfo {
  param($Context, [int]$CpuCount, [switch]$DisableSccache)

  if (Set-SccacheMaxJobsDefault -Default $CpuCount) {
    Write-BuildLog -Context $Context -Message "DEBUG: AUTO-SET SCCACHE_MAX_JOBS=$CpuCount (was not set, defaulting to CPU count)"
  } else {
    Write-BuildLog -Context $Context -Message "DEBUG: SCCACHE_MAX_JOBS already set to: $env:SCCACHE_MAX_JOBS"
  }

  if ($DisableSccache) { Disable-CmakeSccache -Context $Context }
}

function Disable-CmakeSccache {
  param($Context)
  Write-BuildLog -Context $Context -Message "DEBUG: ========== DISABLING SCCACHE =========="
  # A CUDA launcher can arrive from the environment, and a wrapped nvcc breaks multi-arch builds.
  Set-CompilerWrapperEnvironment -Value '' -IncludeCuda
  Write-BuildLog -Context $Context -Message "DEBUG: Cleared all compiler wrapper environment variables"

  $sccachePath = Get-Command 'sccache' -ErrorAction SilentlyContinue
  if ($sccachePath) {
    Invoke-CmakeSccacheServer -Context $Context -Action Stop
  }
}

function Reset-CmakeBuildRoot {
  param($Context, [string]$BuildPath, [string]$Preset, [switch]$CleanBuildRoot, [string]$CleanLabel)
  # Consumer contract, name must stay stable: set for a mounted build dir, whose wipe breaks CMake configure.
  $keepBuildRoot = -not [string]::IsNullOrWhiteSpace($env:KATAGLYPHIS_KEEP_BUILD_ROOT)
  if ($CleanBuildRoot -and -not $keepBuildRoot) {
    $label = if ([string]::IsNullOrWhiteSpace($CleanLabel)) { $Preset } else { $CleanLabel }
    Remove-BuildRootSafe -Context $Context -Path $BuildPath -Label $label
  } elseif ($CleanBuildRoot) {
    Write-BuildLog -Context $Context -Message "Keeping build root (persistent volume): $BuildPath"
  }
}

function Get-CmakeBuildArgs {
  param($Context, [string]$BuildPath, [string]$Configuration, [int]$ParallelJobs, [int]$CpuCount, [switch]$VerboseOutput,
    [string]$Target = '')
  $buildArgs = @('--build', $BuildPath)
  if ($Target) { $buildArgs += @('--target', $Target) }
  $buildArgs += @('--config', $Configuration)
  if ($ParallelJobs -gt 0) {
    $buildArgs += @('--parallel', $ParallelJobs.ToString())
    Write-BuildLog -Context $Context -Message "DEBUG: Using --parallel $ParallelJobs (limited)"
  } else {
    $buildArgs += @('--parallel')
    Write-BuildLog -Context $Context -Message "DEBUG: Using --parallel (unlimited, will use all $CpuCount cores)"
  }

  if ($VerboseOutput) {
    $buildArgs += @('--verbose')
    Write-BuildLog -Context $Context -Message "DEBUG: VerboseOutput mode enabled (--verbose)"
  }
  return $buildArgs
}

function Write-CmakeBuildDiagnostics {
  param($Context, [int]$CpuCount, [switch]$DisableSccache)
  Write-BuildLog -Context $Context -Message "DEBUG: ========== NINJA INFO =========="
  $ninjaPath = Get-Command 'ninja' -ErrorAction SilentlyContinue
  if ($ninjaPath) {
    $ninjaVersion = & ninja --version 2>&1
    Write-BuildLogMessages -Context $Context -Messages @(
      "DEBUG: Ninja version: $ninjaVersion"
      "DEBUG: Ninja path: $($ninjaPath.Source)"
      "DEBUG: Ninja will use $CpuCount jobs by default (based on CPU count)"
    )
  } else {
    Write-BuildLog -Context $Context -Message "DEBUG: Ninja not found on PATH"
  }

  Write-BuildLog -Context $Context -Message "DEBUG: ========== SCCACHE DIAGNOSTICS (BEFORE BUILD) =========="
  $sccachePath = Get-Command 'sccache' -ErrorAction SilentlyContinue
  if ($sccachePath) {
    Write-BuildLog -Context $Context -Message "DEBUG: sccache found at: $($sccachePath.Source)"

    # The resolved path avoids PATH lookup issues in containers and CI.
    if (-not $DisableSccache) {
      $sccacheExe = $sccachePath.Source
      Write-BuildLog -Context $Context -Message "DEBUG: Enabling sccache wrappers using: $sccacheExe"
      Enable-SccacheCompilerWrapper -SccacheExe $sccacheExe
    } else {
      Write-BuildLog -Context $Context -Message "DEBUG: sccache wrappers remain disabled (DisableSccache=true)"
    }

    Write-BuildLog -Context $Context -Message "DEBUG: --- sccache environment variables ---"
    $sccacheEnvVars = @(
      'SCCACHE_DIR', 'SCCACHE_CACHE_SIZE', 'SCCACHE_MAX_JOBS',
      'SCCACHE_IDLE_TIMEOUT', 'SCCACHE_LOG', 'SCCACHE_ERROR_LOG',
      'SCCACHE_RECACHE', 'SCCACHE_SERVER_PORT', 'SCCACHE_NO_DAEMON',
      'SCCACHE_DIRECT', 'SCCACHE_BUCKET', 'SCCACHE_REDIS',
      'CMAKE_C_COMPILER_LAUNCHER', 'CMAKE_CXX_COMPILER_LAUNCHER',
      'CMAKE_CUDA_COMPILER_LAUNCHER', 'SCCACHE_MULTILEVEL_CHAIN',
      'RUSTC_WRAPPER', 'CC_WRAPPER', 'CXX_WRAPPER'
    )
    Write-CmakeEnvironmentDiagnostics -Context $Context -Name $sccacheEnvVars -ShowUnset

    Write-BuildLog -Context $Context -Message "DEBUG: --- sccache server status ---"
    Invoke-CmakeSccacheServer -Context $Context -Action Start

    # No -RequireRemote: these diagnostics are wanted for a container-local cache too.
    Write-BuildLog -Context $Context -Message "DEBUG: --- sccache stats (full) ---"
    Write-CmakeSccacheStats -Context $Context

    Write-BuildLog -Context $Context -Message "DEBUG: --- sccache internal stats ---"
    Write-CmakeSccacheStats -Context $Context -Advanced
  } else {
    Write-BuildLog -Context $Context -Message "DEBUG: sccache not found on PATH"
  }

  Write-BuildLog -Context $Context -Message "DEBUG: ========== OTHER BUILD ENVIRONMENT =========="
  $otherEnvVars = @(
    'CMAKE_BUILD_PARALLEL_LEVEL', 'NINJA_STATUS', 'NINJA_FORCE_COLOR',
    'CL', '_CL_', 'LINK', '_LINK_', 'LIB', 'LIBPATH', 'INCLUDE',
    'MAKEFLAGS', 'NUMBER_OF_PROCESSORS'
  )
  Write-CmakeEnvironmentDiagnostics -Context $Context -Name $otherEnvVars
  return [bool]$sccachePath
}

function Invoke-CmakeBuildCommand {
  param($Context, [string[]]$BuildArgs, [string[]]$SanitizerRuntimeDirs)
  $buildStartTime = Get-Date
  Write-BuildLog -Context $Context -Message "DEBUG: Build started at $($buildStartTime.ToString('HH:mm:ss'))"

  # Streamed directly: Invoke-BuildExternal can lose output in Docker containers.
  $buildCmdLine = "cmake $($BuildArgs -join ' ')"
  Write-BuildLog -Context $Context -Message "CMD: $buildCmdLine"

  $global:LASTEXITCODE = 0
  $runtimePath = if ($SanitizerRuntimeDirs.Count -gt 0) { (($SanitizerRuntimeDirs -join ';') + ';' + $env:PATH) } else { $env:PATH }
  $buildResult = @{ ExitCode = 1 }
  Invoke-WithProcessEnvironment -Environment @{ PATH = $runtimePath } -ScriptBlock {
    try {
      & cmake @buildArgs 2>&1 | Write-BuildCommandOutput -Context $Context
      $buildResult.ExitCode = $global:LASTEXITCODE
    } catch {
      Write-BuildLog -Context $Context -Message "ERROR: Build exception: $_"
      $buildResult.ExitCode = 1
    }
  }
  $buildExitCode = $buildResult.ExitCode

  $buildEndTime = Get-Date
  $buildDuration = $buildEndTime - $buildStartTime
  Write-BuildLog -Context $Context -Message "DEBUG: Build completed at $($buildEndTime.ToString('HH:mm:ss'))"
  Write-BuildLog -Context $Context -Message "DEBUG: Build duration: $($buildDuration.TotalSeconds.ToString('F2')) seconds ($($buildDuration.TotalMinutes.ToString('F2')) minutes)"
  Write-BuildLog -Context $Context -Message "DEBUG: Build exit code: $buildExitCode"

  if ($buildExitCode -ne 0) {
    throw "CMake build failed with exit code $buildExitCode"
  }
}

function Copy-CmakePostBuildSanitizers {
  param($Context, [string]$BuildPath, [string]$Configuration, [object[]]$SanitizerRuntimeDlls)
  if ($Configuration -eq 'Debug') {
    Write-BuildLog -Context $Context -Message "DEBUG: Post-build step: Copying Sanitizer DLLs for debug build..."
    $binDir = Join-Path $BuildPath "bin\Debug"
    if (-not (Test-Path $binDir)) {
        $binDir = Join-Path $BuildPath "bin"
    }
    if (-not (Test-Path $binDir)) {
        $binDir = $BuildPath
    }

    Copy-CmakeSanitizerRuntime -Context $Context -SanitizerRuntimeDlls $SanitizerRuntimeDlls -DestinationDirectories @($BuildPath, $binDir) -MissingMessage 'Could not find Sanitizer dynamic DLLs to copy.'
  }
}

function Copy-CmakeSanitizerRuntime {
  param($Context, [object[]]$SanitizerRuntimeDlls, [string[]]$DestinationDirectories, [string]$MissingMessage)
  if ($SanitizerRuntimeDlls.Count -eq 0) {
    Write-BuildLogWarning -Context $Context -Message $MissingMessage
    return
  }
  Copy-SanitizerRuntimeDlls -Context $Context -SanitizerDlls $SanitizerRuntimeDlls -DestinationDirectories $DestinationDirectories
}

function Initialize-CmakeSanitizers {
  param($Context, [string]$BuildPath, [string]$Configuration)
  $sanitizerRuntimeDlls = @()
  $sanitizerRuntimeDirs = @()
  if ($Configuration -eq 'Debug') {
    $sanitizerRuntimeDlls = @(Get-SanitizerRuntimeDlls)
    Copy-CmakeSanitizerRuntime -Context $Context -SanitizerRuntimeDlls $sanitizerRuntimeDlls -DestinationDirectories @($BuildPath) -MissingMessage 'Could not find Sanitizer dynamic DLLs before build. Build-time helper executables may fail to start.'
    if ($sanitizerRuntimeDlls.Count -gt 0) {
      $sanitizerRuntimeDirs = @($sanitizerRuntimeDlls | ForEach-Object { $_.DirectoryName } | Select-Object -Unique)
      Write-BuildLog -Context $Context -Message "DEBUG: Using sanitizer runtime PATH entries: $($sanitizerRuntimeDirs -join ';')"
    }
  }
  return [pscustomobject]@{ Dlls = $sanitizerRuntimeDlls; Dirs = $sanitizerRuntimeDirs }
}

function Invoke-CmakeConfigureAndBuild {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$BuildPath,
    [Parameter(Mandatory)]
    [string]$Preset,
    [Parameter(Mandatory)]
    [string]$Configuration,
    [string[]]$ConfigureExtraArgs = @(),
    [switch]$CleanBuildRoot,
    [string]$CleanLabel = '',
    [int]$ParallelJobs = 0,
    [switch]$VerboseOutput,
    [switch]$DisableSccache
  )

  $cpuCount = Write-CmakeHostFacts -Context $Context -BuildPath $BuildPath -Preset $Preset -Configuration $Configuration -ParallelJobs $ParallelJobs -VerboseOutput:$VerboseOutput -DisableSccache:$DisableSccache
  Write-CmakeBuildSystemInfo -Context $Context -CpuCount $cpuCount -DisableSccache:$DisableSccache

  Reset-CmakeBuildRoot -Context $Context -BuildPath $BuildPath -Preset $Preset -CleanBuildRoot:$CleanBuildRoot -CleanLabel $CleanLabel

  $configureArgs = Get-CmakeConfigureArgs -BuildPath $BuildPath -Preset $Preset -ConfigureExtraArgs $ConfigureExtraArgs -DisableSccache:$DisableSccache

  $buildArgs = @(Get-CmakeBuildArgs -Context $Context -BuildPath $BuildPath -Configuration $Configuration -ParallelJobs $ParallelJobs -CpuCount $cpuCount -VerboseOutput:$VerboseOutput)

  $configureCmd = "cmake $($configureArgs -join ' ')"
  $buildCmd = "cmake $($buildArgs -join ' ')"
  Write-BuildLog -Context $Context -Message "DEBUG: Configure command: $configureCmd"
  Write-BuildLog -Context $Context -Message "DEBUG: Build command: $buildCmd"

  $hasSccache = Write-CmakeBuildDiagnostics -Context $Context -CpuCount $cpuCount -DisableSccache:$DisableSccache

  Write-BuildLog -Context $Context -Message "DEBUG: ========== STARTING BUILD =========="
  Write-BuildLog -Context $Context -Message "DEBUG: Starting configure step..."
  Invoke-BuildExternal -Context $Context -File 'cmake' -Parameters $configureArgs | Out-Null
  Write-BuildLog -Context $Context -Message "DEBUG: Configure completed. Starting build step..."

  $sanitizer = Initialize-CmakeSanitizers -Context $Context -BuildPath $BuildPath -Configuration $Configuration

  Invoke-CmakeBuildCommand -Context $Context -BuildArgs $buildArgs -SanitizerRuntimeDirs $sanitizer.Dirs

  Copy-CmakePostBuildSanitizers -Context $Context -BuildPath $BuildPath -Configuration $Configuration -SanitizerRuntimeDlls $sanitizer.Dlls

  Write-BuildLog -Context $Context -Message "DEBUG: ========== SCCACHE DIAGNOSTICS (AFTER BUILD) =========="
  if ($hasSccache) {
    Write-CmakeSccacheStats -Context $Context
  }
}

function Test-ClangClThreadSanitizerSupport {
  param(
    [Parameter(Mandatory)]
    [string]$ClangClPath
  )

  try {
    $versionOutput = & $ClangClPath '--version' 2>&1
    $versionText = ($versionOutput | Out-String)
    if ($versionText -match 'Target:\s*x86_64-.*windows-msvc') {
      return $false
    }
  } catch {
    return $false
  }

  return $true
}


# --- CTest metadata after a container build (container paths rewritten for host test runs) ---

function Get-CMakeShareDir {
    param([string]$CMakeExePath)

    if ([string]::IsNullOrWhiteSpace($CMakeExePath)) {
        return $null
    }

    $cmakeBinDir = Split-Path $CMakeExePath -Parent
    $cmakeRoot = Split-Path $cmakeBinDir -Parent
    $shareRoot = Join-Path $cmakeRoot 'share'
    if (-not (Test-Path $shareRoot)) {
        return $null
    }

    $shareDir = Get-ChildItem -Path $shareRoot -Directory -Filter 'cmake-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1

    if (-not $shareDir) {
        return $null
    }

    return $shareDir.FullName.Replace('\', '/')
}

function Update-CTestMetadataPaths {
    param(
        [Parameter(Mandatory)]
        [string]$BuildRoot,
        [Parameter(Mandatory)]
        [string]$WorkspaceRoot,
        [string]$CMakeShareDir,
        [string]$ContainerRoot = 'C:/workspace'
    )

    if (-not (Test-Path $BuildRoot)) {
        return
    }

    $workspacePathUnix = $WorkspaceRoot.Replace('\', '/')
    $containerRootUnix = $ContainerRoot.Replace('\', '/').TrimEnd('/')
    $files = Get-ChildItem -Path $BuildRoot -Recurse -File -Include 'CTestTestfile.cmake', 'DartConfiguration.tcl', '*_include.cmake', '*_discovery.cmake', '*_tests.cmake' -ErrorAction SilentlyContinue
    $asciiEncoding = [System.Text.Encoding]::ASCII

    foreach ($file in $files) {
        $originalContent = [System.IO.File]::ReadAllText($file.FullName)
        $updatedContent = $originalContent.Replace($containerRootUnix, $workspacePathUnix)

        if (-not [string]::IsNullOrWhiteSpace($CMakeShareDir)) {
            $updatedContent = [regex]::Replace($updatedContent, 'C:/Program Files/CMake/share/cmake-[0-9.]+', $CMakeShareDir)
            $updatedContent = [regex]::Replace($updatedContent, 'C:/Strawberry/c/share/cmake-[0-9.]+', $CMakeShareDir)
        }

        if ($updatedContent -cne $originalContent) {
            [System.IO.File]::WriteAllText($file.FullName, $updatedContent, $asciiEncoding)
        }
    }
}

Export-ModuleMember -Function Get-CMakeShareDir, Update-CTestMetadataPaths, Get-CompileCommandsDatabase, Remove-BuildRootSafe, Get-CmakeConfigureArgs, Get-CmakeBuildArgs, Invoke-CmakeConfigureAndBuild, Test-ClangClThreadSanitizerSupport
