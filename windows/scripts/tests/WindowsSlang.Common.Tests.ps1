# Copyright (c) 2025 Kataglyphis. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Covers the pure parts of WindowsSlang.Common: the WGSL varying-location
# validator that stops a broken combined emit from being copied, the
# minSlangcVersionForWgsl floor comparison, the -I expansion and slangc
# resolution. Compiling shaders needs a real slangc and is not exercised here.
#
# The bash twin (linux/scripts/lib/slang-compile.sh) implements the same rules;
# when one side changes, change both.

Describe 'WindowsSlang.Common' {
  BeforeAll {
    $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\WindowsSlang.Common.psm1'
    Import-Module $modulePath -Force

    $script:root = (New-Item -ItemType Directory -Path (Join-Path $env:TEMP ('slang-' + (Get-Random))) -Force).FullName

    # An IO struct (it has @builtin/@location members) with one member carrying
    # neither - exactly what slangc < 2026.8 emitted in combined mode.
    $script:badWgsl = Join-Path $script:root 'bad.wgsl'
    Set-Content -Path $script:badWgsl -Encoding utf8 -Value @(
      'struct VertexOut'
      '{'
      '    @builtin(position) pos : vec4<f32>,'
      '    uv_0 : vec2<f32>,'
      '    @location(1) normal_0 : vec3<f32>,'
      '};'
      ''
      'struct PlainData'
      '{'
      '    a : f32,'
      '    b : f32,'
      '};'
    )

    $script:goodWgsl = Join-Path $script:root 'good.wgsl'
    Set-Content -Path $script:goodWgsl -Encoding utf8 -Value @(
      'struct VertexOut'
      '{'
      '    @builtin(position) pos : vec4<f32>,'
      '    @location(0) uv_0 : vec2<f32>,'
      '};'
    )
  }

  AfterAll {
    Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
  }

  Context 'Test-WgslVaryingsAreLocated' {
    It 'names the file line of a varying member without @builtin/@location' {
      $offenders = Test-WgslVaryingsAreLocated -Path $script:badWgsl
      $offenders.Count | Should -Be 1
      $offenders[0] | Should -Match '^4: struct VertexOut: uv_0'
    }

    It 'accepts a struct whose every member is attributed' {
      (Test-WgslVaryingsAreLocated -Path $script:goodWgsl).Count | Should -Be 0
    }

    It 'ignores plain data structs (no @builtin/@location member at all)' {
      $plain = Join-Path $script:root 'plain.wgsl'
      Set-Content -Path $plain -Encoding utf8 -Value @('struct Params', '{', '    a : f32,', '    b : vec4<f32>,', '};')
      (Test-WgslVaryingsAreLocated -Path $plain).Count | Should -Be 0
    }
  }

  Context 'Test-SlangcVersionAtLeast' {
    It 'rejects the slangc whose combined WGSL emit drops @location' {
      Test-SlangcVersionAtLeast -Have '2026.1-52-gc8ddf20bb' -Want '2026.8' | Should -Be $false
    }

    It 'accepts the floor itself and anything newer' {
      Test-SlangcVersionAtLeast -Have '2026.8' -Want '2026.8' | Should -Be $true
      Test-SlangcVersionAtLeast -Have '2026.9' -Want '2026.8' | Should -Be $true
      Test-SlangcVersionAtLeast -Have '2027.0' -Want '2026.8' | Should -Be $true
    }

    It 'treats an unparseable version as new enough (the emit guard is the backstop)' {
      Test-SlangcVersionAtLeast -Have 'some-dev-build' -Want '2026.8' | Should -Be $true
      Test-SlangcVersionAtLeast -Have '2026.8' -Want '' | Should -Be $true
    }
  }

  Context 'Get-SlangIncludeArgument' {
    It 'passes the source root, the shader directory and every subdirectory to -I' {
      $tree = Join-Path $script:root 'tree'
      New-Item -ItemType Directory -Force -Path (Join-Path $tree 'common') | Out-Null
      New-Item -ItemType Directory -Force -Path (Join-Path $tree 'forward') | Out-Null

      $argv = Get-SlangIncludeArgument -SourceRoot $tree -SourceDirectory (Join-Path $tree 'forward')
      @($argv | Where-Object { $_ -eq '-I' }).Count | Should -Be 4
      ($argv -contains $tree) | Should -Be $true
      ($argv -contains (Join-Path $tree 'common')) | Should -Be $true
      ($argv -contains (Join-Path $tree 'forward')) | Should -Be $true
    }
  }

  Context 'Resolve-Slangc' {
    It 'prefers VULKAN_SDK\Bin\slangc.exe over PATH' {
      $sdk = Join-Path $script:root 'sdk'
      New-Item -ItemType Directory -Force -Path (Join-Path $sdk 'Bin') | Out-Null
      Set-Content -Path (Join-Path $sdk 'Bin\slangc.exe') -Value 'not a real binary'

      $saved = $env:VULKAN_SDK
      try {
        $env:VULKAN_SDK = $sdk
        Resolve-Slangc | Should -Be (Join-Path $sdk 'Bin\slangc.exe')
      } finally {
        $env:VULKAN_SDK = $saved
      }
    }
  }
}
