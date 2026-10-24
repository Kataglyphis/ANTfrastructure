#requires -Version 7.0
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The pin comes from tool-pins.env, the single source shared with linux/scripts/lib/wasm-opt.sh.

Describe 'WindowsWasmOpt.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsWasmOpt.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = New-TestDir -Prefix 'wasmopt-'
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
    Remove-TestDir -Path $script:root
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

    It 'reads the repository tool-pins.env by default (single source of truth)' {
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

  Context 'Install-WasmOpt' {
    It 'reuses the pinned cache without downloading and publishes its bin directory' {
      $cache = New-TestDir -Prefix 'wasmopt-cache-'
      $savedPath = $env:PATH
      try {
        $bin = Join-Path $cache 'binaryen-version_999/bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        $exe = Join-Path $bin 'wasm-opt.exe'
        Set-Content -LiteralPath $exe -Value 'cached binary'
        Mock -ModuleName WindowsWasmOpt.Common -CommandName Invoke-DownloadWithRetry { throw 'download must not run' }

        Install-WasmOpt -VersionsEnvPath $script:fixtureEnv -CacheRoot $cache -Force | Should -Be $exe
        $env:PATH.Split([IO.Path]::PathSeparator)[0] | Should -Be $bin
        Should -Invoke Invoke-DownloadWithRetry -ModuleName WindowsWasmOpt.Common -Times 0
      } finally {
        $env:PATH = $savedPath
        Remove-TestDir -Path $cache
      }
    }

    It 'deletes a corrupt downloaded archive and propagates its checksum failure' {
      $cache = New-TestDir -Prefix 'wasmopt-checksum-'
      try {
        Mock -ModuleName WindowsWasmOpt.Common -CommandName Invoke-DownloadWithRetry {
          param($Url, $DestinationPath)
          Set-Content -LiteralPath $DestinationPath -Value 'bad archive'
        }
        Mock -ModuleName WindowsWasmOpt.Common -CommandName Assert-FileSha256 { throw 'checksum sentinel' }
        Assert-Throws -MessagePattern 'checksum sentinel' -Body {
          Install-WasmOpt -VersionsEnvPath $script:fixtureEnv -CacheRoot $cache -Force
        }
        Test-Path (Join-Path $cache 'binaryen-version_999-x86_64-windows.tar.gz') | Should -BeFalse
      } finally {
        Remove-TestDir -Path $cache
      }
    }
  }

  Context 'Invoke-WasmOpt' {
    BeforeAll {
      function Invoke-WasmOptFixture {
        param([int[]]$ExitCodes, [scriptblock]$Body)
        $state = New-TestCallState @{ Code = 0; ExitCodes = $ExitCodes }
        Invoke-WithTestNativeCommand -Name wasm-opt -FixtureState $state -Implementation {
          param($state, $argumentList)
          $state.Code = $state.ExitCodes[$state.Calls.Count - 1]
        } -Body $Body
      }
    }

    It 'passes a path with spaces as one argument and stops after success' {
      Invoke-WasmOptFixture -ExitCodes @(0) -Body { param($state)
        Invoke-WasmOpt -InputPath 'input dir/in.wasm' -OutputPath 'output dir/out.wasm'
        $state.Calls.Count | Should -Be 1
        $state.Calls[0][-3] | Should -Be 'input dir/in.wasm'
        $state.Calls[0][-1] | Should -Be 'output dir/out.wasm'
        $state.Calls[0] | Should -Contain '--enable-simd'
      }
    }

    It 'retries with all features after a failed first attempt' {
      Invoke-WasmOptFixture -ExitCodes @(5, 0) -Body { param($state)
        { Invoke-WasmOpt -InputPath 'in.wasm' -OutputPath 'out.wasm' } | Should -Not -Throw
        $state.Calls.Count | Should -Be 2
        $state.Calls[1] | Should -Contain '--all-features'
        $state.Calls[1] | Should -Not -Contain '--enable-simd'
      }
    }

    It 'propagates a failed retry' {
      Invoke-WasmOptFixture -ExitCodes @(5, 7) -Body { param($state)
        Assert-Throws -MessagePattern 'wasm-opt failed \(exit code 7\)' -Body {
          Invoke-WasmOpt -InputPath 'in.wasm' -OutputPath 'out.wasm'
        }
        $state.Calls.Count | Should -Be 2
      }
    }
  }
}
