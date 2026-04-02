Set-StrictMode -Version Latest

# Import shared helpers (Resolve-DirectoryPath, New-Timestamp, etc.)
$sharedPath = Join-Path $PSScriptRoot 'WindowsScripts.Shared.psm1'
Import-Module $sharedPath -Force

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

  # Call ninja via its resolved path to make mocking easier in tests
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

function Invoke-ClangTidyFixStep {
  param(
    [Parameter(Mandatory)]
    [pscustomobject]$Context,
    [Parameter(Mandatory)]
    [string]$WorkspacePath,
    [Parameter(Mandatory)]
    [string]$BuildRoot,
    [string[]]$Checks = @('--checks=-misc-include-cleaner'),
    [switch]$Fix
  )

  $clangTidyCommand = Get-Command 'clang-tidy' -ErrorAction SilentlyContinue
  if (-not $clangTidyCommand) {
    throw 'clang-tidy not found on PATH.'
  }

  $compileDb = Get-CompileCommandsDatabase -Context $Context -BuildRoot $BuildRoot

  $srcDir = Join-Path $WorkspacePath 'Src'
  $tidyFiles = @(Get-ChildItem -Path $srcDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.cpp', '.cc', '.cxx') } |
    Select-Object -ExpandProperty FullName)

  if ($tidyFiles.Count -eq 0) {
    Write-BuildLog -Context $Context -Message 'No C/C++ source files found under Src for clang-tidy.'
    return
  }

  $baseParams = @('-p', $BuildRoot) + $Checks
  if ($Fix) { $baseParams += '--fix' }

  foreach ($tidyFile in $tidyFiles) {
    Invoke-BuildExternal -Context $Context -File $clangTidyCommand.Source -Parameters @($baseParams + $tidyFile) | Out-Null
  }
}

# Approved-verb wrapper for the lint/analysis step so it is discoverable by Get-Command
function Invoke-StaticAnalysis {
  param(
    [Parameter(Mandatory)] [string]$BuildRoot
  )

  return Invoke-ClangTidyFixStep -BuildRoot $BuildRoot
}

Export-ModuleMember -Function @(
  'Get-CompileCommandsDatabase',
  'Invoke-ClangTidyFixStep',
  'Invoke-StaticAnalysis'
)
