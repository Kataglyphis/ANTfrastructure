# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Test execution on Windows: locating a test binary in a build tree, and running
# it (or ctest) with the AddressSanitizer runtime reachable and ASAN_OPTIONS
# scoped to the call.
#
# Upstreamed from Kataglyphis-BeschleunigerBallett's vendored
# Scripts/Windows/modules copy (2026-08-11). Nothing in it was project-specific,
# and a second consumer needed the same ASan-runtime discovery:
# Kataglyphis-Inference-Engine's Start-Windows.ps1 was hand-rolling a narrower
# version of Get-AsanRuntimeDirs that only ever matched the BuildTools SKU.
#
# The Visual Studio half now goes through Get-MsvcToolsRoots
# (WindowsScripts.Shared) rather than globbing "Program Files*\Microsoft Visual
# Studio\*\*": that is the vswhere-based single source this repo already
# consolidated on, it finds Community/Professional/Enterprise as well as
# BuildTools, retries a cold-boot race and falls back to filesystem discovery.

Set-StrictMode -Version Latest

# Logging/exec primitives (Write-BuildLog*, Invoke-BuildExternal). Plain,
# unforced import so an entry script's -Force -Global copy is not displaced --
# the shadowing pitfall documented in WindowsCMake.Common's header.
Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
# Get-MsvcToolsRoots.
Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1')

# The MSVC ASan runtime directory, memoised: resolving it walks the VS install
# tree, and a test step calls it once per executable.
$script:MsvcAsanRuntimeDir = $null

$script:AsanRuntimeDllName = 'clang_rt.asan_dynamic-x86_64.dll'

function Add-AsanRuntimeDirIfPresent {
  <#
  .SYNOPSIS
      Appends a directory to a list if it actually holds the ASan runtime DLL.
  #>
  param(
    [Parameter(Mandatory)]
    [object]$RuntimeDirs,
    [string]$CandidateDir
  )

  if ([string]::IsNullOrWhiteSpace($CandidateDir)) {
    return
  }

  $asanRuntime = Join-Path $CandidateDir $script:AsanRuntimeDllName
  if ((Test-Path $CandidateDir) -and (Test-Path $asanRuntime) -and -not $RuntimeDirs.Contains($CandidateDir)) {
    $RuntimeDirs.Add($CandidateDir)
  }
}

function Get-VisualStudioAsanRuntimeDirs {
  <#
  .SYNOPSIS
      Directories under the installed MSVC toolsets that ship the ASan runtime,
      newest toolset first.
  .DESCRIPTION
      Microsoft's runtime, NOT LLVM's. On a Flutter/COM application the two are
      not interchangeable: LLVM's clang_rt.asan_dynamic loads after ucrtbase, so
      allocations made during CRT/COM startup are unhooked and it aborts with an
      unsuppressible bad-free when combase/ole32 later frees them. Microsoft's
      tracks Windows heap ownership and passes those foreign frees through.
  #>
  param()

  $runtimeDirs = [System.Collections.Generic.List[string]]::new()
  # -AllowMissing: no Visual Studio just means one fewer runtime root, never a
  # hard failure. -All so a machine with several installs is fully searched.
  foreach ($toolsRoot in @(Get-MsvcToolsRoots -AllowMissing -All)) {
    Add-AsanRuntimeDirIfPresent -RuntimeDirs $runtimeDirs -CandidateDir (Join-Path $toolsRoot 'bin\Hostx64\x64')
  }

  return @($runtimeDirs)
}

function Get-LlvmAsanRuntimeDirs {
  <#
  .SYNOPSIS
      Directories under the LLVM install that ship the ASan runtime.
  #>
  param()

  $runtimeDirs = [System.Collections.Generic.List[string]]::new()
  $clangCommand = Get-Command 'clang-cl.exe' -ErrorAction SilentlyContinue

  if ($clangCommand) {
    $clangBinDir = Split-Path $clangCommand.Source -Parent
    $llvmRoot = Split-Path $clangBinDir -Parent
    $clangLibRoot = Join-Path $llvmRoot 'lib\clang'
    if (Test-Path $clangLibRoot) {
      Get-ChildItem -Path $clangLibRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Add-AsanRuntimeDirIfPresent -RuntimeDirs $runtimeDirs -CandidateDir (Join-Path $_.FullName 'lib\windows')
      }
    }
  }

  try {
    $clangResourceDir = & 'clang-cl.exe' --print-resource-dir 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($clangResourceDir)) {
      Add-AsanRuntimeDirIfPresent -RuntimeDirs $runtimeDirs -CandidateDir (Join-Path $clangResourceDir.Trim() 'lib\windows')
    }
  } catch {
  }

  return @($runtimeDirs)
}

