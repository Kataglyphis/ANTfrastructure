# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

#requires -Version 7.0

# Runs test binaries and ctest with the ASan runtime reachable and ASAN_OPTIONS scoped to the call.

Set-StrictMode -Version Latest

# Not -Force, so an entry script's -Force -Global copy is not displaced.
Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
# Get-MsvcToolsRoots.
Import-Module (Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1')

# Memoised: resolving walks the VS install tree, and a test step asks once per executable.
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
      MSVC toolset directories that ship the ASan runtime, newest first.
  .DESCRIPTION
      See docs/windows-clang-cl-sanitizers.md § Microsoft's ASan runtime, not LLVM's.
  #>
  param()

  $runtimeDirs = [System.Collections.Generic.List[string]]::new()
  # No Visual Studio means one fewer root, never a failure; -All searches every install.
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
    # Best-effort: the LLVM-install candidates above still apply.
    Write-Verbose "clang-cl resource-dir probe failed: $($_.Exception.Message)"
  }

  return @($runtimeDirs)
}

function Get-AsanRuntimeDirs {
  <#
  .SYNOPSIS
      Every directory holding an ASan runtime DLL, Microsoft's first, then LLVM's.
  .PARAMETER RuntimeFlavor
      'Msvc' or 'Clang' restricts the search; prefer 'Msvc' for anything hosting COM or the CRT before main().
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
      # Inside a VsDevCmd shell this is already the right toolset, and cheaper than vswhere.
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
      Locates a test binary in a build tree: root, multi-config dirs, extra dirs, then a recursive search.
  .DESCRIPTION
      For an installed bundle use Resolve-AppExecutablePath (WindowsAppRunner.Common) instead.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [Parameter(Mandatory)]
    [string]$ExecutableName,
    # Probed before the recursive fallback, e.g. @('Test\commit', 'Test\perf').
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
      Runs a script block with extra ASAN_OPTIONS prepended, then restores them.
  .DESCRIPTION
      Values stay with the caller: a GUI app needs report_globals=0 and windows_hook_rtl_allocators=false.
      An empty -Options leaves ASAN_OPTIONS exactly as the caller had it.
  #>
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Options,
    [Parameter(Mandatory)]
    [scriptblock]$Script
  )

  if ([string]::IsNullOrEmpty($Options)) {
    & $Script
    return
  }

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
      Runs a script block with extra PATH directories and ASAN_OPTIONS, restoring both afterwards.
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
      A missing binary or a loader failure returns $false with a warning: failing the pipeline would hide the
      results that did run.
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
