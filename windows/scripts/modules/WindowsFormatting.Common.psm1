Set-StrictMode -Version Latest
#requires -Version 7.0


# No -Force: see docs/windows-build-invariants.md § Import-Module -Force only at entry-script top level
if (-not (Get-Module -Name 'WindowsUv.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsUv.Common.psm1')
}

if (-not (Get-Module -Name 'WindowsBuild.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

$script:CppExtensions = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.ixx')

# git ls-files fast path, else a Get-ChildItem walk; the public wrappers pass pathspec and predicate.
function Get-ProjectSourceFiles {
  param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [Parameter(Mandatory)]
    [string[]]$GitPathspec,
    [Parameter(Mandatory)]
    [scriptblock]$FileFilter
  )

  $gitCommand = Get-Command 'git' -ErrorAction SilentlyContinue
  if ($gitCommand) {
    try {
      $tracked = & $gitCommand.Source -C $WorkspacePath ls-files -- @GitPathspec 2>$null
      if ($LASTEXITCODE -eq 0 -and $tracked) {
        $trackedPaths = @($tracked |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
          ForEach-Object { Join-Path $WorkspacePath $_ } |
          Where-Object {
            ($_.ToString() -notmatch '\\build([\\-]|\\)') -and
            ($_.ToString() -notmatch '\\(ExternalLib|third_party)\\') -and
            # -notmatch: -match here keeps only _deps and silently formats zero files.
            ($_.ToString() -notmatch '\\_deps\\') -and
            ($_.ToString() -notmatch '\\vcpkg_installed\\')
          })
        return @($trackedPaths | Sort-Object -Unique)
      }
    } catch {
      Write-Verbose "git ls-files enumeration failed: $($_.Exception.Message)"
    }
  }

  # The usual path in a tar-piped container (no .git), so it must exclude at least as much, venvs included.
  $files = Get-ChildItem -Path $WorkspacePath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      (& $FileFilter $_) -and
      ($_.FullName -notmatch '\\build([\\-]|\\)') -and
      ($_.FullName -notmatch '\\(ExternalLib|third_party)\\') -and
      ($_.FullName -notmatch '\\_deps\\') -and
      ($_.FullName -notmatch '\\.git\\modules\\') -and
      ($_.FullName -notmatch '\\vcpkg_installed\\') -and
      ($_.FullName -notmatch '\\\.venv') -and
      ($_.FullName -notmatch '\\site-packages\\')
    } |
    Select-Object -ExpandProperty FullName

  return @($files | Sort-Object -Unique)
}

function Get-ProjectCmakeFiles {
  param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    # Extra regexes excluded on top of the built-in build/_deps/vendor set.
    [string[]]$ExcludePattern = @()
  )

  $cmakeFiles = Get-ProjectSourceFiles -WorkspacePath $WorkspacePath `
    -GitPathspec @('CMakeLists.txt', '**/CMakeLists.txt', '*.cmake') `
    -FileFilter { param($f) $f.Name -eq 'CMakeLists.txt' -or $f.Extension -eq '.cmake' }

  foreach ($pattern in $ExcludePattern) {
    $cmakeFiles = @($cmakeFiles | Where-Object { $_ -notmatch $pattern })
  }
  return @($cmakeFiles | Sort-Object -Unique)
}

function Get-ProjectCppFiles {
  param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath
  )

  return @(Get-ProjectSourceFiles -WorkspacePath $WorkspacePath `
    -GitPathspec @('*.c', '*.cc', '*.cpp', '*.cxx', '*.h', '*.hh', '*.hpp', '*.ixx') `
    -FileFilter { param($f) $script:CppExtensions -contains $f.Extension.ToLowerInvariant() })
}

