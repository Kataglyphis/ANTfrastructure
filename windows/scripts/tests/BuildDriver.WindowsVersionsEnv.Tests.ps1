#requires -Version 7.0
# A Linux-only versions.env edit re-keyed the whole Windows chain (CON87); a key the chain reads must never be filtered out.

Describe 'Get-WindowsVersionsEnvLine' {

    It 'drops a Linux-only key unless windows\ names it or it says WINDOWS, and keeps everything else in order (mutation)' {
        Invoke-InTestDir { param($d)
            $env_ = Join-Path $d 'versions.env'
            Set-Content -LiteralPath $env_ -Value @(
                '# a comment the bake does not need',
                'CMAKE_VERSION=4.4.4',
                '# noforward',
                'CMAKE_VERSION_RISCV64=4.4.4',
                'ANDROID_SDK_VERSION=37',
                'NODE_VERSION=24.1.0',
                'TORCH_WINDOWS_ARM64_TORCH_URL=https://example.invalid/t.whl',
                'CMAKE_POLICY_VERSION_MINIMUM=3.5')
            $script_ = Join-Path $d 'Build-Thing.ps1'
            Set-Content -LiteralPath $script_ -Value '$v = $env:NODE_VERSION'
            $lines = @(Get-WindowsVersionsEnvLine -VersionsEnv $env_ -Corpus @($script_))
            Assert-Equal 'CMAKE_VERSION=4.4.4|NODE_VERSION=24.1.0|TORCH_WINDOWS_ARM64_TORCH_URL=https://example.invalid/t.whl|CMAKE_POLICY_VERSION_MINIMUM=3.5' ($lines -join '|')
        }
    }

    It 'matches a key as a whole name, not inside a longer one' {
        Invoke-InTestDir { param($d)
            $env_ = Join-Path $d 'versions.env'
            Set-Content -LiteralPath $env_ -Value 'NODE_VERSION=24.1.0'
            $script_ = Join-Path $d 'Build-Thing.ps1'
            Set-Content -LiteralPath $script_ -Value '$v = $env:NODE_VERSION_RISCV64'
            Assert-Equal 0 @(Get-WindowsVersionsEnvLine -VersionsEnv $env_ -Corpus @($script_)).Count 'NODE_VERSION_RISCV64 is not NODE_VERSION'
        }
    }
}

Describe 'The Windows chain bakes the filtered versions.env (CON87)' {

    $script:repo = Get-RepoRoot
    $script:all = ConvertFrom-VersionsEnv -Path (Join-Path $script:repo 'linux\scripts\01-core\versions.env')
    $lines = @(Get-WindowsVersionsEnvLine -VersionsEnv (Join-Path $script:repo 'linux\scripts\01-core\versions.env') -Corpus (Get-WindowsVersionsEnvCorpus -RepoRoot $script:repo))
    $script:kept = [System.Collections.Generic.HashSet[string]]::new([string[]]@($lines | ForEach-Object { ($_ -split '=', 2)[0] }))

    It 'leaves out the riscv64-only key whose edit rebuilt the 2026-10-09 :winamd64-rocm' {
        foreach ($k in 'CMAKE_VERSION_RISCV64', 'NODE_VERSION_RISCV64') {
            Assert-True $script:all.Contains($k) "$k left versions.env: pick another Linux-only witness"
            Assert-False $script:kept.Contains($k) "$k would still re-key the Windows chain"
        }
    }

    It 'keeps every key the media and merge stages are forwarded, and every ARG a Windows Dockerfile declares' {
        $need = [System.Collections.Generic.List[string]]::new()
        foreach ($b in 'media-core', 'media-litert', 'media-tvm') { $need.AddRange([string[]]@((Get-MediaBranchVersionArg -Branch $b -VersionTable $script:all).Keys)) }
        $need.AddRange([string[]]@((Get-MediaMergeVersionArg -VersionTable $script:all).Keys))
        foreach ($df in Get-ChildItem -LiteralPath (Join-Path $script:repo 'windows') -File -Filter 'Dockerfile*') {
            foreach ($m in [regex]::Matches((Get-Content -Raw -LiteralPath $df.FullName), '(?m)^ARG\s+([A-Z][A-Z0-9_]*)')) { $need.Add($m.Groups[1].Value) }
        }
        $missing = foreach ($k in [System.Collections.Generic.SortedSet[string]]::new([string[]]$need)) { if ($script:all.Contains($k) -and -not $script:kept.Contains($k)) { $k } }
        Assert-Equal 0 @($missing).Count "filtered out, yet the Windows chain reads them: $(@($missing) -join ', ')"
    }

    It 'every Windows Dockerfile reads the generated file, and none the Linux one (mutation)' {
        $offenders = @()
        foreach ($df in Get-ChildItem -LiteralPath (Join-Path $script:repo 'windows') -File -Filter 'Dockerfile*') {
            # The diagnostic probe runs by hand, outside the chain.
            if ($df.Name -eq 'Dockerfile.probe') { continue }
            if ((Get-Content -Raw -LiteralPath $df.FullName) -match 'linux[\\/]scripts[\\/]01-core[\\/]versions\.env') { $offenders += $df.Name }
        }
        Assert-Equal 0 $offenders.Count "bakes or mounts the unfiltered versions.env: $($offenders -join ', ')"
        foreach ($name in 'Dockerfile.base', 'Dockerfile.toolchain-builder', 'Dockerfile.media-merge-builder') {
            Assert-Match 'windows[\\/]generated[\\/]versions\.env' (Get-Content -Raw -LiteralPath (Join-Path $script:repo "windows\$name")) "$name reads the filtered file"
        }
    }
}
