#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT

Describe 'WindowsAppRunner.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsAppRunner.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('apprunner-' + (Get-Random))) -Force).FullName
    $script:workDir = (New-Item -ItemType Directory -Path (Join-Path $script:root 'work') -Force).FullName
    $script:buildRoot = (New-Item -ItemType Directory -Path (Join-Path $script:root 'build') -Force).FullName

    # A .cmd stands in for the built application: it is executable everywhere
    # Windows PowerShell runs, prints its working directory and returns a
    # non-zero exit code so both can be asserted.
    $script:appName = 'apprunner-probe.cmd'
    $binReleaseDir = (New-Item -ItemType Directory -Path (Join-Path $script:buildRoot 'bin\Release') -Force).FullName
    Set-Content -Path (Join-Path $binReleaseDir $script:appName) `
      -Value @('@echo off', 'echo CWD=%CD%', 'echo HOOK=%APPRUNNER_TEST_HOOK%', 'exit /b 3') -Encoding ascii
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\APPRUNNER_TEST_HOOK -ErrorAction SilentlyContinue
  }

  Context 'Resolve-AppExecutablePath' {
    It 'finds the executable in a per-configuration bin subdirectory' {
      $resolved = Resolve-AppExecutablePath -BuildRoot $script:buildRoot -ExecutableName $script:appName -Configurations @('Release')
      $resolved | Should -Be (Join-Path $script:buildRoot ('bin\Release\' + $script:appName))
    }

    It 'falls back to a recursive search when no candidate path matches' {
      $resolved = Resolve-AppExecutablePath -BuildRoot $script:buildRoot -ExecutableName $script:appName -Configurations @('Debug')
      $resolved | Should -Be (Join-Path $script:buildRoot ('bin\Release\' + $script:appName))
    }

    It 'returns null when the executable does not exist' {
      $resolved = Resolve-AppExecutablePath -BuildRoot $script:buildRoot -ExecutableName 'not-there.exe' -Configurations @('Release')
      ($null -eq $resolved) | Should -Be $true
    }
  }

  Context 'Invoke-AppRun' {
    It 'throws with the caller hint when the executable is missing' {
      $message = ''
      try {
        Invoke-AppRun -BuildRoot $script:buildRoot -ExecutableName 'not-there.exe' -NotFoundHint 'Build it first.'
      } catch {
        $message = $_.Exception.Message
      }

      $message | Should -Match "not-there.exe"
      $message | Should -Match "Build it first."
    }

    It 'runs the executable in the working directory, applies the env hook and reports the exit code' {
      Push-Location $script:root
      try {
        $output = Invoke-AppRun -BuildRoot $script:buildRoot `
          -ExecutableName $script:appName `
          -Configurations @('Release') `
          -WorkingDirectory $script:workDir `
          -EnvHook { $env:APPRUNNER_TEST_HOOK = 'hooked' } 3>$null
        $exitCode = $LASTEXITCODE
      } finally {
        Pop-Location
      }

      $joined = ($output -join "`n")
      $joined | Should -Match ([regex]::Escape("CWD=$script:workDir"))
      $joined | Should -Match 'HOOK=hooked'
      $exitCode | Should -Be 3
    }
  }
}