function Get-AsanRuntimeDirs {
  <#
  .SYNOPSIS
      Every directory holding an ASan runtime DLL, in load-preference order.
  .PARAMETER RuntimeFlavor
      'Msvc' or 'Clang' to restrict the search; 'Auto' (default) returns
      Microsoft's first, then LLVM's. Prefer 'Msvc' for anything that hosts COM
      or the CRT before main() -- see Get-VisualStudioAsanRuntimeDirs.
  #>
  param(
    [ValidateSet('Auto', 'Msvc', 'Clang')]
    [string]$RuntimeFlavor = 'Auto'
  )

  $asanRuntimeDirs = [System.Collections.Generic.List[string]]::new()

  if ($RuntimeFlavor -eq 'Auto' -or $RuntimeFlavor -eq 'Msvc') {
    if ($script:MsvcAsanRuntimeDir) {
      Add-AsanRuntimeDirIfPresent -RuntimeDirs $asanRuntimeDirs -CandidateDir $script:MsvcAsanRuntimeDir
    } elseif ($env:VCToolsInstallDir) {
      # Inside a VsDevCmd shell this is already the right toolset -- cheaper
      # than asking vswhere, and it is what the container entrypoint sets.
      $fromEnv = Join-Path $env:VCToolsInstallDir 'bin\Hostx64\x64'
      Add-AsanRuntimeDirIfPresent -RuntimeDirs $asanRuntimeDirs -CandidateDir $fromEnv
      if ($asanRuntimeDirs.Count -gt 0) {
        $script:MsvcAsanRuntimeDir = $fromEnv
      }
    }

    if ($asanRuntimeDirs.Count -eq 0) {
      foreach ($runtimeDir in Get-VisualStudioAsanRuntimeDirs) {
        Add-AsanRuntimeDirIfPresent -RuntimeDirs $asanRuntimeDirs -CandidateDir $runtimeDir
        if (-not $script:MsvcAsanRuntimeDir) {
          $script:MsvcAsanRuntimeDir = $runtimeDir
        }
      }
    }
  }

  if ($RuntimeFlavor -eq 'Auto' -or $RuntimeFlavor -eq 'Clang') {
    foreach ($runtimeDir in Get-LlvmAsanRuntimeDirs) {
      Add-AsanRuntimeDirIfPresent -RuntimeDirs $asanRuntimeDirs -CandidateDir $runtimeDir
    }
  }

  return @($asanRuntimeDirs)
}

function Get-AsanRuntimeDll {
  <#
  .SYNOPSIS
      Full path of the first ASan runtime DLL found, or $null.
  .DESCRIPTION
      The "I just need the file to copy next to my exe" entry point --
      Get-AsanRuntimeDirs returns directories, and every consumer that only
      wants to stage the DLL was re-deriving this join itself.
  #>
  param(
    [ValidateSet('Auto', 'Msvc', 'Clang')]
    [string]$RuntimeFlavor = 'Auto'
  )

  $dir = @(Get-AsanRuntimeDirs -RuntimeFlavor $RuntimeFlavor) | Select-Object -First 1
  if (-not $dir) { return $null }
  return (Join-Path $dir $script:AsanRuntimeDllName)
}

function Resolve-TestExecutable {
  <#
  .SYNOPSIS
      Locates a test binary inside a build tree.
  .DESCRIPTION
      Tries the build root, then the multi-config subdirectories, then the
      caller's extra relative directories, before a recursive search.
      Distinct from WindowsAppRunner.Common's Resolve-AppExecutablePath, which
      searches an INSTALLED bundle (bin\, per-configuration bundle layout).
  #>
  param(
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$ExecutableName,
    # Extra build-root-relative directories to probe before the recursive
    # fallback, e.g. @('Test\commit', 'Test\perf'). Project layouts differ;
    # the defaults cover single- and multi-config generators only.
    [string[]]$AdditionalRelativeDirectory = @()
  )

  $relativeDirs = @('', 'Debug', 'Release', 'RelWithDebInfo') + $AdditionalRelativeDirectory

  foreach ($relative in $relativeDirs) {
    $candidate = if ([string]::IsNullOrEmpty($relative)) {
      Join-Path $BuildRoot $ExecutableName
    } else {
      Join-Path $BuildRoot (Join-Path $relative $ExecutableName)
    }
    if (Test-Path $candidate) {
      return $candidate
    }
  }

  $found = Get-ChildItem -Path $BuildRoot -Filter $ExecutableName -File -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($found) {
    return $found.FullName
  }

  return $null
}

