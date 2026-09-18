Set-StrictMode -Version Latest
#requires -Version 7.0


# The uv venv lifecycle (health-check, recreate, requirements install) lives in
# WindowsUv.Common - single source of truth instead of a per-module variant.
# No -Force when already loaded: a nested force-reimport moves the module's
# exports out of the global session state on Windows PowerShell 5.1.
if (-not (Get-Module -Name 'WindowsUv.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsUv.Common.psm1')
}

if (-not (Get-Module -Name 'WindowsBuild.Common')) {
  Import-Module (Join-Path $PSScriptRoot 'WindowsBuild.Common.psm1')
}

$script:CppExtensions = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.ixx')

# One enumeration policy for tracked sources: git ls-files fast path, else a
# Get-ChildItem fallback. Private; the public wrappers pass pathspec + predicate.
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
            # -notmatch, not -match. This read `-match '\\_deps\\'` until
            # 2026-07-20, which inverted the intent: it kept ONLY files under a
            # CMake _deps/ directory and dropped every project source. _deps is
            # untracked, so `git ls-files` returned nothing and the whole
            # clang-format step silently formatted zero files - which is why
            # the formatting drift never shrank no matter how often the step
            # ran.
            ($_.ToString() -notmatch '\\_deps\\') -and
            ($_.ToString() -notmatch '\\vcpkg_installed\\')
          })
        return @($trackedPaths | Sort-Object -Unique)
      }
    } catch {
      # Best-effort: fall through to the filesystem enumeration below.
      Write-Verbose "git ls-files enumeration failed: $($_.Exception.Message)"
    }
  }

  # This fallback is NOT rare: the container receives sources by tar-pipe, so
  # there is no .git directory, `git ls-files` fails, and everything below is
  # what actually selects files during a containerized build. It must exclude
  # at least as much as the git path above - Python virtualenvs vendor C
  # headers (lxml, numpy) that are emphatically not our sources.
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
    # Extra regexes a project excludes on top of the built-in build/_deps/vendor
    # set. A consumer whose tree has its own generated CMake (a packaging
    # staging dir, a patch shim) had to re-implement the whole enumeration to
    # drop it; now it passes a pattern.
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

# Thin adapter kept for caller compatibility: the venv health-check/recreate
# and requirements install now live in WindowsUv.Common (Initialize-UvVenv +
# Install-UvRequirements). Same name, same signature, same return value (the
# venv's python.exe path).
function Initialize-UvVenvPython {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [string]$PythonVersion = '3.12',
    [string]$EnvName = '.venv',
    # The requirements file to install into the venv. Default (empty) keeps
    # today's behaviour: <workspace>/requirements.txt, skipped when absent. A
    # caller that only needs cmake-format points this at the hub's pinned
    # linux/scripts/cmake-format.requirements.txt instead of installing a
    # project's whole dependency set to get one formatter.
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
    # Report instead of rewriting. A gate judges the tree as COMMITTED: with
    # --in-place the step can only ever pass and the change turns up in someone
    # else's `git status`. The Linux twin has said so since it was corrected.
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
  Invoke-ClangFormatStep runs `clang-format -i`, which rewrites in place. That
  makes it unusable as a routine check here: 72 of 125 own sources under Src/
  and Test/ currently deviate (measured 2026-07-19), so running it would
  produce one enormous reformatting commit as a side effect of asking a
  question. Whether to take that sweep is a deliberate decision - it collides
  with everything in flight and wants a .git-blame-ignore-revs entry.

  This uses `--dry-run -Werror`, which changes nothing and exits non-zero per
  deviating file, so drift can be tracked over time. It deliberately does NOT
  fail the build: with a known 72-file backlog a failing gate would be
  switched off within a day. Make it fail only once the count is near zero.
#>
function Invoke-ClangFormatCheck {
  param(
    [Parameter(Mandatory)]$Context,
    [Parameter(Mandatory)][string]$WorkspacePath
  )

  $clangFormat = Get-Command 'clang-format' -ErrorAction SilentlyContinue
  if (-not $clangFormat) {
    $candidates = @(
      'C:\Program Files\LLVM\bin\clang-format.exe',
      'C:\Program Files (x86)\LLVM\bin\clang-format.exe'
    )
    $clangFormatSource = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $clangFormatSource) {
      Write-BuildLog -Context $Context -Message 'clang-format not found; skipping format check.'
      return
    }
  } else {
    $clangFormatSource = $clangFormat.Source
  }

  $cppFiles = @(Get-ProjectCppFiles -WorkspacePath $WorkspacePath)
  if ($cppFiles.Count -eq 0) {
    Write-BuildLog -Context $Context -Message 'No C/C++ files found for the clang-format check.'
    return
  }

  $deviating = New-Object System.Collections.Generic.List[string]

  # clang-format --dry-run -Werror exits non-zero for every deviating file -
  # that IS the signal here, not an error. PowerShell 7.3+ defaults
  # $PSNativeCommandUseErrorActionPreference to true, so under the build's
  # $ErrorActionPreference = 'Stop' each deviating file would throw and abort
  # the step on the first hit.
  # Every deviating file makes clang-format exit non-zero AND write to stderr,
  # and here both are the expected signal rather than a failure. Getting that
  # past PowerShell took two tries: PowerShell 7.3+ turns a non-zero native
  # exit into a throw under $ErrorActionPreference='Stop', and Windows
  # PowerShell 5.1 (which the build container runs) turns redirected native
  # stderr into a terminating ErrorRecord. Dispatching through cmd.exe sidesteps
  # both - cmd swallows the output and only the exit code comes back.
  foreach ($cppFile in $cppFiles) {
    $quoted = '"{0}" --dry-run -Werror "{1}" >nul 2>nul' -f $clangFormatSource, $cppFile
    & cmd.exe /c $quoted
    if ($LASTEXITCODE -ne 0) { $deviating.Add($cppFile) }
  }

  Write-BuildLog -Context $Context -Message ("clang-format: {0} of {1} files deviate from .clang-format." -f $deviating.Count, $cppFiles.Count)
  if ($deviating.Count -gt 0) {
    Write-BuildLog -Context $Context -Message 'Not a build failure by design - see BACKLOG.md "Decide on the formatting sweep".'
    foreach ($f in ($deviating | Select-Object -First 20)) {
      Write-BuildLog -Context $Context -Message ("  deviates: {0}" -f $f)
    }
    if ($deviating.Count -gt 20) {
      Write-BuildLog -Context $Context -Message ("  ... and {0} more" -f ($deviating.Count - 20))
    }
  }
}

# Tracked .dart files, vendored trees excluded. `dart format .` must not be used
# on Windows: it walks .git/modules, and a deep vendored submodule gitdir
# overruns MAX_PATH, so the listing throws and the gate dies before formatting
# anything. Docs: docs/windows-reference.md.
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
