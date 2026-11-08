#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
# These receipts bind CI inputs and bytes; trusted CI and a real ARM64 device remain required.

Set-StrictMode -Version Latest

function Resolve-Arm64AcceptanceImage {
    param([AllowEmptyString()][string]$Digest, [Parameter(Mandatory)][string]$DefaultImage)
    if (-not $Digest) { return $DefaultImage }
    if ($Digest -cnotmatch '\Asha256:[0-9a-f]{64}\z') { throw 'candidate digest must be a lowercase SHA256 image digest' }
    return $DefaultImage.Substring(0, $DefaultImage.LastIndexOf(':')) + '@' + $Digest
}

function Write-Arm64ImageReceipt {
    param([string]$ZipPath, [string]$OutputPath, [string]$Image, [object]$Metadata,
        [string]$HubCommit, [string]$RunId, [string]$RunAttempt)
    if ($Metadata.Os -cne 'windows' -or $Metadata.Architecture -cne 'amd64') { throw 'ARM64 bundles must come from a windows/amd64 container image' }
    if ($Metadata.Id -cnotmatch '\Asha256:[0-9a-f]{64}\z') { throw 'image has no valid config digest' }
    $repository = ($Image -split '[@:]')[0]
    $digests = @($Metadata.RepoDigests | Where-Object { $_ -cmatch ('\A' + [regex]::Escape($repository) + '@sha256:[0-9a-f]{64}\z') })
    if ($digests.Count -ne 1) { throw 'expected exactly one immutable image reference for the pulled repository' }
    if ($Image.Contains('@') -and $Image -cne $digests[0]) { throw 'pulled image digest differs from the requested candidate' }
    $revision = $Metadata.Config.Labels.'org.opencontainers.image.revision'
    if ($revision -cnotmatch '\A[0-9a-f]{7,40}\z') { throw 'image has no valid source revision label' }
    $receipt = [ordered]@{ SchemaVersion = 1; RequestedImage = $Image; Image = $digests[0]; ImageConfig = $Metadata.Id
        ImageRevision = $revision; HubCommit = $HubCommit; RunId = $RunId; RunAttempt = $RunAttempt
        BundleSha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant() }
    $receipt | ConvertTo-Json | Set-Content -LiteralPath $OutputPath -Encoding utf8 -ErrorAction Stop
}

function Read-Arm64AcceptanceBundle {
    param([string]$ZipPath, [string]$ReceiptPath, [string]$Image, [string]$HubCommit, [string]$RunId, [string]$RunAttempt)
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($receipt.SchemaVersion -ne 1 -or $receipt.HubCommit -cne $HubCommit -or $receipt.RunId -cne $RunId -or $receipt.RunAttempt -cne $RunAttempt) {
        throw 'bundle receipt belongs to another CI source, run or attempt'
    }
    if ($receipt.RequestedImage -cne $Image -or ($Image.Contains('@') -and $receipt.Image -cne $Image)) { throw 'bundle receipt names another image' }
    $hash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($receipt.BundleSha256 -cne $hash) { throw 'bundle ZIP differs from its export receipt' }
    return $receipt
}

function Invoke-Arm64AcceptanceGate {
    param([Parameter(Mandatory)][hashtable]$Receipt, [string]$OutputPath,
        [Parameter(Mandatory)][ValidateSet('ARM64')][string]$Architecture, [Parameter(Mandatory)][scriptblock]$Gate)
    $code = 1
    try {
        $global:LASTEXITCODE = 0
        & $Gate
        $code = $LASTEXITCODE
        if ($code -ne 0) { throw "the ARM64 bundle gate exited $code" }
    } catch {
        if ($LASTEXITCODE -ne 0) { $code = $LASTEXITCODE }
        throw
    } finally {
        $result = [ordered]@{ Export = $Receipt; DeviceArchitecture = $Architecture; GateExitCode = $code
            Passed = ($code -eq 0); CompletedAtUtc = [datetime]::UtcNow.ToString('o') }
        $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8 -ErrorAction Stop
    }
}

Export-ModuleMember -Function Resolve-Arm64AcceptanceImage, Write-Arm64ImageReceipt, Read-Arm64AcceptanceBundle, Invoke-Arm64AcceptanceGate
