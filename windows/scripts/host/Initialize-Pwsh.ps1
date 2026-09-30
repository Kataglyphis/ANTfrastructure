# No pwsh-7 version directive and no pwsh-7 syntax: Dockerfile.base runs this under PowerShell 5.1 to install pwsh.

# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
# The hash check sits inside the retry loop, so a truncated or HTML body is retried, not fatal.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

New-Item -Path $env:TEMP_DIR -ItemType Directory -Force | Out-Null
$u = 'https://github.com/PowerShell/PowerShell/releases/download/v' + $env:PWSH_VERSION + '/PowerShell-' + $env:PWSH_VERSION + '-win-x64.zip'
$z = $env:TEMP_DIR + '\pwsh.zip'
$d = 'C:\Program Files\PowerShell\7'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ok = $false
$err = $null
foreach ($attempt in 1..3) {
    try {
        if (Test-Path $z) { Remove-Item $z -Force }
        Invoke-WebRequest -Uri $u -OutFile $z -UseBasicParsing
        if ($env:PWSH_ZIP_SHA256) {
            $h = (Get-FileHash -Algorithm SHA256 -Path $z).Hash
            if ($h -ne $env:PWSH_ZIP_SHA256) { throw ('pwsh zip SHA256 mismatch: expected ' + $env:PWSH_ZIP_SHA256 + ' but got ' + $h) }
        }
        $ok = $true
        break
    } catch {
        $err = $_
        Write-Host ('pwsh download attempt ' + $attempt + ' failed: ' + $_.Exception.Message)
        if ($attempt -lt 3) { Start-Sleep -Seconds (10 * $attempt) }
    }
}
if (-not $ok) { throw $err }
Expand-Archive -Path $z -DestinationPath $d -Force
Remove-Item $z -Force
$mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($mp -notlike '*PowerShell\7*') { [Environment]::SetEnvironmentVariable('Path', $mp + ';' + $d, 'Machine') }
