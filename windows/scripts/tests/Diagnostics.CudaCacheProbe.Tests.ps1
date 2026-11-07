#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# The CUDA cache probe's payload is static here; whether nvcc and sccache hit is proven only by Test-CudaCache.ps1 against a live image.

Describe 'CUDA cache probe payload' {
    $script:probe = 'windows/scripts/diagnostics/verify-cuda-cache/Test-Cache.ps1'

    It 'keeps the nonce in code, where preprocessing cannot strip it from the cache key (mutation)' {
        $write = @(Get-TestScriptCommands -ScriptPath $script:probe -Name 'Set-Content' | Where-Object { $_.Extent.Text -match 'cachetest\.cu' })
        Assert-Equal 1 $write.Count 'one .cu payload'
        $value = $write[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ParenExpressionAst] } | Select-Object -First 1
        $nonce = 'f00dfeedf00dfeedf00dfeedf00dfeed'
        $source = & ([scriptblock]::Create('param($nonce) ' + $value.Extent.Text)) $nonce
        $code = [regex]::Replace([regex]::Replace($source, '(?s)/\*.*?\*/', ''), '//[^\n]*', '')
        Assert-Match $nonce $code 'the nonce survives comment stripping'
    }

    It 'requires a miss before the hit, so a warm cache cannot pass without a write (mutation)' {
        $text = [IO.File]::ReadAllText((Join-Path (Get-RepoRoot) $script:probe))
        Assert-Match "if \(\`$misses -lt 1\) \{ throw" $text 'a probe without a miss fails'
        Assert-Match "if \(\`$hits -lt 1\) \{ throw" $text 'a probe without a hit fails'
    }
}