# Adapter over WindowsUv.Common kept for callers; returns the venv's python.exe path.
function Initialize-UvVenvPython {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [string]$PythonVersion = '3.12',
    [string]$EnvName = '.venv',
    # Default <workspace>/requirements.txt if present; cmake-format alone needs only linux/scripts/cmake-format.requirements.txt.
    [string]$RequirementsPath = ''
  )

  $uvCommand = Get-Command 'uv' -ErrorAction SilentlyContinue
  if (-not $uvCommand) {
    throw 'uv not found on PATH. Install Astral uv before running formatting steps.'
  }

  $uvDelegates = New-UvBuildDelegates -Context $Context
  $logInfo = $uvDelegates.LogInfo
  $logWarning = $uvDelegates.LogWarning
  $commandRunner = $uvDelegates.CommandRunner

  $venvPython = Initialize-UvVenv -Workspace $WorkspacePath -PythonVersion $PythonVersion -EnvName $EnvName `
    -CommandRunner $commandRunner -LogInfo $logInfo -LogWarning $logWarning

  $requirementsPath = if ($RequirementsPath) { $RequirementsPath }
                      else { Join-Path $WorkspacePath 'requirements.txt' }
  if (-not (Test-Path $requirementsPath)) {
    Write-BuildLog -Context $Context -Message "No requirements.txt found at $requirementsPath, skipping dependency sync."
    return $venvPython
  }

  Write-BuildLog -Context $Context -Message "Installing requirements from $requirementsPath..."
  Install-UvRequirements -VenvPython $venvPython -RequirementsPath $requirementsPath `
    -CommandRunner $commandRunner -LogInfo $logInfo

  return $venvPython
}

