# No pwsh-7 version directive here, deliberately: Dockerfile.base runs this
# script under the initial Windows PowerShell 5.1 SHELL, before pwsh exists in
# the image - this is the script that installs it. The directive would make it
# refuse to start on its own first line. Guarded by
# windows/scripts/tests/Bootstrap.Ps51Compat.Tests.ps1 (backlog #106).

# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
#
# PowerShell 7 (pwsh) bootstrap for Dockerfile.base — runs as the FIRST RUN,
# under Windows PowerShell 5.1 (the Server Core built-in), BEFORE the SHELL is
# switched to pwsh and BEFORE any module is COPY'd. Bind-mounted into the base
# build (backlog #27: was a 1200-char single-line RUN). Keep this WPS-5.1-safe:
# no pwsh-7-only syntax.
#
# A transient download blip used to cost the whole base build, so: three
# attempts with linear backoff, the SHA256 check INSIDE the loop (a truncated /
# HTML body is retried, not thrown on), and the ORIGINAL exception rethrown when
# the retry budget is exhausted.
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
