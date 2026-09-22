#requires -Version 7.0
# Build-Buildkit.ps1 -Variant: the resolver's refusals and the rocm chain's wiring (its own
# tags, the default media as its base, the smoke switch). NOT covered: a real solve.

Describe 'Resolve-BkVariant' {
    . (Get-ScriptFunctionDefinition -ScriptPath 'windows\Build-Buildkit.ps1' -FunctionName 'Resolve-BkVariant')
    $script:DefaultStages = @('base', 'sdk', 'toolchain', 'media', 'rocm', 'torch', 'final')
    function Invoke-Resolve {
        param([string]$Variant = '', [bool]$Gpu = $false, [string]$TargetArch = 'amd64',
              [string[]]$Stages = $script:DefaultStages, [bool]$StagesBound = $false, [string]$PushRef = '')
        return Resolve-BkVariant -Variant $Variant -Gpu $Gpu -TargetArch $TargetArch -Stages $Stages -StagesBound $StagesBound -PushRef $PushRef
    }

    It 'keeps the default lane default and drops the rocm stage from the inherited list' {
        $r = Invoke-Resolve
        Assert-Equal '' $r.Variant 'default variant'
        Assert-False ($r.Stages -contains 'rocm') 'rocm stage dropped'
        Assert-Equal 6 @($r.Stages).Count 'the other six stages stay'
    }

    It 'maps -Gpu and -Variant nvidia to the same nvidia lane' {
        Assert-Equal 'nvidia' (Invoke-Resolve -Gpu $true).Variant '-Gpu'
        Assert-Equal 'nvidia' (Invoke-Resolve -Variant 'nvidia').Variant '-Variant nvidia'
    }

    It 'keeps the rocm stage on the rocm lane' {
        Assert-True ((Invoke-Resolve -Variant 'rocm').Stages -contains 'rocm') 'rocm stage kept'
    }

    It 'refuses what a variant cannot build' {
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -Gpu $true } '-Gpu + rocm' -MessagePattern 'cannot be combined'
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -TargetArch 'arm64' } 'rocm on arm64' -MessagePattern 'amd64-only'
        Assert-Throws { Invoke-Resolve -Stages @('rocm') -StagesBound $true } 'explicit rocm stage, default lane' -MessagePattern 'needs -Variant rocm'
        Assert-Throws { Invoke-Resolve -Variant 'nvidia' -Stages @('rocm', 'final') -StagesBound $true } 'explicit rocm stage, nvidia lane' -MessagePattern 'needs -Variant rocm'
    }

    It 'lets a push go only to the tag of its own variant' {
        $repo = 'ghcr.io/kataglyphis/kataglyphis_beschleuniger'
        Invoke-Resolve -Variant 'rocm' -PushRef "${repo}:winamd64-rocm" | Out-Null
        Invoke-Resolve -PushRef "${repo}:winamd64" | Out-Null
        Invoke-Resolve -Variant 'rocm' -PushRef 'localhost:5000/k:winamd64-rocm' | Out-Null   # a registry port is not the tag
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -PushRef "${repo}:winamd64" } 'rocm bytes under the default tag' -MessagePattern 'winamd64-rocm'
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -PushRef "${repo}@sha256:0123" } 'rocm by digest' -MessagePattern 'winamd64-rocm'
        Assert-Throws { Invoke-Resolve -Variant 'rocm' -PushRef 'localhost:5000/k' } 'rocm with no tag' -MessagePattern 'winamd64-rocm'
        Assert-Throws { Invoke-Resolve -PushRef "${repo}:winamd64-rocm" } 'default bytes under the rocm tag' -MessagePattern 'not -Variant rocm'
        Assert-Throws { Invoke-Resolve -Gpu $true -PushRef "${repo}:winamd64-rocm" } 'nvidia bytes under the rocm tag' -MessagePattern 'not -Variant rocm'
    }
}

Describe 'Build-Buildkit.ps1: rocm chain wiring' {
    $src = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Build-Buildkit.ps1')

    It 'forks the rocm stage from the default media' {
        Assert-Match "Dockerfile\.rocm'.*-Tag \(Get-BkTag 'windows-rocm'\)" $src 'rocm stage tag'
        Assert-Match "BASE_IMAGE\s+= Get-BkTag 'windows-media'\s+ROCM_WINDOWS_RELEASE" $src 'rocm stage base = default media'
    }

    It 'gives the rocm lane its own torch and final tags, so it never overwrites the default images' {
        Assert-Match "\`$torchTag = if \(\`$Variant -eq 'rocm'\) \{ Get-BkTag 'windows-torch-rocm' \}" $src 'separate torch tag'
        Assert-Match "elseif \(\`$Variant -eq 'rocm'\) \{ 'winamd64-rocm' \}" $src 'separate final tag'
        Assert-Match "\`$finalBase = if \(\`$TargetArch -eq 'amd64'\) \{ \`$torchTag \}" $src 'final builds on the lane''s own torch'
    }

    It 'turns the ROCm smoke checks on for the rocm lane, and the smoke Dockerfile runs them' {
        Assert-Match "EXPECT_ROCM = \`$\(if \(\`$Variant -eq 'rocm'\)" $src 'driver passes EXPECT_ROCM'
        $gate = Get-Content -Raw (Join-Path (Get-RepoRoot) 'windows\Dockerfile.smoke-gate')
        Assert-Match '(?m)^ARG EXPECT_ROCM=0' $gate 'smoke Dockerfile declares EXPECT_ROCM'
        Assert-Match "EXPECT_ROCM -eq '1'.*Test-RocmImage\.ps1" ($gate -replace '\s+', ' ') 'and runs Test-RocmImage.ps1 on it'
    }
}