function Invoke-CmakeFormatStep {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    # Report instead of rewriting: with --in-place a gate can only pass and the change lands in someone's git status.
    [switch]$Check,
    [string]$RequirementsPath = '',
    [string[]]$ExcludePattern = @()
  )

  $venvPython = Initialize-UvVenvPython -Context $Context -WorkspacePath $WorkspacePath `
    -RequirementsPath $RequirementsPath
  $cmakeFormatExe = Join-Path (Split-Path $venvPython -Parent) 'cmake-format.exe'
  if (-not (Test-Path $cmakeFormatExe)) {
    throw "cmake-format not found in venv: $cmakeFormatExe"
  }

  $formatConfig = Join-Path $WorkspacePath '.cmake-format.yaml'
  $cmakeFiles = @(Get-ProjectCmakeFiles -WorkspacePath $WorkspacePath -ExcludePattern $ExcludePattern)
  if ($cmakeFiles.Count -eq 0) {
    Write-BuildLog -Context $Context -Message 'No CMake files found for cmake-format.'
    return
  }

  $mode = if ($Check) { @('--check') } else { @('--in-place') }
  foreach ($cmakeFile in $cmakeFiles) {
    $parameters = if (Test-Path $formatConfig) { @('-c', $formatConfig) + $mode + @($cmakeFile) }
                  else { $mode + @($cmakeFile) }
    Invoke-BuildExternal -Context $Context -File $cmakeFormatExe -Parameters $parameters | Out-Null
  }
}

function Invoke-ClangFormatStep {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$WorkspacePath
  )

  $clangFormat = Get-Command 'clang-format' -ErrorAction SilentlyContinue
  if (-not $clangFormat) {
    $commonPaths = @(
      'C:\Program Files\LLVM\bin\clang-format.exe',
      'C:\Program Files (x86)\LLVM\bin\clang-format.exe'
    )
    foreach ($path in $commonPaths) {
      if (Test-Path $path) {
        $clangFormatSource = $path
        break
      }
    }

    if (-not $clangFormatSource) {
      throw 'clang-format not found on PATH or in common installation locations.'
    }
  } else {
    $clangFormatSource = $clangFormat.Source
  }

  $cppFiles = @(Get-ProjectCppFiles -WorkspacePath $WorkspacePath)
  if ($cppFiles.Count -eq 0) {
    Write-BuildLog -Context $Context -Message 'No C/C++ files found for clang-format.'
    return
  }

  foreach ($cppFile in $cppFiles) {
    Invoke-BuildExternal -Context $Context -File $clangFormatSource -Parameters @('-i', $cppFile) | Out-Null
  }
}

<#
.SYNOPSIS
  Reports how many sources deviate from .clang-format WITHOUT rewriting them.
.DESCRIPTION
  Report-only by default, for a project with a large known backlog. -FailOnDeviation makes it a gate once the
  backlog is zero, and -ExpectedVersion refuses a clang-format of any other LLVM release (BACKLOG CON71).
#>
function Invoke-ClangFormatCheck {
  param(
    [Parameter(Mandatory)]$Context,
    [Parameter(Mandatory)][string]$WorkspacePath,
    [switch]$FailOnDeviation,
    [string]$ExpectedVersion = ''
  )

  $clangFormat = Get-Command 'clang-format' -ErrorAction SilentlyContinue
  if (-not $clangFormat) {
    $candidates = @(
      'C:\Program Files\LLVM\bin\clang-format.exe',
      'C:\Program Files (x86)\LLVM\bin\clang-format.exe'
    )
    $clangFormatSource = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $clangFormatSource) {
      if ($FailOnDeviation) { throw 'clang-format not found; the format gate cannot run.' }
      Write-BuildLog -Context $Context -Message 'clang-format not found; skipping format check.'
      return
    }
  } else {
    $clangFormatSource = $clangFormat.Source
  }

  if ($ExpectedVersion) {
    $version = (& $clangFormatSource --version 2>&1) -join ' '
    if ($version -notmatch ('clang-format version {0}([^0-9.]|$)' -f [regex]::Escape($ExpectedVersion))) {
      throw "$clangFormatSource reports '$version', not clang-format $ExpectedVersion"
    }
  }

  $cppFiles = @(Get-ProjectCppFiles -WorkspacePath $WorkspacePath)
  if ($cppFiles.Count -eq 0) {
    Write-BuildLog -Context $Context -Message 'No C/C++ files found for the clang-format check.'
    return
  }

  $deviating = New-Object System.Collections.Generic.List[string]

  # Via cmd.exe: the expected non-zero exit and stderr would otherwise throw under Stop in PS 7.3+ and 5.1.
  foreach ($cppFile in $cppFiles) {
    $quoted = '"{0}" --dry-run -Werror "{1}" >nul 2>nul' -f $clangFormatSource, $cppFile
    & cmd.exe /c $quoted
    if ($LASTEXITCODE -ne 0) { $deviating.Add($cppFile) }
  }

  Write-BuildLog -Context $Context -Message ("clang-format: {0} of {1} files deviate from .clang-format." -f $deviating.Count, $cppFiles.Count)
  if ($deviating.Count -gt 0) {
    foreach ($f in ($deviating | Select-Object -First 20)) {
      Write-BuildLog -Context $Context -Message ("  deviates: {0}" -f $f)
    }
    if ($deviating.Count -gt 20) {
      Write-BuildLog -Context $Context -Message ("  ... and {0} more" -f ($deviating.Count - 20))
    }
    if ($FailOnDeviation) { throw "$($deviating.Count) of $($cppFiles.Count) file(s) deviate from .clang-format" }
    Write-BuildLog -Context $Context -Message 'Report-only; -FailOnDeviation makes this a gate.'
  }
}

# Not `dart format .`: it walks .git/modules, where a deep submodule gitdir overruns MAX_PATH.
function Get-ProjectDartFiles {
  param(
    [Parameter(Mandatory)]
    [string]$WorkspacePath
  )

  $gitCommand = Get-Command 'git' -ErrorAction SilentlyContinue
  if (-not $gitCommand) { return @() }

  $tracked = & $gitCommand.Source -C $WorkspacePath ls-files -- '*.dart' 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $tracked) { return @() }

  return @($tracked |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { Join-Path $WorkspacePath $_ } |
    Where-Object {
      ($_.ToString() -notmatch '\\build([\\-]|\\)') -and
      ($_.ToString() -notmatch '\\(ExternalLib|third_party)\\') -and
      ($_.ToString() -notmatch '\\.git\\modules\\') -and
      ($_.ToString() -notmatch '\\flutter\\') -and
      ($_.ToString() -notmatch '\\rust_builder\\')
    })
}

Export-ModuleMember -Function Get-ProjectCmakeFiles, Get-ProjectCppFiles, Get-ProjectDartFiles, Initialize-UvVenvPython, Invoke-CmakeFormatStep, Invoke-ClangFormatStep, Invoke-ClangFormatCheck
