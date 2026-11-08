#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# Synthetic image metadata and ZIP bytes prove binding/failure policy, not registry trust or device inference.

Import-Module (Join-Path (Get-RepoRoot) 'windows/scripts/modules/WindowsArm64Acceptance.Common.psm1') -Force

function New-Arm64AcceptanceFixture {
    param([string]$Root)
    $image = 'registry.example/team/bundle@sha256:' + ('a' * 64)
    $metadata = [pscustomobject]@{ Os = 'windows'; Architecture = 'amd64'; Id = 'sha256:' + ('b' * 64); RepoDigests = @($image)
        Config = @{ Labels = @{ 'org.opencontainers.image.revision' = 'cb2b8db6' } } }
    $zip = Join-Path $Root bundle.zip
    New-TestZipFile -Path $zip -Member @{ 'payload.txt' = 'unchanged target bytes' }
    $write = @{ ZipPath = $zip; OutputPath = (Join-Path $Root image.json); Image = $image; Metadata = $metadata
        HubCommit = 'c' * 40; RunId = '123'; RunAttempt = '2' }
    $read = @{ ZipPath = $zip; ReceiptPath = $write.OutputPath; Image = $image; HubCommit = $write.HubCommit; RunId = '123'; RunAttempt = '2' }
    return @{ Write = $write; Read = $read; Metadata = $metadata }
}

Describe 'ARM64 candidate image and receipt binding' {
    It 'uses the owned default unless an exact lowercase digest is supplied' {
        $default = 'registry.example/team/bundle:arm64'
        Assert-Equal $default (Resolve-Arm64AcceptanceImage -Digest '' -DefaultImage $default)
        Assert-Equal ('registry.example/team/bundle@sha256:' + ('a' * 64)) (Resolve-Arm64AcceptanceImage -Digest ('sha256:' + ('a' * 64)) -DefaultImage $default)
        foreach ($invalid in @('latest', 'sha256:123', ('sha256:' + ('A' * 64)), ('sha256:' + ('a' * 64) + "`n"), 'https://external.example/image')) {
            Assert-Throws { Resolve-Arm64AcceptanceImage -Digest $invalid -DefaultImage $default } -MessagePattern 'lowercase SHA256'
        }
    }

    It 'binds both the default tag and a candidate to the actual image, ZIP and CI attempt' {
        Invoke-InTestDir { param($dir)
            $fixture = New-Arm64AcceptanceFixture -Root $dir
            foreach ($requested in @($fixture.Write.Image, 'registry.example/team/bundle:arm64')) {
                $fixture.Write.Image = $requested
                $fixture.Read.Image = $requested
                $write = $fixture.Write
                Write-Arm64ImageReceipt @write
                $read = $fixture.Read
                $receipt = Read-Arm64AcceptanceBundle @read
                Assert-Equal $fixture.Metadata.RepoDigests[0] $receipt.Image
                Assert-Equal $fixture.Metadata.Id $receipt.ImageConfig
                Assert-Equal 'cb2b8db6' $receipt.ImageRevision
                Assert-Equal ((Get-FileHash -LiteralPath $fixture.Write.ZipPath).Hash.ToLowerInvariant()) $receipt.BundleSha256
            }
        }
    }

    It 'rejects foreign candidates, ambiguous digests and wrong platform metadata' {
        Invoke-InTestDir { param($dir)
            $fixture = New-Arm64AcceptanceFixture -Root $dir
            $request = $fixture.Write
            $request.Image = 'registry.example/team/bundle@sha256:' + ('d' * 64)
            Assert-Throws { Write-Arm64ImageReceipt @request } -MessagePattern 'differs from the requested'
            $request.Image = $fixture.Read.Image
            $fixture.Metadata.RepoDigests = @($request.Image, $request.Image)
            Assert-Throws { Write-Arm64ImageReceipt @request } -MessagePattern 'exactly one'
            $fixture.Metadata.RepoDigests = @($request.Image)
            $fixture.Metadata.Architecture = 'arm64'
            Assert-Throws { Write-Arm64ImageReceipt @request } -MessagePattern 'windows/amd64'
            $fixture.Metadata.Architecture = 'amd64'
            $fixture.Metadata.Id = ''
            Assert-Throws { Write-Arm64ImageReceipt @request } -MessagePattern 'config digest'
            $fixture.Metadata.Id = 'sha256:' + ('b' * 64)
            $fixture.Metadata.Config.Labels['org.opencontainers.image.revision'] = 'not-a-commit'
            Assert-Throws { Write-Arm64ImageReceipt @request } -MessagePattern 'source revision'
        }
    }

    It 'rejects changed ZIP bytes, image, source, run and attempt before invoking a gate' {
        Invoke-InTestDir { param($dir)
            $fixture = New-Arm64AcceptanceFixture -Root $dir
            $write = $fixture.Write
            Write-Arm64ImageReceipt @write
            foreach ($key in 'HubCommit', 'RunId', 'RunAttempt', 'Image') {
                $request = $fixture.Read.Clone()
                $request[$key] = 'another'
                Assert-Throws { Read-Arm64AcceptanceBundle @request } -MessagePattern 'another'
            }
            Add-Content -LiteralPath $write.ZipPath -Value 'changed'
            $request = $fixture.Read
            Assert-Throws { Read-Arm64AcceptanceBundle @request } -MessagePattern 'ZIP differs'
        }
    }
}

Describe 'ARM64 device receipt verdict' {
    It 'preserves the gate status and cannot turn an exception into a passed receipt' {
        Invoke-InTestDir { param($dir)
            $output = Join-Path $dir device.json
            $params = @{ Receipt = @{ Image = 'fixture' }; OutputPath = $output; Architecture = 'ARM64' }
            Invoke-Arm64AcceptanceGate @params -Gate { $global:LASTEXITCODE = 0 }
            Assert-True ((Get-Content -LiteralPath $output -Raw | ConvertFrom-Json).Passed)
            Assert-Throws { Invoke-Arm64AcceptanceGate @params -Gate { $global:LASTEXITCODE = 7 } } -MessagePattern 'exited 7'
            $result = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
            Assert-False $result.Passed
            Assert-Equal 7 $result.GateExitCode
            Assert-Throws { Invoke-Arm64AcceptanceGate @params -Gate { throw 'device crashed' } } -MessagePattern 'device crashed'
            Assert-False ((Get-Content -LiteralPath $output -Raw | ConvertFrom-Json).Passed)
            $params.Architecture = 'AMD64'
            Assert-Throws { Invoke-Arm64AcceptanceGate @params -Gate { throw 'must not execute' } } -MessagePattern 'ValidateSet|does not belong|not belong'
        }
    }
}
