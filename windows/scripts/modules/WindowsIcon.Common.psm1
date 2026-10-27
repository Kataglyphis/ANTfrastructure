#requires -Version 7.0
# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'WindowsMsix.Common.psm1') -DisableNameChecking -ErrorAction Stop

function ConvertTo-PythonAppIcon {
    <#
    .SYNOPSIS
        Wraps a PNG as a one-image .ico, which MSI shortcuts and Add/Remove Programs need; Windows reads PNG frames.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PngPath,
        [Parameter(Mandatory)][string]$Destination
    )

    $png = [IO.File]::ReadAllBytes($PngPath)
    if ($png.Length -lt 24 -or [Text.Encoding]::ASCII.GetString($png, 1, 3) -cne 'PNG') { throw "$PngPath is not a PNG" }
    # IHDR's width and height are big-endian; an .ico entry stores 256 as 0.
    $width = ([int]$png[16] -shl 24) -bor ([int]$png[17] -shl 16) -bor ([int]$png[18] -shl 8) -bor [int]$png[19]
    $height = ([int]$png[20] -shl 24) -bor ([int]$png[21] -shl 16) -bor ([int]$png[22] -shl 8) -bor [int]$png[23]
    if ($width -lt 1 -or $height -lt 1 -or $width -gt 256 -or $height -gt 256) { throw "$PngPath is ${width}x${height}; an .ico image must be 1x1 to 256x256" }
    $decoded = Read-MsixLogo -Path $PngPath
    $decoded.Dispose()
    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
    $writer.Write([byte]($width % 256)); $writer.Write([byte]($height % 256)); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$png.Length); $writer.Write([uint32]22)
    $writer.Write($png)
    $writer.Flush()
    [IO.File]::WriteAllBytes($Destination, $stream.ToArray())
    return $Destination
}


# The resource file is linked into each launcher, so shell shortcuts and Explorer use the project icon.
function New-WindowsIconResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PngPath,
        [Parameter(Mandatory)][string]$WorkDir,
        [string]$ResourceCompiler = 'llvm-rc'
    )
    $png = (Resolve-Path -LiteralPath $PngPath -ErrorAction Stop).Path
    $compiler = (Get-Command -Name $ResourceCompiler -CommandType Application -ErrorAction Stop).Source
    if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { New-Item -ItemType Directory -Path $WorkDir -Force -ErrorAction Stop | Out-Null }
    $directory = (Resolve-Path -LiteralPath $WorkDir -ErrorAction Stop).Path
    $name = 'app-icon-' + [Guid]::NewGuid().ToString('N')
    $ico = Join-Path $directory "$name.ico"
    $source = Join-Path $directory "$name.rc"
    $resource = Join-Path $directory "$name.res"
    $pushed = $false
    $completed = $false
    try {
        $null = ConvertTo-PythonAppIcon -PngPath $png -Destination $ico
        [IO.File]::WriteAllText($source, "1 ICON `"$name.ico`"`n", [Text.Encoding]::ASCII)
        Push-Location -LiteralPath $directory -ErrorAction Stop
        $pushed = $true
        & $compiler /fo "$name.res" "$name.rc"
        $status = $LASTEXITCODE
        if ($status -ne 0) { throw "Icon resource compiler failed with exit $status" }
        if (-not (Test-Path -LiteralPath $resource -PathType Leaf) -or (Get-Item -LiteralPath $resource).Length -eq 0) {
            throw "Icon resource compiler produced no resource: $resource"
        }
        $completed = $true
    } finally {
        if ($pushed) { Pop-Location }
        foreach ($temporary in @($ico, $source)) {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop }
        }
        if (-not $completed -and (Test-Path -LiteralPath $resource)) { Remove-Item -LiteralPath $resource -Force -ErrorAction Stop }
    }
    return $resource
}

Export-ModuleMember -Function ConvertTo-PythonAppIcon, New-WindowsIconResource
