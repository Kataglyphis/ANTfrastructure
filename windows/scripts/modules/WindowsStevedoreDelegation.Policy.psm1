#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis. SPDX-License-Identifier: MIT
Set-StrictMode -Version Latest

function Get-DelegatedRetirementPlan {
    param([Parameter(Mandatory)]$Snapshot)
    $containers = @($Snapshot.Containers | Where-Object {
        $_.Disposable -and -not $_.Running -and $_.Status -cin @('created', 'exited', 'stopped', 'dead')
    })
    $protectedContainers = @($Snapshot.Containers | Where-Object { $_.Id -cnotin @($containers | ForEach-Object Id) })
    $images = @(foreach ($image in $Snapshot.Images) {
        $pattern = '^(?:docker.io/)?local/kataglyphis:bk-windows-(?:media-core(?:-(?:onnx|ffmpeg|opencv|hailo))?|media-litert|media-tvm)(?:(?<lane>-(?:nvidia|rocm))|(?<arch>-arm64))?$'
        if ($image.Tag -cnotmatch $pattern) { continue }
        $merge = 'local/kataglyphis:bk-windows-media' + $Matches['lane'] + $Matches['arch']
        if (-not @($Snapshot.Images | Where-Object { ($_.Tag -creplace '^docker.io/', '') -ceq $merge }).Count) { continue }
        if ($image.Config -cin @($protectedContainers | ForEach-Object Image) -or $image.Manifest -cin @($protectedContainers | ForEach-Object Image)) { continue }
        $image
    })
    [pscustomobject]@{
        Images = $images
        Containers = $containers
        PreservedImages = @($Snapshot.Images | Where-Object { $_.Tag -cnotin @($images | ForEach-Object Tag) })
        PreservedContainers = $protectedContainers
        CacheMounts = @($Snapshot.CacheMounts)
    }
}

function Assert-DelegatedPreservation {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Snapshot)
    $before = @($Plan.PreservedImages | ForEach-Object { "$($_.Tag) $($_.Manifest) $($_.Config)" } | Sort-Object)
    $after = @($Snapshot.Images | ForEach-Object { "$($_.Tag) $($_.Manifest) $($_.Config)" } | Sort-Object)
    if (($before -join "`n") -cne ($after -join "`n")) { throw 'Retained image identities differ.' }
    $beforeContainers = @($Plan.PreservedContainers | ForEach-Object { "$($_.Id) $($_.Image) $($_.Status)" } | Sort-Object)
    $afterContainers = @($Snapshot.Containers | ForEach-Object { "$($_.Id) $($_.Image) $($_.Status)" } | Sort-Object)
    if (($beforeContainers -join "`n") -cne ($afterContainers -join "`n")) { throw 'Retained container identities differ.' }
    if ((@($Plan.CacheMounts | Sort-Object) -join "`n") -cne (@($Snapshot.CacheMounts | Sort-Object) -join "`n")) { throw 'Compiler cache identities differ.' }
}

Export-ModuleMember -Function Get-DelegatedRetirementPlan, Assert-DelegatedPreservation