function Invoke-WithAsanOptions {
  <#
  .SYNOPSIS
      Runs a script block with extra ASAN_OPTIONS prepended, then restores.
  .DESCRIPTION
      The single home for the save/override/restore pattern - do not hand-roll
      it at call sites. Option VALUES stay with the caller: test binaries
      typically want report_globals=1, while a full GUI application needs
      report_globals=0 + windows_hook_rtl_allocators=false, because GUI/driver
      globals and RTL allocator hooking produce noise a test binary never sees.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$Options,
    [Parameter(Mandatory)]
    [scriptblock]$Script
  )

  $oldAsanOptions = $env:ASAN_OPTIONS
  if ([string]::IsNullOrEmpty($oldAsanOptions)) {
    $env:ASAN_OPTIONS = $Options
  } else {
    $env:ASAN_OPTIONS = "${Options}:$oldAsanOptions"
  }
  try {
    & $Script
  } finally {
    if ($null -ne $oldAsanOptions) {
      $env:ASAN_OPTIONS = $oldAsanOptions
    } else {
      Remove-Item Env:\ASAN_OPTIONS -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-WithRuntimePath {
  <#
  .SYNOPSIS
      Runs a script block with extra directories on PATH and ASAN_OPTIONS set,
      restoring both afterwards.
  #>
  param(
    [string[]]$RuntimeDirs = @(),
    [Parameter(Mandatory)]
    [scriptblock]$Script,
    [string]$AsanOptions = 'log_path=logs/asan.log:report_globals=1'
  )

  # Normalize to a clean string array, even when the caller provides $null or a scalar value.
  $normalizedRuntimeDirs = @($RuntimeDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $oldPath = $env:PATH
  if ($normalizedRuntimeDirs.Length -gt 0) {
    $env:PATH = (($normalizedRuntimeDirs -join ';') + ';' + $oldPath)
  }

  try {
    Invoke-WithAsanOptions -Options $AsanOptions -Script $Script
  } finally {
    if ($normalizedRuntimeDirs.Length -gt 0) {
      $env:PATH = $oldPath
    }
  }
}

function Invoke-ManualTestExecutable {
  <#
  .SYNOPSIS
      Runs one test binary with the ASan runtime reachable.
  .DESCRIPTION
      Returns $false (with a warning) rather than throwing when the binary is
      missing, or when Windows refuses to start it with STATUS_DLL_NOT_FOUND /
      STATUS_ENTRYPOINT_NOT_FOUND -- a loader/runtime mismatch is an
      environment problem, and failing the whole pipeline on it hides the test
      results that DID run.
  #>
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$ExecutableName,
    [string[]]$Arguments = @(),
    [ValidateSet('Auto', 'Msvc', 'Clang')]
    [string]$RuntimeFlavor = 'Auto',
    [string[]]$AdditionalRelativeDirectory = @()
  )

  $testExecutable = Resolve-TestExecutable -BuildRoot $BuildRoot -ExecutableName $ExecutableName `
    -AdditionalRelativeDirectory $AdditionalRelativeDirectory
  if (-not $testExecutable) {
    Write-BuildLogWarning -Context $Context -Message "Test executable '$ExecutableName' not found under '$BuildRoot'."
    return $false
  }

  $asanRuntimeDirs = Get-AsanRuntimeDirs -RuntimeFlavor $RuntimeFlavor

  $started = Invoke-WithRuntimePath -RuntimeDirs $asanRuntimeDirs -Script {
    try {
      Invoke-BuildExternal -Context $Context -File $testExecutable -Parameters $Arguments | Out-Null
      $true
    } catch {
      $errorText = $_.Exception.Message
      if ($errorText -match 'exit code -1073741511|exit code -1073741515') {
        Write-BuildLogWarning -Context $Context -Message "Manual test execution failed to start '$ExecutableName' (Windows loader/runtime mismatch). Continuing pipeline."
        $false
      } else {
        throw
      }
    }
  }

  return [bool]$started
}

function Invoke-CtestDiscoveredTests {
  <#
  .SYNOPSIS
      Runs ctest over a build tree with the ASan runtime reachable.
  #>
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$Configuration,
    [string[]]$ExcludeRegex = @(),
    [ValidateSet('Auto', 'Msvc', 'Clang')]
    [string]$RuntimeFlavor = 'Auto',
    [int]$TimeoutSeconds = 300
  )

  $ctestCommand = Get-Command 'ctest' -ErrorAction SilentlyContinue
  if (-not $ctestCommand) {
    throw 'ctest not found on PATH.'
  }

  $asanRuntimeDirs = Get-AsanRuntimeDirs -RuntimeFlavor $RuntimeFlavor

  $ctestParameters = @(
    '--test-dir', $BuildRoot,
    '--build-config', $Configuration,
    '--output-on-failure',
    '--timeout', $TimeoutSeconds.ToString()
  )

  foreach ($regex in @($ExcludeRegex | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    $ctestParameters += @('--exclude-regex', $regex)
  }

  Invoke-WithRuntimePath -RuntimeDirs $asanRuntimeDirs -Script {
    Invoke-BuildExternal -Context $Context -File $ctestCommand.Source -Parameters $ctestParameters | Out-Null
  }
}

Export-ModuleMember -Function @(
  'Resolve-TestExecutable',
  'Invoke-ManualTestExecutable',
  'Invoke-CtestDiscoveredTests',
  'Invoke-WithAsanOptions',
  'Invoke-WithRuntimePath',
  'Get-AsanRuntimeDirs',
  'Get-AsanRuntimeDll',
  'Get-VisualStudioAsanRuntimeDirs',
  'Get-LlvmAsanRuntimeDirs'
)
