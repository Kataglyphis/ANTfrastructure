#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# Covers the pure parts of WindowsWasmOpt.Common: pin resolution out of
# versions.env (the single source shared with linux/scripts/lib/wasm-opt.sh) and
# the wasm-opt argument construction. The download itself is not exercised here.

Describe 'WindowsWasmOpt.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsWasmOpt.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('wasmopt-' + (Get-Random))) -Force).FullName
    $script:fixtureEnv = Join-Path $script:root 'versions.env'
    Set-Content -Path $script:fixtureEnv -Value @(
      '# noforward'
      'BINARYEN_VERSION=version_999'
      '# noforward'
      'BINARYEN_LINUX_X86_64_SHA256=aaaa1111'
      '# noforward'
      'BINARYEN_WINDOWS_X86_64_SHA256=BBBB2222'
    )
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Get-BinaryenPin' {
    It 'resolves version, asset, checksum and URL for windows/x86_64' {
      $pin = Get-BinaryenPin -VersionsEnvPath $script:fixtureEnv -Platform 'windows' -Architecture 'x86_64'
      $pin.Version | Should -Be 'version_999'
      $pin.Asset | Should -Be 'binaryen-version_999-x86_64-windows.tar.gz'
      $pin.Sha256 | Should -Be 'bbbb2222'
      $pin.Url | Should -Be 'https://github.com/WebAssembly/binaryen/releases/download/version_999/binaryen-version_999-x86_64-windows.tar.gz'
    }

    It 'picks the per-platform checksum for linux' {
      (Get-BinaryenPin -VersionsEnvPath $script:fixtureEnv -Platform 'linux').Sha256 | Should -Be 'aaaa1111'
    }

    It 'throws when the platform/architecture has no pinned checksum' {
      $threw = $false
      try { Get-BinaryenPin -VersionsEnvPath $script:fixtureEnv -Platform 'windows' -Architecture 'aarch64' } catch { $threw = $true }
      $threw | Should -Be $true
    }

    It 'reads the repository versions.env by default (single source of truth)' {
      $pin = Get-BinaryenPin -Platform 'linux'
      $pin.Version | Should -Match '^version_\d+$'
      $pin.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }

    It 'keeps the linux and windows pins on the same binaryen version' {
      $linux = Get-BinaryenPin -Platform 'linux'
      $windows = Get-BinaryenPin -Platform 'windows'
      $windows.Version | Should -Be $linux.Version
      ($windows.Sha256 -eq $linux.Sha256) | Should -Be $false
    }
  }

  Context 'Get-WasmOptArgument' {
    It 'puts the optimisation level first and the -o output last' {
      $argv = Get-WasmOptArgument -InputPath 'in.wasm' -OutputPath 'out.wasm'
      $argv[0] | Should -Be '-Oz'
      $argv[-3] | Should -Be 'in.wasm'
      $argv[-2] | Should -Be '-o'
      $argv[-1] | Should -Be 'out.wasm'
    }

    It 'includes every wasm feature flag wgpu/naga codegen needs' {
      $argv = Get-WasmOptArgument -InputPath 'in.wasm' -OutputPath 'out.wasm'
      foreach ($flag in @('--enable-bulk-memory-opt', '--enable-nontrapping-float-to-int', '--enable-simd',
                          '--enable-sign-ext', '--enable-reference-types', '--enable-mutable-globals',
                          '--enable-multivalue')) {
        ($argv -contains $flag) | Should -Be $true
      }
    }

    It 'collapses to --all-features on the retry path' {
      $argv = Get-WasmOptArgument -InputPath 'in.wasm' -OutputPath 'out.wasm' -AllFeatures
      ($argv -contains '--all-features') | Should -Be $true
      ($argv -contains '--enable-simd') | Should -Be $false
      $argv.Count | Should -Be 5
    }

    It 'honours a custom optimisation level' {
      (Get-WasmOptArgument -InputPath 'in.wasm' -OutputPath 'out.wasm' -OptimizationLevel '-O3')[0] | Should -Be '-O3'
    }
  }
}
