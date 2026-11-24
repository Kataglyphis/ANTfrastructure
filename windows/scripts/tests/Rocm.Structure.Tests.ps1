#requires -Version 7.0
# Structural module/pin checks do not prove native DLL loading or GPU inference.
Import-Module (Join-Path $PSScriptRoot 'WindowsHarness.DockerFixtures.psm1') -DisableNameChecking

Describe 'ROCm Dockerfile stage scopes' {
    It 'keeps source-view arguments separate from compiling-stage pin defaults' {
        Invoke-InTestDir { param($dir)
            $path = Join-Path $dir 'Dockerfile'
            Set-Content -LiteralPath $path -Value "FROM fixture AS migraphxmods`nARG VIEW_ONLY=1`nARG MIGRAPHX_VERSION=view-pin`nFROM fixture AS built`nARG MIGRAPHX_VERSION=built-pin"
            $pins = Get-TestDockerfileArgDefault -Path $path
            Assert-Equal 'MIGRAPHX_VERSION' ($pins.Keys -join ',') 'only compiling-stage defaults'
            Assert-Equal 'built-pin' $pins['MIGRAPHX_VERSION'] 'a source-view pin cannot shadow its consumer'
            Set-Content -LiteralPath $path -Value "FROM fixture AS migraphxmods`nARG MIGRAPHX_VERSION=view-pin`nFROM fixture AS built"
            Assert-Equal 0 (Get-TestDockerfileArgDefault -Path $path).Count 'a source-view pin cannot satisfy a missing compiling-stage pin'
            Set-Content -LiteralPath $path -Value 'FROM fixture AS migraphxmods'
            Assert-Throws { Get-TestDockerfileArgDefault -Path $path } -MessagePattern 'built' 'a missing compiling stage fails before inspecting defaults'
        }
    }

    It 'keeps the real llama closure complete when arguments precede COPY' {
        $root = Get-RepoRoot
        Assert-TestDockerfileModuleClosure -Path (Join-Path $root 'windows/Dockerfile.rocm-llama') -Stage llamamods `
            -ScriptPath @('windows/scripts/build/Install-LlamaCpp.ps1', 'windows/scripts/build/rocm-checks/LlamaCpp.ps1', 'windows/scripts/build/Build-LlamaCppHipFromSource.ps1') `
            -Root $root -MinimumNeeded 4 -ExpectedMountCount 2
    }
}
